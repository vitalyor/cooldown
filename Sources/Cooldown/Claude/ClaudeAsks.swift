import AppKit
import Darwin
import Foundation

/// Claude Code's permission requests and questions (terminal, IDE, the Code tab) as cards.
/// Its permission hook drops each request into a folder and waits; Cooldown answers at once
/// "ask as usual" when you are in the app running that session, and otherwise shows a card and
/// writes back the answer you press. Coming back to that app hands the question back to it.
@MainActor
final class ClaudeAsks {
    static let shared = ClaudeAsks()

    private struct Held {
        var pid: pid_t
        var hostBundle: String?
        var key: String
    }

    private var source: DispatchSourceFileSystemObject?
    private var seen = Set<String>()
    private var held: [String: Held] = [:]
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    func start() {
        let folder = AgentHooks.asks
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Leftovers of hooks that are gone (Cooldown was quit while they waited).
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !Self.alive(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { ClaudeAsks.shared.scan() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                     object: nil, queue: .main) { note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { ClaudeAsks.shared.appActivated(bundle) }
        }
        scan()
    }

    /// The pid at the start of a request file's name: is that hook still waiting?
    private static func alive(_ name: String) -> Bool {
        guard let pid = name.split(separator: "-").first.flatMap({ Int32($0) }) else { return false }
        return kill(pid, 0) == 0
    }

    private func path(_ id: String, _ ext: String) -> URL { AgentHooks.asks.appendingPathComponent("\(id).\(ext)") }

    private func scan() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: AgentHooks.asks.path)) ?? []
        let requests = Set(names.filter { $0.hasSuffix(".req") }.map { String($0.dropLast(4)) })
        for id in requests where !seen.contains(id) {
            seen.insert(id)
            FileManager.default.createFile(atPath: path(id, "ack").path, contents: Data())
            handle(id)
        }
        // Answered here, or the hook gave up / was stopped.
        for id in seen where !requests.contains(id) {
            seen.remove(id)
            if let entry = held.removeValue(forKey: id) { RequestCenter.shared.resolved(entry.key) }
        }
    }

    private func handle(_ id: String) {
        guard let data = try? Data(contentsOf: path(id, "req")),
              let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = id.split(separator: "-").first.flatMap({ Int32($0) }) else { pass(id); return }
        let host = Self.hostApp(of: pid)
        // In the very app that runs this session, with someone at the keyboard: ask as usual there.
        if let host, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == host, ToastController.idleSeconds < 120 {
            pass(id)
            return
        }
        guard Settings.notifyAttention, let request = card(input, id: id, host: host) else { pass(id); return }
        held[id] = Held(pid: pid, hostBundle: host, key: request.key)
        AgentActivity.trace("claude ask \(id) held (\(input["tool_name"] as? String ?? "?"), host \(host ?? "?"))")
        RequestCenter.shared.post(request, open: { [weak self] in self?.handBack(id, activate: true) },
                                  respond: { [weak self] choice in try await self?.respond(id, input: input, choice: choice) })
        if timer == nil {
            timer = Timer.every(3) { _ in Task { @MainActor in ClaudeAsks.shared.checkAlive() } }
        }
    }

    private func checkAlive() {
        for (id, entry) in held where kill(entry.pid, 0) != 0 {
            held[id] = nil
            RequestCenter.shared.resolved(entry.key)
            try? FileManager.default.removeItem(at: path(id, "req"))
            try? FileManager.default.removeItem(at: path(id, "ack"))
        }
        if held.isEmpty { timer?.invalidate(); timer = nil }
    }

    /// Back in the app running the session: the question goes back to it, as usual.
    private func appActivated(_ bundle: String?) {
        guard let bundle else { return }
        for (id, entry) in held where entry.hostBundle == bundle { handBack(id, activate: false) }
    }

    private func handBack(_ id: String, activate: Bool) {
        guard let entry = held.removeValue(forKey: id) else { return }
        RequestCenter.shared.resolved(entry.key)
        pass(id)
        if activate, let bundle = entry.hostBundle,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            app.activate()
        }
    }

    /// "Ask as usual": an empty answer.
    private func pass(_ id: String) { write(id, Data()) }

    private func write(_ id: String, _ data: Data) {
        let temp = path(id, "restmp")
        try? data.write(to: temp)
        try? FileManager.default.moveItem(at: temp, to: path(id, "res"))
    }

    private func respond(_ id: String, input: [String: Any], choice: RequestChoice) async throws {
        guard let entry = held[id], kill(entry.pid, 0) == 0,
              FileManager.default.fileExists(atPath: path(id, "req").path) else {
            throw ResumeError.refused("Claude Code уже не ждёт этого ответа.")
        }
        let tool = input["tool_name"] as? String ?? ""
        let toolInput = input["tool_input"] as? [String: Any] ?? [:]
        var decision: [String: Any]
        switch choice.id {
        case "allow":
            decision = ["behavior": "allow", "updatedInput": toolInput]
        case "allowSession":
            let suggestions = (input["permission_suggestions"] as? [[String: Any]] ?? []).filter { $0["destination"] as? String == "session" }
            decision = ["behavior": "allow", "updatedInput": toolInput, "updatedPermissions": suggestions]
        case "deny":
            decision = ["behavior": "deny", "message": "Пользователь отклонил это действие (из Cooldown)."]
        case let option where option.hasPrefix("option:") && tool == "AskUserQuestion":
            guard let index = Int(option.dropFirst("option:".count)),
                  let question = (toolInput["questions"] as? [[String: Any]])?.first, let text = question["question"] as? String,
                  let options = question["options"] as? [[String: Any]], options.indices.contains(index),
                  let label = options[index]["label"] as? String else { throw ResumeError.refused("Вариант ответа не найден.") }
            decision = ["behavior": "allow", "updatedInput": ["questions": toolInput["questions"] ?? [Any](), "answers": [text: label]]]
        case let picks where picks.hasPrefix("answers:") && tool == "AskUserQuestion":
            let indices = picks.dropFirst("answers:".count).split(separator: ",").compactMap { Int($0) }
            let questions = toolInput["questions"] as? [[String: Any]] ?? []
            guard indices.count == questions.count else { throw ResumeError.refused("Ответы не совпадают с вопросами.") }
            var answers: [String: String] = [:]
            for (question, index) in zip(questions, indices) {
                guard let text = question["question"] as? String, let options = question["options"] as? [[String: Any]],
                      options.indices.contains(index), let label = options[index]["label"] as? String else {
                    throw ResumeError.refused("Вариант ответа не найден.")
                }
                answers[text] = label
            }
            decision = ["behavior": "allow", "updatedInput": ["questions": toolInput["questions"] ?? [Any](), "answers": answers]]
        default:
            throw ResumeError.refused("Такой ответ здесь не поддерживается.")
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        let data = try JSONSerialization.data(withJSONObject: output)
        held[id] = nil
        write(id, data)
        AgentActivity.trace("claude ask \(id): \(choice.id)")
    }

    // MARK: What the card says

    private func card(_ input: [String: Any], id: String, host: String?) -> AgentRequest? {
        let tool = input["tool_name"] as? String ?? ""
        let toolInput = input["tool_input"] as? [String: Any] ?? [:]
        let project = (input["cwd"] as? String).map { Stats.projectName($0) } ?? ""
        let chat = project.isEmpty ? "Claude Code" : "Claude Code · \(project)"
        let open = RequestChoice(id: "open", title: "Ответить там", role: .open)
        let hasSession = (input["permission_suggestions"] as? [[String: Any]] ?? []).contains { $0["destination"] as? String == "session" }
        var approve = [RequestChoice(id: "allow", title: "Разрешить", role: .allow)]
        if hasSession { approve.append(RequestChoice(id: "allowSession", title: "На всю сессию", role: .allow)) }
        approve += [RequestChoice(id: "deny", title: "Отклонить", role: .decline), open]
        func make(_ headline: String, _ detail: String?, _ choices: [RequestChoice]) -> AgentRequest {
            AgentRequest(key: "claude-code|\(id)", provider: .claude, chat: chat, headline: headline, detail: detail,
                         choices: choices, appBundleIDs: host.map { [$0] } ?? [], threadId: nil)
        }
        func home(_ path: String?) -> String? { path.map { ($0 as NSString).abbreviatingWithTildeInPath } }
        switch tool {
        case "Bash":
            let text = [toolInput["command"] as? String, toolInput["description"] as? String].compactMap { $0 }.joined(separator: "\n")
            return make("Claude хочет выполнить команду", text, approve)
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return make(tool == "Write" ? "Claude хочет создать или перезаписать файл" : "Claude хочет изменить файл",
                        home(toolInput["file_path"] as? String ?? toolInput["notebook_path"] as? String), approve)
        case "WebFetch":
            return make("Claude хочет открыть страницу", toolInput["url"] as? String, approve)
        case "WebSearch":
            return make("Claude хочет поискать в интернете", toolInput["query"] as? String, approve)
        case "ExitPlanMode":
            let plan = (toolInput["plan"] as? String).map { String($0.prefix(600)) }
            return make("Claude предлагает план", plan,
                        [RequestChoice(id: "allow", title: "Одобрить", role: .allow),
                         RequestChoice(id: "deny", title: "Отклонить", role: .decline), open])
        case "AskUserQuestion":
            let questions = toolInput["questions"] as? [[String: Any]] ?? []
            if questions.count == 1, let question = questions.first, JSON.bool(question["multiSelect"]) != true,
               let options = question["options"] as? [[String: Any]], !options.isEmpty {
                var choices = options.enumerated().compactMap { index, option -> RequestChoice? in
                    guard let label = option["label"] as? String else { return nil }
                    let note = (option["description"] as? String).flatMap { $0.isEmpty ? nil : " — " + $0 } ?? ""
                    return RequestChoice(id: "option:\(index)", title: label + note)
                }
                choices.append(RequestChoice(id: "open", title: "Свой ответ там", role: .open))
                return make("Claude спрашивает", question["question"] as? String, choices)
            }
            let steps = questions.map { question -> RequestStep? in
                guard JSON.bool(question["multiSelect"]) != true, let options = question["options"] as? [[String: Any]], !options.isEmpty else { return nil }
                var choices = options.enumerated().compactMap { index, option -> RequestChoice? in
                    guard let label = option["label"] as? String else { return nil }
                    let note = (option["description"] as? String).flatMap { $0.isEmpty ? nil : " — " + $0 } ?? ""
                    return RequestChoice(id: "option:\(index)", title: label + note)
                }
                choices.append(RequestChoice(id: "open", title: "Ответить там", role: .open))
                return RequestStep(headline: "Claude спрашивает", detail: question["question"] as? String, choices: choices)
            }
            if questions.count > 1, steps.allSatisfy({ $0 != nil }) {
                var request = make("Claude спрашивает", nil, [open])
                request.steps = steps.compactMap { $0 }
                return request
            }
            let text = questions.compactMap { $0["question"] as? String }.joined(separator: "\n")
            return make(questions.count > 1 ? "Claude задал \(questions.count) вопроса" : "Claude спрашивает", text, [open])
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
                let server = parts.count > 1 ? String(parts[1]) : "MCP"
                let name = parts.count > 2 ? parts[2...].joined(separator: "_") : tool
                return make("Claude хочет использовать \(server)", name, approve)
            }
            return make("Claude просит разрешение: \(tool)", nil, approve)
        }
    }

    // MARK: Which app runs the session

    /// Walks up from the hook's process to the first one that is an app (Terminal, iTerm,
    /// VS Code, Claude…): that is where the person would answer.
    static func hostApp(of pid: pid_t) -> String? {
        var current = pid
        for _ in 0..<30 {
            if let app = NSRunningApplication(processIdentifier: current), let bundle = app.bundleIdentifier,
               app.activationPolicy == .regular {
                return bundle
            }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
            let parent = info.kp_eproc.e_ppid
            if parent <= 1 || parent == current { return nil }
            current = parent
        }
        return nil
    }
}
