import AppKit
import Foundation

/// A Codex conversation as the add-task screen lists it.
struct CodexConversation: Identifiable, Equatable {
    var id: String
    var title: String
    var cwd: String?
    var updatedAt: Date?
    var archived: Bool

    init(id: String, title: String, cwd: String?, updatedAt: Date?, archived: Bool) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.archived = archived
    }

    init(id: String, name: String?, preview: String?, cwd: String?, updatedAt: Date?, archived: Bool) {
        let clean = [name, preview].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        self.init(id: id, title: String((clean ?? "Без названия").prefix(120)), cwd: cwd, updatedAt: updatedAt, archived: archived)
    }
}

/// One watched conversation, as the Tasks tab shows it.
struct ResumeWatch: Identifiable, Equatable {
    var threadId: String
    var enabled: Bool
    var maxResumes: Int
    var status: String
    var reason: String
    var updated: Date
    var attempts: Int

    var id: String { threadId }
}

/// What a read-only check of one conversation found.
struct ResumeCheck: Equatable {
    var threadId: String
    var title: String?
    var taskState: String
    var canMonitor: Bool
    var reason: String
    var model: String?
}

enum ResumeError: LocalizedError {
    case refused(String)

    var errorDescription: String? {
        if case .refused(let text) = self { return text }
        return nil
    }

    static func friendly(_ error: Error) -> String { error.localizedDescription }
}

/// Auto-continue for Codex, inside Cooldown: chosen conversations only, one message per stopped
/// turn, never an approval. It reacts to events instead of polling: the conversation's own
/// session file (a turn ended or failed), Codex hooks, the app starting or quitting, the Mac
/// waking — and it reads the limits again exactly when they reset. A slow heartbeat only
/// catches what no event reported.
final class AutoResume: @unchecked Sendable {
    static let shared = AutoResume()

    private let queue = DispatchQueue(label: "cooldown.autoresume", qos: .utility)
    /// A second connection for the person's own actions, so "stop" never waits behind a check.
    private let controlQueue = DispatchQueue(label: "cooldown.autoresume.control", qos: .userInitiated)
    private var store: ResumeStore?
    private var control: ResumeStore?
    private var storeError: String?
    private var controllers: [String: ResumeController] = [:]
    private var timers: [String: DispatchSourceTimer] = [:]
    private var fireAt: [String: Date] = [:]
    private let watchedLock = NSLock()
    private var watchedIds = Set<String>()
    private var observers: [NSObjectProtocol] = []

    /// Called on the main thread with every change of the watches.
    @MainActor var onChange: (([ResumeWatch]) -> Void)?

    // MARK: Starting

    func start() {
        queue.async { self.boot() }
        let center = NSWorkspace.shared.notificationCenter
        let codex: (Notification) -> Bool = {
            ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == CodexApp.bundleId
        }
        observers = [
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in self?.pokeAll(after: 5) },
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { [weak self] note in
                if codex(note) { self?.pokeAll(after: 6) }   // the app needs a moment to open its socket
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { [weak self] note in
                if codex(note) { self?.pokeAll(after: 1) }
            },
        ]
    }

    private func boot() {
        do {
            let store = try ResumeStore()
            self.store = store
            control = try ResumeStore()
            let moved = store.importLegacy()
            for watch in store.all() where watch.enabled {
                activate(watch.threadId, delay: moved.contains(watch.threadId) ? 3 : 1)
            }
        } catch {
            storeError = error.localizedDescription
        }
        publish()
    }

    // MARK: Events

    /// Whether a conversation is being watched (cheap, from any thread).
    func isWatched(_ id: String) -> Bool {
        watchedLock.lock(); defer { watchedLock.unlock() }
        return watchedIds.contains(id.lowercased())
    }

    /// Something happened to a conversation (its turn ended, failed, asked for permission):
    /// look at it now instead of at the next heartbeat.
    func poke(_ id: String, after delay: TimeInterval = 1) {
        guard isWatched(id) else { return }
        queue.async { self.schedule(id.lowercased(), in: delay, sooner: true) }
    }

    /// The limits may have reset, the app came back, the Mac woke: look at every watch.
    func pokeAll(after delay: TimeInterval = 1) {
        queue.async { for id in self.controllers.keys { self.schedule(id, in: delay, sooner: true) } }
    }

    // MARK: Watching

    private func activate(_ id: String, delay: TimeInterval) {
        guard let store, controllers[id] == nil else { return }
        do { try store.lock(id) } catch {
            store.update(id, status: "blocked", reason: error.localizedDescription, disable: true)
            return
        }
        controllers[id] = ResumeController(threadId: id, store: store,
                                           connect: { let connection = CodexIPCConnection(); try connection.open(); return connection },
                                           readQuota: { try CodexReadOnlyServer().query("account/rateLimits/read") },
                                           openThread: { try Self.reopen($0, store: store) })
        watchedLock.lock(); watchedIds.insert(id); watchedLock.unlock()
        schedule(id, in: delay, sooner: true)
    }

    private func deactivate(_ id: String) {
        controllers[id] = nil
        timers.removeValue(forKey: id)?.cancel()
        fireAt[id] = nil
        store?.unlock(id)
        watchedLock.lock(); watchedIds.remove(id); watchedLock.unlock()
    }

    /// One timer per conversation on the wall clock, so it fires right after the Mac wakes.
    private func schedule(_ id: String, in delay: TimeInterval, sooner: Bool) {
        guard controllers[id] != nil else { return }
        let when = Date().addingTimeInterval(max(0, delay))
        if sooner, let current = fireAt[id], current <= when { return }
        timers[id]?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(wallDeadline: .now() + max(0, delay), leeway: .milliseconds(delay > 60 ? 2000 : 200))
        timer.setEventHandler { [weak self] in self?.run(id) }
        timers[id] = timer
        fireAt[id] = when
        timer.resume()
    }

    private func run(_ id: String) {
        timers.removeValue(forKey: id)?.cancel()
        fireAt[id] = nil
        guard let controller = controllers[id], let store else { return }
        // The old separate watcher (if one was moved over) must be gone before Cooldown acts.
        guard ResumeStore.legacyWatcherGone(id) else {
            store.update(id, status: "starting", reason: "Ждём, пока остановится прежний наблюдатель", onlyEnabled: true)
            schedule(id, in: 2, sooner: false)
            return
        }
        let keep = controller.step()
        if keep {
            schedule(id, in: nextLook(store.get(id)?.status ?? "", controller), sooner: false)
        } else {
            deactivate(id)
        }
        publish()
    }

    /// When to look again with no event: exactly at the limit reset while waiting for it, soon
    /// right after a send, rarely while a turn simply runs (its end arrives as an event).
    private func nextLook(_ status: String, _ controller: ResumeController) -> TimeInterval {
        let now = Date().timeIntervalSince1970
        switch status {
        case "waiting_quota":
            let reset = controller.nextQuotaCheck - now
            return reset > 0 ? min(reset, 10 * 60) : 60
        case "resumed": return 20
        case "retrying": return 30
        case "waiting_connection": return CodexApp.isRunning ? 30 : 5 * 60
        case "starting": return 2
        default: return 3 * 60
        }
    }

    private func publish() {
        guard let store else { return }
        let rows = store.all().map {
            ResumeWatch(threadId: $0.threadId, enabled: $0.enabled, maxResumes: $0.maxResumes, status: $0.status,
                        reason: $0.reason, updated: $0.updated, attempts: store.count($0.threadId))
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onChange?(rows) } }
    }

    // MARK: The person's actions

    func watches() async -> [ResumeWatch] {
        await withCheckedContinuation { continuation in
            queue.async {
                let rows = self.store?.all().map { watch in
                    ResumeWatch(threadId: watch.threadId, enabled: watch.enabled, maxResumes: watch.maxResumes, status: watch.status,
                                reason: watch.reason, updated: watch.updated, attempts: self.store?.count(watch.threadId) ?? 0)
                } ?? []
                continuation.resume(returning: rows)
            }
        }
    }

    /// Codex's conversations, newest first, from its own index on disk (instant); through the
    /// official read-only interface when the index cannot be read.
    func conversations() async throws -> [CodexConversation] {
        if let rows = CodexThreadIndex.conversations() { return rows }
        return try await background { try CodexReadOnlyServer().conversations() }
    }

    func check(_ id: String) async throws -> ResumeCheck {
        try await background { try Self.inspect(id) }
    }

    func start(_ id: String, maxResumes: Int) async throws {
        guard let uuid = UUID(uuidString: id) else { throw ResumeError.refused("Нужен точный идентификатор диалога") }
        let id = uuid.uuidString.lowercased()
        let check = try await self.check(id)
        guard check.canMonitor else { throw ResumeError.refused(check.reason) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let store = self.store else {
                    continuation.resume(throwing: ResumeError.refused(self.storeError ?? "Хранилище автопродолжения недоступно"))
                    return
                }
                if store.uncertain(id) {
                    continuation.resume(throwing: ResumeError.refused("У этой задачи есть неподтверждённая отправка; сначала проверьте её в Codex"))
                    return
                }
                if store.count(id) >= maxResumes {
                    continuation.resume(throwing: ResumeError.refused("Попытки для этой задачи уже израсходованы; увеличьте их число"))
                    return
                }
                do {
                    self.deactivate(id)
                    try store.arm(id, maxResumes: maxResumes)
                    self.activate(id, delay: 0)
                    self.publish()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Switches the watch off at once (from its own connection), then lets the watcher let go.
    func stop(_ id: String) async {
        let id = id.lowercased()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            controlQueue.async {
                self.control?.stop(id)
                continuation.resume()
            }
        }
        queue.async {
            self.deactivate(id)
            self.publish()
        }
    }

    private func background<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    // MARK: Read-only checks

    /// Archived (from Codex's index; the official list if the index cannot say).
    private static func isArchived(_ id: String) throws -> Bool {
        if let archived = CodexThreadIndex.isArchived(id: id) { return archived }
        let server = try CodexReadOnlyServer()
        defer { server.close() }
        return try server.conversations(archived: [true]).contains { $0.id == id }
    }

    /// The task state of one conversation, read-only: live from the app when it is open,
    /// otherwise from the saved history (which may allow watching, never sending).
    static func inspect(_ rawId: String) throws -> ResumeCheck {
        guard let uuid = UUID(uuidString: rawId) else { throw ResumeError.refused("Нужен точный идентификатор диалога") }
        let id = uuid.uuidString.lowercased()
        if try isArchived(id) {
            return ResumeCheck(threadId: id, title: CodexThreadIndex.thread(id: id)?.title, taskState: "archived", canMonitor: false,
                               reason: "Этот диалог в архиве — автопродолжение для него не включается", model: nil)
        }
        do {
            let connection = CodexIPCConnection()
            try connection.open()
            defer { connection.close() }
            let state = try connection.snapshot(id)
            let decision = ResumePolicy.decide(state)
            if decision.taskState != "connecting" {
                return ResumeCheck(threadId: id, title: state["title"] as? String, taskState: decision.taskState,
                                   canMonitor: ["running", "quota_limited"].contains(decision.taskState),
                                   reason: decision.reason, model: state["latestModel"] as? String)
            }
        } catch let error as CodexIPCError where error.isTransient {
            // Not loaded in the app right now: the saved history decides whether it may be watched.
        }
        let server = try CodexReadOnlyServer()
        defer { server.close() }
        let saved = try server.query("thread/read", ["threadId": id, "includeTurns": true])
        return try storedAssessment(saved["thread"], id: id)
    }

    /// Saved turns may allow watching a conversation; they never allow sending.
    static func storedAssessment(_ raw: Any?, id: String) throws -> ResumeCheck {
        guard let thread = raw as? [String: Any], thread["id"] as? String == id else {
            throw ResumeError.refused("Результат чтения не соответствует выбранному диалогу")
        }
        let title = JSON.nonEmptyString(thread["name"]) ?? JSON.nonEmptyString(thread["preview"])
        func result(_ state: String, _ can: Bool, _ reason: String) -> ResumeCheck {
            ResumeCheck(threadId: id, title: title, taskState: state, canMonitor: can, reason: reason, model: nil)
        }
        let unknown = result("unknown", false, "Пока не удаётся подтвердить статус задачи, автопродолжение не включается")
        guard JSON.bool(thread["ephemeral"]) == false, let turns = thread["turns"] as? [Any] else { return unknown }
        guard let turn = turns.last as? [String: Any] else {
            return turns.isEmpty ? result("empty", false, "В этом диалоге ещё нет задач — автопродолжение не нужно") : unknown
        }
        guard JSON.nonEmptyString(turn["id"]) != nil else { return unknown }
        switch turn["status"] as? String {
        case "completed": return result("idle", false, "Последний раунд завершён, выполняющихся задач нет — автопродолжение не нужно")
        case "interrupted": return result("interrupted", false, "Последний раунд остановлен, автоматически перезапущен не будет")
        case "inProgress": return result("running", true, "История показывает, что задача ещё выполняется")
        case "failed" where ResumePolicy.quotaFailure(turn):
            return result("quota_limited", true, "История показывает, что задача остановилась из-за исчерпания лимита")
        case "failed": return result("other_failure", false, "Задача остановлена из-за другой ошибки, не из-за лимита")
        default: return unknown
        }
    }

    /// Before re-opening a conversation whose window went away: still not archived, its saved
    /// history still allows watching, still watched. False: no longer eligible.
    private static func reopen(_ id: String, store: ResumeStore) throws -> Bool {
        if try isArchived(id) { return false }
        let server = try CodexReadOnlyServer()
        let saved = try server.query("thread/read", ["threadId": id, "includeTurns": true])
        server.close()
        guard try storedAssessment(saved["thread"], id: id).canMonitor, store.get(id)?.enabled == true else { return false }
        try CodexApp.openThread(id)
        return true
    }
}

/// How a conversation's task state reads in the interface.
enum ResumeStatus {
    static func taskStateTitle(_ state: String) -> String {
        switch state {
        case "running": return "Задача выполняется"
        case "quota_limited": return "Остановлена из-за лимита"
        case "needs_attention": return "Ждёт вашего решения"
        case "idle": return "Раунд завершён"
        case "empty": return "Пустой диалог"
        case "interrupted": return "Остановлена вручную"
        case "other_failure": return "Остановлена из-за другой ошибки"
        case "unsupported": return "Не поддерживается"
        case "archived": return "В архиве"
        case "connecting": return "Ждёт подключения"
        default: return "Статус неизвестен"
        }
    }
}
