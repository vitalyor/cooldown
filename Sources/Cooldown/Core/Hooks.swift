import Foundation

/// Cooldown's hooks in Codex and Claude Code. Both agents run a command at moments of a turn
/// (a prompt sent, a turn finished, a permission asked); Cooldown's command only appends one line
/// to a file and exits, in milliseconds, in the background where the agent allows it. Nothing it
/// prints changes what the agent does. Cooldown reads that file and learns at once what file
/// watching would notice only later, or not at all (Claude Code sessions, permission prompts).
///
/// Installed next to other tools' hooks (Coucou and the like), never in their place: entries are
/// appended as their own groups, and removing Cooldown's leaves the others as they were.
enum AgentHooks {
    enum Agent: String, CaseIterable { case claude, codex }

    enum Status: Equatable {
        case off
        case on
        /// Codex runs a new hook only after the person reviews and trusts it.
        case needsTrust(Int)
    }

    static var directory: URL { Settings.appSupport.appendingPathComponent("hooks", isDirectory: true) }
    static var script: URL { directory.appendingPathComponent("cooldown-hook") }
    static var events: URL { Settings.appSupport.appendingPathComponent("hook-events.jsonl") }
    static let marker = "cooldown-hook"

    /// The whole hook: one line built in memory, appended in one write. Input is capped at 64 KB
    /// (a long final answer is cut, the line then fails to parse and is skipped; nothing breaks).
    private static let scriptText = """
    #!/bin/sh
    # Cooldown hook: notes the event for Cooldown and exits. Prints nothing, never blocks the agent.
    out="$HOME/Library/Application Support/Cooldown/hook-events.jsonl"
    [ -d "$HOME/Library/Application Support/Cooldown" ] || exit 0
    body=$(head -c 65536 | tr -d '\\n\\r')
    [ -n "$body" ] || exit 0
    printf '{"agent":"%s","t":%s,"p":%s}\\n' "$1" "$(date +%s)" "$body" >> "$out" 2>/dev/null
    exit 0
    """

    static var askScript: URL { directory.appendingPathComponent("cooldown-hook-ask") }
    static var asks: URL { Settings.appSupport.appendingPathComponent("asks", isDirectory: true) }

    /// Claude Code's permission hook. At the terminal (or with Cooldown not running) it returns
    /// at once and Claude Code asks as usual; while you are away, Cooldown shows the request as
    /// a card and this waits (up to an hour) for the answer pressed there.
    private static let askText = """
    #!/bin/sh
    # Cooldown: Claude Code's permission request as a card while you are away from the terminal.
    # Prints the answer pressed on the card; prints nothing (Claude Code asks as usual) otherwise.
    dir="$HOME/Library/Application Support/Cooldown/asks"
    pgrep -xq Cooldown || exit 0
    mkdir -p "$dir" 2>/dev/null || exit 0
    id="$$-$(date +%s)"
    head -c 1048576 > "$dir/$id.tmp" 2>/dev/null || exit 0
    mv "$dir/$id.tmp" "$dir/$id.req" || exit 0
    i=0
    while [ $i -lt 14000 ]; do
      if [ -f "$dir/$id.res" ]; then cat "$dir/$id.res"; rm -f "$dir/$id.res" "$dir/$id.req" "$dir/$id.ack"; exit 0; fi
      if [ $i -eq 30 ] && [ ! -f "$dir/$id.ack" ]; then rm -f "$dir/$id.req"; exit 0; fi
      if [ $i -lt 40 ]; then sleep 0.05; else sleep 0.25; fi
      i=$((i+1))
    done
    rm -f "$dir/$id.req" "$dir/$id.ack"
    exit 0
    """

    static func writeScript() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (url, text) in [(script, scriptText), (askScript, askText)] {
            let current = try? String(contentsOf: url, encoding: .utf8)
            if current != text { try text.write(to: url, atomically: true, encoding: .utf8) }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    /// Hooks installed by an earlier version, missing a newer event (Claude's permission cards).
    static func needsUpdate(_ agent: Agent) -> Bool {
        guard status(agent) != .off, agent == .claude,
              let root = try? read(agent), let hooks = root["hooks"] as? [String: Any] else { return false }
        return plan(agent).contains { item in
            !((hooks[item.event] as? [[String: Any]]) ?? []).contains(where: isOurs)
        }
    }

    // MARK: Where each agent keeps hooks

    private static var claudeFile: URL { ClaudePaths.settings }
    private static var codexFile: URL { CodexPaths.home.appendingPathComponent("hooks.json") }

    private static func file(_ agent: Agent) -> URL { agent == .claude ? claudeFile : codexFile }

    /// Events and how each is run. Async where the agent allows it, so the agent never waits;
    /// Codex's permission hook stays in the foreground (a background one there is not run) and
    /// prints nothing, which leaves the decision to the person as usual.
    private static func plan(_ agent: Agent) -> [(event: String, handler: [String: Any])] {
        let quoted = "\"\(script.path)\""
        switch agent {
        case .claude:
            let handler: [String: Any] = ["type": "command", "command": "\(quoted) claude", "async": true, "timeout": 5]
            let ask: [String: Any] = ["type": "command", "command": "\"\(askScript.path)\"", "timeout": 3600]
            return ["UserPromptSubmit", "Stop", "StopFailure", "Notification", "SessionEnd"].map { ($0, handler) }
                + [("PermissionRequest", ask)]
        case .codex:
            let command = "/bin/sh \(quoted) codex"
            // Codex has no name field for a hook; `statusMessage` is the only words it can show,
            // so it says plainly what each one is for.
            func hook(_ message: String, async: Bool, timeout: Int) -> [String: Any] {
                var handler: [String: Any] = ["type": "command", "command": command, "timeout": timeout,
                                              "statusMessage": "Cooldown: \(message)"]
                if async { handler["async"] = true }
                return handler
            }
            return [
                ("UserPromptSubmit", hook("отмечает, что Codex начал работу", async: true, timeout: 5)), // l10n:skip
                ("Stop", hook("сообщает, что Codex закончил", async: true, timeout: 5)), // l10n:skip
                ("PermissionRequest", hook("сообщает, что Codex ждёт вашего решения", async: false, timeout: 5)), // l10n:skip
                ("Interrupt", hook("отмечает, что работа прервана", async: false, timeout: 2)), // l10n:skip
                ("SessionEnd", hook("отмечает конец сессии", async: false, timeout: 2)), // l10n:skip
            ]
        }
    }

    // MARK: Status

    static func status(_ agent: Agent) -> Status {
        guard let root = try? read(agent), let hooks = root["hooks"] as? [String: Any] else { return .off }
        var ours: [(event: String, group: Int)] = []
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            for (index, group) in groups.enumerated() where isOurs(group) { ours.append((event, index)) }
        }
        guard !ours.isEmpty else { return .off }
        guard agent == .codex else { return .on }
        // Codex records trust per hook as "<file>:<event_in_snake_case>:<group>:<handler>".
        let config = (try? String(contentsOf: CodexPaths.home.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        let untrusted = ours.filter { item in
            !config.contains("\"\(codexFile.path):\(snake(item.event)):\(item.group):0\"")
        }
        return untrusted.isEmpty ? .on : .needsTrust(untrusted.count)
    }

    private static func snake(_ event: String) -> String {
        var result = ""
        for (index, character) in event.enumerated() {
            if character.isUppercase && index > 0 { result.append("_") }
            result.append(Character(character.lowercased()))
        }
        return result
    }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        let handlers = group["hooks"] as? [[String: Any]] ?? []
        return handlers.contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    // MARK: Install / remove

    static func install(_ agent: Agent) throws {
        try writeScript()
        var root = try read(agent)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for item in plan(agent) {
            var groups = hooks[item.event] as? [[String: Any]] ?? []
            // Already there: brought up to date in place (same position), otherwise left alone.
            if let index = groups.firstIndex(where: isOurs) {
                groups[index] = ["hooks": [item.handler]]
                hooks[item.event] = groups
                continue
            }
            // Appended last: the groups already there keep their positions (and Codex's trust).
            groups.append(["hooks": [item.handler]])
            hooks[item.event] = groups
        }
        root["hooks"] = hooks
        try write(agent, root)
    }

    static func uninstall(_ agent: Agent) throws {
        var root = try read(agent)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { continue }
            groups.removeAll(where: isOurs)
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        root["hooks"] = hooks
        try write(agent, root)
    }

    private static func read(_ agent: Agent) throws -> [String: Any] {
        let url = file(agent)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Cooldown", code: 1, userInfo: [NSLocalizedDescriptionKey: L("%@ в неожиданном формате, Cooldown его не трогает.", "\(url.lastPathComponent)")])
        }
        return object
    }

    private static func write(_ agent: Agent, _ root: [String: Any]) throws {
        let url = file(agent)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? fm.copyItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).bak-cooldown-\(stamp)"))
        }
        // The same layout these files are written in (sorted keys, pretty), so other tools'
        // entries come out byte-for-byte as they were.
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// Reads what the hooks wrote and passes it on to AgentActivity.
@MainActor
final class HookEventReader {
    static let shared = HookEventReader()

    private var offset: UInt64 = 0
    private var timer: Timer?
    private var watch: FileGrowthWatch?
    private var codexThreads: [String: String] = [:]      // transcript path → conversation id
    private var claudeTitles: [String: (title: String, desktop: Bool)] = [:]
    private var claudeTitlesRead = Date.distantPast
    /// Whether events came recently, per agent: then hooks are the live source.
    private(set) var lastEvent: [AgentHooks.Agent: Date] = [:]

    func start() {
        // Only what happens from now on: older lines were for a Cooldown that was not running.
        offset = size()
        // Read the moment a hook appends a line; a slow timer only as a safety net.
        watch = FileGrowthWatch(AgentHooks.events) {
            MainActor.assumeIsolated { HookEventReader.shared.poll() }
        }
        timer?.invalidate()
        timer = Timer.every(30) { _ in
            Task { @MainActor in HookEventReader.shared.poll() }
        }
    }

    private func size() -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: AgentHooks.events.path))?[.size] as? UInt64) ?? 0
    }

    private func poll() {
        let end = size()
        if end < offset { offset = 0 }              // the file was rotated
        guard end > offset, let handle = try? FileHandle(forReadingFrom: AgentHooks.events) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: Int(min(end - offset, 4 << 20))) else { return }
        // Only whole lines; a line still being written waits for the next look.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = data[data.startIndex...lastNewline]
        offset += UInt64(complete.count)
        for line in complete.split(separator: UInt8(ascii: "\n")) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let agent = (object["agent"] as? String).flatMap(AgentHooks.Agent.init(rawValue:)),
                  let payload = object["p"] as? [String: Any] else { continue }
            let time = Num.date(object["t"]) ?? Date()
            guard Date().timeIntervalSince(time) < 10 * 60 else { continue }
            lastEvent[agent] = time
            if agent == .claude { claude(payload, at: time) } else { codex(payload, at: time) }
        }
        // Keep the file small: once everything in it is read, start it again.
        if offset > 2 << 20, offset == size() {
            try? FileManager.default.removeItem(at: AgentHooks.events)
            offset = 0
        }
    }

    // MARK: Claude Code

    /// The model of the session's latest answer, from the end of its transcript.
    nonisolated static func lastModel(_ path: String?) -> String? {
        guard let path, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65536 ? size - 65536 : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        guard let range = text.range(of: #""model":"(claude-[^"]+)""#, options: [.regularExpression, .backwards]) else { return nil }
        let match = String(text[range]).replacingOccurrences(of: #""model":""#, with: "").dropLast()
        return String(match)
    }

    private func claude(_ p: [String: Any], at time: Date) {
        guard p["agent_id"] == nil, let session = p["session_id"] as? String else { return }   // subagents: the main turn speaks
        // Cooldown's own /usage reads run Claude Code too; they are not the person's work.
        if let cwd = p["cwd"] as? String, cwd.hasPrefix(Settings.appSupport.path) { return }
        let event = p["hook_event_name"] as? String ?? ""
        let info = claudeInfo(session, cwd: p["cwd"] as? String)
        let opener: AgentActivity.Opener = info.desktop ? .claudeApp : .none
        let activity = AgentActivity.shared
        switch event {
        case "UserPromptSubmit":
            activity.started(.claude, key: session, title: info.title, source: .hook, at: time)
        case "Stop":
            activity.finished(.claude, key: session, title: info.title, message: p["last_assistant_message"] as? String ?? "",
                              duration: nil, source: .hook, opener: opener, at: time,
                              project: p["cwd"] as? String, model: Self.lastModel(p["transcript_path"] as? String))
        case "StopFailure":
            let reason = (p["error"] as? String) ?? (p["error_message"] as? String) ?? (p["reason"] as? String) ?? ""
            activity.failed(.claude, key: session, title: info.title, reason: reason, opener: opener)
        case "SessionEnd":
            activity.ended(.claude, key: session)
        case "Notification":
            let type = p["notification_type"] as? String ?? ""
            guard ["permission_prompt", "elicitation_dialog"].contains(type) else { return }
            let message = (p["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? L("Нужно ваше разрешение.")
            activity.waiting(.claude, key: session, title: info.title, reason: message, opener: opener)
        default:
            break
        }
    }

    /// A Claude Code session's name: the one Claude Desktop gave it (Code tab), else its folder.
    private func claudeInfo(_ session: String, cwd: String?) -> (title: String, desktop: Bool) {
        if claudeTitles[session] == nil, Date().timeIntervalSince(claudeTitlesRead) > 20 {
            claudeTitlesRead = Date()
            loadDesktopTitles()
        }
        if let known = claudeTitles[session] { return known }
        let folder = cwd.map { ($0 as NSString).lastPathComponent } ?? ""
        return (folder.isEmpty ? "Claude Code" : folder, false)
    }

    private func loadDesktopTitles() {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let cli = object["cliSessionId"] as? String else { continue }
            let title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Claude Code"
            claudeTitles[cli] = (title, true)
        }
    }

    // MARK: Codex

    private func codex(_ p: [String: Any], at time: Date) {
        let event = p["hook_event_name"] as? String ?? ""
        // The conversation id is the first line of its session file; hooks may carry another id.
        var key = p["session_id"] as? String ?? ""
        if let path = p["transcript_path"] as? String, !path.isEmpty {
            if codexThreads[path] == nil, let id = CodexFinishWatcher.meta(URL(fileURLWithPath: path)).id { codexThreads[path] = id }
            key = codexThreads[path] ?? key
        }
        guard !key.isEmpty else { return }
        if event == "Stop" || event == "PermissionRequest" { AutoResume.shared.poke(key) }
        let thread = CodexThreadIndex.thread(id: key)
        if let thread, !thread.isUser { return }                 // Codex's own reviewers and helpers
        let title = thread?.title ?? AppModel.shared.knownTitle(key) ?? CodexFinishWatcher.indexTitle(key) ?? ""
        let opener: AgentActivity.Opener = thread != nil ? .codexThread(key) : .none
        let activity = AgentActivity.shared
        switch event {
        case "UserPromptSubmit":
            activity.started(.codex, key: key, title: title, source: .hook, at: time)
        case "Stop":
            // Unknown to Codex's index (an id that is not the conversation's): the session files
            // announce this turn under the right id, so only stop showing it busy here.
            guard thread != nil else { activity.ended(.codex, key: key); return }
            activity.finished(.codex, key: key, title: title, message: p["last_assistant_message"] as? String ?? "",
                              duration: nil, source: .hook, opener: opener, at: time)
        case "PermissionRequest":
            let tool = p["tool_name"] as? String
            activity.permissionAsked(.codex, key: key, title: title,
                                     reason: tool.map { L("Codex просит разрешение: %@.", "\($0)") } ?? L("Codex просит разрешение."),
                                     opener: opener, at: time)
        case "Interrupt", "SessionEnd":
            activity.ended(.codex, key: key)
        default:
            break
        }
    }
}
