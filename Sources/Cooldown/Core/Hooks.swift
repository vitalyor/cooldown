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
    umask 077
    out="$HOME/Library/Application Support/Cooldown/hook-events.jsonl"
    [ -d "$HOME/Library/Application Support/Cooldown" ] || exit 0
    # A Cooldown that was closed for a long time must not let this file grow without limit.
    size=$(stat -f%z "$out" 2>/dev/null || echo 0)
    if [ "$size" -gt 8388608 ]; then
      mv -f "$out" "$out.1" 2>/dev/null || :
    fi
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
    umask 077
    dir="$HOME/Library/Application Support/Cooldown/asks"
    pgrep -xq Cooldown || exit 0
    mkdir -p "$dir" 2>/dev/null || exit 0
    chmod 700 "$dir" 2>/dev/null || exit 0
    # Random and unguessable: another process cannot answer by guessing the file name.
    id="$$-$(uuidgen 2>/dev/null | tr -d '-')"
    [ -n "$id" ] || exit 0
    head -c 1048576 > "$dir/$id.tmp" 2>/dev/null || exit 0
    mv "$dir/$id.tmp" "$dir/$id.req" || exit 0
    i=0
    while [ $i -lt 14000 ]; do
      if [ -f "$dir/$id.res" ]; then cat "$dir/$id.res"; rm -f "$dir/$id.res" "$dir/$id.req" "$dir/$id.ack"; exit 0; fi
      if [ $i -eq 30 ] && [ ! -f "$dir/$id.ack" ]; then rm -f "$dir/$id.req"; exit 0; fi
      # Cooldown quit while Claude waits: release the agent now instead of keeping it for an hour.
      if [ $((i % 40)) -eq 0 ] && ! pgrep -xq Cooldown; then rm -f "$dir/$id.req" "$dir/$id.ack"; exit 0; fi
      if [ $i -lt 40 ]; then sleep 0.05; else sleep 0.25; fi
      i=$((i+1))
    done
    rm -f "$dir/$id.req" "$dir/$id.ack"
    exit 0
    """

    static func writeScript() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.createDirectory(at: asks, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: asks.path)
        for (url, text) in [(script, scriptText), (askScript, askText)] {
            let current = try? String(contentsOf: url, encoding: .utf8)
            if current != text { try text.write(to: url, atomically: true, encoding: .utf8) }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    /// Hooks installed by an earlier version, missing a newer event (Claude's permission cards).
    /// Only events added to the plan since the last install: an entry the person removed on
    /// purpose is not put back on every launch.
    static func needsUpdate(_ agent: Agent) -> Bool {
        guard status(agent) != .off, agent == .claude,
              let root = try? read(agent), let hooks = root["hooks"] as? [String: Any] else { return false }
        let installed = Set(Settings.strings("hookEvents-\(agent)") ?? [])
        return plan(agent).contains { item in
            !installed.contains(item.event) && !((hooks[item.event] as? [[String: Any]]) ?? []).contains(where: isOurs)
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

    static func status(_ agent: Agent) -> Status { status(agent, mark: marker) }

    private static func status(_ agent: Agent, mark: String) -> Status {
        guard let root = try? read(agent), let hooks = root["hooks"] as? [String: Any] else { return .off }
        var ours: [(event: String, group: Int, handler: Int)] = []
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            for (index, group) in groups.enumerated() {
                for (handler, value) in ((group["hooks"] as? [[String: Any]]) ?? []).enumerated()
                where (value["command"] as? String).map({ $0.contains(mark) && !$0.contains(offMarker) }) == true {
                    ours.append((event, index, handler))
                }
            }
        }
        guard !ours.isEmpty else { return .off }
        guard agent == .codex else { return .on }
        // Codex records trust per hook as "<file>:<event_in_snake_case>:<group>:<handler>".
        let config = (try? String(contentsOf: CodexPaths.home.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        let untrusted = ours.filter { item in
            !config.contains("\"\(codexFile.path):\(snake(item.event)):\(item.group):\(item.handler)\"")
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
        return handlers.contains(where: isOurHandler)
    }

    private static func isOurHandler(_ handler: [String: Any]) -> Bool {
        (handler["command"] as? String)?.contains(marker) == true
    }

    static func updatedGroup(_ group: [String: Any], handler: [String: Any]?) -> [String: Any]? {
        guard isOurs(group) else { return group }
        var updated = group
        let handlers = ((group["hooks"] as? [[String: Any]]) ?? []).compactMap { isOurHandler($0) ? handler : $0 }
        guard !handlers.isEmpty else { return nil }
        updated["hooks"] = handlers
        return updated
    }

    /// Another tool that also answers permission requests (Coucou/NotchBuddy is common). Both
    /// handlers will run; Cooldown shows its card, the other may answer first. The person needs to
    /// know before it looks like Cooldown's answer was ignored.
    static func foreignPermissionHook(_ agent: Agent) -> String? {
        guard let root = try? read(agent), let hooks = root["hooks"] as? [String: Any],
              let groups = hooks["PermissionRequest"] as? [[String: Any]] else { return nil }
        return foreignPermissionHook(in: groups)
    }

    static func foreignPermissionHook(in groups: [[String: Any]]) -> String? {
        for group in groups {
            for handler in (group["hooks"] as? [[String: Any]] ?? []) where !isOurHandler(handler) {
                if let command = handler["command"] as? String, !command.isEmpty {
                    return String(command.prefix(80))
                }
            }
        }
        return nil
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
                if let updated = updatedGroup(groups[index], handler: item.handler) { groups[index] = updated }
                hooks[item.event] = groups
                continue
            }
            // Appended last: the groups already there keep their positions (and Codex's trust).
            groups.append(["hooks": [item.handler]])
            hooks[item.event] = groups
        }
        root["hooks"] = hooks
        try write(agent, root)
        Settings.set(plan(agent).map(\.event), forKey: "hookEvents-\(agent)")
    }

    /// What stays in place of Cooldown's handler in Codex when other tools' groups follow it:
    /// Codex trusts a hook by its position, so removing ours would cost theirs their trust.
    static let offMarker = "cooldown-hook-off"
    private static let offHandler: [String: Any] = ["type": "command", "command": "true # \(offMarker)"]

    static func uninstall(_ agent: Agent) throws {
        var root = try read(agent)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard let existing = value as? [[String: Any]] else { continue }
            let othersFollow = agent == .codex && (existing.lastIndex(where: isOurs).map { $0 < existing.count - 1 } ?? false)
            let groups = existing.compactMap { updatedGroup($0, handler: othersFollow ? offHandler : nil) }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        root["hooks"] = hooks
        try write(agent, root)
    }

    // MARK: VPN guard hooks

    /// The guard's own hooks, kept apart from the ones above: another marker, their own groups,
    /// installed and removed only with the guard. They are the one thing here that may stop the
    /// agent: a prompt is held, or work stops between steps, while the route is wrong.
    static let guardMarker = "cooldown-guard"
    static var guardScript: URL { directory.appendingPathComponent("cooldown-guard") }

    /// `$1`: anthropic or openai; `$2`: prompt (before a prompt goes out) or step (before the
    /// next model request inside a turn). Cooldown's fresh reading first; with none (Cooldown
    /// closed, or more than 30 s old) the hook checks the route itself.
    private static let guardText = """
    #!/bin/sh
    # Cooldown VPN guard: lets the agent's request out only while its route is right.
    # The agent's JSON on stdin is not needed; it is drained in the background, so a large one
    # never meets a closed pipe.
    if [ ! -t 0 ]; then exec 3<&0; cat <&3 >/dev/null 2>&1 & exec 3<&-; fi
    dir="$HOME/Library/Application Support/Cooldown/guard"
    service="$1"; when="$2"
    [ -f "$dir/on" ] || exit 0
    # Cooldown moved to the Trash or deleted: the guard is gone, nothing is held.
    app=$(head -n 1 "$dir/on" 2>/dev/null)
    if [ -n "$app" ] && [ ! -d "$app" ]; then exit 0; fi
    now=$(date +%s)
    # Paused (in Cooldown, on a card or from the phone): until the time on the second line, even
    # if Cooldown is closed meanwhile.
    until=$(sed -n 2p "$dir/on" 2>/dev/null)
    case "$until" in ''|*[!0-9]*) ;; *) [ "$now" -lt "$until" ] && exit 0;; esac
    state=""; at=0
    [ -f "$dir/$service" ] && read -r state at < "$dir/$service"
    case "$at" in ''|*[!0-9]*) at=0;; esac
    # A fresh answer from Cooldown counts; "unchecked" (a network just changed) is checked here,
    # and so is everything when this terminal names a proxy: its route is not Cooldown's.
    proxy="$HTTPS_PROXY$https_proxy$ALL_PROXY$all_proxy"
    cache="$dir/self-$service"
    cached=""; cached_at=0
    [ -z "$proxy" ] && [ -f "$cache" ] && read -r cached cached_at < "$cache"
    case "$cached_at" in ''|*[!0-9]*) cached_at=0;; esac
    # Cooldown says the network just changed (or never checked it): an own answer from before
    # does not count.
    if [ "$state" = unchecked ] || { [ -n "$state" ] && [ "$at" = 0 ]; }; then cached=""; fi
    if [ -z "$proxy" ] && [ -n "$state" ] && [ "$state" != unchecked ] && [ $((now - at)) -le 30 ]; then
      verdict="$state"
    elif [ -n "$cached" ] && [ $((now - cached_at)) -le 15 ]; then
      # This hook's own check from a moment ago: not repeated on every step.
      verdict="$cached"
    else
      case "$service" in anthropic) hosts="api.anthropic.com claude.ai";; openai) hosts="chatgpt.com api.openai.com";; *) exit 0;; esac
      # Each address the agent talks to, IPv4 and IPv6 apart (per-site VPN rules may let one of
      # them out directly; a VPN that carries one family lets the other out), all at once.
      verdict=unchecked
      tmp=$(mktemp -d "${TMPDIR:-/tmp}/cooldown-guard.XXXXXX" 2>/dev/null)
      if [ -n "$tmp" ]; then
        n=0; jobs=""
        for host in $hosts; do
          for family in -4 -6; do
            n=$((n + 1))
            curl -s "$family" -m 3 --connect-timeout 2 --proto =https "https://$host/cdn-cgi/trace" > "$tmp/$n" 2>/dev/null &
            jobs="$jobs $!"
          done
        done
        wait $jobs
        for answer in "$tmp"/*; do
          loc=$(sed -n 's/^loc=//p' "$answer")
          ip=$(sed -n 's/^ip=//p' "$answer")
          [ -n "$loc" ] || continue
          if grep -qw "$loc" "$dir/forbidden" 2>/dev/null; then verdict=block; break; fi
          if [ -n "$ip" ] && grep -qxF "$ip" "$dir/refused" 2>/dev/null; then verdict=block; break; fi
          verdict=ok
        done
        rm -rf "$tmp"
      fi
      [ -z "$proxy" ] && printf '%s %s' "$verdict" "$now" > "$cache" 2>/dev/null
    fi
    [ "$verdict" = ok ] && exit 0
    msg=$(cat "$dir/msg-$service-$verdict" 2>/dev/null)
    [ -n "$msg" ] || msg="Cooldown: the route is not confirmed, the request was held."
    if [ "$when" = step ]; then
      printf '{"continue":false,"stopReason":"%s"}\n' "$msg"
      exit 0
    fi
    printf '%s\n' "$msg" >&2
    exit 2
    """

    static func writeGuardScript() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if (try? String(contentsOf: guardScript, encoding: .utf8)) != guardText {
            try guardText.write(to: guardScript, atomically: true, encoding: .utf8)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: guardScript.path)
    }

    /// If Cooldown is removed, the command finds no script and lets everything through, so an
    /// agent is never left blocked by a guard that no longer exists.
    static func guardCommand(_ service: String, _ when: String) -> String {
        "/bin/sh -c 'f=\"$HOME/Library/Application Support/Cooldown/hooks/\(guardMarker)\"; [ -x \"$f\" ] || exit 0; exec \"$f\" \(service) \(when)'"
    }

    private static func guardPlan(_ agent: Agent) -> [(event: String, handler: [String: Any])] {
        switch agent {
        case .claude:
            // "block" on failure: a hook that crashed or ran out of time does not let the prompt out.
            func handler(_ when: String) -> [String: Any] {
                ["type": "command", "command": guardCommand("anthropic", when), "timeout": 8, "onFailure": "block"]
            }
            return [("UserPromptSubmit", handler("prompt")), ("PostToolBatch", handler("step"))]
        case .codex:
            return [("UserPromptSubmit", ["type": "command", "command": guardCommand("openai", "prompt"), "timeout": 8,
                                          "statusMessage": "Cooldown: проверяет, что Codex выходит в сеть через VPN"])] // l10n:skip
        }
    }

    static func guardStatus(_ agent: Agent) -> Status { status(agent, mark: guardMarker) }

    private static func isGuard(_ handler: [String: Any]) -> Bool {
        (handler["command"] as? String)?.contains(guardMarker) == true
    }

    static func installGuard(_ agent: Agent) throws {
        try writeGuardScript()
        var root = try read(agent)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for item in guardPlan(agent) {
            var groups = hooks[item.event] as? [[String: Any]] ?? []
            if let index = groups.firstIndex(where: { (($0["hooks"] as? [[String: Any]]) ?? []).contains(where: isGuard) }) {
                var group = groups[index]
                group["hooks"] = ((group["hooks"] as? [[String: Any]]) ?? []).map { isGuard($0) ? item.handler : $0 }
                groups[index] = group
            } else {
                // Last, after everything already there: other hooks keep their places (and Codex's trust).
                groups.append(["hooks": [item.handler]])
            }
            hooks[item.event] = groups
        }
        root["hooks"] = hooks
        try write(agent, root)
    }

    static func uninstallGuard(_ agent: Agent) throws {
        var root = try read(agent)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        var changed = false
        for (event, value) in hooks {
            guard let existing = value as? [[String: Any]] else { continue }
            // Codex trusts a hook by its position. A guard group with others after it stays where it
            // is (it does nothing once the guard is off), so theirs keep their places and their trust.
            if agent == .codex, let index = existing.lastIndex(where: { (($0["hooks"] as? [[String: Any]]) ?? []).contains(where: isGuard) }),
               index < existing.count - 1 {
                continue
            }
            let groups = existing.compactMap { group -> [String: Any]? in
                let handlers = (group["hooks"] as? [[String: Any]]) ?? []
                guard handlers.contains(where: isGuard) else { return group }
                changed = true
                let kept = handlers.filter { !isGuard($0) }
                guard !kept.isEmpty else { return nil }
                var updated = group
                updated["hooks"] = kept
                return updated
            }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        guard changed else { return }
        root["hooks"] = hooks
        try write(agent, root)
    }

    /// A copy of a settings file before Cooldown changes it; the newest three are kept (they hold
    /// the person's whole settings, secrets in `env` included, so they must not pile up).
    static func backup(_ url: URL, keep: Int = 3) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let folder = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".bak-cooldown-"
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? fm.copyItem(at: url, to: folder.appendingPathComponent(prefix + stamp))
        // The stamps sort by time as text.
        let old = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(prefix) }.sorted().dropLast(keep)
        for name in old { try? fm.removeItem(at: folder.appendingPathComponent(name)) }
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
        backup(url)
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
        if end < offset {
            // The hook script moved an oversized file to .1. Read what we had not seen yet
            // before starting on the new file, otherwise a finished turn or permission can be lost.
            let old = URL(fileURLWithPath: AgentHooks.events.path + ".1")
            let oldEnd = (try? FileManager.default.attributesOfItem(atPath: old.path))?[.size] as? UInt64 ?? 0
            if oldEnd > offset, let handle = try? FileHandle(forReadingFrom: old) {
                defer { try? handle.close() }
                try? handle.seek(toOffset: offset)
                if let data = try? handle.read(upToCount: Int(min(oldEnd - offset, 4 << 20))) {
                    consume(data)
                }
            }
            offset = 0
        }
        guard end > offset, let handle = try? FileHandle(forReadingFrom: AgentHooks.events) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: Int(min(end - offset, 4 << 20))) else { return }
        // Only whole lines; a line still being written waits for the next look.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = data[data.startIndex...lastNewline]
        offset += UInt64(complete.count)
        consume(Data(complete))
        // Keep the file small: once everything in it is read, start it again.
        if offset > 2 << 20, offset == size() {
            try? FileManager.default.removeItem(at: AgentHooks.events)
            offset = 0
        }
    }

    private func consume(_ data: Data) {
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let agent = (object["agent"] as? String).flatMap(AgentHooks.Agent.init(rawValue:)),
                  let payload = object["p"] as? [String: Any] else { continue }
            let time = Num.date(object["t"]) ?? Date()
            guard Date().timeIntervalSince(time) < 10 * 60 else { continue }
            lastEvent[agent] = time
            if agent == .claude { claude(payload, at: time) } else { codex(payload, at: time) }
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
