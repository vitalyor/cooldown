import AppKit
import Combine
import CooldownLink
import Foundation

@MainActor
extension PhoneLink {
    // MARK: State

    func observe() {
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
            Task { @MainActor in
                self?.client?.probe()
                self?.awake()
            }
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

    func scheduleState() {
        guard paired, stateSoon == nil else { return }
        stateSoon = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.stateSoon = nil
            self?.publishState()
        }
    }

    func currentState(now: Date = Date()) -> LinkState {
        let model = AppModel.shared
        let limits: [LinkLimit] = [model.codex, model.claude, model.antigravity].compactMap { store in
            guard let s = store.snapshot else { return nil }
            func used(_ w: LimitWindow?) -> Double? { w.map { $0.isExpired(at: now) ? 0 : $0.usedPercent } }
            return LinkLimit(provider: store.id.rawValue, session: used(s.session), week: used(s.weekly),
                             sessionReset: s.session?.resetsAt, weekReset: s.weekly?.resetsAt,
                             stale: now.timeIntervalSince(s.fetchedAt) > 1800)
        }
        let agents = ProviderID.agents.map { p in
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
        guard paired, !DemoController.shared.active else { return }
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
    func catchUp() {
        guard away, !DemoController.shared.active else { return }
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
        let pressable = open.filter { Self.liveButtons($0) != nil }
            .sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.created > $1.created }
        let items = pressable.prefix(2).map(Self.liveItem)
        var countdowns: [LiveState.Countdown] = []
        for p in ProviderID.agents {
            guard let reset = AgentActivity.spentAndStopped(p) else { continue }
            let waiting = p == .codex
                ? watches.filter { $0.provider == "codex" && ["quota_limited", "waiting_quota", "waiting_reset", "waiting_connection"].contains($0.state) }.count
                : ClaudeChatList.shared.entries.count
            // Only a task that will go on after the reset is worth a Live Activity; the bare countdown
            // stays in the menu bar on the Mac.
            guard waiting > 0 else { continue }
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
        return LiveState.Item(id: card.collapseID, kind: card.kind, provider: card.provider, title: title,
                              buttons: Array((liveButtons(card) ?? []).prefix(3)))
    }

    static func liveButtons(_ card: LinkCard) -> [LiveState.Button]? {
        let actions = card.actions.filter { $0.input != true }
        guard !actions.isEmpty else { return nil }
        var buttons: [LiveState.Button] = []
        for action in actions {
            let title: String
            switch action.id {
            case "continue", "continueChat", "afterReset": title = L("Продолжить")
            case "continueAll": title = L("Продолжить все сейчас")
            case "choice:allow", "choice:accept", "choice:grant": title = L("Разрешить")
            case "choice:allowSession", "choice:acceptForSession", "choice:grantSession": title = L("На всю сессию")
            case "choice:deny", "choice:decline", "choice:elicit:decline": title = L("Отклонить")
            case "choice:cancel": title = L("Отклонить и остановить")
            case "choice:elicit:accept": title = L("Подтвердить")
            default: return nil // Custom answers belong only in the encrypted card.
            }
            buttons.append(LiveState.Button(id: action.id, title: String(title.prefix(26)), primary: action.style == .primary,
                                            destructive: action.style == .destructive, auth: action.auth))
        }
        return buttons
    }

    /// A Live Activity that should be on the phone but did not appear (Live Activities off, iOS's
    /// budget for starts spent, the phone offline): what waits for a press must not be lost, so it
    /// goes as an ordinary notification instead.
    func verifyLive() {
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

    static func sound(for item: LiveState.Item?) -> String {
        switch item?.kind {
        case "attention": return "cd-decision.caf"
        case "reset": return "cd-reset.caf"
        default: return "cd-limit.caf"
        }
    }


    func live(_ state: LinkState) {
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
                // Once more a little later: an end can miss a Live Activity whose token was still on
                // its way to the relay, and one left on the phone keeps counting for hours.
                liveEndAgain?.cancel()
                liveEndAgain = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(90))
                    guard let self, !Task.isCancelled, !self.liveOn, let client = self.client else { return }
                    client.send(.live("end", LiveState(items: []), dismiss: Date()))
                    AgentActivity.trace("phone: live end (again, to be sure)")
                }
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
}
