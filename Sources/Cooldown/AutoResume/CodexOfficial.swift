import Foundation

/// Codex's official `app-server`, used strictly for reading: limits, the list of conversations
/// and a conversation's saved history. Nothing else can be called through it.
final class CodexOfficial {
    static let allowed: Set<String> = ["account/rateLimits/read", "thread/list", "thread/read"]

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextId = 1
    private let deadline: Date

    /// Starts `codex app-server` and introduces Cooldown. The whole session ends by `timeout`.
    init(timeout: TimeInterval = 20) throws {
        guard let binary = CodexPaths.binary(override: Settings.codexPath) else { throw CodexError.binaryNotFound }
        deadline = Date().addingTimeInterval(timeout)
        process.executableURL = binary
        process.arguments = ["app-server", "--stdio"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = CodexPaths.home.path
        environment["PATH"] = [binary.deletingLastPathComponent().path, "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                               "/opt/homebrew/bin", "/usr/local/bin"].joined(separator: ":")
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // If the server dies, writing to it must fail with an error, not kill Cooldown with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        _ = try call("initialize", ["clientInfo": ["name": "cooldown", "version": "1.0"]], setup: true)
        try post(["method": "initialized"])
    }

    deinit { close() }

    func close() {
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
    }

    func rateLimits() throws -> [String: Any] { try call("account/rateLimits/read", nil) }

    /// One saved conversation with its turns.
    func readThread(_ id: String) throws -> [String: Any] {
        let result = try call("thread/read", ["threadId": id, "includeTurns": true])
        guard let thread = result["thread"] as? [String: Any] else { throw CodexError.unexpected }
        return thread
    }

    /// Every conversation, page by page (a cursor seen twice means something is wrong).
    func listThreads(archived: Bool) throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            var params: [String: Any] = ["limit": 100, "archived": archived, "sortKey": "updated_at", "modelProviders": [String](),
                                         "sourceKinds": ["cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview",
                                                         "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown"]]
            cursor.map { params["cursor"] = $0 }
            let result = try call("thread/list", params)
            rows += (result["data"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            cursor = JSON.nonEmptyString(result["nextCursor"])
            if let cursor, !seen.insert(cursor).inserted { throw CodexError.unexpected }
        } while cursor != nil
        return rows
    }

    // MARK: Wire

    private func call(_ method: String, _ params: [String: Any]?, setup: Bool = false) throws -> [String: Any] {
        guard setup || Self.allowed.contains(method) else { throw CodexError.unexpected }
        let id = nextId
        nextId += 1
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        try post(message)
        while true {
            let line = try readLine()
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  JSON.number(object["id"]) == Double(id) else { continue }   // notifications and the like
            if let error = object["error"] as? [String: Any] {
                throw CodexError.server(error["message"] as? String ?? L("без описания"))
            }
            guard let result = object["result"] as? [String: Any] else { throw CodexError.unexpected }
            return result
        }
    }

    private func post(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func readLine() throws -> Data {
        let handle = output.fileHandleForReading
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer = Data(buffer[buffer.index(after: newline)...])
                return line
            }
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { close(); throw CodexError.timeout }
            var item = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, Int32(min(left, 1) * 1000) + 1)
            if ready < 0 && errno != EINTR { throw CodexError.exited }
            guard ready > 0 else { continue }
            let chunk = handle.availableData
            if chunk.isEmpty { throw CodexError.exited }
            buffer.append(chunk)
        }
    }
}
