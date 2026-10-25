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
    /// Commands that type into Claude, waiting for the Mac to be unlocked.
    private var afterUnlock: [(cmd: LinkCommand, phone: String)] = []

    private var liveOn = UserDefaults.standard.bool(forKey: "phoneLiveOn") {
        didSet { UserDefaults.standard.set(liveOn, forKey: "phoneLiveOn") }
    }
    private var lastLive: LiveState?
    private var lastLiveSent = Date.distantPast

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
        c.onStatus = { [weak self] status in self?.status = status }
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

    private func send(_ box: LinkBox, to phones: [String]? = nil, ttl: TimeInterval = 600, keep: String? = nil, push: LinkPush?) {
        guard let session, let client, let account else { return }
        for peer in account.peers where phones == nil || phones!.contains(peer.id) {
            var b = box
            if phones == nil && account.peers.count > 1 { b.id = LinkID.make() } // one id per envelope
            guard let frame = try? session.envelope(b, to: peer.id, ttl: ttl, keep: keep, push: push) else { continue }
            client.send(frame)
        }
    }

    /// Nobody at the Mac: cards go to the phone as notifications. At the Mac they only appear in the
    /// phone's app, unless pushes are wanted always.
    private var away: Bool {
        Settings.phoneAlways || ToastController.screenLocked || ToastController.idleSeconds > 120
    }

    /// A card was shown on the Mac (or would be): the phone gets it too, with the buttons that make
    /// sense there.
    func forward(_ content: ToastContent) {
        guard paired, !content.key.hasPrefix("demo"), content.key != "req-example", !DemoController.shared.active else { return }
        if let old = cards[content.key], old.content == content { return }
        let card = Self.card(content)
        let push = away
        cards[content.key] = (content, card, push || (cards[content.key]?.pushed ?? false))
        let level = content.kind == .attention || content.kind == .reset ? "time-sensitive" : "active"
        send(.card(card), ttl: content.life == .sticky ? 12 * 3600 : 2 * 3600,
             push: push ? LinkPush(collapse: card.collapseID, sound: true, level: level) : nil)
        scheduleState()
    }

    /// A card was answered or closed on the Mac: it goes away on the phone as well.
    func resolve(_ key: String, by: String = "mac") {
        guard let item = cards.removeValue(forKey: key) else { return }
        send(.resolve(key, by: by), ttl: 12 * 3600,
             push: item.pushed ? LinkPush(remove: [item.card.collapseID], silent: true) : nil)
        scheduleState()
    }

    static func actionID(_ action: ToastAction) -> String? {
        switch action {
        case .continueClaude(let demo): return demo ? nil : "continue" // a sample card sends nothing
        case .continueClaudeChat: return "continueChat"
        case .continueAllClaude: return "continueAll"
        case .remindBeforeReset: return "remind"
        case .installUpdate, .installRelease: return "update"
        default: return nil // opening something on the Mac means nothing on the phone
        }
    }

    static func card(_ content: ToastContent) -> LinkCard {
        var actions = content.actions.compactMap { action -> LinkAction? in
            guard let id = actionID(action) else { return nil }
            return LinkAction(id: id, title: action.title, style: id.hasPrefix("continue") ? .primary : .normal)
        }
        for choice in content.choices where choice.role != .open {
            actions.append(LinkAction(id: "choice:" + choice.id, title: choice.title,
                                      style: choice.role == .allow ? .primary : choice.role == .decline ? .destructive : .normal,
                                      auth: choice.role == .allow))
        }
        var body = content.body
        if let detail = content.detail, !detail.isEmpty { body = body.isEmpty ? detail : body + "\n" + detail }
        let expires: Date? = content.life == .sticky ? Date().addingTimeInterval(24 * 3600) : Date().addingTimeInterval(2 * 3600)
        return LinkCard(key: content.key, kind: "\(content.kind)", provider: content.provider?.rawValue,
                        title: content.title, body: body, actions: actions, created: Date(), expires: expires)
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
            let content = ToastContent(key: card.key, kind: .info, provider: nil, title: card.title, body: card.body)
            cards[card.key] = (content, card, true)
            send(.card(card), ttl: 3600, push: LinkPush(collapse: card.collapseID, sound: true, level: "active"))
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
        // A minute's tick keeps "stale" and the Live Activity honest when nothing else changes.
        Timer.publish(every: 60, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.scheduleState() }
            .store(in: &subscriptions)
        let center = DistributedNotificationCenter.default()
        center.publisher(for: Notification.Name("com.apple.screenIsUnlocked")).sink { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                self?.runAfterUnlock()
            }
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
        watches += ClaudeChatList.shared.entries.map { e in
            LinkWatch(provider: "claude", id: e.id, title: e.chat.title, state: "waiting_reset",
                      detail: L("После сброса придёт карточка «Продолжить»."), at: model.claude.snapshot?.session?.resetsAt)
        }
        let open = cards.values.map(\.card).filter { ($0.expires ?? .distantFuture) > now }.sorted { $0.created > $1.created }
        let mac = LinkMac(name: Host.current().localizedName ?? "Mac", version: GitHubUpdater.current,
                          locked: ToastController.screenLocked, language: AppLanguage.code)
        let live = liveState(limits: limits, agents: agents, watches: watches, cards: open)
        return LinkState(limits: limits, agents: agents, watches: watches, cards: open, mac: mac, live: live, at: now)
    }

    func publishState(now force: Bool = false) {
        guard paired else { return }
        var state = currentState()
        // Only real changes go out; the time alone is not news.
        if !force, var last = lastState {
            last.at = state.at
            if last == state { return }
        }
        state.at = Date()
        lastState = state
        send(.state(state), ttl: 86400, keep: "state", push: nil)
        live(state)
    }

    // MARK: Live Activity

    /// What the Live Activity should show now, or nil when none is wanted: a limit near its end,
    /// chats waiting for a reset, or a card that asks for a press (its buttons go on the Lock Screen).
    func liveState(limits: [LinkLimit], agents: [LinkAgent], watches: [LinkWatch], cards open: [LinkCard]) -> LiveState? {
        guard Settings.phoneLive else { return nil }
        func limit(_ p: String) -> LiveState.Limit? {
            guard let l = limits.first(where: { $0.provider == p }) else { return nil }
            return .init(session: (l.session ?? 0).rounded(), week: (l.week ?? 0).rounded(), reset: l.sessionReset?.timeIntervalSince1970)
        }
        let codex = limit("codex"), claude = limit("claude")
        let working = agents.filter(\.working).map(\.provider)
        // Waiting means waiting for a limit now: Codex tasks stopped by it, Claude chats while its limit is spent.
        let claudeSpent = AgentActivity.spent(.claude) != nil
        let waiting = watches.filter { $0.provider == "codex" ? ["quota_limited", "waiting_reset"].contains($0.state) : claudeSpent }.count
        let ready = open.filter { $0.kind == "reset" && !$0.actions.isEmpty }.count
        let high = [codex, claude].compactMap { $0?.session }.contains { $0 >= Double(Settings.phoneLiveThreshold) }
        let card = open.first { !$0.actions.isEmpty }.map(Self.liveCard)
        guard high || waiting > 0 || ready > 0 || card != nil else { return nil }
        return LiveState(codex: codex, claude: claude, working: working, waiting: waiting, ready: ready, card: card)
    }

    /// A card for the Lock Screen: a general title by kind, never the chat's name or the command.
    static func liveCard(_ card: LinkCard) -> LiveState.Card {
        let name = card.provider == "codex" ? "Codex" : card.provider == "claude" ? "Claude" : "Cooldown"
        let title: String
        switch card.kind {
        case "attention": title = L("%@ ждёт вашего решения", "\(name)")
        case "reset": title = L("Лимит %@ восстановился", "\(name)")
        case "warning": title = L("Лимит %@ исчерпан", "\(name)")
        default: title = card.provider == nil ? L("Cooldown ждёт нажатия") : L("%@ ждёт вашего решения", "\(name)")
        }
        let buttons = card.actions.prefix(3).map { a in
            LiveState.Button(id: a.id, title: String(a.title.prefix(24)), primary: a.style == .primary,
                             destructive: a.style == .destructive, auth: a.auth)
        }
        return LiveState.Card(id: card.collapseID, kind: card.kind, provider: card.provider, title: title, buttons: Array(buttons))
    }

    private func live(_ state: LinkState) {
        guard let client else { return }
        if var live = state.live {
            live.updated = Date().timeIntervalSince1970
            if !liveOn {
                liveOn = true
                lastLive = live
                lastLiveSent = Date()
                let reason = live.card?.title ?? Self.liveReason(high: true, waiting: live.waiting, ready: live.ready)
                client.send(.live("start", live, alert: LiveAlert(title: "Cooldown", body: reason),
                                  stale: Date().addingTimeInterval(1800), urgent: true))
                return
            }
            // Just started (the Live Activity is running from before): send what it should show now.
            var previous = lastLive ?? LiveState(codex: nil, claude: nil, working: [], waiting: -1, ready: -1)
            previous.updated = live.updated
            guard previous != live else { return }
            // Big moments at once; small ticks at most once a minute.
            let urgent = previous.ready != live.ready || previous.working != live.working || previous.waiting != live.waiting
                || previous.card != live.card
            guard urgent || Date().timeIntervalSince(lastLiveSent) > 60 else { return }
            lastLive = live
            lastLiveSent = Date()
            // A new card that asks for a press is started afresh (in case the last one was swiped
            // away), with a sound; the phone keeps only the newest Live Activity.
            let fresh = live.card != nil && previous.card?.id != live.card?.id
            let alert = fresh ? LiveAlert(title: "Cooldown", body: live.card!.title) : nil
            client.send(.live(fresh ? "start" : "update", live, alert: alert, stale: Date().addingTimeInterval(1800), urgent: urgent))
        } else if liveOn {
            liveOn = false
            let last = lastLive ?? LiveState(codex: nil, claude: nil, working: [], waiting: 0, ready: 0)
            lastLive = nil
            client.send(.live("end", last, dismiss: Date().addingTimeInterval(15 * 60)))
        }
    }

    static func liveReason(high: Bool, waiting: Int, ready: Int) -> String {
        if ready > 0 { return L("Лимит восстановился — можно продолжать") }
        if waiting > 0 { return L("Чаты ждут сброса лимита") }
        return L("Лимит заканчивается")
    }

    // MARK: Receiving

    private func handle(_ frame: LinkFrame) {
        switch frame.t {
        case "ready":
            lastState = nil
            publishState(now: true)
            Task { await refreshDevices() }
        case "paired":
            paired(frame)
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
            Task {
                let result = await run(cmd, from: phone)
                reply(result, to: phone, quiet: cmd.op == .chats || cmd.op == .refresh)
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
        case .cancel:
            let target = cmd.args["cmd"] ?? ""
            let before = afterUnlock.count
            afterUnlock.removeAll { $0.cmd.id == target }
            return before != afterUnlock.count ? ok(L("Отменено.")) : LinkResult(cmd: cmd.id, code: "stale", text: L("Уже выполнено или отменено."))
        case .chats:
            return await chats(cmd)
        case .watch:
            return await watch(cmd, from: phone)
        case .cardAct:
            return await act(cmd, from: phone)
        }
    }

    private func act(_ cmd: LinkCommand, from phone: String) async -> LinkResult {
        var key = cmd.args["key"] ?? "", actionID = cmd.args["action"] ?? ""
        // From a Live Activity button: the card by its opaque id.
        if key.hasPrefix("#"), let found = cards.first(where: { $0.value.card.collapseID == String(key.dropFirst()) }) {
            key = found.key
        }
        // From the Live Activity: the newest card that continues a chat whose limit came back.
        if key == "@ready" {
            let ready = cards.values.filter { $0.content.kind == .reset }.sorted { $0.card.created > $1.card.created }
                .first { $0.card.actions.contains { $0.id.hasPrefix("continue") } }
            guard let ready else {
                return LinkResult(cmd: cmd.id, code: "stale", text: L("Нечего продолжать: карточка уже закрыта."))
            }
            key = ready.content.key
            actionID = ready.card.actions.first { $0.id.hasPrefix("continue") }?.id ?? ""
        }
        guard let item = cards[key] else {
            return LinkResult(cmd: cmd.id, code: "stale", text: L("Уже не актуально: карточку закрыли или ответили на Mac."))
        }
        let content = item.content
        if key.hasPrefix("linkdemo") {
            // A sample card: the press made it all the way here, and nothing is done.
            cards.removeValue(forKey: key)
            send(.resolve(key, by: phone), ttl: 3600, push: LinkPush(remove: [item.card.collapseID], silent: true))
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
        guard let action = content.actions.first(where: { Self.actionID($0) == actionID }) else {
            return LinkResult(cmd: cmd.id, code: "stale", text: L("Уже не актуально."))
        }
        let typesIntoClaude: Bool
        switch action {
        case .continueClaude, .continueClaudeChat, .continueAllClaude: typesIntoClaude = true
        default: typesIntoClaude = false
        }
        if typesIntoClaude && ToastController.screenLocked {
            afterUnlock.append((cmd, phone))
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
            case .remindBeforeReset(let p, let reset):
                ResetReminder.set(p, reset: reset)
                return LinkResult(cmd: cmd.id, code: "ok", text: L("Напомню за 10 минут до сброса."))
            case .installUpdate:
                UpdateWatch.install()
                return LinkResult(cmd: cmd.id, code: "ok", text: L("Cooldown на Mac перезапускается с новой версией."))
            case .installRelease:
                Task { await GitHubUpdater.shared.install() }
                return LinkResult(cmd: cmd.id, code: "ok", text: L("Cooldown на Mac обновляется."))
            default:
                return LinkResult(cmd: cmd.id, code: "unknown", text: L("Это действие доступно только на Mac."))
            }
        } catch {
            return LinkResult(cmd: cmd.id, code: "failed", text: error.localizedDescription)
        }
    }

    private func runAfterUnlock() {
        guard !afterUnlock.isEmpty, !ToastController.screenLocked else { return }
        let waiting = afterUnlock
        afterUnlock = []
        for (cmd, phone) in waiting {
            Task {
                let result: LinkResult
                if cmd.op == .watch {
                    result = await watch(cmd, from: phone)
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
                    afterUnlock.append((cmd, phone))
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
