import AppKit
import CooldownLink
import Foundation

@MainActor
extension PhoneLink {
    // MARK: Sending

    /// Seals a box for each phone (or the ones named) and sends it. Returns the envelope ids.
    @discardableResult
    func send(_ box: LinkBox, to phones: [String]? = nil, ttl: TimeInterval = 600, keep: String? = nil, push: LinkPush?) -> [String] {
        guard let session, let client, let account else { return [] }
        var push = push
        if push != nil { push?.badge = liveCards.filter { !$0.card.actions.filter { $0.input != true }.isEmpty }.count }
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
        let ids = Set(send(.card(card), ttl: 300, push: LinkPush(collapse: card.collapseID, sound: true, level: "active")))
        guard !ids.isEmpty else {
            finishCheck(ok: false, L("Нет связи с сервером Cooldown."))
            return
        }
        checkIDs = ids
        checkCard = card
        AgentActivity.trace("phone: delivery check sent env=\(checkIDs.joined(separator: ","))")
        checkTimer?.cancel()
        checkTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, self.checking, self.checkIDs == ids else { return }
            self.finishCheck(ok: false, L("iPhone не подтвердил уведомление за минуту. Проверьте, что уведомления Cooldown на iPhone включены и у телефона есть интернет."))
        }
    }

    // MARK: Sleep

    func goingToSleep() async {
        let working = ProviderID.agents.flatMap { AgentActivity.shared.working($0) }
        let waiting = AppModel.shared.watches.filter { $0.enabled && ["quota_limited", "waiting_quota", "waiting_reset", "waiting_connection"].contains($0.status) }.count
            + (AgentActivity.spent(.claude) != nil ? ClaudeChatList.shared.entries.count : 0)
        AgentActivity.trace("phone: Mac going to sleep — working \(working.count), waiting \(waiting)")
        guard paired, !working.isEmpty || waiting > 0, let session, let account else { return }
        let what = working.first.map { L("%@ работал над «%@».", $0.provider.displayName, $0.title) }
            ?? L("Ждут сброса лимита: %@.", "\(waiting)")
        let card = LinkCard(key: "mac-sleep", kind: "warning", provider: working.first?.provider.rawValue,
                            title: L("Mac уходит в сон"),
                            body: what + " " + L("Пока он спит, ничего не продолжится и Cooldown ничего не пришлёт."), actions: [])
        // Before sending: a wake that comes while the request is still out takes the card back too.
        sleptAnnounced = true
        // Straight over HTTPS and waited for: the socket may not get to send before the Mac sleeps.
        for peer in account.peers {
            guard let frame = try? session.envelope(.card(card), to: peer.id, ttl: 6 * 3600,
                                                    push: LinkPush(collapse: card.collapseID, sound: true, level: "time-sensitive")) else { continue }
            _ = try? await LinkHTTP.call(account.relay, "POST", "v1/send", token: account.token, body: frame)
        }
        sleptAnnounced = true
        AgentActivity.trace("phone: told the phone the Mac is going to sleep")
    }

    // MARK: Keeping the phone's line to Apple open

    /// On mobile data the iPhone's connection to Apple's push service is closed by the network
    /// when it stays quiet, and iOS opens it again only every ten minutes or so: notifications then
    /// arrive in batches, minutes late (measured: a push every 10 minutes took 1.5–6 minutes to
    /// arrive; one every 3 minutes, under a second and a half). So while something may come — an
    /// agent at work, a card waiting for a press, a limit about to come back — and nobody is at the
    /// Mac, a silent push goes every two and a half minutes (the network closed the line after 3–5 quiet minutes); the phone shows nothing and it is taken off again.

    /// `phoneProbeMinutes` (diagnostics) sends them always, at that interval, for measuring.
    var keepAliveInterval: TimeInterval? {
        let probe = UserDefaults.standard.double(forKey: "phoneProbeMinutes")
        if probe > 0 { return probe * 60 }
        guard Settings.phoneKeepAlive, paired else { return nil }
        let working = ProviderID.agents.contains { !AgentActivity.shared.working($0).isEmpty }
        let waitingPress = liveCards.contains { !$0.card.actions.filter { $0.input != true }.isEmpty }
        let resetSoon = ProviderID.agents.contains { p in AgentActivity.spent(p).map { $0.timeIntervalSinceNow < 15 * 60 } ?? false }
        guard working || waitingPress || resetSoon else { return nil }
        // Only mobile data puts the phone's line to sleep. On Wi-Fi a rare one is enough to notice
        // that it left the Wi-Fi (you went out); on mobile data often enough to keep it awake.
        return phoneOnWiFi ? 600 : 150
    }
    /// The network the phone named with its last confirmation (unknown counts as mobile data).
    var phoneOnWiFi: Bool {
        guard let phoneNet, Date().timeIntervalSince(phoneNet.at) < 15 * 60 else { return false }
        return phoneNet.net.hasPrefix("wifi")
    }

    func keepAliveIfDue() {
        guard let interval = keepAliveInterval, status == .online, Date().timeIntervalSince(lastKeepAlive) > interval,
              devices.contains(where: { $0.confirms ?? false }) else { return }
        lastKeepAlive = Date()
        let card = LinkCard(key: "keepalive", kind: "info", provider: nil, title: "", body: "", actions: [])
        let ids = send(.card(card), ttl: 600, push: LinkPush(background: true))
        for id in ids { keepAliveIDs[id] = Date() }
        AgentActivity.trace("phone: keep-alive sent env=\(ids.joined(separator: ","))")
    }

    func keepAliveAnswered(_ id: String) -> Bool {
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

    func finishCheck(ok: Bool, _ text: String) {
        AgentActivity.trace("phone: delivery check — \(text)")
        checkTimer?.cancel()
        checkTimer = nil
        checking = false
        checkIDs = []
        checkResult = (ok, text)
        // The test notification has done its job: it does not stay on the phone.
        if let card = checkCard {
            checkCard = nil
            _ = send(.resolve(card.key, by: "mac"), ttl: 3600, push: LinkPush(remove: [card.collapseID], silent: true))
        }
    }

    /// Awake again: "Mac уходит в сон" is no longer true.
    func awake() {
        guard paired, sleptAnnounced else { return }
        sleptAnnounced = false
        _ = send(.resolve("mac-sleep", by: "mac"), ttl: 6 * 3600, push: LinkPush(remove: [LinkCard.collapseID("mac-sleep")], silent: true))
    }

    /// The relay says a notification reached the phone, or that it never did.
    func delivered(_ frame: LinkFrame, ok: Bool) {
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
            finishCheck(ok: true, L("Дошло до iPhone за %@ с.", seconds.formatted(.number.precision(.fractionLength(1)).locale(AppLanguage.locale))))
        } else {
            finishCheck(ok: false, L("iPhone не подтвердил уведомление. Проверьте, что уведомления Cooldown на iPhone включены и у телефона есть интернет."))
        }
    }

    /// Nobody at the Mac: cards go to the phone as notifications. At the Mac they only appear in the
    /// phone's app, unless pushes are wanted always. Only real input counts (see Presence).
    /// Reading at the Mac without touching it is still being there: five quiet minutes count as away
    /// (a locked screen or a sleeping display at once).
    var away: Bool { Settings.phoneAlways || rehearsing || Presence.shared.away(after: 300).away }
    var awayReason: String { rehearsing ? "rehearsal" : Settings.phoneAlways ? "always" : Presence.shared.away(after: 300).reason }
    /// Since when you are at the Mac (nil while away). After two minutes there the Live Activity
    /// goes: everything is on the screen in front of you. It comes back when you leave.
    var atMacLongEnough: Bool { !away && presentSince.map { Date().timeIntervalSince($0) > 120 } ?? false }

    /// Checked every few seconds: the moment you leave, what is open goes to the phone and the Live
    /// Activity starts — not at the next half-minute tick.
    func checkPresence() {
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
        // At the Mac the card is already on screen. No notification and no Live Activity unless
        // the person explicitly asked for pushes at the Mac ("phoneAlways" includes it in `away`).
        guard away else { return .none }
        // Things to press: on the Lock Screen in the Live Activity, not as one more notification.
        if Self.liveButtons(card) != nil, Settings.phoneLive, phoneHasLive { return .live }
        // Reference, not news: numbers, summaries and the Mac's own business stay in the app.
        let quiet = ["pace-", "route-tz", "week", "day-", "morning", "project-", "report-", "update", "github-update",
                     "remind-set-", "claude-all-done"]
        if quiet.contains(where: { key.hasPrefix($0) }) && content.kind != .finished { return .none }
        // A nearly spent limit while you are away is worth a normal alert (20 % and 5 % alike),
        // never a time-sensitive one: nothing waits for an answer.
        if key.hasPrefix("low-") { return QuietHours.active ? .alert(sound: false, level: "passive") : .alert(sound: true, level: "active") }
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
    var phoneHasLive: Bool { devices.isEmpty || devices.contains { $0.live ?? false } }

    /// A card was shown on the Mac (or would be): the phone gets it too, with the buttons that make
    /// sense there.
    func forward(_ content: ToastContent) {
        // The Mac's own notes about the phone are not for the phone.
        guard paired, !content.key.hasPrefix("demo"), content.key != "req-example", content.key != "phone-offline",
              !DemoController.shared.active else { return }
        if let old = cards[content.key], old.content == content { return }
        // Tasks Cooldown continued after a reset: one note for all of them, not one each.
        if content.kind == .reset, content.key.hasPrefix("task-") {
            noteResumed(content.title, provider: content.provider)
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


    func noteResumed(_ title: String, provider: ProviderID?) {
        resumed.append((title, provider))
        resumedFlush?.cancel()
        resumedFlush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard let self, !Task.isCancelled, !self.resumed.isEmpty else { return }
            let entries = self.resumed
            self.resumed = []
            let titles = entries.map(\.title)
            let providers = Set(entries.compactMap(\.provider))
            let provider = providers.count == 1 ? providers.first?.rawValue : nil
            let card = LinkCard(key: "resumed-\(Int(Date().timeIntervalSince1970))", kind: "reset", provider: provider,
                                title: L("Cooldown продолжил задач: %@", "\(entries.count)"), body: titles.joined(separator: "\n"), actions: [])
            let push = self.away ? LinkPush(collapse: card.collapseID, sound: false, level: "passive") : nil
            let ids = self.send(.card(card), ttl: 6 * 3600, push: push)
            AgentActivity.trace("phone: card \(card.key) (\(entries.count) resumed) → \(push == nil ? "app only" : "push passive") env=\(ids.joined(separator: ","))")
        }
    }

    /// A card was answered or closed on the Mac: it goes away on the phone as well.
    func hasCard(_ key: String) -> Bool { cards[key].map { ($0.card.expires ?? .distantFuture) > Date() } ?? false }

    /// Cards the phone still shows: one past its time is gone there, so it neither counts on the
    /// badge nor keeps the phone's line awake (a card nobody answered on the Mac stayed here).
    var liveCards: [(content: ToastContent, card: LinkCard, pushed: Bool)] {
        let now = Date()
        return cards.values.filter { ($0.card.expires ?? .distantFuture) > now }
    }

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
        case .restartAgent(let provider): return "restart:" + provider.rawValue
        case .guardExit(let choice, let key): return "guardExit:" + choice.rawValue + ":" + key
        case .guardPause: return "guardPause"
        case .guardCheck: return "guardCheck"
        case .guardResume: return "guardResume"
        case .timeZoneSnooze(let seconds): return "tzSnooze:\(Int(seconds))"
        case .installRelease: return "installRelease"
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
            // Quitting an app on the Mac from afar: Face ID first.
            if case .restartAgent = action { return LinkAction(id: id, title: action.title, style: .normal, auth: true) }
            // Letting work go on past the VPN guard from afar: Face ID too.
            if case .guardPause = action { return LinkAction(id: id, title: action.title, style: .normal, auth: true) }
            // Restarting Cooldown on the Mac from afar: Face ID too.
            if case .installRelease = action { return LinkAction(id: id, title: action.title, style: .primary, auth: true) }
            if case .guardExit(let choice, _) = action {
                return LinkAction(id: id, title: action.title, style: choice == .refuse ? .destructive : .primary, auth: choice != .refuse)
            }
            return LinkAction(id: id, title: action.title, style: .primary)
        }
        for choice in content.choices where choice.role != .open {
            actions.append(LinkAction(id: "choice:" + (content.step.map { "step\($0):" } ?? "") + choice.id, title: choice.title,
                                      style: choice.role == .allow ? .primary : choice.role == .decline ? .destructive : .normal,
                                      // Typed words go to the agent as your message: Face ID, as for "allow".
                                      auth: choice.role == .allow || choice.role == .input, input: choice.role == .input ? true : nil))
        }
        // A finished chat can be answered right from the notification.
        if content.kind == .finished, chat(of: content) != nil {
            actions.append(LinkAction(id: "reply", title: L("Ответить"), auth: true, input: true))
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
}
