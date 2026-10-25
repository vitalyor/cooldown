import AppKit
import Foundation

/// Codex auto-continue. For each conversation the person chose, Cooldown looks at the live
/// state in the Codex app; when the current turn failed because the usage limit ran out, it
/// waits until a fresh reading of the limits says work can go on and then starts one new turn
/// with a short continuation message. Every look runs on one serial queue; the stored data is
/// the single source of truth, so switching a watch off takes effect even during a look.
final class AutoResume: @unchecked Sendable {
    static let shared = AutoResume()

    /// Called on the main thread after every change of any watch.
    @MainActor var onChange: (([ResumeWatch]) -> Void)?

    private let store: ResumeStore
    private let queue = DispatchQueue(label: "cooldown.auto-continue", qos: .utility)
    private var started = false

    // Owned by `queue`.
    private var timers: [String: (item: DispatchWorkItem, at: Date)] = [:]
    private var failures: [String: Int] = [:]
    private var lastOpened: [String: Date] = [:]

    // Read from any thread.
    private let shownLock = NSLock()
    private var shown: [ResumeWatch] = []
    /// Watches another Cooldown copy is running: shown as blocked here, storage left alone.
    private var foreign: [String: String] = [:]

    init(store: ResumeStore = .shared) { self.store = store }

    // MARK: Interface

    func start() {
        guard !started else { return }
        started = true
        listenToWorkspace()
        queue.async { self.boot() }
    }

    /// The Mac waking up and the Codex app starting or quitting are moments to look again.
    private func listenToWorkspace() {
        let workspaceEvents = NSWorkspace.shared.notificationCenter
        workspaceEvents.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            AutoResume.shared.pokeAll(after: 10)
        }
        for (name, delay) in [(NSWorkspace.didLaunchApplicationNotification, 6.0), (NSWorkspace.didTerminateApplicationNotification, 2.0)] {
            workspaceEvents.addObserver(forName: name, object: nil, queue: nil) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                // A launched app needs a few seconds to open its socket.
                if app?.bundleIdentifier == CodexApp.bundleId { AutoResume.shared.pokeAll(after: delay) }
            }
        }
    }

    func watches() async -> [ResumeWatch] {
        await quietly { (try? self.store.load()).map(self.rows) ?? self.current() }
    }

    func conversations() async throws -> [CodexConversation] {
        try await offMain {
            if let list = CodexThreadIndex.conversations() { return list }
            let official = try CodexOfficial()
            defer { official.close() }
            return try official.listThreads(archived: false).compactMap { row in
                guard let id = (row["id"] as? String)?.lowercased() else { return nil }
                return CodexConversation(id: id, name: row["name"] as? String, preview: row["preview"] as? String,
                                         cwd: row["cwd"] as? String, updatedAt: Num.date(row["updatedAt"]), archived: false)
            }
        }
    }

    func check(_ id: String) async throws -> ResumeCheck {
        try await offMain { try Self.examine(id).check }
    }

    func start(_ raw: String, maxResumes: Int) async throws {
        try await offMain {
            let (check, latest) = try Self.examine(raw)
            try Self.requireWatchable(check)
            let id = check.threadId
            let limit = min(10, max(1, maxResumes))
            try self.store.update { data in
                if let refusal = ResumeRules.startRefusal(data, thread: id, maxResumes: limit, latestTurn: latest) {
                    throw ResumeError.refused(refusal)
                }
                // The conversation moved past an unconfirmed send: the person took over. The record
                // stays as a used attempt but no longer blocks.
                for index in data.sends.indices where data.sends[index].threadId == id && data.sends[index].state == "pending" {
                    data.sends[index].state = "unconfirmed"
                }
                let watch = ResumeData.Watch(threadId: id, enabled: true, maxResumes: limit, status: "starting",
                                             reason: L("Проверяю диалог."), updated: Date())
                if let index = data.watches.firstIndex(where: { $0.threadId == id }) {
                    data.watches[index] = watch
                } else {
                    data.watches.append(watch)
                }
            }
            AgentActivity.trace("auto-continue \(id): on, \(limit) attempts")
            self.publish()
            self.queue.async {
                self.failures[id] = 0
                self.schedule(id, after: 0.5, replace: true)
            }
        }
    }

    /// Switches a watch off at once: the stored flag is what the send path checks last.
    func stop(_ raw: String) async {
        let id = raw.lowercased()
        await quietly {
            try? self.store.update { data in
                data.edit(id) {
                    $0.enabled = false
                    $0.status = "paused"
                    $0.reason = L("Выключено вами.")
                    $0.updated = Date()
                }
            }
            AgentActivity.trace("auto-continue \(id): off")
            self.publish()
        }
        queue.async {
            self.cancel(id)
            self.store.release(id)
        }
    }

    func isWatched(_ id: String) -> Bool { enabledIds().contains(id.lowercased()) }

    private func enabledIds() -> Set<String> { Set(current().lazy.filter(\.enabled).map(\.threadId)) }

    /// Only running work and work stopped by the limit can be put under a watch.
    private static func requireWatchable(_ check: ResumeCheck) throws {
        if check.canMonitor { return }
        throw ResumeError.refused(check.reason)
    }

    /// Something happened in this conversation (a turn ended, a hook fired): look soon.
    func poke(_ id: String, after delay: TimeInterval = 2) {
        let id = id.lowercased()
        if !enabledIds().contains(id) { return }
        queue.async { self.schedule(id, after: delay, replace: false) }
    }

    /// Something happened that concerns every watch (limits reset, Mac woke, Codex started or quit).
    func pokeAll(after delay: TimeInterval = 2) {
        let ids = enabledIds()
        queue.async { for id in ids { self.schedule(id, after: delay, replace: false) } }
    }

    // MARK: Read-only inspection

    static func inspect(_ id: String) throws -> ResumeCheck { try examine(id).check }

    /// What can be said about a conversation without changing anything, and its newest turn.
    /// The live state wins; saved history is used only when the app does not have it loaded.
    static func examine(_ raw: String) throws -> (check: ResumeCheck, latestTurn: String?) {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ResumeRules.isThreadId(id) else { throw ResumeError.refused(L("Нужен точный номер диалога Codex.")) }
        let index = CodexThreadIndex.thread(id: id)
        var title = JSON.nonEmptyString(index?.title)
        var model = JSON.nonEmptyString(index?.model)
        func result(_ state: String, _ reason: String, _ latest: String?) -> (ResumeCheck, String?) {
            (ResumeCheck(threadId: id, title: title, taskState: state, canMonitor: ResumeStatus.canMonitor(state),
                         reason: reason, model: model), latest)
        }
        if try inArchive(id) { return result("archived", L("Диалог в архиве — его не продолжить."), nil) }

        if CodexApp.url != nil, CodexApp.isRunning, (try? CodexApp.checkVersion()) != nil {
            let connection = CodexIPCConnection(timeout: 8)
            defer { connection.close() }
            do {
                try connection.open()
                let owner = try connection.discoverOwner(id)
                let live = try connection.snapshot(id, owner: owner)
                let verdict = ResumeRules.decide(live, thread: id)
                title = JSON.nonEmptyString(live["title"]) ?? title
                model = verdict.model ?? model
                if verdict.taskState != "connecting" {
                    var latest: String?
                    if case .turn(let turn) = ResumeRules.turns(live).latest { latest = ResumeRules.turnId(turn) }
                    return result(verdict.taskState, verdict.reason, latest)
                }
            } catch let error as CodexIPCError where error.isTemporary {
                // Not loaded in a window or the app is busy: the saved history says enough to watch.
            }
        }

        let official = try CodexOfficial()
        defer { official.close() }
        let thread = try official.readThread(id)
        title = title ?? JSON.nonEmptyString(thread["name"]) ?? JSON.nonEmptyString(thread["preview"]).map { String($0.prefix(120)) }
        model = model ?? JSON.nonEmptyString(thread["model"])
        let judged = ResumeRules.judgeHistory(thread)
        return result(judged.state, judged.reason, ResumeRules.latestSavedTurn(thread))
    }

    /// Codex's own index first; the official list only when the index cannot say.
    private static func inArchive(_ id: String) throws -> Bool {
        switch CodexThreadIndex.isArchived(id: id) {
        case .some(let known): return known
        case .none: break
        }
        let official = try CodexOfficial()
        defer { official.close() }
        return try official.listThreads(archived: true).contains { ($0["id"] as? String)?.lowercased() == id }
    }

    // MARK: Scheduling (on `queue`)

    private func boot() {
        // A send that was written but never confirmed (Cooldown quit or crashed around it) has
        // an unknown outcome: that conversation gets nothing more automatically.
        try? store.update { data in
            for watch in data.watches where watch.enabled && data.pending(watch.threadId) != nil {
                data.edit(watch.threadId) {
                    $0.enabled = false
                    $0.status = "uncertain"
                    $0.reason = L("Неизвестно, дошло ли продолжение. Проверьте диалог — сам я туда больше не отправлю.")
                    $0.updated = Date()
                }
            }
        }
        publish()
        for watch in current() where watch.enabled { schedule(watch.threadId, after: 3, replace: true) }
    }

    /// Looks at a watch after `delay`, on the wall clock (so it holds across sleep). Unless
    /// `replace` is set, an already planned earlier look is kept.
    private func schedule(_ id: String, after delay: TimeInterval, replace: Bool) {
        let at = Date().addingTimeInterval(delay)
        if let planned = timers[id], !replace, planned.at <= at { return }
        timers[id]?.item.cancel()
        let item = DispatchWorkItem { [weak self] in self?.look(id) }
        timers[id] = (item, at)
        queue.asyncAfter(wallDeadline: .now() + max(0, delay), execute: item)
    }

    private func cancel(_ id: String) {
        timers[id]?.item.cancel()
        timers[id] = nil
    }

    // MARK: One look (on `queue`)

    private enum Kind { case fine, temporary, failure }

    private struct Outcome {
        var status: String
        var reason: String
        var kind: Kind = .fine
        var disable = false
        /// When to look again; nil for never (the watch ends).
        var next: TimeInterval? = 300
        /// Written even if the watch was switched off meanwhile: it reports something that happened.
        var force = false
    }

    private func look(_ id: String) {
        timers[id] = nil
        let data: ResumeData
        do { data = try store.load() } catch {
            // The stored data cannot be read right now; without it nothing may be sent.
            AgentActivity.trace("auto-continue \(id): store unreadable: \(error.localizedDescription)")
            schedule(id, after: 60, replace: true)
            return
        }
        guard let watch = data.watch(id), watch.enabled else {
            store.release(id)
            return
        }
        guard store.claim(id) else {
            setForeign(id, L("Этот диалог уже ведёт другая копия Cooldown."))
            schedule(id, after: 300, replace: true)
            return
        }
        setForeign(id, nil)
        apply(id, observe(id, watch: watch, data: data))
    }

    private func apply(_ id: String, _ outcome: Outcome) {
        var outcome = outcome
        switch outcome.kind {
        case .fine:
            failures[id] = 0
        case .temporary:
            break
        case .failure:
            let count = (failures[id] ?? 0) + 1
            failures[id] = count
            if count >= 3 {
                outcome = Outcome(status: "blocked", reason: outcome.reason, disable: true, next: nil)
            } else {
                outcome = Outcome(status: "retrying", reason: outcome.reason, next: 30)
            }
        }
        var stillOn = false
        try? store.update { data in
            guard let watch = data.watch(id), watch.enabled || outcome.force else { return }
            data.edit(id) {
                if $0.status != outcome.status || $0.reason != outcome.reason { $0.updated = Date() }
                $0.status = outcome.status
                $0.reason = outcome.reason
                if outcome.disable { $0.enabled = false }
                stillOn = $0.enabled
            }
        }
        if outcome.status != "watching" && outcome.status != "waiting_quota" {
            AgentActivity.trace("auto-continue \(id): \(outcome.status) — \(outcome.reason)")
        }
        publish()
        if stillOn, let next = outcome.next {
            schedule(id, after: next, replace: true)
        } else {
            cancel(id)
            store.release(id)
        }
    }

    private func observe(_ id: String, watch: ResumeData.Watch, data: ResumeData) -> Outcome {
        guard CodexApp.url != nil else {
            return Outcome(status: "waiting_connection", reason: L("Не найдено приложение Codex."), kind: .temporary, next: 600)
        }
        do { try CodexApp.checkVersion() } catch {
            return Outcome(status: "retrying", reason: ResumeError.friendly(error), kind: .failure)
        }
        guard CodexApp.isRunning else {
            return Outcome(status: "waiting_connection", reason: L("Приложение Codex закрыто — продолжу, когда оно откроется."),
                           kind: .temporary, next: 600)
        }
        let connection = CodexIPCConnection(timeout: 8)
        defer { connection.close() }
        let state: [String: Any]
        do {
            try connection.open()
            state = try connection.snapshot(id)
        } catch CodexIPCError.threadUnavailable {
            connection.close()
            return notLoaded(id)
        } catch let error as CodexIPCError where error.isTemporary {
            return Outcome(status: "waiting_connection", reason: ResumeError.friendly(error), kind: .temporary, next: 60)
        } catch {
            return Outcome(status: "retrying", reason: ResumeError.friendly(error), kind: .failure)
        }
        connection.close()
        return judge(id, state: state, watch: watch, data: data)
    }

    /// The app runs but no window has the conversation. Now and then (at most every five
    /// minutes) check it is still worth watching and have the app load it in the background.
    private func notLoaded(_ id: String) -> Outcome {
        let waiting = Outcome(status: "waiting_connection", reason: L("Диалог не открыт в Codex — жду, когда он загрузится."),
                              kind: .temporary, next: 60)
        if let last = lastOpened[id], Date().timeIntervalSince(last) < 300 { return waiting }
        lastOpened[id] = Date()
        do {
            if try Self.inArchive(id) {
                return Outcome(status: "stopped", reason: L("Диалог в архиве — его не продолжить."), disable: true, next: nil)
            }
            let official = try CodexOfficial()
            defer { official.close() }
            let judged = ResumeRules.judgeHistory(try official.readThread(id))
            guard ResumeStatus.canMonitor(judged.state) else { return stopOutcome(judged.state, judged.reason) }
        } catch {
            return waiting
        }
        guard (try? store.load())?.watch(id)?.enabled == true else { return waiting }
        CodexApp.load(thread: id)
        AgentActivity.trace("auto-continue \(id): asked Codex to load the conversation")
        return Outcome(status: "waiting_connection", reason: L("Открываю диалог в Codex в фоне."), kind: .temporary, next: 30)
    }

    /// What a stop verdict means for the watch.
    private func stopOutcome(_ taskState: String, _ reason: String) -> Outcome {
        switch taskState {
        case "needs_attention":
            // The person may answer and the work go on; keep looking, but slowly.
            return Outcome(status: "needs_attention", reason: reason, next: 300)
        case "idle", "interrupted", "empty", "archived":
            return Outcome(status: "stopped", reason: reason, disable: true, next: nil)
        case "other_failure", "unsupported":
            return Outcome(status: "blocked", reason: reason, disable: true, next: nil)
        default:
            return Outcome(status: "retrying", reason: reason, kind: .failure)
        }
    }

    private func judge(_ id: String, state: [String: Any], watch: ResumeData.Watch, data: ResumeData) -> Outcome {
        let verdict = ResumeRules.decide(state, thread: id)
        switch verdict.action {
        case .wait:
            forget(id)
            if verdict.taskState == "running" {
                return Outcome(status: "watching", reason: verdict.reason, next: 180)
            }
            return Outcome(status: "waiting_connection", reason: verdict.reason, next: 20)
        case .stop:
            forget(id)
            return stopOutcome(verdict.taskState, verdict.reason)
        case .send:
            break
        }
        guard let turn = verdict.failedTurn else { return stopOutcome("unknown", verdict.reason) }

        switch ResumeRules.gate(data, thread: id, turn: turn, maxResumes: watch.maxResumes, now: Date()) {
        case .proceed:
            break
        case .justSent:
            return Outcome(status: "resumed", reason: L("Продолжение отправлено, жду, когда Codex начнёт."), next: 20)
        case .alreadySent:
            return Outcome(status: "needs_attention",
                           reason: L("Продолжение уже отправлялось, но задача стоит на той же остановке. Повторно не отправляю."), next: 600)
        case .uncertain:
            return Outcome(status: "uncertain", reason: L("Неизвестно, дошло ли продолжение. Проверьте диалог — сам я туда больше не отправлю."),
                           disable: true, next: nil, force: true)
        case .budget:
            return Outcome(status: "budget", reason: L("Все попытки продолжения использованы."), disable: true, next: nil)
        }

        guard let print = ResumeRules.fingerprint(state) else { return stopOutcome("unknown", L("Не удалось запомнить состояние задачи.")) }
        if watch.fingerprintTurn == turn, let remembered = watch.fingerprint {
            if remembered != print {
                return Outcome(status: "changed", reason: L("Пока ждали лимит, в диалоге поменялись настройки или состояние. Не продолжаю."),
                               disable: true, next: nil)
            }
        } else {
            try? store.update { data in data.edit(id) { $0.fingerprint = print; $0.fingerprintTurn = turn } }
        }

        // Only a fresh reading of the limits may say they are back, never the clock alone.
        let limits: [String: Any]
        do {
            let official = try CodexOfficial()
            defer { official.close() }
            limits = try official.rateLimits()
        } catch {
            return Outcome(status: "waiting_quota", reason: L("Не удалось узнать лимиты, попробую ещё раз."), kind: .temporary, next: 60)
        }
        let now = Date()
        switch ResumeRules.judgeLimits(limits, now: now) {
        case .blocked(let reason):
            return Outcome(status: "blocked", reason: reason, disable: true, next: nil)
        case .notYet(let at):
            return Outcome(status: "waiting_quota", reason: L("Лимит исчерпан. Продолжу после сброса в %@.", "\(Format.time(at))"),
                           next: min(600, at.timeIntervalSince(now)))
        case .stale(let at):
            return Outcome(status: "waiting_quota", reason: L("Жду, пока Codex обновит данные о лимите."), next: at.timeIntervalSince(now))
        case .available:
            return send(id, turn: turn, fingerprint: print)
        }
    }

    private func forget(_ id: String) {
        try? store.update { data in data.edit(id) { $0.fingerprint = nil; $0.fingerprintTurn = nil } }
    }

    // MARK: Sending (on `queue`)

    private func send(_ id: String, turn: String, fingerprint: String) -> Outcome {
        // 1. The intent goes to disk first. If Cooldown dies after this, the send counts as unknown.
        let messageId = UUID().uuidString.lowercased()
        let written: Bool
        do {
            written = try store.update { data in
                guard let watch = data.watch(id), watch.enabled,
                      ResumeRules.gate(data, thread: id, turn: turn, maxResumes: watch.maxResumes, now: Date()) == .proceed else { return false }
                data.sends.append(ResumeData.Send(threadId: id, failedTurn: turn, messageId: messageId, state: "pending", newTurn: nil, time: Date()))
                return true
            }
        } catch {
            return Outcome(status: "retrying", reason: ResumeError.friendly(error), kind: .failure)
        }
        guard written else { return Outcome(status: "waiting_quota", reason: L("Проверяю диалог ещё раз."), next: 2) }

        // Nothing has gone out yet: an intent that fails the checks below is simply taken back.
        func withdraw(_ outcome: Outcome) -> Outcome {
            try? store.update { data in data.sends.removeAll { $0.messageId == messageId && $0.state == "pending" } }
            return outcome
        }
        var sent = false
        let connection = CodexIPCConnection(timeout: 8)
        defer { connection.close() }
        let reply: [String: Any]
        do {
            // 2. The checks right before sending, all on fresh data.
            try CodexApp.checkVersion()
            try connection.open()
            let owner = try connection.discoverOwner(id)
            let state = try connection.snapshot(id, owner: owner, keepFollowing: true)
            var moved = false
            connection.onBroadcast = { message in
                if case .unrelated = CodexIPCConnection.stateChange(message, thread: id, owner: owner) { return }
                moved = true
            }
            // Whatever already waits behind the snapshot is read, never trusted: any state change
            // means the snapshot is not the latest.
            let settle = Date().addingTimeInterval(0.7)
            while Date() < settle && !moved {
                if connection.hasPending() { try connection.read(deadline: Date().addingTimeInterval(2)) } else { usleep(50_000) }
            }
            try? connection.setFollowing(id, owner: owner, false)
            connection.onBroadcast = nil
            if moved {
                return withdraw(Outcome(status: "waiting_quota", reason: L("Диалог ещё меняется, попробую чуть позже."), next: 30))
            }
            let again = ResumeRules.decide(state, thread: id)
            guard again.action == .send, again.failedTurn == turn, ResumeRules.fingerprint(state) == fingerprint else {
                return withdraw(Outcome(status: "waiting_quota", reason: L("Состояние диалога изменилось, смотрю заново."), next: 2))
            }
            let current = try store.load()
            guard current.watch(id)?.enabled == true, current.pending(id)?.messageId == messageId else {
                return withdraw(Outcome(status: "paused", reason: L("Выключено вами."), next: nil))
            }

            // 3. The one message.
            let params: [String: Any] = [
                "conversationId": id,
                "turnStart": ["request": ["threadId": id, "clientUserMessageId": messageId,
                                          "input": [["type": "text", "text": ResumeRules.continuation, "text_elements": [Any]()]]]],
            ]
            AgentActivity.trace("auto-continue \(id): sending continuation for turn \(turn)")
            sent = true
            reply = try connection.request("thread-follower-start-turn", params: params, version: 2, target: owner, wait: 30)
        } catch {
            if !sent {
                if let error = error as? CodexIPCError, error.isTemporary {
                    return withdraw(Outcome(status: "waiting_connection", reason: ResumeError.friendly(error), kind: .temporary, next: 30))
                }
                return withdraw(Outcome(status: "retrying", reason: ResumeError.friendly(error), kind: .failure))
            }
            return unknownOutcome(id, error.localizedDescription)
        }
        let newTurn = JSON.dig(reply, "result", "result", "turn", "id") as? String
        guard let newTurn, !newTurn.isEmpty else { return unknownOutcome(id, "no turn id") }
        try? store.update { data in
            for index in data.sends.indices where data.sends[index].messageId == messageId {
                data.sends[index].state = "confirmed"
                data.sends[index].newTurn = newTurn
            }
            data.edit(id) { $0.fingerprint = nil; $0.fingerprintTurn = nil }
        }
        AgentActivity.trace("auto-continue \(id): new turn \(newTurn)")
        return Outcome(status: "resumed", reason: L("Лимит восстановился, продолжение отправлено."), next: 20, force: true)
    }

    /// The message may or may not have gone out. The record stays pending, which blocks any
    /// further automatic send to this conversation until the person has looked.
    private func unknownOutcome(_ id: String, _ detail: String) -> Outcome {
        AgentActivity.trace("auto-continue \(id): outcome unknown (\(detail))")
        return Outcome(status: "uncertain", reason: L("Не удалось подтвердить, что продолжение дошло. Проверьте диалог — сам я туда больше не отправлю."),
                       disable: true, next: nil, force: true)
    }

    // MARK: Publishing

    private func rows(_ data: ResumeData) -> [ResumeWatch] {
        shownLock.lock()
        let foreign = self.foreign
        shownLock.unlock()
        return data.watches.map { watch in
            let other = watch.enabled ? foreign[watch.threadId] : nil
            return ResumeWatch(threadId: watch.threadId, enabled: watch.enabled, maxResumes: watch.maxResumes,
                               status: other == nil ? watch.status : "blocked", reason: other ?? watch.reason,
                               updated: watch.updated, attempts: data.attempts(watch.threadId))
        }
    }

    private func current() -> [ResumeWatch] {
        shownLock.lock()
        defer { shownLock.unlock() }
        return shown
    }

    private func setForeign(_ id: String, _ reason: String?) {
        shownLock.lock()
        let changed = foreign[id] != reason
        foreign[id] = reason
        shownLock.unlock()
        if changed { publish() }
    }

    private func publish() {
        guard let data = try? store.load() else { return }
        let list = rows(data)
        shownLock.lock()
        shown = list
        shownLock.unlock()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AutoResume.shared.onChange?(list) }
        }
    }

    private func offMain<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
        }
    }

    private func quietly<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }
}
