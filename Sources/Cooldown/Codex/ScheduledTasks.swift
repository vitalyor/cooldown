import Foundation

/// A Codex task written now and started by Cooldown the moment Codex has limit again,
/// through the official `codex exec` command line. Runs in the chosen folder only.
struct ScheduledTask: Codable, Identifiable, Equatable {
    enum State: String, Codable { case waiting, running, done, failed, cancelled }

    var id = UUID()
    var prompt: String
    var folder: String
    var canEdit: Bool
    var created = Date()
    var state: State = .waiting
    var started: Date?
    var finished: Date?
    var result: String?

    var title: String {
        let line = prompt.split(separator: "\n").first.map(String.init) ?? prompt
        return line.count > 70 ? String(line.prefix(70)) + "…" : line
    }
}

@MainActor
final class ScheduledRunner: ObservableObject {
    static let shared = ScheduledRunner()

    @Published private(set) var tasks: [ScheduledTask] = []
    private var processes: [UUID: Process] = [:]
    private let url: URL
    private var logs: URL {
        let folder = Settings.appSupport.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    init(url: URL = Settings.appSupport.appendingPathComponent("scheduled.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([ScheduledTask].self, from: data) {
            // A run interrupted by quitting Cooldown is not resumed silently.
            tasks = saved.map { task in
                var task = task
                if task.state == .running { task.state = .failed; task.result = L("Cooldown был закрыт во время выполнения.") }
                return task
            }
        }
    }

    var waiting: [ScheduledTask] { tasks.filter { $0.state == .waiting || $0.state == .running } }
    var recent: [ScheduledTask] { tasks.filter { $0.state != .waiting && $0.state != .running }.prefix(3).map { $0 } }

    func add(prompt: String, folder: String, canEdit: Bool) throws {
        var updated = tasks
        updated.insert(ScheduledTask(prompt: prompt, folder: folder, canEdit: canEdit), at: 0)
        try commit(updated)
        tick(limits: AppModel.shared.codex.snapshot)
    }

    func cancel(_ id: UUID) throws {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        var updated = tasks
        updated[index].state = .cancelled
        updated[index].finished = Date()
        try commit(updated)
        processes[id]?.terminate()
    }

    func remove(_ id: UUID) throws {
        try commit(tasks.filter { $0.id != id || $0.state == .running })
    }

    /// Starts waiting tasks once Codex has room again in both windows; one at a time.
    func tick(limits: LimitSnapshot?) {
        guard !AppModel.shared.demoActive, processes.isEmpty,
              let snapshot = limits, let session = snapshot.session else { return }
        let now = Date()
        let room = session.remaining(at: now) >= 5 && (snapshot.weekly?.remaining(at: now) ?? 100) >= 2
        guard room, let index = tasks.lastIndex(where: { $0.state == .waiting }) else { return }
        start(index)
    }

    private func start(_ index: Int) {
        guard let binary = CodexPaths.binary(override: Settings.codexPath) else {
            fail(index, L("Не найдена программа codex."))
            return
        }
        var task = tasks[index]
        guard FileManager.default.fileExists(atPath: task.folder) else {
            fail(index, L("Папка %@ не найдена.", "\(task.folder)"))
            return
        }
        let last = logs.appendingPathComponent("scheduled-\(task.id.uuidString)-answer.txt")
        let log = logs.appendingPathComponent("scheduled-\(task.id.uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let process = Process()
        process.executableURL = binary
        var arguments = ["exec", "--skip-git-repo-check", "-C", task.folder,
                         "-s", task.canEdit ? "workspace-write" : "read-only",
                         "-o", last.path]
        if task.canEdit { arguments.append("--approve-for-me") }
        arguments.append(task.prompt)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: task.folder)
        if let handle = try? FileHandle(forWritingTo: log) {
            process.standardOutput = handle
            process.standardError = handle
        }
        process.standardInput = FileHandle.nullDevice
        let id = task.id
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.finished(id, status: status, answer: last) }
        }
        do {
            // A crash after launch must leave a running record, never a second queued launch.
            task.state = .running
            task.started = Date()
            var starting = tasks
            starting[index] = task
            try commit(starting)
            try process.run()
        } catch {
            fail(index, L("Не удалось запустить codex: %@", "\(error.localizedDescription)"))
            return
        }
        processes[id] = process
        let detail = L("Лимит Codex восстановился, задача запущена в папке %@.", "\(Stats.projectName(task.folder))")
        Notifier.shared.post(id: "scheduled-start-\(id)", title: L("Запланированная задача запущена"), body: "«\(task.title)». \(detail)",
                             toast: ToastContent(key: "scheduled-\(id)", kind: .reset, provider: .codex,
                                                 title: L("Запущено: «%@»", "\(task.title)"), body: detail, actions: [.openPanel], life: .auto(10)))
    }

    private func finished(_ id: UUID, status: Int32, answer: URL) {
        processes[id] = nil
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[index].state == .running else { save(); return }
        let text = (try? String(contentsOf: answer, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        tasks[index].finished = Date()
        tasks[index].state = status == 0 ? .done : .failed
        tasks[index].result = text.isEmpty ? (status == 0 ? L("Готово.") : L("Codex завершился с ошибкой (код %@). Подробности в журнале.", "\(status)")) : String(text.prefix(400))
        save()
        let task = tasks[index]
        let body = String((task.result ?? "").replacingOccurrences(of: "\n", with: " ").prefix(200))
        Notifier.shared.post(id: "scheduled-done-\(id)", title: task.state == .done ? L("Запланированная задача выполнена") : L("Запланированная задача не удалась"),
                             body: "«\(task.title)»: \(body)",
                             toast: ToastContent(key: "scheduled-\(id)", kind: task.state == .done ? .finished : .warning, provider: .codex,
                                                 title: (task.state == .done ? L("Выполнено: «") : L("Не удалось: «")) + task.title + "»",
                                                 body: body, actions: [.openPanel], life: task.state == .done ? .auto(14) : .sticky))
        tick(limits: AppModel.shared.codex.snapshot)
    }

    private func fail(_ index: Int, _ reason: String) {
        tasks[index].state = .failed
        tasks[index].result = reason
        tasks[index].finished = Date()
        save()
        Notifier.shared.post(id: "scheduled-fail-\(tasks[index].id)", title: L("Запланированная задача не запущена"), body: reason,
                             toast: ToastCatalog.failure(L("Не запущено: «%@»", "\(tasks[index].title)"), reason, provider: .codex))
    }

    func logURL(_ task: ScheduledTask) -> URL { logs.appendingPathComponent("scheduled-\(task.id.uuidString).log") }

    private func save() {
        do { try Self.persist(tasks, to: url) }
        catch {
            AgentActivity.trace("scheduled tasks: save failed: \(error.localizedDescription)")
            ToastController.shared.show(ToastCatalog.failure(L("Не удалось"), L("Не сохранилось: %@", error.localizedDescription)))
        }
    }

    private func commit(_ updated: [ScheduledTask]) throws {
        try Self.persist(updated, to: url)
        tasks = updated
    }

    static func persist(_ tasks: [ScheduledTask], to url: URL) throws {
        try JSONEncoder().encode(savedTasks(tasks)).write(to: url, options: .atomic)
    }

    static func savedTasks(_ tasks: [ScheduledTask]) -> [ScheduledTask] {
        var finished = 0
        return tasks.filter { task in
            if task.state == .waiting || task.state == .running { return true }
            finished += 1
            return finished <= 30
        }
    }
}
