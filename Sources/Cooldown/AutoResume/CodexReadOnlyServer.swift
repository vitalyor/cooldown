import Foundation

/// Read-only questions to `codex app-server` (Codex's official interface, signed in with Codex's
/// own account): the limits, the conversation list and one conversation's saved history. Any
/// other method is refused here, so this path can never start work or touch the account.
final class CodexReadOnlyServer {
    static let methods: Set<String> = ["account/rateLimits/read", "thread/list", "thread/read"]
    static let maxResponse = 32 * 1024 * 1024

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var counter = 0
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 25) throws {
        self.timeout = timeout
        guard let binary = CodexPaths.binary(override: Settings.codexPath) else { throw CodexError.binaryNotFound }
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
        try process.run()
        do {
            _ = try call("initialize", ["clientInfo": ["name": "cooldown", "version": "1.0"]])
            try write(["method": "initialized"])
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func close() {
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
    }

    func query(_ method: String, _ params: [String: Any]? = nil) throws -> [String: Any] {
        guard Self.methods.contains(method) else {
            throw CodexError.server(L("это соединение разрешает только чтение лимитов и диалогов"))
        }
        return try call(method, params)
    }

    private func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func call(_ method: String, _ params: [String: Any]?) throws -> [String: Any] {
        counter += 1
        let id = counter
        var request: [String: Any] = ["id": id, "method": method]
        if let params { request["params"] = params }
        try write(request)
        let deadline = Date().addingTimeInterval(timeout)
        let handle = output.fileHandleForReading.fileDescriptor
        while true {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let reply = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      Num.int(reply["id"]) == id, reply["method"] == nil else { continue }
                if reply["error"] != nil { throw CodexError.server(L("запрос только для чтения не выполнен; проверьте вход в Codex и сеть")) }
                guard let result = reply["result"] as? [String: Any] else { throw CodexError.unexpected }
                return result
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CodexError.timeout }
            var item = pollfd(fd: handle, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, Int32((remaining * 1000).rounded(.up)))
            if ready == 0 { throw CodexError.timeout }
            if ready < 0 { if errno == EINTR { continue }; throw CodexError.exited }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let got = Darwin.read(handle, &chunk, chunk.count)
            if got <= 0 { throw CodexError.exited }
            buffer.append(contentsOf: chunk[0..<got])
            if buffer.count > Self.maxResponse { throw CodexError.unexpected }
        }
    }

    // MARK: Conversations

    static let sourceKinds = ["cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview", "subAgentCompact",
                              "subAgentThreadSpawn", "subAgentOther", "unknown"]

    /// Every page of the list (never just the first), archived ones too when asked.
    func conversations(archived filters: [Bool] = [false, true]) throws -> [CodexConversation] {
        var rows: [CodexConversation] = []
        var ids = Set<String>()
        let deadline = Date().addingTimeInterval(55)
        for archived in filters {
            var cursor: String?
            var seen = Set<String>()
            repeat {
                guard Date() < deadline else { throw CodexError.server(L("список диалогов ещё не прочитан полностью")) }
                var params: [String: Any] = ["limit": 100, "archived": archived, "sourceKinds": Self.sourceKinds,
                                             "sortKey": "updated_at", "modelProviders": [String]()]
                if let cursor { params["cursor"] = cursor }
                let page = try query("thread/list", params)
                guard let data = page["data"] as? [Any], page.keys.contains("nextCursor") else {
                    throw CodexError.server(L("список диалогов неполон"))
                }
                for row in data {
                    guard let row = row as? [String: Any], let id = row["id"] as? String else { throw CodexError.unexpected }
                    guard ids.insert(id).inserted else { continue }
                    rows.append(CodexConversation(id: id, name: row["name"] as? String, preview: row["preview"] as? String,
                                                  cwd: row["cwd"] as? String, updatedAt: Num.date(row["updatedAt"]), archived: archived))
                }
                if JSON.isNull(page["nextCursor"]) { cursor = nil; break }
                guard let next = JSON.nonEmptyString(page["nextCursor"]), seen.insert(next).inserted else {
                    throw CodexError.server(L("аномальный курсор списка диалогов"))
                }
                cursor = next
            } while cursor != nil
        }
        return rows
    }
}
