import Foundation

/// Google Antigravity's limits, read from its own CLI: `agy -p /usage --output-format json` runs the
/// /usage command locally, without a model turn and without spending any quota.
enum AntigravityLimits {
    /// The `agy` command line: Antigravity installs it into ~/.gemini/bin.
    static var binary: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.gemini/bin/agy", "\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static var installed: Bool { binary != nil }

    enum Failure: LocalizedError {
        case notFound, timeout, unexpected(String)
        var errorDescription: String? {
            switch self {
            case .notFound: return L("Antigravity не найден. Откройте Antigravity один раз, чтобы он поставил команду agy.")
            case .timeout: return L("Antigravity не ответил за 30 секунд.")
            case .unexpected(let text): return text.isEmpty ? L("Antigravity прислал ответ в незнакомом формате.") : text
            }
        }
    }

    static func fetch() async throws -> LimitSnapshot {
        guard let binary else { throw Failure.notFound }
        let data = try await Task.detached(priority: .utility) { try run(binary) }.value
        return try parse(data, now: Date())
    }

    private static func run(_ binary: URL) throws -> Data {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-p", "/usage", "--output-format", "json"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning {
            if Date() > deadline { process.terminate(); throw Failure.timeout }
            Thread.sleep(forTimeInterval: 0.1)
        }
        // ponytail: read after exit; the reply is a few KB, far below the pipe buffer.
        return out.fileHandleForReading.readDataToEndOfFile()
    }

    /// Antigravity groups its models; each group has a 5-hour and a weekly limit. The first group
    /// (Gemini, its default models) gives the main windows, the others come as labelled extras.
    static func parse(_ data: Data, now: Date) throws -> LimitSnapshot {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.unexpected("") }
        guard let groups = ((root["command"] as? [String: Any])?["data"] as? [String: Any])?["groups"] as? [[String: Any]], !groups.isEmpty else {
            throw Failure.unexpected((root["response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        let iso = ISO8601DateFormatter()
        var snapshot = LimitSnapshot(provider: .antigravity, fetchedAt: now, source: "agy /usage")
        for (index, group) in groups.enumerated() {
            let name = (group["name"] as? String ?? "")
                .replacingOccurrences(of: " Models", with: "").replacingOccurrences(of: " models", with: "")
            // The 5-hour window first, then the week, as in the main ring.
            let buckets = (group["buckets"] as? [[String: Any]] ?? [])
                .sorted { ($0["window"] as? String) != "weekly" && ($1["window"] as? String) == "weekly" }
            for bucket in buckets {
                guard let fraction = bucket["remaining_fraction"] as? Double,
                      let reset = (bucket["reset_time"] as? String).flatMap(iso.date(from:)) else { continue }
                let kind: WindowKind = (bucket["window"] as? String) == "weekly" ? .weekly : .session
                var window = LimitWindow(kind: kind, usedPercent: (1 - fraction) * 100, durationMinutes: kind.defaultMinutes, resetsAt: reset)
                if index == 0 {
                    if kind == .session { snapshot.session = window } else { snapshot.weekly = window }
                } else {
                    window.label = "\(name) · \(kind.title)"
                    snapshot.extras.append(window)
                }
            }
        }
        guard snapshot.session != nil || snapshot.weekly != nil else { throw Failure.unexpected("") }
        return snapshot
    }
}
