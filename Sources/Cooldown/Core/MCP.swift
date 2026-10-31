import AppKit
import Darwin
import Foundation

/// Cooldown as an MCP server for Claude Desktop. Claude starts this process with `--mcp`; it
/// speaks JSON-RPC over stdio and offers a small, read-only bridge plus a way for Claude to say
/// that an answer is finished. It never sends anything into a chat and never reads cookies.
///
/// The server is registered only when the person turns it on in Settings: the config file belongs
/// to Claude, and Cooldown keeps every other server in it untouched.
enum CooldownMCP {
    static let name = "cooldown"

    static var configURL: URL {
        if let path = ProcessInfo.processInfo.environment["COOLDOWN_CLAUDE_CONFIG"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    static var eventsURL: URL { Settings.appSupport.appendingPathComponent("mcp-events.jsonl") }
    /// Questions asked through MCP: one `.json` request in, one `.json` answer out.
    static var asksURL: URL {
        if let path = ProcessInfo.processInfo.environment["COOLDOWN_MCP_ASKS"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return Settings.appSupport.appendingPathComponent("mcp-asks", isDirectory: true)
    }

    static var isInstalled: Bool {
        guard let root = try? readConfig(), let servers = root["mcpServers"] as? [String: Any],
              let entry = servers[name] as? [String: Any], let command = entry["command"] as? String else { return false }
        return command == executable
    }

    static var executable: String { Bundle.main.executablePath ?? "/Applications/Cooldown.app/Contents/MacOS/Cooldown" }

    static func install() throws {
        var root = try readConfig()
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[name] = ["command": executable, "args": ["--mcp"]]
        root["mcpServers"] = servers
        try writeConfig(root)
    }

    static func uninstall() throws {
        var root = try readConfig()
        guard var servers = root["mcpServers"] as? [String: Any] else { return }
        servers.removeValue(forKey: name)
        if servers.isEmpty { root.removeValue(forKey: "mcpServers") } else { root["mcpServers"] = servers }
        try writeConfig(root)
    }

    private static func readConfig() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return [:] }
        let data = try Data(contentsOf: configURL)
        guard !data.isEmpty else { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Cooldown", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "claude_desktop_config.json has an unexpected format; Cooldown leaves it alone."])
        }
        return root
    }

    private static func writeConfig(_ root: [String: Any]) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: configURL.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = configURL.deletingLastPathComponent().appendingPathComponent("claude_desktop_config.json.bak-cooldown-\(stamp)")
            try? fm.copyItem(at: configURL, to: backup)
        }
        try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: configURL, options: .atomic)
    }

    // MARK: Running as the MCP server

    /// The stdio loop. Only JSON-RPC goes to stdout; diagnostics go nowhere, so a client never
    /// sees a stray line.
    static func run() -> Never {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            handle(message)
        }
        exit(0)
    }

    private static func handle(_ message: [String: Any]) {
        let method = message["method"] as? String ?? ""
        guard let id = message["id"] else {
            // A notification (initialized, cancelled): nothing to answer.
            return
        }
        switch method {
        case "initialize":
            reply(id, ["protocolVersion": "2025-06-18",
                       "capabilities": ["tools": [String: Any]()],
                       "serverInfo": ["name": name, "version": "1.0"]])
        case "ping":
            reply(id, [String: Any]())
        case "tools/list":
            reply(id, ["tools": tools])
        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            call(id, name: params["name"] as? String ?? "", arguments: params["arguments"] as? [String: Any] ?? [:])
        default:
            error(id, code: -32601, message: "Method not found")
        }
    }

    private static func call(_ id: Any, name: String, arguments: [String: Any]) {
        switch name {
        case "cooldown_limits":
            reply(id, text(limitsText()))
        case "cooldown_status":
            reply(id, text("Cooldown MCP is running. Events are written to \(eventsURL.path)."))
        case "cooldown_report_finished":
            let summary = (arguments["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty, summary.count <= 4000 else {
                reply(id, text("summary is required and must be at most 4000 characters", error: true))
                return
            }
            let title = (arguments["title"] as? String).map { String($0.prefix(120)) }
            let needsInput = JSON.bool(arguments["needs_input"]) ?? false
            let event: [String: Any] = ["id": UUID().uuidString.lowercased(), "at": Date().timeIntervalSince1970,
                                        "title": title ?? "Claude", "summary": summary, "needs_input": needsInput]
            do {
                try append(event)
                reply(id, text("Cooldown recorded the event."))
            } catch {
                reply(id, text("Could not write the event: \(error.localizedDescription)", error: true))
            }
        case "cooldown_ask":
            ask(id, arguments: arguments)
        default:
            error(id, code: -32602, message: "Unknown tool: \(name)")
        }
    }

    private static var tools: [[String: Any]] {
        [
            ["name": "cooldown_limits",
             "description": "Claude plan limits as Cooldown last read them (five-hour and weekly windows).",
             "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false]],
            ["name": "cooldown_status",
             "description": "Whether the Cooldown bridge is alive and where its events go.",
             "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false]],
            ["name": "cooldown_report_finished",
             "description": "Tell Cooldown that this answer is finished, so the Mac and iPhone can show it.",
             "inputSchema": ["type": "object",
                             "properties": ["summary": ["type": "string", "maxLength": 4000],
                                            "title": ["type": "string", "maxLength": 120],
                                            "needs_input": ["type": "boolean"]],
                             "required": ["summary"], "additionalProperties": false]],
            ["name": "cooldown_ask",
             "description": "Ask the person a question through Cooldown's card on the Mac or iPhone. Blocks until they answer or the timeout passes; the answer is returned as text.",
             "inputSchema": ["type": "object",
                             "properties": ["question": ["type": "string", "maxLength": 4000],
                                            "options": ["type": "array", "maxItems": 6,
                                                        "items": ["type": "string", "maxLength": 160]],
                                            "allow_text": ["type": "boolean"],
                                            "timeout_seconds": ["type": "integer", "minimum": 10, "maximum": 1800]],
                             "required": ["question"], "additionalProperties": false]],
        ]
    }

    private static func ask(_ id: Any, arguments: [String: Any]) {
        let question = (arguments["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= 4000 else {
            reply(id, text("question is required and must be at most 4000 characters", error: true))
            return
        }
        let options = (arguments["options"] as? [String] ?? []).map { String($0.prefix(160)) }.filter { !$0.isEmpty }.prefix(6)
        let allowText = JSON.bool(arguments["allow_text"]) ?? false
        guard !options.isEmpty || allowText else {
            reply(id, text("Give at least one option or allow_text", error: true))
            return
        }
        let timeout = min(1800, max(10, Int(JSON.number(arguments["timeout_seconds"]) ?? 300)))
        let token = UUID().uuidString.lowercased()
        let request = asksURL.appendingPathComponent("\(token).json")
        let response = asksURL.appendingPathComponent("\(token).res")
        let payload: [String: Any] = ["id": token, "question": question, "options": Array(options),
                                      "allow_text": allowText, "expires": Date().timeIntervalSince1970 + Double(timeout)]
        do {
            try FileManager.default.createDirectory(at: asksURL, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: asksURL.path)
            try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).write(to: request, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: request.path)
        } catch {
            reply(id, text("Could not create the question: \(error.localizedDescription)", error: true))
            return
        }
        defer {
            try? FileManager.default.removeItem(at: request)
            try? FileManager.default.removeItem(at: response)
        }
        let deadline = Date().addingTimeInterval(Double(timeout))
        while Date() < deadline {
            if let data = try? Data(contentsOf: response),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let answer = object["answer"] as? String {
                reply(id, text(answer))
                return
            }
            usleep(250_000)
        }
        reply(id, text("The person did not answer in time. Continue without the answer or ask again later.", error: true))
    }

    private static func limitsText() -> String {
        guard let data = try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cache = root["cachedUsageUtilization"] as? [String: Any],
              let usage = cache["utilization"] as? [String: Any] else {
            return "No cached Claude limits are available yet."
        }
        var lines: [String] = []
        if let five = usage["five_hour"] as? [String: Any], let percent = Num.double(five["utilization"]) {
            lines.append("five-hour: \(Int(percent.rounded()))% used" + resetSuffix(five["resets_at"]))
        }
        if let week = usage["seven_day"] as? [String: Any], let percent = Num.double(week["utilization"]) {
            lines.append("weekly: \(Int(percent.rounded()))% used" + resetSuffix(week["resets_at"]))
        }
        if let millis = Num.double(cache["fetchedAtMs"]) {
            let fetched = Date(timeIntervalSince1970: millis / 1000)
            lines.append("read at: \(fetched.formatted(date: .abbreviated, time: .standard))")
        }
        return lines.isEmpty ? "No cached Claude limits are available yet." : lines.joined(separator: "\n")
    }

    private static func resetSuffix(_ raw: Any?) -> String {
        guard let text = raw as? String, let date = ISO8601DateFormatter().date(from: text) else { return "" }
        return ", resets \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private static func append(_ event: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        var line = data
        line.append(0x0A)
        try FileManager.default.createDirectory(at: eventsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(eventsURL.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(fd) }
        try line.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { throw CocoaError(.fileWriteUnknown) }
                offset += written
            }
        }
    }

    // MARK: Wire

    private static func reply(_ id: Any, _ result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func error(_ id: Any, code: Int, message: String) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func text(_ text: String, error: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": error]
    }

    private static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

/// Reads the events Claude's MCP tool writes and turns them into the same cards as hooks.
@MainActor
final class MCPEventReader {
    static let shared = MCPEventReader()

    private var offset: UInt64 = 0
    private var timer: Timer?

    func start() {
        offset = size()
        timer = Timer.every(10) { _ in
            Task { @MainActor in MCPEventReader.shared.poll() }
        }
    }

    private func size() -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: CooldownMCP.eventsURL.path))?[.size] as? UInt64) ?? 0
    }

    private func poll() {
        let end = size()
        if end < offset { offset = 0 }
        guard end > offset, let handle = try? FileHandle(forReadingFrom: CooldownMCP.eventsURL) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: Int(min(end - offset, 1 << 20))),
              let last = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex...last]
        offset += UInt64(complete.count)
        for line in complete.split(separator: 0x0A) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let id = object["id"] as? String, let summary = object["summary"] as? String else { continue }
            let at = Date(timeIntervalSince1970: Num.double(object["at"]) ?? Date().timeIntervalSince1970)
            guard Date().timeIntervalSince(at) < 10 * 60 else { continue }
            let title = object["title"] as? String ?? "Claude"
            if JSON.bool(object["needs_input"]) == true {
                ToastController.shared.show(ToastContent(key: "mcp-\(id)", kind: .attention, provider: .claude,
                                                         title: L("Claude просит ответа"), body: summary,
                                                         actions: [.openClaude], life: .sticky))
            } else if Settings.watchClaudeWindow {
                // The window watcher already announces a finished answer under the chat's own id.
                // This is the same turn; put it in the feed without a second card.
                EventLog.shared.add(CooldownEvent(kind: .finished, provider: .claude, title: title, body: summary))
            } else {
                AgentActivity.shared.finished(.claude, key: "mcp:\(id)", title: title, message: summary, duration: nil,
                                              source: .hook, opener: .claudeApp, at: at)
            }
        }
    }
}
