import Foundation

/// Auto-resume is done by the Relay command line tool (codex-auto-resume). The app only calls its
/// commands, so the checks that guard sending a message stay in one tested place.
struct RelayWatch: Identifiable, Equatable {
    var threadId: String
    var enabled: Bool
    var maxResumes: Int
    var status: String
    var reason: String
    var updated: Date
    var attempts: Int
    var processGone: Bool

    var id: String { threadId }
}

struct RelayThread: Identifiable, Equatable {
    var id: String
    var title: String
    var cwd: String?
    var updatedAt: Date?
    var archived: Bool
}

struct RelayCheck: Equatable {
    var threadId: String
    var title: String?
    var taskState: String
    var canMonitor: Bool
    var reason: String
    var model: String?
}

enum RelayError: LocalizedError {
    case notFound(String)
    case failed(String)
    case timeout
    case badOutput

    var errorDescription: String? {
        switch self {
        case .notFound(let path): return "Не найдена папка Relay: \(path). Укажите её в настройках."
        case .failed(let message): return message
        case .timeout: return "Relay не ответил вовремя."
        case .badOutput: return "Relay прислал ответ, который не удалось прочитать."
        }
    }

    /// Relay's own messages are precise but long; the version pin one deserves plain words here.
    static func friendly(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.contains("вне проверенного диапазона") {
            return "Relay ещё не проверен с этой версией Codex, поэтому автопродолжение недоступно. Лимиты и статистика работают."
        }
        return text
    }
}

final class RelayBridge {
    let root: URL

    init(path: String) {
        root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    var launcher: URL { root.appendingPathComponent("resume") }
    var isAvailable: Bool { FileManager.default.fileExists(atPath: launcher.path) }

    func status() async throws -> [RelayWatch] {
        guard let rows = try await run(["status"], timeout: 30) as? [[String: Any]] else { throw RelayError.badOutput }
        return rows.compactMap { row in
            guard let id = row["thread_id"] as? String else { return nil }
            return RelayWatch(threadId: id,
                              enabled: (row["enabled"] as? NSNumber)?.boolValue ?? false,
                              maxResumes: Num.int(row["max_resumes"]) ?? 0,
                              status: row["status"] as? String ?? "",
                              reason: row["reason"] as? String ?? "",
                              updated: Date(timeIntervalSince1970: Num.double(row["updated"]) ?? 0),
                              attempts: Num.int(row["attempts"]) ?? 0,
                              processGone: row["process"] as? String == "not_running")
        }
    }

    func threads() async throws -> [RelayThread] {
        guard let rows = try await run(["list"], timeout: 90) as? [[String: Any]] else { throw RelayError.badOutput }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            // Codex's own reviewer runs ("Guardian review") are side threads the app never lists.
            if name == "Guardian review" { return nil }
            let preview = (row["preview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = [name, preview].compactMap { $0 }.first { !$0.isEmpty } ?? "Без названия"
            return RelayThread(id: id, title: String(title.prefix(120)), cwd: row["cwd"] as? String,
                               updatedAt: Num.double(row["updatedAt"]).map { Date(timeIntervalSince1970: $0) },
                               archived: (row["archived"] as? NSNumber)?.boolValue ?? false)
        }
    }

    func check(_ id: String) async throws -> RelayCheck {
        guard let row = try await run(["check", id], timeout: 120) as? [String: Any] else { throw RelayError.badOutput }
        return RelayCheck(threadId: row["threadId"] as? String ?? id,
                          title: row["title"] as? String,
                          taskState: row["taskState"] as? String ?? "unknown",
                          canMonitor: (row["canMonitor"] as? NSNumber)?.boolValue ?? false,
                          reason: row["reason"] as? String ?? "",
                          model: row["model"] as? String)
    }

    func start(_ id: String, maxResumes: Int) async throws {
        _ = try await run(["start", id, "--max-resumes", String(maxResumes)], timeout: 150)
    }

    func stop(_ id: String) async throws {
        _ = try await run(["stop", id], timeout: 30)
    }

    private func run(_ arguments: [String], timeout: TimeInterval) async throws -> Any {
        guard isAvailable else { throw RelayError.notFound(root.path) }
        let launcher = self.launcher
        let root = self.root
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = [launcher.path] + arguments
                process.currentDirectoryURL = root
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
                environment["PYTHONIOENCODING"] = "utf-8"
                process.environment = environment
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(throwing: RelayError.failed(error.localizedDescription))
                    return
                }
                var outData = Data()
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { outData = stdout.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter()
                DispatchQueue.global().async { errData = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                if group.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                    continuation.resume(throwing: RelayError.timeout)
                    return
                }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: RelayError.failed(message.isEmpty
                        ? "Relay завершился с кодом \(process.terminationStatus)." : message))
                    return
                }
                guard let json = try? JSONSerialization.jsonObject(with: outData) else {
                    continuation.resume(throwing: RelayError.badOutput)
                    return
                }
                continuation.resume(returning: json)
            }
        }
    }
}

/// How Relay's task states read in the interface.
enum RelayStatus {
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
