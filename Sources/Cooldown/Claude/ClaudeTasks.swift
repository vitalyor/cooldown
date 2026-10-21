import Foundation

/// A Claude Code conversation on disk, as the task picker shows it.
struct ClaudeSession: Identifiable, Equatable {
    var id: String          // session id
    var title: String
    var cwd: String
    var transcript: String
    var updated: Date
    var state: ClaudeSessionState
}

enum ClaudeSessionState: Equatable {
    case running
    /// Stopped by a plan limit. `stopID` identifies that exact stop, so it is answered once.
    case limited(stopID: String, at: Date, resetHint: Date?)
    case idle
    case unknown

    var title: String {
        switch self {
        case .running: return "Задача выполняется"
        case .limited: return "Остановлена из-за лимита"
        case .idle: return "Раунд завершён"
        case .unknown: return "Статус неизвестен"
        }
    }

    var canWatch: Bool {
        switch self {
        case .running, .limited: return true
        default: return false
        }
    }
}

/// One Claude Code conversation that Cooldown continues after the limit resets.
struct ClaudeTask: Codable, Identifiable, Equatable {
    var sessionId: String
    var title: String
    var cwd: String
    var transcript: String
    var maxResumes: Int
    var attempts: Int
    var enabled: Bool
    var status: String
    var reason: String
    var updated: Date
    /// The limit stop already answered with a continuation; never answered twice.
    var answeredStop: String?

    var id: String { sessionId }
}

enum ClaudeTaskError: LocalizedError {
    case notEligible(String)
    case noBinary

    var errorDescription: String? {
        switch self {
        case .notEligible(let reason): return reason
        case .noBinary: return "Не найдена программа claude. Укажите путь к ней в настройках."
        }
    }
}

/// Reads Claude Code transcripts to tell whether a conversation is working, finished, or stopped by
/// the plan limit, and continues stopped ones with `claude -p … --resume <session>` once the limit
/// is back. The same rules as Relay for Codex: only chosen conversations, one message per stop, a
/// cap on attempts, nothing approved on the person's behalf.
@MainActor
final class ClaudeTaskManager: ObservableObject {
    @Published private(set) var tasks: [ClaudeTask] = []
    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var loadingSessions = false

    static let continuation = "Лимит восстановился. Продолжи прерванную работу в этой сессии. Сначала сверь текущий прогресс и рабочую папку; не повторяй уже выполненные шаги, не расширяй объём работы, не обходи подтверждения. Если работа уже завершена или нужно решение пользователя, прямо скажи об этом и остановись."

    var onChange: ((ClaudeTask, String) -> Void)?

    private var running: [String: Process] = [:]
    private var storeURL: URL { Settings.appSupport.appendingPathComponent("claude-tasks.json") }
    private var logsURL: URL {
        let url = Settings.appSupport.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Storage

    func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let data = try? Data(contentsOf: storeURL), let saved = try? decoder.decode([ClaudeTask].self, from: data) {
            tasks = saved
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(tasks) { try? data.write(to: storeURL, options: .atomic) }
    }

    private func update(_ id: String, _ change: (inout ClaudeTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let before = tasks[index].status
        change(&tasks[index])
        tasks[index].updated = Date()
        save()
        if tasks[index].status != before { onChange?(tasks[index], before) }
    }

    // MARK: Sessions

    func loadSessions() async {
        guard !loadingSessions else { return }
        loadingSessions = true
        defer { loadingSessions = false }
        let root = ClaudePaths.projects
        sessions = await Task.detached(priority: .userInitiated) { Self.discover(root: root) }.value
    }

    nonisolated static func discover(root: URL) -> [ClaudeSession] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var result: [ClaudeSession] = []
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        let own = ClaudeUsageCLI.transcriptFolder.standardizedFileURL.path
        for project in projects where project.standardizedFileURL.path != own {
            guard let files = try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modified >= cutoff else { continue }
                let info = describe(file)
                // Sessions where nothing was ever asked (no prompt, no title) are leftovers such as /usage runs.
                if info.empty { continue }
                result.append(ClaudeSession(id: file.deletingPathExtension().lastPathComponent, title: info.title,
                                            cwd: info.cwd, transcript: file.path, updated: modified,
                                            state: state(of: file, modified: modified)))
            }
        }
        return result.sorted { $0.updated > $1.updated }
    }

    /// Title and folder from the transcript: the custom title if set, else the last prompt.
    nonisolated static func describe(_ file: URL) -> (title: String, cwd: String, empty: Bool) {
        var title: String?
        var prompt: String?
        var cwd = ""
        for object in lines(of: file, tailBytes: 2 << 20) {
            if let custom = object["customTitle"] as? String, !custom.isEmpty { title = custom }
            if let last = object["lastPrompt"] as? String, !last.isEmpty { prompt = last }
            if let folder = object["cwd"] as? String, !folder.isEmpty { cwd = folder }
        }
        let text = title ?? prompt.map { $0.replacingOccurrences(of: "\n", with: " ") } ?? "Сессия \(file.deletingPathExtension().lastPathComponent.prefix(8))"
        return (String(text.prefix(120)), cwd, title == nil && prompt == nil)
    }

    nonisolated static func state(of file: URL, modified: Date) -> ClaudeSessionState {
        let entries = lines(of: file, tailBytes: 512 << 10).filter {
            let type = $0["type"] as? String
            return type == "assistant" || type == "user"
        }
        guard let last = entries.last else { return .unknown }
        if last["type"] as? String == "assistant", let stop = limitStop(last) { return stop }
        if Date().timeIntervalSince(modified) < 90 { return .running }
        if last["type"] as? String == "user" { return .idle }
        let message = last["message"] as? [String: Any]
        if message?["stop_reason"] as? String == "tool_use" { return .idle }
        return .idle
    }

    /// A synthetic assistant message (an API error shown in the conversation) about the plan limit.
    nonisolated static func limitStop(_ entry: [String: Any]) -> ClaudeSessionState? {
        let message = entry["message"] as? [String: Any]
        let synthetic = message?["model"] as? String == "<synthetic>" || entry["isApiErrorMessage"] as? Bool == true || entry["error"] != nil
        guard synthetic else { return nil }
        let content = (message?["content"] as? [[String: Any]]) ?? []
        let text = content.compactMap { $0["text"] as? String }.joined(separator: " ")
        let error = String(describing: entry["error"] ?? "")
        let haystack = (text + " " + error).lowercased()
        let markers = ["rate_limit", "usage limit", "limit reached", "hit your limit", "limit will reset", "resets at", "· resets"]
        guard markers.contains(where: { haystack.contains($0) }) else { return nil }
        let at = Num.date(entry["timestamp"]) ?? Date()
        return .limited(stopID: entry["uuid"] as? String ?? "\(at.timeIntervalSince1970)", at: at, resetHint: resetHint(text, after: at))
    }

    /// "resets 3pm", "resets at 15:30" in the limit message, as the next such moment.
    nonisolated static func resetHint(_ text: String, after: Date) -> Date? {
        let pattern = #"resets?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let hourRange = Range(match.range(at: 1), in: text), var hour = Int(text[hourRange]) else { return nil }
        let minute = Range(match.range(at: 2), in: text).flatMap { Int(text[$0]) } ?? 0
        if let suffixRange = Range(match.range(at: 3), in: text) {
            let suffix = text[suffixRange].lowercased()
            if suffix == "pm" && hour < 12 { hour += 12 }
            if suffix == "am" && hour == 12 { hour = 0 }
        }
        guard hour < 24, minute < 60 else { return nil }
        let calendar = Calendar.current
        var date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: after) ?? after
        if date <= after { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
        return date
    }

    nonisolated static func lines(of file: URL, tailBytes: Int) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        var parts = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if start > 0, !parts.isEmpty { parts.removeFirst() }
        return parts.compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
    }

    // MARK: Tasks

    func add(_ session: ClaudeSession, maxResumes: Int) throws {
        let fresh = Self.state(of: URL(fileURLWithPath: session.transcript), modified: session.updated)
        guard fresh.canWatch else {
            throw ClaudeTaskError.notEligible("Эта сессия сейчас не работает и не остановлена лимитом, продолжать нечего.")
        }
        guard ClaudePaths.binary(override: Settings.claudePath) != nil else { throw ClaudeTaskError.noBinary }
        let attempts = tasks.first { $0.id == session.id }?.attempts ?? 0
        let task = ClaudeTask(sessionId: session.id, title: session.title, cwd: session.cwd, transcript: session.transcript,
                              maxResumes: maxResumes, attempts: attempts, enabled: true,
                              status: fresh == .running ? "watching" : "waiting_quota",
                              reason: fresh == .running ? "Задача выполняется; если её остановит лимит, Cooldown дождётся сброса."
                                                        : "Ждём сброса лимита Claude.",
                              updated: Date(), answeredStop: tasks.first { $0.id == session.id }?.answeredStop)
        tasks.removeAll { $0.id == session.id }
        tasks.insert(task, at: 0)
        save()
    }

    func stop(_ id: String) {
        update(id) {
            $0.enabled = false
            $0.status = "paused"
            $0.reason = "Вы выключили автопродолжение."
        }
    }

    /// Called every minute with Claude's current limits.
    func tick(limits: LimitSnapshot?) {
        let now = Date()
        for task in tasks where task.enabled {
            if running[task.id] != nil {
                update(task.id) { $0.status = "resumed"; $0.reason = "Claude продолжает работу в фоне." }
                continue
            }
            let file = URL(fileURLWithPath: task.transcript)
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            switch Self.state(of: file, modified: modified) {
            case .running:
                update(task.id) { $0.status = "watching"; $0.reason = "Задача выполняется." }
            case .idle, .unknown:
                update(task.id) {
                    $0.enabled = false
                    $0.status = "stopped"
                    $0.reason = "Раунд завершён, продолжать нечего."
                }
            case .limited(let stopID, let at, let hint):
                if task.answeredStop == stopID {
                    update(task.id) {
                        $0.enabled = false
                        $0.status = "uncertain"
                        $0.reason = "Продолжение отправлено, но сессия снова на той же остановке. Откройте её и проверьте."
                    }
                    continue
                }
                if task.attempts >= task.maxResumes {
                    update(task.id) {
                        $0.enabled = false
                        $0.status = "budget"
                        $0.reason = "Использованы все попытки продолжения."
                    }
                    continue
                }
                if let wait = waitReason(limits: limits, stoppedAt: at, hint: hint, now: now) {
                    update(task.id) { $0.status = "waiting_quota"; $0.reason = wait }
                    continue
                }
                if now.timeIntervalSince(modified) < 60 {
                    update(task.id) { $0.status = "waiting_quota"; $0.reason = "Сессию кто-то открыл, подождём минуту." }
                    continue
                }
                resume(task, stopID: stopID)
            }
        }
    }

    /// nil when the limit is back; otherwise why to keep waiting.
    private func waitReason(limits: LimitSnapshot?, stoppedAt: Date, hint: Date?, now: Date) -> String? {
        if let weekly = limits?.weekly, !weekly.isExpired(at: now), weekly.usedPercent >= 99 {
            return "Исчерпан недельный лимит Claude, ждём сброса \(Format.time(weekly.resetsAt, now: now))."
        }
        if let window = limits?.session {
            if window.isExpired(at: now) { return nil }
            if limits.map({ now.timeIntervalSince($0.fetchedAt) < 15 * 60 }) == true && window.usedPercent < 98 { return nil }
            return "Ждём сброса лимита Claude в \(Format.time(window.resetsAt, now: now))."
        }
        if let hint {
            return hint <= now ? nil : "Ждём сброса лимита Claude в \(Format.time(hint, now: now))."
        }
        let fallback = stoppedAt.addingTimeInterval(5 * 3600)
        return fallback <= now ? nil : "Лимиты Claude не подключены, попробуем в \(Format.time(fallback, now: now))."
    }

    private func resume(_ task: ClaudeTask, stopID: String) {
        guard let claude = ClaudePaths.binary(override: Settings.claudePath) else {
            update(task.id) { $0.status = "blocked"; $0.reason = ClaudeTaskError.noBinary.localizedDescription }
            return
        }
        // Recorded before starting, so a crash in between can never lead to a second message.
        update(task.id) {
            $0.attempts += 1
            $0.answeredStop = stopID
            $0.status = "resumed"
            $0.reason = "Лимит восстановился, продолжение отправлено."
        }
        let process = Process()
        process.executableURL = claude
        process.arguments = ["-p", Self.continuation, "--resume", task.sessionId]
        if !task.cwd.isEmpty, FileManager.default.fileExists(atPath: task.cwd) {
            process.currentDirectoryURL = URL(fileURLWithPath: task.cwd)
        }
        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        environment["PATH"] = [claude.deletingLastPathComponent().path, "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                               "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let log = logsURL.appendingPathComponent("claude-\(task.sessionId).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: log)
        process.standardOutput = handle ?? FileHandle.nullDevice
        process.standardError = handle ?? FileHandle.nullDevice
        let id = task.id
        process.terminationHandler = { finished in
            try? handle?.close()
            let code = finished.terminationStatus
            Task { @MainActor in
                let manager = AppModel.shared.claudeTasks
                manager.running[id] = nil
                if code != 0 {
                    manager.update(id) {
                        $0.status = "blocked"
                        $0.reason = "Claude завершился с ошибкой (код \(code)). Подробности в журнале Cooldown."
                    }
                }
                manager.tick(limits: AppModel.shared.claude.snapshot)
            }
        }
        do {
            try process.run()
            running[id] = process
        } catch {
            update(id) { $0.status = "blocked"; $0.reason = "Не удалось запустить claude: \(error.localizedDescription)" }
        }
    }
}
