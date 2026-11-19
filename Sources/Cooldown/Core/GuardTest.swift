import AppKit
import Darwin

/// `Cooldown --guard-test <home> <dummy.app>`: the VPN guard end to end, with made-up answers to
/// "where do I come from". Its own settings and folder under <home> (never the real ones), no
/// cards, notifications or phone, no hooks in the real agents; it freezes only <dummy.app>, a
/// throwaway app bundle whose process stands in for Claude Desktop.
///
/// `Cooldown --guard-test-hold <home> <dummy.app>` freezes the dummy and waits to be killed: the
/// watcher must then let the dummy go on by itself.
///
/// `Cooldown --guard-hooks-test` installs and removes the guard's hooks in copies of the agents'
/// settings (CLAUDE_CONFIG_DIR and CODEX_HOME must point elsewhere, or it refuses).
@MainActor
enum GuardTest {
    static func setUp(home: String, dummy: String, extra: [String] = []) {
        let root = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Cooldown", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Settings.testRoot = root
        let suite = "cooldown-guard-test-\(getpid())"
        Settings.testDefaults = UserDefaults(suiteName: suite)
        Settings.testDefaults?.removePersistentDomain(forName: suite)
        RouteGuard.quiet = true
        RouteGuard.installsHooks = false
        ProviderID.testShown = [.codex, .claude]
        // The dummy stands in for Claude Desktop; nothing else is ever frozen.
        Freezer.resolve = { ids in ids.contains("com.anthropic.claudefordesktop") ? [([dummy + "/"] + extra, "Dummy")] : [] }
    }

    static func run(home: String, dummy: String) async -> [String] {
        setUp(home: home, dummy: dummy)
        var failures: [String] = []
        func expect(_ ok: Bool, _ name: String) { if !ok { failures.append(name) } }
        let guardian = RouteGuard.shared
        let defaults = Settings.testDefaults!
        let us = RouteExit(ip: "64.0.0.1", country: "US", colo: "ORD")
        let us2 = RouteExit(ip: "64.0.0.2", country: "US", colo: "ORD")
        let ru = RouteExit(ip: "95.0.0.1", country: "RU", colo: "ARN")
        func direct(_ exit: RouteExit?) -> RouteTrace { RouteTrace(direct: exit) }
        var answers: [GuardService: RouteTrace] = [.anthropic: direct(us), .openai: direct(us)]
        var calls: [GuardService: Int] = [:]
        var delay: Duration = .zero
        RouteGuard.tracer = { service in
            calls[service, default: 0] += 1
            if delay > .zero { try? await Task.sleep(for: delay) }
            return answers[service] ?? RouteTrace()
        }
        let dummyPid = Freezer.processes(in: [[dummy + "/"]]).first
        expect(dummyPid != nil, "setup: the dummy app is running")
        func running() -> Bool { let s = dummyPid.map(state) ?? "?"; return s.hasPrefix("S") || s.hasPrefix("R") }
        func frozen() -> Bool { (dummyPid.map(state) ?? "").hasPrefix("T") }
        func hookState(_ service: String) -> String {
            (try? String(contentsOf: RouteGuard.dir.appendingPathComponent(service), encoding: .utf8))?.split(separator: " ").first.map(String.init) ?? ""
        }
        func hook(_ service: String, _ when: String, env: [String: String] = [:]) -> (Int32, String) {
            let process = Process()
            process.executableURL = AgentHooks.guardScript
            process.arguments = [service, when]
            process.environment = ["HOME": home, "PATH": "/usr/bin:/bin"].merging(env) { $1 }
            let out = Pipe()
            process.standardOutput = out
            process.standardError = out
            try? process.run()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        let on = RouteGuard.dir.appendingPathComponent("on")

        // 1. Off: nothing is held, nothing is asked.
        expect(RouteGuard.allows(.claude) && RouteGuard.allows(.codex) && RouteGuard.allows(.antigravity), "off: everything allowed")

        // 2. On, both routes through the US: all goes, hooks see "ok".
        Settings.set(true, forKey: SettingsKey.guardEnabled)
        guardian.apply()
        await guardian.round()
        expect(RouteGuard.allows(.claude) && RouteGuard.allows(.codex) && RouteGuard.allows(.antigravity), "US: everything allowed")
        expect(hookState("anthropic") == "ok" && hookState("openai") == "ok", "US: hooks told ok")
        expect((try? String(contentsOf: on, encoding: .utf8))?.contains(".app") == true, "US: hooks on, with Cooldown's path")
        expect(guardian.shown["route-guard"] == nil, "US: no warning card")
        expect(running(), "US: dummy app running")
        expect(hook("anthropic", "prompt").0 == 0, "US: hook lets the prompt out")
        expect(Settings.guardExits["anthropic"]?[us.ip] != nil, "US: first exit learned")

        // 3. Only Anthropic leaks to Russia: only Claude stops; the card is about Claude only.
        answers[.anthropic] = direct(ru)
        await guardian.round()
        expect(!RouteGuard.allows(.claude), "Claude via RU: Claude held")
        expect(RouteGuard.allows(.codex), "Claude via RU: Codex goes on")
        expect(RouteGuard.allows(.antigravity), "Claude via RU: Antigravity goes on (not every route is wrong)")
        expect(hookState("anthropic") == "block" && hookState("openai") == "ok", "Claude via RU: hook states")
        expect(frozen(), "Claude via RU: Claude's app frozen")
        let card = guardian.shown["route-guard"]
        expect(card.map { $0.title.contains("Claude") && !$0.title.contains("Codex") } ?? false, "Claude via RU: card names Claude only")
        let blocked = hook("anthropic", "prompt")
        expect(blocked.0 == 2 && blocked.1.contains("VPN"), "Claude via RU: hook holds the prompt with a message")
        let step = hook("anthropic", "step")
        expect(step.0 == 0 && step.1.contains("\"continue\":false"), "Claude via RU: hook stops work between steps")
        expect((try? JSONSerialization.jsonObject(with: Data(step.1.utf8))) != nil, "Claude via RU: the step answer is valid JSON")
        expect(hook("openai", "prompt").0 == 0, "Claude via RU: Codex hook still lets prompts out")
        var gateThrew = false
        do { try await RouteGuard.gate(.claude) } catch { gateThrew = true }
        expect(gateThrew, "Claude via RU: Cooldown's own requests to Claude refused")

        // 4. Both through Russia (the VPN is down): everything stops, one card for both.
        answers[.openai] = direct(ru)
        await guardian.round()
        expect(!RouteGuard.allows(.claude) && !RouteGuard.allows(.codex) && !RouteGuard.allows(.antigravity), "VPN down: all held")
        expect(guardian.shown["route-guard"].map { $0.body.contains("Claude") && $0.body.contains("Codex") } ?? false, "VPN down: one card names both")

        // 5. The VPN is back: everything goes on, the app thaws, "VPN is back".
        answers = [.anthropic: direct(us), .openai: direct(us)]
        await guardian.round()
        expect(RouteGuard.allows(.claude) && RouteGuard.allows(.codex), "VPN back: allowed again")
        expect(running(), "VPN back: app thawed")
        expect(guardian.shown["route-guard"] == nil && guardian.shown["route-ok"] != nil, "VPN back: warning gone, 'back' card shown")

        // 6. One lost answer holds requests but neither freezes nor warns; the second does.
        answers[.anthropic] = direct(nil)
        await guardian.round()
        expect(!RouteGuard.allows(.claude), "one lost answer: requests held")
        expect(running() && guardian.shown["route-guard"] == nil, "one lost answer: no freeze, no card")
        await guardian.round()
        expect(frozen(), "two lost answers: frozen")
        expect(guardian.shown["route-guard"]?.title.contains(L("Не удалось проверить маршрут к %@", "Claude")) ?? false, "two lost answers: 'could not check' card")
        answers[.anthropic] = direct(us)
        await guardian.round()
        expect(running(), "answers back: thawed")

        // 7. The router moves to another US server: work goes on, a card asks; an old card's
        //    answer changes nothing.
        answers[.anthropic] = direct(us2)
        await guardian.round()
        expect(RouteGuard.allows(.claude), "new US exit: work not stopped")
        expect(guardian.pending["anthropic|\(us2.ip)"]?.exit == us2 && guardian.shown["route-exit"] != nil, "new US exit: card asks")
        await guardian.round()
        expect(guardian.pending.count == 1, "new US exit: asked once, not every check")
        guardian.dismissForTest("route-exit")
        expect(!guardian.answerExit(.remember, key: "anthropic|9.9.9.9"), "old card: answer ignored")
        expect(guardian.pending["anthropic|\(us2.ip)"] != nil && guardian.shown["route-exit"] != nil, "old card: still waiting, card back")
        let phoneIDs = guardian.shown["route-exit"]?.actions.compactMap(PhoneLink.actionID) ?? []
        expect(phoneIDs.allSatisfy { $0.hasSuffix(guardian.pendingKey) }, "phone: buttons carry the card's addresses")
        guardian.answerExit(.refuse, key: guardian.pendingKey)
        await guardian.round()
        expect(!RouteGuard.allows(.claude) && hook("anthropic", "prompt").0 == 2, "refused exit: held")
        guardian.forget(.anthropic, ip: us2.ip)
        await guardian.round()
        guardian.answerExit(.remember, key: guardian.pendingKey)
        await guardian.round()
        expect(RouteGuard.allows(.claude) && Settings.guardExits["anthropic"]?[us2.ip] != nil, "remembered exit: allowed and kept")

        // 8. A reading too old counts for nothing.
        if var old = RouteGuard.state.get(.openai) {
            old.at = Date().addingTimeInterval(-RouteGuard.freshFor - 5)
            RouteGuard.state.set(.openai, old)
        }
        expect(!RouteGuard.allows(.codex), "stale reading: held")
        await guardian.round()

        // 9. A network change: requests wait for a new check, but nothing freezes on a guess.
        guardian.pathChanged(true)
        expect(!RouteGuard.allows(.claude), "network change: requests wait")
        expect(running() && guardian.shown["route-guard"] == nil, "network change: no freeze, no card before the check")
        expect(hook("anthropic", "prompt").0 == 0, "network change: hook checks by itself (real route)")
        await guardian.round()
        expect(RouteGuard.allows(.claude), "network change: allowed after the check")

        // 10. The network changes during a check: the old results are dropped and it checks again.
        delay = .milliseconds(300)
        async let during: Void = guardian.round()
        try? await Task.sleep(for: .milliseconds(100))
        answers[.anthropic] = direct(ru)
        guardian.pathChanged(true)
        await during
        expect(!RouteGuard.allows(.claude) && frozen(), "change mid-check: the new route counts")
        delay = .zero
        answers[.anthropic] = direct(us2)
        await guardian.round()

        // 11. A system proxy: the app goes through it (fine), the terminal goes direct (RU).
        answers[.anthropic] = RouteTrace(direct: ru, viaProxy: us2, proxied: true)
        await guardian.round()
        expect(running(), "proxy: the app is not frozen")
        expect(!RouteGuard.allows(.claude) && hookState("anthropic") == "block", "proxy: terminal agents held")
        expect(guardian.shown["route-guard"] == nil && guardian.shown["route-cli"] != nil, "proxy: a quiet note, not an alarm")
        calls = [:]
        var refused = false
        do { try await RouteGuard.gate(.claude) } catch { refused = true }
        expect(refused && calls.isEmpty, "proxy: a refused own request starts no extra check")
        // Both exits new at once (router VPN and proxy): each asked about once.
        let d = RouteExit(ip: "64.0.0.7", country: "US", colo: "ORD"), p = RouteExit(ip: "64.0.0.8", country: "US", colo: "ORD")
        answers[.anthropic] = RouteTrace(direct: d, viaProxy: p, proxied: true)
        await guardian.round()
        await guardian.round()
        expect(guardian.pending.count == 2, "two new exits: both waiting, each once (\(guardian.pending.count))")
        guardian.answerExit(.remember, key: guardian.pendingKey)
        await guardian.round()
        expect(guardian.pending.isEmpty && RouteGuard.allows(.claude), "two new exits: one answer covers both")
        answers[.anthropic] = RouteTrace(direct: us2, viaProxy: ru, proxied: true)
        await guardian.round()
        expect(frozen(), "proxy itself leaking: the app is frozen")
        answers[.anthropic] = direct(us2)
        await guardian.round()

        // 12. A hidden agent is neither checked nor frozen nor counted.
        ProviderID.testShown = [.claude]
        calls = [:]
        answers[.openai] = direct(ru)
        await guardian.round()
        expect(calls[.openai] == nil, "hidden Codex: not checked")
        expect(guardian.shown["route-guard"] == nil && running(), "hidden Codex: no card, nothing frozen")
        ProviderID.testShown = [.codex, .claude]
        answers[.openai] = direct(us)
        await guardian.round()

        // 13. Two checks at once: the second waits its turn instead of running alongside.
        calls = [:]
        delay = .milliseconds(300)
        async let first: Void = guardian.round()
        async let second: Void = guardian.round()
        _ = await (first, second)
        expect(calls[.anthropic] == 1 && calls[.openai] == 1, "two rounds at once: each service asked once")
        delay = .zero

        // 14. Paused: all goes, hooks off, nothing checked; resumed: on again.
        answers = [.anthropic: direct(ru), .openai: direct(ru)]
        await guardian.round()
        guardian.pause(3600)
        calls = [:]
        await guardian.round()
        expect(calls.isEmpty, "paused: nothing checked")
        expect(RouteGuard.allows(.claude) && RouteGuard.allows(.codex), "paused: allowed")
        expect(!FileManager.default.fileExists(atPath: on.path) && hook("anthropic", "prompt").0 == 0, "paused: hooks off")
        expect(running() && guardian.shown["route-guard"] == nil, "paused: thawed, no warning")
        guardian.pause(nil)
        await guardian.round()
        expect(!RouteGuard.allows(.claude) && hook("anthropic", "prompt").0 == 2 && frozen(), "resumed: held again")

        // 15. Turned off during an episode and on again: the warning comes back (no stale flags).
        Settings.set(false, forKey: SettingsKey.guardEnabled)
        guardian.apply()
        expect(running() && RouteGuard.allows(.claude), "off: thawed and allowed")
        Settings.set(true, forKey: SettingsKey.guardEnabled)
        guardian.apply()
        await guardian.round()
        expect(guardian.shown["route-guard"] != nil && frozen(), "on again: warned and frozen again")

        // 16. Turned off in the middle of a check: nothing happens afterwards (no freeze, no card).
        answers = [.anthropic: direct(us), .openai: direct(us)]
        await guardian.round()
        answers = [.anthropic: direct(RouteExit(ip: "64.0.0.9", country: "US", colo: "ORD")), .openai: direct(ru)]
        delay = .milliseconds(400)
        async let midway: Void = guardian.round()
        try? await Task.sleep(for: .milliseconds(100))
        Settings.set(false, forKey: SettingsKey.guardEnabled)
        guardian.apply()
        await midway
        delay = .zero
        expect(RouteGuard.allows(.claude) && RouteGuard.allows(.codex) && running(), "off mid-check: allowed, not frozen")
        expect(guardian.pending.isEmpty && guardian.shown["route-exit"] == nil, "off mid-check: no late exit card")
        expect(hook("anthropic", "prompt").0 == 0, "off mid-check: hook lets prompts out")

        // 17. Right after launch Cooldown's own request waits for the first check, then goes.
        answers = [.anthropic: direct(us), .openai: direct(us)]
        Settings.set(true, forKey: SettingsKey.guardEnabled)
        guardian.apply()
        await guardian.round()
        guardian.forgetReadings()
        delay = .milliseconds(300)
        let started = Date()
        var went = false
        do { try await RouteGuard.gate(.codex); went = true } catch {}
        expect(went && Date().timeIntervalSince(started) >= 0.25, "first launch: own request waited for the check, then went")
        delay = .zero

        // 18. The hook on its own: Cooldown deleted, or a proxy named in the terminal.
        try? "block \(Int(Date().timeIntervalSince1970))\n".write(to: RouteGuard.dir.appendingPathComponent("anthropic"), atomically: true, encoding: .utf8)
        try? "/Applications/Cooldown-deleted-\(getpid()).app\n".write(to: on, atomically: true, encoding: .utf8)
        expect(hook("anthropic", "prompt").0 == 0, "hook: Cooldown deleted, nothing held")
        guardian.writeHookFiles()
        let proxied = hook("anthropic", "prompt", env: ["HTTPS_PROXY": "http://127.0.0.1:9"])
        expect(proxied.0 == 2 && proxied.1.contains(L("Cooldown: не удалось проверить маршрут к %@. Запрос не отправлен — проверьте VPN и повторите.", "Claude")),
               "hook: a terminal proxy is checked by the hook itself")

        // 19. The real thing, over the network: both services answer with a country.
        let realA = await RouteGuard.trace("api.anthropic.com"), realO = await RouteGuard.trace("chatgpt.com")
        expect(realA.direct?.country.count == 2 && realO.direct?.country.count == 2, "real check: both services answered")

        // 20. Turned off: thawed, hooks off, nothing held.
        Settings.set(false, forKey: SettingsKey.guardEnabled)
        guardian.apply()
        expect(RouteGuard.allows(.claude) && RouteGuard.allows(.codex) && running(), "off again: allowed, thawed")
        expect(hook("anthropic", "prompt").0 == 0, "off again: hook lets prompts out")
        return failures
    }

    /// Which processes are taken for an app: its own, what belongs to it, never Cooldown's own
    /// children or other programs the app started. `tree.app` runs `/bin/sleep` as a child.
    static func tree(home: String, dummy: String) -> [String] {
        setUp(home: home, dummy: dummy)
        var failures: [String] = []
        func expect(_ ok: Bool, _ name: String) { if !ok { failures.append(name) } }
        let bundleOnly = Freezer.processes(in: [[dummy + "/"]])
        let withSleep = Freezer.processes(in: [[dummy + "/", "/bin/sleep"]])
        expect(bundleOnly.count == 1, "tree: the app alone (\(bundleOnly.count))")
        expect(withSleep.count == 2, "tree: the app and its child from a folder that belongs to it (\(withSleep.count))")
        // A copy of the app started by Cooldown itself is never taken.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: dummy + "/Contents/MacOS/tree")
        try? child.run()
        usleep(300_000)
        let after = Freezer.processes(in: [[dummy + "/"]])
        expect(!after.contains(child.processIdentifier), "tree: Cooldown's own child left alone")
        child.terminate()
        return failures
    }

    static func hooks() -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ name: String) { if !ok { failures.append(name) } }
        let real = FileManager.default.homeDirectoryForCurrentUser
        func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        guard resolved(ClaudePaths.home) != resolved(real.appendingPathComponent(".claude")),
              resolved(CodexPaths.home) != resolved(real.appendingPathComponent(".codex")) else {
            return ["refused: CLAUDE_CONFIG_DIR / CODEX_HOME point at the real folders"]
        }
        // The guard script goes to a scratch folder too, never the real Cooldown folder.
        Settings.testRoot = ClaudePaths.home.deletingLastPathComponent().appendingPathComponent("cooldown-support")
        let files = [AgentHooks.Agent.claude: ClaudePaths.settings, .codex: CodexPaths.home.appendingPathComponent("hooks.json")]
        func json(_ url: URL) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        }
        func save(_ root: [String: Any], _ url: URL) {
            try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        }
        func groups(_ root: [String: Any], _ event: String) -> [[String: Any]] {
            ((root["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
        }
        func same(_ a: Any, _ b: Any) -> Bool {
            let x = try? JSONSerialization.data(withJSONObject: a, options: .sortedKeys)
            let y = try? JSONSerialization.data(withJSONObject: b, options: .sortedKeys)
            return x != nil && x == y
        }
        func isGuard(_ group: [String: Any]) -> Bool {
            ((group["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.contains(AgentHooks.guardMarker) == true }
        }
        for (agent, url) in files {
            let before = json(url)
            let regular = AgentHooks.status(agent)
            do { try AgentHooks.installGuard(agent) } catch { failures.append("\(agent): install threw \(error)") }
            do { try AgentHooks.installGuard(agent) } catch { failures.append("\(agent): second install threw \(error)") }
            let after = json(url)
            for (event, value) in (before["hooks"] as? [String: Any]) ?? [:] {
                let old = (value as? [[String: Any]]) ?? []
                let new = groups(after, event)
                expect(new.count >= old.count && same(Array(new.prefix(old.count)), old), "\(agent): \(event) entries kept in place")
            }
            for event in agent == .claude ? ["UserPromptSubmit", "PostToolBatch"] : ["UserPromptSubmit"] {
                let added = groups(after, event).filter(isGuard)
                expect(added.count == 1, "\(agent): exactly one guard hook in \(event) after two installs (\(added.count))")
                expect(groups(after, event).last.map(isGuard) ?? false, "\(agent): guard hook last in \(event)")
            }
            expect(AgentHooks.status(agent) == regular, "\(agent): Cooldown's own hooks status unchanged")
            expect(AgentHooks.guardStatus(agent) != .off, "\(agent): guard hook seen as installed")
            if agent == .claude {
                let handler = groups(after, "UserPromptSubmit").last?["hooks"] as? [[String: Any]]
                expect((handler?.first?["onFailure"] as? String) == "block", "claude: guard hook blocks on failure")
            }
            if agent == .codex {
                // Another tool's hook added after the guard: removing the guard must not move it.
                var root = after
                var hooks = root["hooks"] as? [String: Any] ?? [:]
                let later: [String: Any] = ["hooks": [["type": "command", "command": "/bin/true later-tool"]]]
                hooks["UserPromptSubmit"] = groups(after, "UserPromptSubmit") + [later]
                root["hooks"] = hooks
                save(root, url)
                let positions = groups(root, "UserPromptSubmit").count
                try? AgentHooks.uninstallGuard(agent)
                expect(groups(json(url), "UserPromptSubmit").count == positions, "codex: a later hook keeps its place (and trust)")
                hooks["UserPromptSubmit"] = groups(after, "UserPromptSubmit")
                root["hooks"] = hooks
                save(root, url)
            }
            do { try AgentHooks.uninstallGuard(agent) } catch { failures.append("\(agent): uninstall threw \(error)") }
            expect(same(json(url), before), "\(agent): removing the guard restores the file exactly")
            expect(AgentHooks.guardStatus(agent) == .off, "\(agent): guard hook gone")
        }
        return failures
    }

    /// Freezes the dummy, says which process, and waits to be killed.
    static func hold(home: String, dummy: String) -> Never {
        setUp(home: home, dummy: dummy, extra: ["/bin/sleep"])
        Freezer.shared.set(["com.anthropic.claudefordesktop"])
        print("frozen \(Freezer.shared.frozen.map(String.init).joined(separator: " "))")
        fflush(stdout)
        while true { sleep(60) }
    }

    /// `ps` state letters: T stopped, S sleeping, R running.
    static func state(_ pid: pid_t) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "stat=", "-p", String(pid)]
        let out = Pipe()
        process.standardOutput = out
        try? process.run()
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
