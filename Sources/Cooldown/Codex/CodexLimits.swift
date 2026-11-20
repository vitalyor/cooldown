import Foundation

enum CodexPaths {
    static var home: URL {
        if let value = ProcessInfo.processInfo.environment["CODEX_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: value)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static var sessions: URL { home.appendingPathComponent("sessions") }

    /// The Codex command line that ships inside the desktop app, or a standalone install.
    static func binary(override: String) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        let custom = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { candidates.append((custom as NSString).expandingTildeInPath) }
        candidates += [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.npm-global/bin/codex",
        ] + ToolPaths.userInstalled("codex")
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}

enum CodexError: LocalizedError {
    case binaryNotFound
    case timeout
    case exited
    case server(String)
    case unexpected

    var errorDescription: String? {
        switch self {
        case .binaryNotFound: return L("Codex не найден. Откройте настройку Cooldown: она установит его по одной кнопке.")
        case .timeout: return L("Codex не ответил за 20 секунд.")
        case .exited: return L("Codex завершился, не прислав ответ.")
        case .server(let message): return L("Codex вернул ошибку: %@", "\(message)")
        case .unexpected: return L("Codex прислал ответ в незнакомом формате.")
        }
    }
}

/// One read-only JSON-RPC request through `codex app-server`, the same source as Codex's own /status.
enum CodexAppServer {
    static func request(binary: URL, method: String, timeout: TimeInterval = 20) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try requestSync(binary: binary, method: method, timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private final class Flag { var value = false }

    private static func requestSync(binary: URL, method: String, timeout: TimeInterval) throws -> [String: Any] {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["app-server", "--stdio"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = CodexPaths.home.path
        environment["PATH"] = [binary.deletingLastPathComponent().path, "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                               "/opt/homebrew/bin", "/usr/local/bin"].joined(separator: ":")
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let timedOut = Flag()
        let killer = DispatchWorkItem {
            timedOut.value = true
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        defer { killer.cancel() }

        let requests = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"cooldown","version":"0.1.0"}}}"#,
            #"{"method":"initialized"}"#,
            "{\"id\":2,\"method\":\"\(method)\"}",
        ]
        // A codex that already quit (a wrong path, an old version without app-server) must not
        // take Cooldown down with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try input.fileHandleForWriting.write(contentsOf: Data((requests.joined(separator: "\n") + "\n").utf8)) } catch { throw CodexError.exited }

        // Read with a deadline of its own: a child of codex holding the pipe open after it was
        // stopped would otherwise keep this read (and the "refreshing" state) forever.
        let deadline = Date().addingTimeInterval(timeout + 2)
        let fd = output.fileHandleForReading.fileDescriptor
        var chunk = [UInt8](repeating: 0, count: 65_536)
        var buffer = Data()
        while true {
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let wait = deadline.timeIntervalSinceNow
            if wait <= 0 { throw CodexError.timeout }
            let polled = poll(&ready, 1, Int32(min(wait, 1) * 1000))
            if polled == 0 || (polled < 0 && errno == EINTR) { continue }
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { throw timedOut.value ? CodexError.timeout : CodexError.exited }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer = buffer.subdata(in: buffer.index(after: newline)..<buffer.endIndex)
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      Num.int(object["id"]) == 2 else { continue }
                if let error = object["error"] as? [String: Any] {
                    throw CodexError.server(error["message"] as? String ?? L("без описания"))
                }
                guard let result = object["result"] as? [String: Any] else { throw CodexError.unexpected }
                return result
            }
        }
    }
}

enum CodexLimits {
    static func fetch(binaryOverride: String) async throws -> LimitSnapshot {
        guard let binary = CodexPaths.binary(override: binaryOverride) else { throw CodexError.binaryNotFound }
        let result = try await CodexAppServer.request(binary: binary, method: "account/rateLimits/read")
        guard let snapshot = parse(result, now: Date()) else { throw CodexError.unexpected }
        return snapshot
    }

    static func parse(_ result: [String: Any], now: Date) -> LimitSnapshot? {
        guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
        var snapshot = LimitSnapshot(provider: .codex, plan: limits["planType"] as? String, session: nil, weekly: nil,
                                     resetCredits: nil, limitReached: limits["rateLimitReachedType"] as? String != nil,
                                     fetchedAt: now, source: "Codex")
        for key in ["primary", "secondary"] {
            guard let raw = limits[key] as? [String: Any], let used = Num.double(raw["usedPercent"]),
                  let resets = Num.double(raw["resetsAt"]) else { continue }
            let minutes = Num.int(raw["windowDurationMins"]) ?? (key == "primary" ? 300 : 10080)
            let window = LimitWindow(kind: .from(minutes: minutes), usedPercent: min(100, max(0, used)),
                                     durationMinutes: minutes, resetsAt: Date(timeIntervalSince1970: resets))
            if window.kind == .session { snapshot.session = window } else { snapshot.weekly = window }
        }
        if let credits = result["rateLimitResetCredits"] as? [String: Any] {
            snapshot.resetCredits = Num.int(credits["availableCount"])
        }
        guard snapshot.session != nil || snapshot.weekly != nil else { return nil }
        return snapshot
    }
}
