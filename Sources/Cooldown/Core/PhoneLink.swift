import AppKit
import Combine
import CooldownLink
import CoreImage.CIFilterBuiltins
import Foundation

/// Cooldown in the pocket: sends the state and the cards to paired iPhones over the relay and
/// carries out what is pressed there. The Mac stays the only side that does anything; a phone
/// only asks. See docs/LINK.md.
@MainActor
final class PhoneLink: ObservableObject {
    static let shared = PhoneLink()
    static let defaultRelay = URL(string: "https://cooldown.nolim.cloud")!

    @Published private(set) var account: LinkAccount?
    @Published private(set) var status: LinkClient.Status = .off
    @Published private(set) var devices: [LinkDeviceRow] = []
    @Published private(set) var invite: PairingInvite?
    @Published private(set) var inviteExpires: Date?
    @Published private(set) var busy = false
    @Published var message: String?

    /// The last notification the phone confirmed (or that never got confirmed), and the check.
    struct Delivery: Equatable { var ok: Bool; var seconds: Double?; var at: Date }
    @Published private(set) var lastDelivery: Delivery?
    /// Recent results, for "how reliable is it": a day's worth, kept across restarts.
    @Published private(set) var history: [Delivery] = PhoneLink.loadHistory() {
        didSet {
            let day = Date().addingTimeInterval(-86400)
            if history.contains(where: { $0.at < day }) { history.removeAll { $0.at < day } }
            let rows = history.map { [$0.ok ? 1 : 0, $0.seconds ?? -1, $0.at.timeIntervalSince1970] }
            UserDefaults.standard.set(rows, forKey: "phoneDeliveryHistory")
        }
    }

    private static func loadHistory() -> [Delivery] {
        let rows = UserDefaults.standard.array(forKey: "phoneDeliveryHistory") as? [[Double]] ?? []
        let day = Date().addingTimeInterval(-86400)
        return rows.compactMap { r in
            guard r.count == 3 else { return nil }
            return Delivery(ok: r[0] == 1, seconds: r[1] < 0 ? nil : r[1], at: Date(timeIntervalSince1970: r[2]))
        }.filter { $0.at > day }
    }

    /// "За сутки: 12 из 12 дошли, обычно за 0,4 с, дольше всего — 5,5 мин".
    var historySummary: String? {
        guard !history.isEmpty else { return nil }
        let ok = history.filter(\.ok)
        let times = ok.compactMap(\.seconds).sorted()
        var text = L("За сутки дошло %@ из %@", "\(ok.count)", "\(history.count)")
        if !times.isEmpty {
            text += L(", обычно за %@", Self.span(times[times.count / 2]))
            if let worst = times.last, worst > 10 { text += L(", дольше всего — %@", Self.span(worst)) }
        }
        return text
    }

    /// Several notifications held back for minutes in a day: that is Apple's push service on the
    /// phone's network (mobile networks with restrictions do it), not Cooldown — said in plain words.
    var slowHint: String? {
        let slow = history.filter { $0.ok && ($0.seconds ?? 0) > 60 }.count + history.filter { !$0.ok }.count
        guard slow >= 3 else { return nil }
        return L("Apple доставляет уведомления на этот iPhone с задержкой в минуты. Так бывает на мобильных сетях с ограничениями: телефон подключается к сервису уведомлений Apple только время от времени. Помогает Wi‑Fi или VPN на телефоне.")
    }

    static func span(_ seconds: Double) -> String {
        seconds < 60 ? L("%@ с", seconds.formatted(.number.precision(.fractionLength(1))))
                     : L("%@ мин", (seconds / 60).formatted(.number.precision(.fractionLength(1))))
    }
    @Published private(set) var checking = false
    @Published private(set) var checkResult: (ok: Bool, text: String)?
    private var checkIDs: Set<String> = []

    private let vault = LinkVault()
    private var client: LinkClient?
    private var session: LinkSession?
    private var offer: (code: String, secret: Data)?
    private var subscriptions = Set<AnyCancellable>()
    private var stateSoon: Task<Void, Never>?
    private var lastState: LinkState?

    /// Cards sent to phones by key, so a press there can be checked and carried out here.
    private var cards: [String: (content: ToastContent, card: LinkCard, pushed: Bool)] = [:]
    /// Commands already carried out, for a day, so a repeated one does nothing.
    private var done: [String: Date] = [:]
    /// Commands that type into Claude, waiting for the Mac to be unlocked (for as long as they live).
    private var afterUnlock: [(cmd: LinkCommand, phone: String, at: Date)] = []

    private var liveOn = UserDefaults.standard.bool(forKey: "phoneLiveOn") {
        didSet { UserDefaults.standard.set(liveOn, forKey: "phoneLiveOn") }
    }
    /// What the Live Activity shows, kept across restarts: a restarted Mac updates it instead of
    /// starting a second one.
    /// When the phone's Live Activity was started. iOS ends one by itself after eight hours, without
    /// a word to the Mac, so a long wait (a weekly limit, a long run of work) starts a new one in time.
    private var liveStartedAt: Date? = UserDefaults.standard.object(forKey: "phoneLiveStarted") as? Date {
        didSet { UserDefaults.standard.set(liveStartedAt, forKey: "phoneLiveStarted") }
    }
    private static let liveRenewAfter: TimeInterval = 7.5 * 3600
    private var renewDue: Bool { liveOn && liveStartedAt.map { Date().timeIntervalSince($0) > Self.liveRenewAfter } ?? false }
    private var lastLive: LiveState? = UserDefaults.standard.data(forKey: "phoneLastLive").flatMap { try? JSONDecoder().decode(LiveState.self, from: $0) } {
        didSet { UserDefaults.standard.set(lastLive.flatMap { try? JSONEncoder().encode($0) }, forKey: "phoneLastLive") }
    }
    private var countdownEnd: Task<Void, Never>?
    /// An agent's stretch of work: since when, and when it was last seen working. Short pauses
    /// between turns do not end it, so the Live Activity does not flicker.
    private var streaks: [String: (since: Date, last: Date, count: Int)] = [:]
    private var endSent = false

    var paired: Bool { !(account?.peers.isEmpty ?? true) }
    var relay: URL { URL(string: UserDefaults.standard.string(forKey: SettingsKey.phoneRelay) ?? "") ?? Self.defaultRelay }

    private init() {
        if let saved = UserDefaults.standard.dictionary(forKey: "phoneLinkDone") as? [String: Double] {
            let dayAgo = Date().addingTimeInterval(-86400).timeIntervalSince1970
            done = saved.filter { $0.value > dayAgo }.mapValues { Date(timeIntervalSince1970: $0) }
        }
    }

    // MARK: Lifecycle

    func start() {
        guard Settings.phoneLink, let saved = vault.load() else { return }
        use(saved)
    }

    private func use(_ saved: LinkAccount) {
        account = saved
        session = LinkSession(saved)
        client?.stop()
        let c = LinkClient(relay: saved.relay, token: saved.token)
        c.onStatus = { [weak self] status in self?.statusChanged(status) }
        c.onFrame = { [weak self] frame in self?.handle(frame) }
        client = c
        c.start()
        observe()
        Task { await refreshDevices() }
    }

    /// Turns the link on: registers this Mac at the relay the first time.
    func enable() async {
        UserDefaults.standard.set(true, forKey: SettingsKey.phoneLink)
        if let saved = vault.load() { use(saved); return }
        busy = true
        defer { busy = false }
        struct Registered: Decodable { var space: String; var device: String; var token: String }
        do {
            let name = Host.current().localizedName ?? "Mac"
            let r = try await LinkHTTP.json(Registered.self, relay, "POST", "v1/register", body: ["name": name])
            let key = LinkCrypto.newPrivateKey()
            let saved = LinkAccount(relay: relay, space: r.space, device: r.device, token: r.token, privateKey: key)
            guard vault.save(saved) else { message = L("Не удалось сохранить ключ в Связке ключей."); return }
            use(saved)
        } catch {
            message = L("Сервер Cooldown недоступен: %@", "\(error.localizedDescription)")
        }
    }

    /// Turns the link off and forgets this Mac at the relay, with all its phones.
    func disable() async {
        UserDefaults.standard.set(false, forKey: SettingsKey.phoneLink)
        if let account {
            _ = try? await LinkHTTP.call(account.relay, "DELETE", "v1/devices/\(account.device)", token: account.token)
        }
        client?.stop()
        client = nil
        session = nil
        vault.delete()
        account = nil
        devices = []
        invite = nil
        cards = [:]
        liveOn = false
        status = .off
    }

    private var offlineSince: Date?
    private var offlineWarned = false

    /// The connection to the relay, logged, and said out loud when it stays down: while it is,
    /// nothing reaches the phone.
    private func statusChanged(_ new: LinkClient.Status) {
        let old = status
        status = new
        switch new {
        case .online:
            if let since = offlineSince, Date().timeIntervalSince(since) > 30 {
                AgentActivity.trace("phone: relay back after \(Int(Date().timeIntervalSince(since))) s")
            }
            if offlineWarned {
                ToastController.shared.dismiss(key: "phone-offline")
                EventLog.shared.add(CooldownEvent(kind: .info, provider: nil, title: L("Связь с iPhone восстановлена"), body: ""))
            }
            offlineSince = nil
            offlineWarned = false
        case .offline(let reason):
            if case .offline = old {} else { AgentActivity.trace("phone: relay unreachable — \(reason)") }
            if offlineSince == nil { offlineSince = Date() }
            checkOffline()
        default:
            break
        }
    }

    private func checkOffline() {
        guard case .offline(let reason) = status else { return }
        if !offlineWarned, paired, let since = offlineSince, Date().timeIntervalSince(since) > 600 {
                offlineWarned = true
                AgentActivity.trace("phone: relay down for 10 min, warned")
                ToastController.shared.show(ToastContent(key: "phone-offline", kind: .warning, provider: nil,
                    title: L("iPhone не получает уведомления"),
                    body: L("Уже 10 минут нет связи с сервером Cooldown (%@). Пока её нет, карточки и Live Activity до телефона не дойдут.", reason),
                    actions: [.openPanel], life: .sticky))
                EventLog.shared.add(CooldownEvent(kind: .info, provider: nil, title: L("iPhone не получает уведомления"), body: reason))
        }
    }

    // MARK: Pairing

    /// A fresh QR code for adding a phone, valid for 5 minutes.
    func makeInvite() async {
        guard let account else { return }
        busy = true
        defer { busy = false }
        let code = LinkCrypto.random(16).base64URL
        let secret = LinkCrypto.random(32)
        do {
            _ = try await LinkHTTP.call(account.relay, "POST", "v1/pair/offer", token: account.token, body: ["code": code])
            offer = (code, secret)
            invite = PairingInvite(relay: account.relay, code: code, secret: secret, macKey: account.publicKey,
                                   macName: Host.current().localizedName ?? "Mac")
            inviteExpires = Date().addingTimeInterval(300)
            message = nil
        } catch {
            message = L("Сервер Cooldown недоступен: %@", "\(error.localizedDescription)")
        }
    }

    func cancelInvite() {
        invite = nil
        offer = nil
    }

    private func paired(_ frame: LinkFrame) {
        guard var account, let device = frame.device, let sealed = frame.hello else { return }
        client?.got(["pair-" + device])
        guard let offer, let hello = try? LinkCrypto.openHello(sealed, secret: offer.secret, code: offer.code) else {
            // Not a phone that saw this Mac's QR code: it doesn't get in.
            Task { _ = try? await LinkHTTP.call(account.relay, "DELETE", "v1/devices/\(device)", token: account.token) }
            message = L("Отклонено подключение устройства, которое не сканировало QR-код.")
            return
        }
        account.peers.removeAll { $0.id == device }
        account.peers.append(LinkPeer(id: device, name: hello.name, key: hello.key))
        vault.save(account)
        self.account = account
        session?.update(account)
        self.offer = nil
        invite = nil
        message = L("Подключено: %@", "\(hello.name)")
        EventLog.shared.add(CooldownEvent(kind: .info, provider: nil, title: L("Подключено: %@", "\(hello.name)"),
                                          body: L("Карточки и лимиты теперь приходят и на него.")))
        lastState = nil
        publishState(now: true)
        for item in cards.values { send(.card(item.card), push: nil) }
        Task { await refreshDevices() }
    }

    func unpair(_ id: String) async {
        guard let account else { return }
        _ = try? await LinkHTTP.call(account.relay, "DELETE", "v1/devices/\(id)", token: account.token)
        forget(id)
    }

    private func forget(_ id: String) {
        guard var account else { return }
        account.peers.removeAll { $0.id == id }
        vault.save(account)
        self.account = account
        session?.update(account)
        devices.removeAll { $0.id == id }
    }

    func refreshDevices() async {
        guard let account else { return }
        struct Rows: Decodable { var devices: [LinkDeviceRow] }
        if let rows = try? await LinkHTTP.json(Rows.self, account.relay, "GET", "v1/devices", token: account.token) {
            devices = rows.devices.filter { $0.role == "phone" }
            // A phone the relay no longer knows was unpaired elsewhere: stop sealing boxes for it.
            let known = Set(rows.devices.map(\.id))
            for peer in account.peers where !known.contains(peer.id) { forget(peer.id) }
        }
    }

    static func qr(_ url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Sending

    /// Seals a box for each phone (or the ones named) and sends it. Returns the envelope ids.
    @discardableResult
    private func send(_ box: LinkBox, to phones: [String]? = nil, ttl: TimeInterval = 600, keep: String? = nil, push: LinkPush?) -> [String] {
        guard let session, let client, let account else { return [] }
        var push = push
        if push != nil { push?.badge = cards.values.filter { !$0.card.actions.filter { $0.input != true }.isEmpty }.count }
        var ids: [String] = []
        for peer in account.peers where phones == nil || phones!.contains(peer.id) {
            var b = box
            if phones == nil && account.peers.count > 1 { b.id = LinkID.make() } // one id per envelope
            guard let frame = try? session.envelope(b, to: peer.id, ttl: ttl, keep: keep, push: push) else { continue }
            client.send(frame)
            if let id = frame.id { ids.append(id) }
        }
        return ids
    }

    // MARK: Delivery check

    /// Sends a notification to the phone and waits for it to say it arrived.
    func checkDelivery() {
        guard paired, !checking else { return }
        checking = true
        checkResult = nil
        let card = LinkCard(key: "linkcheck-\(Int(Date().timeIntervalSince1970))", kind: "info", provider: nil,
                            title: L("Проверка связи"), body: L("Уведомления с этого Mac доходят до iPhone."), actions: [])
        checkIDs = Set(send(.card(card), ttl: 300, push: LinkPush(collapse: card.collapseID, sound: true, level: "active")))
        AgentActivity.trace("phone: delivery check sent env=\(checkIDs.joined(separator: ","))")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, self.checking else { return }
            self.finishCheck(ok: false, L("iPhone не подтвердил уведомление за минуту. Проверьте, что уведомления Cooldown на iPhone включены и у телефона есть интернет."))
        }
    }

    // MARK: Sleep

    private func goingToSleep() async {
        let working = ProviderID.allCases.flatMap { AgentActivity.shared.working($0) }
        let waiting = AppModel.shared.watches.filter { $0.enabled && ["quota_limited", "waiting_reset", "waiting_connection"].contains($0.status) }.count
            + (AgentActivity.spent(.claude) != nil ? ClaudeChatList.shared.entries.count : 0)
        AgentActivity.trace("phone: Mac going to sleep — working \(working.count), waiting \(waiting)")
        guard paired, !working.isEmpty || waiting > 0, let session, let account else { return }
        let what = working.first.map { L("%@ работал над «%@».", $0.provider.displayName, $0.title) }
            ?? L("Ждут сброса лимита: %@.", "\(waiting)")
        let card = LinkCard(key: "mac-sleep", kind: "warning", provider: working.first?.provider.rawValue,
                            title: L("Mac уходит в сон"),
                            body: what + " " + L("Пока он спит, ничего не продолжится и Cooldown ничего не пришлёт."), actions: [])
        // Straight over HTTPS and waited for: the socket may not get to send before the Mac sleeps.
        for peer in account.peers {
            guard let frame = try? session.envelope(.card(card), to: peer.id, ttl: 6 * 3600,
                                                    push: LinkPush(collapse: card.collapseID, sound: true, level: "time-sensitive")) else { continue }
            _ = try? await LinkHTTP.call(account.relay, "POST", "v1/send", token: account.token, body: frame)
        }
        AgentActivity.trace("phone: told the phone the Mac is going to sleep")
    }

    // MARK: Keeping the phone's line to Apple open

    /// On mobile data the iPhone's connection to Apple's push service is closed by the network
    /// when it stays quiet, and iOS opens it again only every ten minutes or so: notifications then
    /// arrive in batches, minutes late (measured: a push every 10 minutes took 1.5–6 minutes to
    /// arrive; one every 3 minutes, under a second and a half). So while something may come — an
    /// agent at work, a card waiting for a press, a limit about to come back — and nobody is at the
    /// Mac, a silent push goes every two and a half minutes (the network closed the line after 3–5 quiet minutes); the phone shows nothing and it is taken off again.
    private var keepAliveIDs: [String: Date] = [:]
    private var lastKeepAlive = Date.distantPast

    /// `phoneProbeMinutes` (diagnostics) sends them always, at that interval, for measuring.
    private var keepAliveInterval: TimeInterval? {
        let probe = UserDefaults.standard.double(forKey: "phoneProbeMinutes")
        if probe > 0 { return probe * 60 }
        guard Settings.phoneKeepAlive, paired else { return nil }
        let working = ProviderID.allCases.contains { !AgentActivity.shared.working($0).isEmpty }
        let waitingPress = cards.values.contains { !$0.card.actions.filter { $0.input != true }.isEmpty }
        let resetSoon = ProviderID.allCases.contains { p in AgentActivity.spent(p).map { $0.timeIntervalSinceNow < 15 * 60 } ?? false }
        guard working || waitingPress || resetSoon else { return nil }
        // Only mobile data puts the phone's line to sleep. On Wi-Fi a rare one is enough to notice
        // that it left the Wi-Fi (you went out); on mobile data often enough to keep it awake.
        return phoneOnWiFi ? 600 : 150
    }
    /// The network the phone named with its last confirmation (unknown counts as mobile data).
    private var phoneNet: (net: String, at: Date)?
    private var phoneOnWiFi: Bool {
        guard let phoneNet, Date().timeIntervalSince(phoneNet.at) < 15 * 60 else { return false }
        return phoneNet.net.hasPrefix("wifi")
    }

    private func keepAliveIfDue() {
        guard let interval = keepAliveInterval, status == .online, Date().timeIntervalSince(lastKeepAlive) > interval,
              devices.contains(where: { $0.confirms ?? false }) else { return }
        lastKeepAlive = Date()
        let card = LinkCard(key: "keepalive", kind: "info", provider: nil, title: "", body: "", actions: [])
        let ids = send(.card(card), ttl: 600, push: LinkPush(collapse: card.collapseID, sound: false, level: "passive", urgent: true))
        for id in ids { keepAliveIDs[id] = Date() }
        AgentActivity.trace("phone: keep-alive sent env=\(ids.joined(separator: ","))")
    }

    private func keepAliveAnswered(_ id: String) -> Bool {
        guard keepAliveIDs.removeValue(forKey: id) != nil else { return false }
        keepAliveIDs = keepAliveIDs.filter { Date().timeIntervalSince($0.value) < 3600 }
        // Off the phone again: it only kept the line open.
        send(.resolve("keepalive", by: "mac"), ttl: 600, push: LinkPush(remove: [LinkCard.collapseID("keepalive")], silent: true))
        return true
    }

    // MARK: Rehearsal

    /// A full run on the phone, as if an agent worked while you were away: the Live Activity shows
    /// "at work" with its timer, then the "done" notification comes and the Live Activity closes.
    /// Nothing runs on the Mac; it only shows the way there and back works.
    @Published private(set) var rehearsing = false
    private var rehearsalSince: Date?

    func rehearse(seconds: Double = 40) {
        guard paired, !rehearsing else { return }
        rehearsing = true
        rehearsalSince = Date()
        AgentActivity.trace("phone: rehearsal started")
        publishState(now: true)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.rehearsing else { return }
            self.rehearsalSince = nil
            let content = ToastContent(key: "rehearsal-\(Int(Date().timeIntervalSince1970))", kind: .finished, provider: nil,
                                       title: L("Проверка: задача готова"),
                                       body: L("Так приходит «готово», когда агент закончил, а вас нет у Mac. Live Activity при этом закрывается."))
            self.forward(content)
            self.publishState(now: true)
            try? await Task.sleep(for: .seconds(5))
            self.rehearsing = false
            self.publishState()
            AgentActivity.trace("phone: rehearsal finished")
        }
    }

    private func finishCheck(ok: Bool, _ text: String) {
        AgentActivity.trace("phone: delivery check — \(text)")
        checking = false
        checkIDs = []
        checkResult = (ok, text)
    }

    /// The relay says a notification reached the phone, or that it never did.
    private func delivered(_ frame: LinkFrame, ok: Bool) {
        let seconds = frame.ms.map { Double($0) / 1000 }
        let keepAlive = frame.id.map { keepAliveAnswered($0) } ?? false
        if ok, let net = frame.net {
            if phoneNet?.net != net { AgentActivity.trace("phone: on \(net)") }
            phoneNet = (net, Date())
        }
        AgentActivity.trace(ok ? "phone: push confirmed in \(frame.ms ?? 0) ms\(keepAlive ? " (keep-alive)" : "")"
                               : "phone: push \(frame.id ?? "") never confirmed\(keepAlive ? " (keep-alive)" : "")")
        // The summary is about real news; the line-keeping pushes would only drown it.
        guard !keepAlive else { return }
        // A real push just got through: the line is open, the next keep-alive can wait.
        if ok { lastKeepAlive = Date() }
        lastDelivery = Delivery(ok: ok, seconds: seconds, at: Date())
        history.append(Delivery(ok: ok, seconds: seconds, at: Date()))
        guard let id = frame.id, checkIDs.contains(id) else { return }
        if ok, let seconds {
            finishCheck(ok: true, L("Дошло до iPhone за %@ с.", seconds.formatted(.number.precision(.fractionLength(1)))))
        } else {
            finishCheck(ok: false, L("iPhone не подтвердил уведомление. Проверьте, что уведомления Cooldown на iPhone включены и у телефона есть интернет."))
        }
    }

    /// Nobody at the Mac: cards go to the phone as notifications. At the Mac they only appear in the
    /// phone's app, unless pushes are wanted always. Only real input counts (see Presence).
    /// Reading at the Mac without touching it is still being there: five quiet minutes count as away
    /// (a locked screen or a sleeping display at once).
    private var away: Bool { Settings.phoneAlways || rehearsing || Presence.shared.away(after: 300).away }
    private var awayReason: String { rehearsing ? "rehearsal" : Settings.phoneAlways ? "always" : Presence.shared.away(after: 300).reason }
    private var wasAway: Bool?
    /// Since when you are at the Mac (nil while away). After two minutes there the Live Activity
    /// goes: everything is on the screen in front of you. It comes back when you leave.
    private var presentSince: Date?
    private var atMacLongEnough: Bool { !away && presentSince.map { Date().timeIntervalSince($0) > 120 } ?? false }

    /// Checked every few seconds: the moment you leave, what is open goes to the phone and the Live
    /// Activity starts — not at the next half-minute tick.
    private func checkPresence() {
        checkOffline()
        keepAliveIfDue()
        if liveOn, atMacLongEnough { publishState() }
        if renewDue, status == .online { publishState() }
        let now = away
        // At the Mac already when Cooldown starts: nothing for the Lock Screen from the first look.
        if now { presentSince = nil } else if presentSince == nil { presentSince = wasAway == nil ? .distantPast : Date() }
        guard now != wasAway else { return }
        if wasAway != nil { AgentActivity.trace("phone: \(now ? "away" : "back at the Mac") — \(awayReason)") }
        wasAway = now
        publishState()
    }

    /// How a card reaches the phone. The phone interrupts only when something is wanted from you
    /// or something changed that you would act on; the rest is there in the app, quietly.
    enum Route: Equatable { case live, alert(sound: Bool, level: String), none }

    func delivery(_ content: ToastContent, card: LinkCard, away: Bool) -> Route {
        let key = content.key
        // Things to press: on the Lock Screen in the Live Activity, not as one more notification.
        if !card.actions.filter({ $0.input != true }).isEmpty, Settings.phoneLive, phoneHasLive { return .live }
        guard away else { return .none }
        // Reference, not news: numbers, summaries and the Mac's own business stay in the app.
        let quiet = ["low-", "pace-", "week", "day-", "morning", "project-", "report-", "update", "github-update",
                     "remind-set-", "claude-all-done"]
        if quiet.contains(where: { key.hasPrefix($0) }) && content.kind != .attention && content.kind != .finished { return .none }
        // "Waits for the reset": the Live Activity counts that down already.
        if content.kind == .waiting { return .none }
        // Night: only an agent that needs an answer is worth waking for.
        if QuietHours.active && content.kind != .attention { return .alert(sound: false, level: "passive") }
        switch content.kind {
        case .attention: return .alert(sound: true, level: "time-sensitive")
        case .reset: return .alert(sound: false, level: "passive")   // back without anything waiting
        default: return .alert(sound: true, level: "active")
        }
    }

    /// Whether a paired phone can show a Live Activity the Mac starts (it said where to send one).
    private var phoneHasLive: Bool { devices.isEmpty || devices.contains { $0.live ?? false } }

    /// A card was shown on the Mac (or would be): the phone gets it too, with the buttons that make
    /// sense there.
    func forward(_ content: ToastContent) {
        // The Mac's own notes about the phone are not for the phone.
        guard paired, !content.key.hasPrefix("demo"), content.key != "req-example", content.key != "phone-offline",
              !DemoController.shared.active else { return }
        if let old = cards[content.key], old.content == content { return }
        // Tasks Cooldown continued after a reset: one note for all of them, not one each.
        if content.kind == .reset, content.key.hasPrefix("task-") {
            noteResumed(content.title)
            return
        }
        // The agent stopped: its "working" leaves the Live Activity now, not after the pause allowance.
        if let p = content.provider?.rawValue, content.kind == .finished || content.key.hasPrefix("out-") {
            streaks[p] = nil
        }
        let card = Self.card(content)
        let how = delivery(content, card: card, away: away)
        var push: LinkPush?
        if case .alert(let sound, let level) = how { push = LinkPush(collapse: card.collapseID, sound: sound, level: level) }
        // The same card again with new words (a countdown, a progress line): the notification is
        // replaced quietly, it does not ring a second time.
        if let old = cards[content.key], old.pushed, old.content.kind == content.kind, push != nil,
           Date().timeIntervalSince(old.card.created) < 600, content.kind != .finished {
            push = LinkPush(collapse: card.collapseID, sound: false, level: "passive")
        }
        cards[content.key] = (content, card, push != nil || (cards[content.key]?.pushed ?? false))
        let ids = send(.card(card), ttl: content.life == .sticky ? 12 * 3600 : 2 * 3600, push: push)
        AgentActivity.trace("phone: card \(content.key) → \(Self.describe(how)) (\(awayReason)) env=\(ids.joined(separator: ","))")
        scheduleState()
    }

    static func describe(_ route: Route) -> String {
        switch route {
        case .live: return "live activity"
        case .alert(let sound, let level): return "push \(level)\(sound ? "" : " silent")"
        case .none: return "app only"
        }
    }

    private var resumed: [String] = []
    private var resumedFlush: Task<Void, Never>?

    private func noteResumed(_ title: String) {
        resumed.append(title)
        resumedFlush?.cancel()
        resumedFlush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard let self, !Task.isCancelled, !self.resumed.isEmpty else { return }
            let titles = self.resumed
            self.resumed = []
            let card = LinkCard(key: "resumed-\(Int(Date().timeIntervalSince1970))", kind: "reset", provider: "codex",
                                title: L("Cooldown продолжил задач: %@", "\(titles.count)"), body: titles.joined(separator: "\n"), actions: [])
            let push = self.away ? LinkPush(collapse: card.collapseID, sound: false, level: "passive") : nil
            let ids = self.send(.card(card), ttl: 6 * 3600, push: push)
            AgentActivity.trace("phone: card \(card.key) (\(titles.count) resumed) → \(push == nil ? "app only" : "push passive") env=\(ids.joined(separator: ","))")
        }
    }

    /// A card was answered or closed on the Mac: it goes away on the phone as well.
    func resolve(_ key: String, by: String = "mac") {
        ClaudeChatList.shared.cardClosed(key)
        guard let item = cards.removeValue(forKey: key) else { return }
        send(.resolve(key, by: by), ttl: 12 * 3600,
             push: item.pushed ? LinkPush(remove: [item.card.collapseID], silent: true) : nil)
        scheduleState()
    }

    /// The buttons a phone gets. Opening things on the Mac, reminders (the Live Activity counts
    /// down by itself) and updating the Mac app stay on the Mac.
    static func actionID(_ action: ToastAction) -> String? {
        switch action {
        case .continueClaude(let demo): return demo ? nil : "continue" // a sample card sends nothing
        case .continueClaudeChat: return "continueChat"
        case .continueAllClaude: return "continueAll"
        case .continueAfterReset: return "afterReset"
        default: return nil
        }
    }

    /// The chat a card is about, when it names one: where "Ответить" sends to.
    static func chat(of content: ToastContent) -> AgentActivity.Opener? {
        for action in content.actions {
            switch action {
            case .openCodexThread(let id): return .codexThread(id)
            case .openClaudeChat(let chat): return .claudeChat(chat)
            case .continueAfterReset(let opener): return opener
            default: continue
            }
        }
        return nil
    }

    static let maxBody = 600

    static func card(_ content: ToastContent) -> LinkCard {
        var actions = content.actions.compactMap { action -> LinkAction? in
            guard let id = actionID(action) else { return nil }
            return LinkAction(id: id, title: action.title, style: .primary)
        }
        for choice in content.choices where choice.role != .open {
            actions.append(LinkAction(id: "choice:" + choice.id, title: choice.title,
                                      style: choice.role == .allow ? .primary : choice.role == .decline ? .destructive : .normal,
                                      auth: choice.role == .allow))
        }
        // A finished chat can be answered right from the notification.
        if content.kind == .finished, chat(of: content) != nil {
            actions.append(LinkAction(id: "reply", title: L("Ответить"), input: true))
        }
        var body = content.body
        if let detail = content.detail, !detail.isEmpty { body = body.isEmpty ? detail : body + "\n" + detail }
        // Small enough to travel inside the push itself: the phone then shows it with no network
        // request of its own, which on a restricted mobile network may never get through.
        if body.count > Self.maxBody { body = String(body.prefix(Self.maxBody - 1)) + "…" }
        let expires: Date? = content.life == .sticky ? Date().addingTimeInterval(24 * 3600) : Date().addingTimeInterval(2 * 3600)
        return LinkCard(key: content.key, kind: "\(content.kind)", provider: content.provider?.rawValue,
                        title: String(content.title.prefix(160)), body: body, actions: actions, created: Date(), expires: expires)
    }

    /// Two sample cards with buttons, straight to the phones (not shown on the Mac): a request
    /// and a limit that came back. Pressing them goes the whole way and does nothing.
    func sendSamples() {
        let samples = [
            LinkCard(key: "linkdemo-request", kind: "attention", provider: "codex", title: L("Codex хочет выполнить команду"),
                     body: L("Пример · ничего не отправлено") + "\nswift test --filter ParserTests", // l10n:skip
                     actions: [LinkAction(id: "choice:allow", title: L("Разрешить"), style: .primary, auth: true),
                               LinkAction(id: "choice:decline", title: L("Отклонить"), style: .destructive)]),
            LinkCard(key: "linkdemo-reset", kind: "reset", provider: "claude", title: L("Лимит Claude восстановился"),
                     body: L("Пример · ничего не отправлено"),
                     actions: [LinkAction(id: "continue", title: L("Продолжить"), style: .primary)]),
        ]
        for card in samples {
            let content = ToastContent(key: card.key, kind: card.kind == "reset" ? .reset : .attention, provider: nil,
                                       title: card.title, body: card.body)
            // Like real cards with buttons: on the Lock Screen in the Live Activity, no extra notification.
            cards[card.key] = (content, card, false)
            send(.card(card), ttl: 3600, push: nil)
        }
        scheduleState()
    }

    // MARK: State

    private func observe() {
        guard subscriptions.isEmpty else { return }
        let model = AppModel.shared
        let changes: [AnyPublisher<Void, Never>] = [
            model.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            model.codex.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            model.claude.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            AgentActivity.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            ClaudeChatList.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes).sink { [weak self] in self?.scheduleState() }.store(in: &subscriptions)
        Timer.publish(every: 5, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.checkPresence() }
            .store(in: &subscriptions)
        // A half-minute tick keeps "stale" and the Live Activity honest when nothing else changes.
        Timer.publish(every: 30, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.scheduleState() }
            .store(in: &subscriptions)
        let center = DistributedNotificationCenter.default()
        center.publisher(for: Notification.Name("com.apple.screenIsUnlocked")).sink { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                self?.runAfterUnlock()
            }
        }.store(in: &subscriptions)
        // `Проверить доставку` from outside the app (support, scripts): same as the button.
        center.publisher(for: Notification.Name("com.vitalyor.cooldown.check-delivery")).sink { [weak self] _ in
            Task { @MainActor in self?.checkDelivery() }
        }.store(in: &subscriptions)
        // The Mac is about to sleep while agents work or tasks wait: nothing will go on until it
        // wakes, and from the phone that looks just like "all quiet". Say so before it goes.
        // Awake again: the connection from before the sleep is most likely dead; find out now.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor in self?.client?.probe() }
        }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification).sink { [weak self] _ in
            Task { @MainActor in await self?.goingToSleep() }
        }.store(in: &subscriptions)
        center.publisher(for: Notification.Name("com.vitalyor.cooldown.rehearse")).sink { [weak self] _ in
            Task { @MainActor in self?.rehearse() }
        }.store(in: &subscriptions)
        center.publisher(for: Notification.Name("com.apple.screenIsLocked")).sink { [weak self] _ in
            self?.scheduleState()
        }.store(in: &subscriptions)
    }

    private func scheduleState() {
        guard paired, stateSoon == nil else { return }
        stateSoon = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.stateSoon = nil
            self?.publishState()
        }
    }

    func currentState(now: Date = Date()) -> LinkState {
        let model = AppModel.shared
        let limits: [LinkLimit] = [model.codex, model.claude].compactMap { store in
            guard let s = store.snapshot else { return nil }
            func used(_ w: LimitWindow?) -> Double? { w.map { $0.isExpired(at: now) ? 0 : $0.usedPercent } }
            return LinkLimit(provider: store.id.rawValue, session: used(s.session), week: used(s.weekly),
                             sessionReset: s.session?.resetsAt, weekReset: s.weekly?.resetsAt,
                             stale: now.timeIntervalSince(s.fetchedAt) > 1800)
        }
        let agents = ProviderID.allCases.map { p in
            let working = AgentActivity.shared.working(p)
            return LinkAgent(provider: p.rawValue, working: !working.isEmpty, since: working.map(\.started).min())
        }
        var watches = model.watches.filter(\.enabled).map { w in
            LinkWatch(provider: "codex", id: w.threadId, title: model.knownTitle(w.threadId) ?? L("Без названия"),
                      state: w.status, detail: w.reason, resumes: w.attempts, max: w.maxResumes)
        }
        // A chosen Claude chat waits only while the limit is spent; otherwise it is just looked after.
        let claudeReset = AgentActivity.spent(.claude, now: now)
        watches += ClaudeChatList.shared.entries.map { e in
            LinkWatch(provider: "claude", id: e.id, title: e.chat.title, state: claudeReset != nil ? "waiting_reset" : "watching",
                      detail: claudeReset != nil ? L("После сброса придёт карточка «Продолжить».")
                                                 : L("Упрётся в лимит — после сброса придёт карточка «Продолжить»."),
                      at: claudeReset)
        }
        cards = cards.filter { ($0.value.card.expires ?? .distantFuture) > now }
        let open = cards.values.map(\.card).sorted { $0.created > $1.created }
        let mac = LinkMac(name: Host.current().localizedName ?? "Mac", version: GitHubUpdater.current,
                          locked: ToastController.screenLocked, language: AppLanguage.code)
        // At the Mac for a while: nothing for the Lock Screen (it comes back when you leave). Sent as
        // "no Live Activity", so a phone whose one was missed by the end push closes it too.
        let live = atMacLongEnough ? nil : liveState(limits: limits, agents: agents, watches: watches, cards: open)
        return LinkState(limits: limits, agents: agents, watches: watches, cards: open, mac: mac, live: live, at: now)
    }

    func publishState(now force: Bool = false) {
        guard paired else { return }
        catchUp()
        var state = currentState()
        // Only real changes go out; the time alone is not news.
        if !force, var last = lastState {
            last.at = state.at
            // The same state; the Live Activity may still need to start (you just left the Mac).
            if last == state { live(last); return }
        }
        state.at = Date()
        lastState = state
        send(.state(state), ttl: 86400, keep: "state", push: nil)
        live(state)
    }

    /// News that came while you were still at the Mac and is still open when you leave: the phone
    /// gets it then, instead of never.
    private func catchUp() {
        guard away else { return }
        let now = Date()
        for (key, item) in cards where !item.pushed && now.timeIntervalSince(item.card.created) < 600 {
            guard case .alert(let sound, let level) = delivery(item.content, card: item.card, away: true) else { continue }
            cards[key] = (item.content, item.card, true)
            let ids = send(.card(item.card), ttl: 2 * 3600, push: LinkPush(collapse: item.card.collapseID, sound: sound, level: level))
            AgentActivity.trace("phone: card \(key) → push \(level) after you left (\(awayReason)) env=\(ids.joined(separator: ","))")
        }
    }

    // MARK: Live Activity

    /// What the Live Activity shows now, or nil when nothing matters: up to two things waiting for a
    /// press (most urgent first) and when spent limits come back.
    func liveState(limits: [LinkLimit], agents: [LinkAgent], watches: [LinkWatch], cards open: [LinkCard]) -> LiveState? {
        guard Settings.phoneLive else { return nil }
        func rank(_ card: LinkCard) -> Int {
            switch card.kind {
            case "attention": return 0
            case "reset": return 1
            case "warning": return 2
            default: return 3
            }
        }
        let pressable = open.filter { !$0.actions.filter { $0.input != true }.isEmpty }
            .sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.created > $1.created }
        let items = pressable.prefix(2).map(Self.liveItem)
        var countdowns: [LiveState.Countdown] = []
        for p in ProviderID.allCases {
            guard let reset = AgentActivity.spent(p) else { continue }
            let waiting = p == .codex
                ? watches.filter { $0.provider == "codex" && ["quota_limited", "waiting_reset", "waiting_connection"].contains($0.state) }.count
                : ClaudeChatList.shared.entries.count
            countdowns.append(.init(provider: p.rawValue, until: reset.timeIntervalSince1970, waiting: waiting))
        }
        countdowns.sort { $0.until < $1.until }
        // An older iPhone app would show an empty Live Activity for work alone.
        let live = LiveState(items: Array(items), more: max(0, pressable.count - 2), countdowns: countdowns,
                             working: devices.contains { $0.confirms ?? false } ? work(agents) : nil)
        return live.isEmpty ? nil : live
    }

    /// Who is working right now, for the Live Activity: one stretch per agent, pauses up to 45
    /// seconds between turns included (a finished turn's card ends it at once, see forward).
    func work(_ agents: [LinkAgent], now: Date = Date()) -> [LiveState.Work]? {
        for agent in agents {
            guard agent.working, let since = agent.since, let p = ProviderID(rawValue: agent.provider) else { continue }
            let count = max(1, AgentActivity.shared.working(p).count)
            if let old = streaks[agent.provider], now.timeIntervalSince(old.last) < 45 {
                streaks[agent.provider] = (old.since, now, count)
            } else {
                streaks[agent.provider] = (since, now, count)
            }
        }
        streaks = streaks.filter { now.timeIntervalSince($0.value.last) < 45 }
        var work = streaks.map { LiveState.Work(provider: $0.key, since: $0.value.since.timeIntervalSince1970, count: $0.value.count) }
            .sorted { $0.since < $1.since }
        if let since = rehearsalSince { work.insert(LiveState.Work(provider: "cooldown", since: since.timeIntervalSince1970, count: 1), at: 0) }
        return work.isEmpty ? nil : work
    }

    /// A card for the Lock Screen: a general title, never the chat's name or the command.
    static func liveItem(_ card: LinkCard) -> LiveState.Item {
        let name = card.provider == "codex" ? "Codex" : card.provider == "claude" ? "Claude" : "Cooldown"
        let key = card.key
        let title: String
        if key.hasPrefix("low-") {
            title = L("%@ скоро упрётся в лимит", "\(name)")
        } else if key.hasPrefix("out-") {
            title = L("%@ упёрся в лимит", "\(name)")
        } else if card.kind == "reset" {
            title = L("Лимит %@ восстановился", "\(name)")
        } else if card.kind == "attention" {
            title = L("%@ ждёт вашего решения", "\(name)")
        } else {
            title = card.provider == nil ? L("Cooldown ждёт нажатия") : L("%@ ждёт вашего решения", "\(name)")
        }
        let buttons = card.actions.filter { $0.input != true }.prefix(3).map { a in
            LiveState.Button(id: a.id, title: String(a.title.prefix(26)), primary: a.style == .primary,
                             destructive: a.style == .destructive, auth: a.auth)
        }
        return LiveState.Item(id: card.collapseID, kind: card.kind, provider: card.provider, title: title, buttons: Array(buttons))
    }

    /// A Live Activity that should be on the phone but did not appear (Live Activities off, iOS's
    /// budget for starts spent, the phone offline): what waits for a press must not be lost, so it
    /// goes as an ordinary notification instead.
    private func verifyLive() {
        liveCheck?.cancel()
        liveCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard let self, !Task.isCancelled, self.liveOn, let live = self.lastLive, !live.items.isEmpty else { return }
            await self.refreshDevices()
            let phones = self.devices.filter { $0.confirms ?? false }
            guard !phones.isEmpty, phones.allSatisfy({ ($0.activities ?? 0) == 0 }) else { return }
            for item in live.items {
                guard let (key, entry) = self.cards.first(where: { $0.value.card.collapseID == item.id }), !entry.pushed else { continue }
                self.cards[key] = (entry.content, entry.card, true)
                let level = entry.content.kind == .attention ? "time-sensitive" : "active"
                let ids = self.send(.card(entry.card), ttl: 2 * 3600, push: LinkPush(collapse: entry.card.collapseID, sound: true, level: level))
                AgentActivity.trace("phone: live activity did not appear — \(key) sent as a notification env=\(ids.joined(separator: ","))")
            }
        }
    }

    static func providerName(_ id: String?) -> String {
        id == "codex" ? "Codex" : id == "claude" ? "Claude" : "Cooldown"
    }

    private static func sound(for item: LiveState.Item?) -> String {
        switch item?.kind {
        case "attention": return "cd-decision.caf"
        case "reset": return "cd-reset.caf"
        default: return "cd-limit.caf"
        }
    }

    private let launched = Date()
    private var launchSettle: Task<Void, Never>?
    private var liveCheck: Task<Void, Never>?
    private var refreshLive = false

    private func live(_ state: LinkState) {
        guard let client else { return }
        // Just started: the limits and the agents are not read yet, so "nothing to show" is not to
        // be believed. A Live Activity from before the restart is left alone until they are.
        let age = Date().timeIntervalSince(launched)
        if age < 12 || (state.live == nil && age < 25) {
            if launchSettle == nil {
                launchSettle = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(26))
                    self?.publishState()
                }
            }
            return
        }
        guard var live = state.live else {
            // Also once per connection: a Live Activity the Mac lost track of (a restart) goes too.
            if liveOn || !endSent {
                endSent = true
                liveOn = false
                lastLive = nil
                liveStartedAt = nil
                // Nothing left to press or wait for: gone at once.
                client.send(.live("end", LiveState(items: []), dismiss: Date()))
                AgentActivity.trace("phone: live end\(atMacLongEnough ? " — you are at the Mac" : "")")
            }
            return
        }
        live.updated = Date().timeIntervalSince1970
        // When a countdown runs out, look again: the limit is back and the countdown goes.
        countdownEnd?.cancel()
        if let next = live.countdowns.map(\.until).min() {
            let wait = max(1, next - Date().timeIntervalSince1970 + 3)
            countdownEnd = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self?.publishState()
            }
        }
        var previous = lastLive
        previous?.updated = live.updated
        // After a reconnect it goes again even if unchanged: the relay may have marked it out of date.
        if liveOn, previous == live, !refreshLive, !renewDue { return }
        refreshLive = false
        let newItem = live.items.first { item in !(previous?.items.contains { $0.id == item.id } ?? false) }
        let newCountdown = live.countdowns.first { c in !(previous?.countdowns.contains { $0.provider == c.provider } ?? false) }
        // At the Mac the cards are in front of you: no Live Activity is started then, only kept current.
        if !liveOn && !away { return }
        let renew = renewDue
        let fresh = !liveOn || newItem != nil || newCountdown != nil || renew
        var alert: LiveAlert?
        if fresh && away && !renew {
            if let body = newItem?.title ?? newCountdown.map({ c in
                L("%@: снова можно в %@", "\(c.provider == "codex" ? "Codex" : "Claude")", "\(Format.clock(Date(timeIntervalSince1970: c.until)))")
            }) {
                // A countdown is not news to ring about: only something to press makes a sound.
                alert = LiveAlert(title: "Cooldown", body: body, sound: newItem == nil || (QuietHours.active && newItem?.kind != "attention") ? nil : Self.sound(for: newItem))
            } else if let w = live.working?.first {
                // Only "at work": shown without a sound, it is not news by itself.
                alert = LiveAlert(title: "Cooldown", body: L("%@ работает", Self.providerName(w.provider)))
            }
        }
        liveOn = true
        lastLive = live
        if fresh || liveStartedAt == nil { liveStartedAt = Date() }
        // Something new starts afresh (in case the last one was swiped away); the phone keeps one.
        // iOS gives each app a budget of high-priority updates: spend it on what you would act on
        // (something to press, an alert); timers and counts go at normal priority.
        let urgent = fresh || alert != nil || live.items.map(\.id) != (previous?.items.map(\.id) ?? [])
        client.send(.live(fresh ? "start" : "update", live, alert: alert, stale: Date().addingTimeInterval(1800), urgent: urgent))
        if fresh, !live.items.isEmpty { verifyLive() }
        AgentActivity.trace("phone: live \(renew ? "renew" : fresh ? "start" : "update") items=\(live.items.map(\.kind)) work=\((live.working ?? []).map(\.provider)) countdowns=\(live.countdowns.map(\.provider))\(alert.map { " alert «\($0.body)»" } ?? "")")
    }

    // MARK: Receiving

    private func handle(_ frame: LinkFrame) {
        switch frame.t {
        case "ready":
            lastState = nil
            endSent = false
            refreshLive = true
            publishState(now: true)
            Task { await refreshDevices() }
        case "paired":
            paired(frame)
        case "error":
            AgentActivity.trace("phone: relay refused env=\(frame.id ?? "") — \(frame.code ?? "") \(frame.text ?? "")")
        case "delivered":
            delivered(frame, ok: true)
        case "undelivered":
            delivered(frame, ok: false)
        case "presence":
            if frame.online == true { lastState = nil; publishState(now: true) }
            Task { await refreshDevices() }
        case "unpaired":
            if frame.device == account?.device {
                // Removed at the relay (from another Mac or by the server): start over.
                Task { await disable() }
            } else if let id = frame.device {
                forget(id)
            }
        case "env":
            guard let session, let id = frame.id else { return }
            client?.got([id])
            guard let box = try? session.open(frame), let from = frame.from else { return }
            receive(box, from: from)
        default:
            break
        }
    }

    private func receive(_ box: LinkBox, from phone: String) {
        switch box.m {
        case .cmd:
            guard let cmd = box.cmd else { return }
            if done[cmd.id] != nil { return }
            if box.ts.addingTimeInterval(cmd.ttl) < Date() {
                reply(LinkResult(cmd: cmd.id, code: "stale", text: L("Команда устарела и не выполнена.")), to: phone)
                return
            }
            remember(cmd.id)
            AgentActivity.trace("phone \(phone): \(cmd.op.rawValue) \(cmd.args.filter { $0.key != "text" && $0.key != "log" })")
            Task {
                let result = await run(cmd, from: phone)
                AgentActivity.trace("phone \(phone): \(cmd.op.rawValue) → \(result.code)\(result.code == "ok" ? "" : " «\(String(result.text.prefix(160)))»")")
                // A press that worked needs no notification: the card simply goes away.
                reply(result, to: phone, quiet: cmd.op == .chats || cmd.op == .refresh || cmd.op == .diag || (cmd.op == .cardAct && result.ok))
                scheduleState()
            }
        case .resolve:
            // Closed on the phone: closed here too.
            if let key = box.key {
                cards.removeValue(forKey: key)
                ToastController.shared.dismiss(key: key)
            }
        default:
            break
        }
    }

    private func remember(_ id: String) {
        done[id] = Date()
        let dayAgo = Date().addingTimeInterval(-86400)
        done = done.filter { $0.value > dayAgo }
        UserDefaults.standard.set(done.mapValues(\.timeIntervalSince1970), forKey: "phoneLinkDone")
    }

    /// The answer to a press goes back as a quiet notification, so a press from the lock screen
    /// gets its outcome even with the app closed. Lists and refreshes need none.
    private func reply(_ result: LinkResult, to phone: String, quiet: Bool = false) {
        let push = quiet || result.text.isEmpty ? nil
            : LinkPush(collapse: LinkCard.collapseID("result-" + result.cmd), sound: !result.ok, level: result.ok ? "passive" : "active")
        send(.result(result), to: [phone], ttl: 3600, push: push)
    }

    private func phoneName(_ id: String) -> String { account?.peers.first { $0.id == id }?.name ?? "iPhone" }

    private func note(_ phone: String, _ what: String, provider: ProviderID? = nil) {
        EventLog.shared.add(CooldownEvent(kind: .info, provider: provider, title: L("С %@: %@", "\(phoneName(phone))", "\(what)"), body: ""))
    }

    // MARK: Commands

    private func run(_ cmd: LinkCommand, from phone: String) async -> LinkResult {
        let ok = { (text: String) in LinkResult(cmd: cmd.id, code: "ok", text: text) }
        switch cmd.op {
        case .refresh:
            lastState = nil
            publishState(now: true)
            return ok("")
        case .chats:
            return await chats(cmd)
        case .watch:
            return await watch(cmd, from: phone)
        case .cardAct:
            return await act(cmd, from: phone)
        case .diag:
            // The phone's own delivery log: what arrived when, so delivery can be checked end to end.
            let url = Settings.appSupport.appendingPathComponent("phone-delivery.log")
            let text = (cmd.args["log"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let block = "— \(phoneName(phone)), \(Date().formatted(.iso8601))\n\(text)\n"
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile(); handle.write(Data(block.utf8)); try? handle.close()
                } else {
                    try? Data(block.utf8).write(to: url)
                }
            }
            return ok("")
        }
    }

    private func act(_ cmd: LinkCommand, from phone: String) async -> LinkResult {
        var key = cmd.args["key"] ?? ""
        let actionID = cmd.args["action"] ?? ""
        // From a Live Activity button: the card by its opaque id.
        if key.hasPrefix("#"), let found = cards.first(where: { $0.value.card.collapseID == String(key.dropFirst()) }) {
            key = found.key
        }
        guard let item = cards[key] else {
            return LinkResult(cmd: cmd.id, code: "stale", text: L("Уже не актуально: карточку закрыли или ответили на Mac."))
        }
        let content = item.content
        if key.hasPrefix("linkdemo") {
            // A sample card: the press made it all the way here, and nothing is done.
            resolve(key, by: phone)
            return LinkResult(cmd: cmd.id, code: "ok", text: L("Пример · ничего не отправлено"))
        }
        if actionID.hasPrefix("choice:") {
            let choiceID = String(actionID.dropFirst("choice:".count))
            guard let requestKey = content.requestKey, RequestCenter.shared.isPending(requestKey),
                  let choice = content.choices.first(where: { $0.id == choiceID }) else {
                return LinkResult(cmd: cmd.id, code: "stale", text: L("Уже не актуально: агент больше не ждёт ответа."))
            }
            note(phone, L("ответ «%@»", "\(choice.title)"), provider: content.provider)
            RequestCenter.shared.answer(requestKey, choice)
            if choice.id.hasPrefix("option:") { return LinkResult(cmd: cmd.id, code: "ok", text: L("Принято.")) }
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                if !RequestCenter.shared.isPending(requestKey) {
                    return LinkResult(cmd: cmd.id, code: "ok", text: L("Ответ отправлен: «%@».", "\(choice.title)"))
                }
            }
            return LinkResult(cmd: cmd.id, code: "failed", text: L("Ответ не дошёл. Откройте чат на Mac и ответьте там."))
        }
        if actionID == "reply" {
            let text = (cmd.args["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let opener = Self.chat(of: content) else {
                return LinkResult(cmd: cmd.id, code: "failed", text: L("Пустой ответ не отправлен."))
            }
            return await replyText(text, to: opener, cmd: cmd, phone: phone, key: key)
        }
        guard let action = content.actions.first(where: { Self.actionID($0) == actionID }) else {
            return LinkResult(cmd: cmd.id, code: "stale", text: L("Уже не актуально."))
        }
        let typesIntoClaude: Bool
        switch action {
        case .continueClaude, .continueClaudeChat, .continueAllClaude: typesIntoClaude = true
        default: typesIntoClaude = false
        }
        // Answered from the phone: the Mac does not bring the same card up again later.
        ClaudeChatList.shared.cardClosed(key)
        if typesIntoClaude && ToastController.screenLocked {
            afterUnlock.append((cmd, phone, Date()))
            note(phone, L("«%@» — после разблокировки", "\(action.title)"), provider: content.provider)
            return LinkResult(cmd: cmd.id, code: "locked", text: L("Mac заблокирован. Отправлю, как только его разблокируют."))
        }
        return await perform(action, key: key, cmd: cmd, phone: phone)
    }

    private func perform(_ action: ToastAction, key: String, cmd: LinkCommand, phone: String) async -> LinkResult {
        let provider = cards[key]?.content.provider
        ToastController.shared.dismiss(key: key) // also takes it off every phone
        note(phone, action.title, provider: provider)
        do {
            switch action {
            case .continueClaude:
                let chat = ClaudeSender.pendingChat
                try await ClaudeSender.continueChat(chat)
                return LinkResult(cmd: cmd.id, code: "ok", text: chat.map { L("Отправлено в «%@».", "\($0.title)") } ?? L("Отправлено в открытый чат Claude."))
            case .continueClaudeChat(let chat):
                try await ClaudeSender.continueChat(chat)
                return LinkResult(cmd: cmd.id, code: "ok", text: L("Отправлено в «%@».", "\(chat.title)"))
            case .continueAllClaude(let chats):
                Task { await ClaudeChatList.shared.continueAll(chats) }
                return LinkResult(cmd: cmd.id, code: "ok", text: L("Продолжаю чаты по очереди: %@.", "\(chats.count)"))
            case .continueAfterReset(let opener):
                let text = await AgentActivity.continueAfterReset(opener)
                return LinkResult(cmd: cmd.id, code: "ok", text: text)
            default:
                return LinkResult(cmd: cmd.id, code: "unknown", text: L("Это действие доступно только на Mac."))
            }
        } catch {
            return LinkResult(cmd: cmd.id, code: "failed", text: error.localizedDescription)
        }
    }

    /// "Ответить": the text goes into the chat the card is about. Codex takes it through its own
    /// connection (works with the Mac locked); Claude needs the Mac unlocked, as it is typed in.
    private func replyText(_ text: String, to opener: AgentActivity.Opener, cmd: LinkCommand, phone: String, key: String) async -> LinkResult {
        switch opener {
        case .codexThread(let id):
            do {
                try await AutoResume.shared.reply(id, text: text)
                ToastController.shared.dismiss(key: key)
                note(phone, L("ответ в Codex"), provider: .codex)
                return LinkResult(cmd: cmd.id, code: "ok", text: L("Отправлено в Codex."))
            } catch {
                return LinkResult(cmd: cmd.id, code: "failed", text: ResumeError.friendly(error))
            }
        case .claudeChat(let chat):
            if ToastController.screenLocked {
                afterUnlock.append((cmd, phone, Date()))
                return LinkResult(cmd: cmd.id, code: "locked", text: L("Mac заблокирован. Отправлю, как только его разблокируют."))
            }
            do {
                try await ClaudeSender.send(text, to: chat)
                ToastController.shared.dismiss(key: key)
                note(phone, L("ответ в «%@»", "\(chat.title)"), provider: .claude)
                return LinkResult(cmd: cmd.id, code: "ok", text: L("Отправлено в «%@».", "\(chat.title)"))
            } catch {
                return LinkResult(cmd: cmd.id, code: "failed", text: error.localizedDescription)
            }
        default:
            return LinkResult(cmd: cmd.id, code: "failed", text: L("Это действие доступно только на Mac."))
        }
    }

    private func runAfterUnlock() {
        guard !afterUnlock.isEmpty, !ToastController.screenLocked else { return }
        let waiting = afterUnlock.filter { Date().timeIntervalSince($0.at) < $0.cmd.ttl }
        afterUnlock = []
        for (cmd, phone, _) in waiting {
            Task {
                let result: LinkResult
                if cmd.op == .watch {
                    result = await watch(cmd, from: phone)
                } else if cmd.args["action"] == "reply", let item = cards[cmd.args["key"] ?? ""], let opener = Self.chat(of: item.content) {
                    result = await replyText(cmd.args["text"] ?? "", to: opener, cmd: cmd, phone: phone, key: cmd.args["key"] ?? "")
                } else if let item = cards[cmd.args["key"] ?? ""],
                          let action = item.content.actions.first(where: { Self.actionID($0) == cmd.args["action"] }) {
                    result = await perform(action, key: cmd.args["key"] ?? "", cmd: cmd, phone: phone)
                } else {
                    result = LinkResult(cmd: cmd.id, code: "stale", text: L("Уже не актуально."))
                }
                reply(result, to: phone)
            }
        }
    }

    private func chats(_ cmd: LinkCommand) async -> LinkResult {
        let model = AppModel.shared
        if cmd.args["provider"] == "claude" {
            let list = ClaudeChatList.shared
            list.refreshAvailable()
            for _ in 0..<30 where list.loadingAvailable { try? await Task.sleep(for: .milliseconds(500)) }
            let watched = Set(list.entries.map(\.id))
            var rows = list.entries.map { LinkChat(provider: "claude", id: $0.id, title: $0.chat.title, watched: true, updated: $0.chat.seen) }
            for known in list.available.prefix(60) {
                let id = known.chat.id.isEmpty ? known.chat.title : known.chat.id
                guard !watched.contains(id), !rows.contains(where: { $0.title == known.chat.title }) else { continue }
                rows.append(LinkChat(provider: "claude", id: id, title: known.chat.title, subtitle: known.project, updated: known.updated))
            }
            return LinkResult(cmd: cmd.id, code: "ok", text: "", chats: rows)
        }
        await model.loadThreads(force: true, maxAge: 30)
        if let error = model.threadsError, model.threads.isEmpty {
            return LinkResult(cmd: cmd.id, code: "failed", text: error)
        }
        let watches = Dictionary(model.watches.map { ($0.threadId, $0) }, uniquingKeysWith: { a, _ in a })
        let rows = model.threads.filter { !$0.archived }.prefix(60).map { t in
            LinkChat(provider: "codex", id: t.id, title: t.title, subtitle: t.cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                     state: watches[t.id]?.status, watched: watches[t.id]?.enabled ?? false, updated: t.updatedAt)
        }
        return LinkResult(cmd: cmd.id, code: "ok", text: "", chats: Array(rows))
    }

    private func watch(_ cmd: LinkCommand, from phone: String) async -> LinkResult {
        let id = cmd.args["id"] ?? "", mode = cmd.args["mode"] ?? "reset", title = cmd.args["title"] ?? ""
        let ok = { (text: String) in LinkResult(cmd: cmd.id, code: "ok", text: text) }
        if cmd.args["provider"] == "claude" {
            let list = ClaudeChatList.shared
            let chat = ClaudeChat(id: id == title ? "" : id, title: title)
            switch mode {
            case "stop":
                for entry in list.entries where entry.id == id || entry.chat.title == title { list.remove(entry) }
                note(phone, L("не ждать «%@»", "\(title)"), provider: .claude)
                return ok(L("«%@» больше не ждёт сброса.", "\(title)"))
            case "now":
                if ToastController.screenLocked {
                    afterUnlock.append((cmd, phone, Date()))
                    return LinkResult(cmd: cmd.id, code: "locked", text: L("Mac заблокирован. Отправлю, как только его разблокируют."))
                }
                note(phone, L("продолжить «%@»", "\(title)"), provider: .claude)
                do {
                    try await ClaudeSender.continueChat(chat)
                    return ok(L("Отправлено в «%@».", "\(title)"))
                } catch {
                    return LinkResult(cmd: cmd.id, code: "failed", text: error.localizedDescription)
                }
            default:
                list.add(chat)
                note(phone, L("ждать сброса: «%@»", "\(title)"), provider: .claude)
                return ok(L("После сброса лимита придёт карточка «Продолжить» для «%@».", "\(title)"))
            }
        }
        let model = AppModel.shared
        do {
            switch mode {
            case "stop":
                try await model.stopTask(id)
                note(phone, L("не отслеживать «%@»", "\(title)"), provider: .codex)
                return ok(L("«%@» больше не отслеживается.", "\(title)"))
            default:
                try await model.startTask(id, maxResumes: Int(cmd.args["max"] ?? "") ?? 2)
                if mode == "now" { AutoResume.shared.poke(id, after: 0) }
                note(phone, L("отслеживать «%@»", "\(title)"), provider: .codex)
                return ok(mode == "now" ? L("Cooldown продолжит «%@», как только Codex сможет.", "\(title)")
                                        : L("«%@» продолжится сам после сброса лимита.", "\(title)"))
            }
        } catch {
            return LinkResult(cmd: cmd.id, code: "failed", text: ResumeError.friendly(error))
        }
    }
}
