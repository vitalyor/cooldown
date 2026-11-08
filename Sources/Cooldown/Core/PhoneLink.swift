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

    @Published var account: LinkAccount?
    @Published var status: LinkClient.Status = .off
    @Published var devices: [LinkDeviceRow] = []
    @Published var invite: PairingInvite?
    @Published var inviteExpires: Date?
    @Published var busy = false
    @Published var message: String?

    /// The last notification the phone confirmed (or that never got confirmed), and the check.
    struct Delivery: Equatable { var ok: Bool; var seconds: Double?; var at: Date }
    @Published var lastDelivery: Delivery?
    /// Recent results, for "how reliable is it": a day's worth, kept across restarts.
    @Published var history: [Delivery] = PhoneLink.loadHistory() {
        didSet {
            let day = Date().addingTimeInterval(-86400)
            if history.contains(where: { $0.at < day }) { history.removeAll { $0.at < day } }
            let rows = history.map { [$0.ok ? 1 : 0, $0.seconds ?? -1, $0.at.timeIntervalSince1970] }
            UserDefaults.standard.set(rows, forKey: "phoneDeliveryHistory")
        }
    }

    static func loadHistory() -> [Delivery] {
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
        seconds < 60 ? L("%@ с", seconds.formatted(.number.precision(.fractionLength(1)).locale(AppLanguage.locale)))
                     : L("%@ мин", (seconds / 60).formatted(.number.precision(.fractionLength(1))))
    }
    @Published var checking = false
    @Published var checkResult: (ok: Bool, text: String)?
    var checkIDs: Set<String> = []
    var checkTimer: Task<Void, Never>?

    let vault = LinkVault()
    var client: LinkClient?
    var session: LinkSession?
    var offer: (code: String, secret: Data)?
    var subscriptions = Set<AnyCancellable>()
    var stateSoon: Task<Void, Never>?
    var lastState: LinkState?

    /// Cards sent to phones by key, so a press there can be checked and carried out here.
    var cards: [String: (content: ToastContent, card: LinkCard, pushed: Bool)] = [:]
    /// Commands already carried out, for a day, so a repeated one does nothing.
    var done: [String: Date] = [:]
    /// Commands that type into Claude, waiting for the Mac to be unlocked (for as long as they live).
    var afterUnlock: [(cmd: LinkCommand, phone: String, at: Date)] = []
    @Published var rehearsing = false
    var keepAliveIDs: [String: Date] = [:]
    var lastKeepAlive = Date.distantPast
    var phoneNet: (net: String, at: Date)?
    var rehearsalSince: Date?
    var wasAway: Bool?
    var presentSince: Date?
    var resumed: [(title: String, provider: ProviderID?)] = []
    var resumedFlush: Task<Void, Never>?
    let launched = Date()
    var launchSettle: Task<Void, Never>?
    var liveCheck: Task<Void, Never>?
    var refreshLive = false

    var liveOn = UserDefaults.standard.bool(forKey: "phoneLiveOn") {
        didSet { UserDefaults.standard.set(liveOn, forKey: "phoneLiveOn") }
    }
    /// What the Live Activity shows, kept across restarts: a restarted Mac updates it instead of
    /// starting a second one.
    /// When the phone's Live Activity was started. iOS ends one by itself after eight hours, without
    /// a word to the Mac, so a long wait (a weekly limit, a long run of work) starts a new one in time.
    var liveStartedAt: Date? = UserDefaults.standard.object(forKey: "phoneLiveStarted") as? Date {
        didSet { UserDefaults.standard.set(liveStartedAt, forKey: "phoneLiveStarted") }
    }
    static let liveRenewAfter: TimeInterval = 7.5 * 3600
    var renewDue: Bool { liveOn && liveStartedAt.map { Date().timeIntervalSince($0) > Self.liveRenewAfter } ?? false }
    var lastLive: LiveState? = UserDefaults.standard.data(forKey: "phoneLastLive").flatMap { try? JSONDecoder().decode(LiveState.self, from: $0) } {
        didSet { UserDefaults.standard.set(lastLive.flatMap { try? JSONEncoder().encode($0) }, forKey: "phoneLastLive") }
    }
    var countdownEnd: Task<Void, Never>?
    /// A second "end" for the Live Activity, a little after the first (see live()).
    var liveEndAgain: Task<Void, Never>?
    /// An agent's stretch of work: since when, and when it was last seen working. Short pauses
    /// between turns do not end it, so the Live Activity does not flicker.
    var streaks: [String: (since: Date, last: Date, count: Int)] = [:]
    var endSent = false

    var paired: Bool { !(account?.peers.isEmpty ?? true) }
    var relay: URL { URL(string: UserDefaults.standard.string(forKey: SettingsKey.phoneRelay) ?? "") ?? Self.defaultRelay }

    init() {
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

    func use(_ saved: LinkAccount) {
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
        if let saved = vault.load() {
            UserDefaults.standard.set(true, forKey: SettingsKey.phoneLink)
            use(saved)
            return
        }
        busy = true
        defer { busy = false }
        struct Registered: Decodable { var space: String; var device: String; var token: String }
        do {
            let name = Host.current().localizedName ?? "Mac"
            let r = try await LinkHTTP.json(Registered.self, relay, "POST", "v1/register", body: ["name": name])
            let key = LinkCrypto.newPrivateKey()
            let saved = LinkAccount(relay: relay, space: r.space, device: r.device, token: r.token, privateKey: key)
            guard vault.save(saved) else {
                UserDefaults.standard.set(false, forKey: SettingsKey.phoneLink)
                message = L("Не удалось сохранить ключ в Связке ключей.")
                return
            }
            UserDefaults.standard.set(true, forKey: SettingsKey.phoneLink)
            use(saved)
        } catch {
            UserDefaults.standard.set(false, forKey: SettingsKey.phoneLink)
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

    var offlineSince: Date?
    var offlineWarned = false

    /// The connection to the relay, logged, and said out loud when it stays down: while it is,
    /// nothing reaches the phone.
    func statusChanged(_ new: LinkClient.Status) {
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
            // A refused WebSocket looks like any dropped connection; this call sees the real 401.
            Task { await refreshDevices() }
        default:
            break
        }
    }

    func checkOffline() {
        guard case .offline(let reason) = status else { return }
        if !offlineWarned, paired, let since = offlineSince, Date().timeIntervalSince(since) > 600 {
                offlineWarned = true
                AgentActivity.trace("phone: relay down for 10 min, warned")
                ToastController.shared.show(ToastContent(key: "phone-offline", kind: .warning, provider: nil,
                    title: L("iPhone не получает уведомления"),
                    body: L("Уже 10 минут нет связи с сервером Cooldown (%@). Пока её нет, карточки и Live Activity до телефона не дойдут.", reason),
                    actions: [.openSettings(.iphone)], life: .sticky))
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

    func paired(_ frame: LinkFrame) {
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
        guard vault.save(account) else {
            message = L("Не удалось сохранить ключ в Связке ключей.")
            return
        }
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

    func forget(_ id: String) {
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
        do {
            let rows = try await LinkHTTP.json(Rows.self, account.relay, "GET", "v1/devices", token: account.token)
            // The relay may still know a phone this Mac has deliberately forgotten (a test
            // device, a replaced phone). Show only devices that are still in this account's peers.
            let peers = Set(account.peers.map(\.id))
            devices = rows.devices.filter { $0.role == "phone" && peers.contains($0.id) }
            // A phone the relay no longer knows was unpaired elsewhere: stop sealing boxes for it.
            let known = Set(rows.devices.map(\.id))
            for peer in account.peers where !known.contains(peer.id) { forget(peer.id) }
        } catch let failure as LinkHTTP.Failure where failure.status == 401 {
            // The relay no longer accepts this Mac (removed elsewhere, or its store was restored).
            // Do not keep showing a dead pairing: start over from a fresh QR code.
            let text = L("Сервер больше не знает этот Mac. Включите Cooldown для iPhone заново.")
            message = text
            await disable()
            offlineWarned = true // the card goes away by itself once the new pairing is online
            ToastController.shared.show(ToastContent(key: "phone-offline", kind: .warning, provider: nil,
                title: L("iPhone не получает уведомления"), body: text, actions: [.openSettings(.iphone)], life: .sticky))
        } catch {}
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
}
