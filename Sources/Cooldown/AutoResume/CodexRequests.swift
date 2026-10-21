import Darwin
import Foundation

/// Codex's requests (permissions, questions) as cards you can answer. While a Codex conversation
/// works, Cooldown follows it the way the app's own extra windows do and sees its pending
/// requests the moment they appear. An answer is sent through the same follower commands those
/// windows use, only after a fresh read shows the very same request still waiting.
final class CodexRequestWatcher: @unchecked Sendable {
    static let shared = CodexRequestWatcher()

    private let lock = NSLock()
    private var wanted = Set<String>()
    private var _live = false
    private let wake = DispatchSemaphore(value: 0)
    private var started = false

    /// Connected and following: the hook-based "Codex is waiting" card is not needed then.
    var live: Bool { lock.lock(); defer { lock.unlock() }; return _live }

    func start() {
        guard !started else { return }
        started = true
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "cooldown.codex-requests"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// The conversations worth following: those working or waiting right now.
    func follow(_ ids: Set<String>) {
        lock.lock()
        let changed = ids != wanted
        wanted = ids
        lock.unlock()
        if changed { wake.signal() }
    }

    private func currentWanted() -> Set<String> { lock.lock(); defer { lock.unlock() }; return wanted }
    private func setLive(_ value: Bool) { lock.lock(); _live = value; lock.unlock() }

    // MARK: Following

    private struct Followed {
        var owner: String
        var lastSnapshot = Date.distantPast
        var wantsSnapshot = false
        var lastAsked = Date.distantPast
    }

    private func loop() {
        while true {
            let ids = currentWanted()
            guard !ids.isEmpty, CodexApp.url != nil, CodexApp.isRunning else {
                setLive(false)
                _ = wake.wait(timeout: .now() + 30)
                continue
            }
            let connection = CodexIPCConnection(timeout: 8)
            do {
                try connection.open()
                try follow(on: connection)
            } catch {
                AgentActivity.trace("codex requests: \(error.localizedDescription)")
            }
            connection.close()
            setLive(false)
            _ = wake.wait(timeout: .now() + 5)
        }
    }

    private func follow(on connection: CodexIPCConnection) throws {
        var followed: [String: Followed] = [:]
        var states: [String: [String: Any]] = [:]
        connection.onBroadcast = { message in
            guard message["method"] as? String == "thread-stream-state-changed",
                  let params = message["params"] as? [String: Any], params["hostId"] as? String == "local",
                  let thread = params["conversationId"] as? String, var entry = followed[thread],
                  message["sourceClientId"] as? String == entry.owner,
                  let change = params["change"] as? [String: Any] else { return }
            switch change["type"] as? String {
            case "snapshot":
                if let state = change["conversationState"] as? [String: Any], state["id"] as? String == thread {
                    states[thread] = state
                    entry.lastSnapshot = Date()
                    entry.wantsSnapshot = false
                    self.evaluate(thread, state)
                }
            case "patches":
                // Only a change to the requests needs a fresh look; the text streaming by does not.
                if Self.touchesRequests(change["patches"]) { entry.wantsSnapshot = true }
            default:
                entry.wantsSnapshot = true
            }
            followed[thread] = entry
        }
        setLive(true)
        var lastOwnerCheck = Date()
        while true {
            let wanted = currentWanted()
            if wanted.isEmpty || !CodexApp.isRunning { break }
            // Start following new conversations; let go of finished ones.
            for id in wanted where followed[id] == nil {
                do {
                    let owner = try connection.discoverOwner(id)
                    followed[id] = Followed(owner: owner, wantsSnapshot: true)
                } catch CodexIPCError.threadUnavailable {
                    continue   // not open in the app right now; tried again on the next round
                }
            }
            for (id, entry) in followed where !wanted.contains(id) {
                try? connection.setFollowing(id, owner: entry.owner, false)
                followed[id] = nil
                states[id] = nil
                DispatchQueue.main.async { MainActor.assumeIsolated { RequestCenter.shared.resolveAll(prefix: Self.prefix(id), except: []) } }
            }
            // The owner window may change (a conversation moved to another window).
            if Date().timeIntervalSince(lastOwnerCheck) > 60 {
                lastOwnerCheck = Date()
                for (id, entry) in followed {
                    if let owner = try? connection.discoverOwner(id), owner != entry.owner {
                        followed[id] = Followed(owner: owner, wantsSnapshot: true)
                    }
                }
            }
            // A fresh full state: stop and start following, and the owner sends a snapshot.
            for (id, entry) in followed where entry.wantsSnapshot && Date().timeIntervalSince(entry.lastAsked) > 0.8 {
                followed[id]?.lastAsked = Date()
                followed[id]?.wantsSnapshot = false
                try connection.setFollowing(id, owner: entry.owner, false)
                try connection.setFollowing(id, owner: entry.owner, true)
            }
            var item = pollfd(fd: connection.descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 1000)
            if ready > 0 { try connection.read(deadline: Date().addingTimeInterval(8)) }
            if ready < 0 && errno != EINTR { throw CodexIPCError.connection("Соединение с приложением разорвано") }
        }
        for (id, entry) in followed { try? connection.setFollowing(id, owner: entry.owner, false) }
    }

    static func touchesRequests(_ patches: Any?) -> Bool {
        guard let patches = patches as? [Any] else { return true }
        for patch in patches {
            guard let patch = patch as? [String: Any] else { return true }
            if let path = patch["path"] as? [Any] {
                if path.isEmpty || path.first as? String == "requests" { return true }
            } else if let path = patch["path"] as? String {
                if path.isEmpty || path == "/" || path.hasPrefix("/requests") { return true }
            } else {
                return true
            }
        }
        return false
    }

    static func prefix(_ thread: String) -> String { "codex|\(thread)|" }

    static func requestKey(_ thread: String, _ id: Any?) -> String? {
        switch id {
        case let text as String: return prefix(thread) + text
        case let number as NSNumber where !JSON.isBool(number): return prefix(thread) + number.stringValue
        default: return nil
        }
    }

    // MARK: Requests → cards

    /// Requests first seen at, so Codex's own reviewer ("approve for me") gets its few seconds first.
    private var firstSeen: [String: Date] = [:]

    private func evaluate(_ thread: String, _ state: [String: Any]) {
        let title = (state["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? CodexThreadIndex.thread(id: thread)?.title ?? "Диалог Codex"
        let requests = state["requests"] as? [Any] ?? []
        var keys = Set<String>()
        var cards: [(AgentRequest, [String: Any])] = []
        for raw in requests {
            guard let request = raw as? [String: Any], let key = Self.requestKey(thread, request["id"]),
                  let card = Self.card(request, thread: thread, key: key, title: title) else { continue }
            keys.insert(key)
            cards.append((card, request))
        }
        lock.lock()
        for key in firstSeen.keys where key.hasPrefix(Self.prefix(thread)) && !keys.contains(key) { firstSeen[key] = nil }
        for key in keys where firstSeen[key] == nil { firstSeen[key] = Date() }
        lock.unlock()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                RequestCenter.shared.resolveAll(prefix: Self.prefix(thread), except: keys)
                for (card, request) in cards { self.post(card, request: request, thread: thread, attempt: 0) }
            }
        }
    }

    @MainActor
    private func post(_ card: AgentRequest, request: [String: Any], thread: String, attempt: Int) {
        if RequestCenter.shared.isPending(card.key) {
            // Already on a card; keep its answer bound to the same request.
            RequestCenter.shared.post(card, open: { CodexApp.open(thread: thread) }, respond: Self.responder(thread, request))
            return
        }
        lock.lock(); let seen = firstSeen[card.key]; lock.unlock()
        guard let seen else { return }   // gone in the meantime
        let method = request["method"] as? String ?? ""
        let reviewable = method.hasSuffix("/requestApproval")
        // "Approve for me": Codex's reviewer usually answers within seconds; give it that time.
        if reviewable && attempt < 18 {
            let age = Date().timeIntervalSince(seen)
            if age < 4 || CodexThreadIndex.reviewerActive(since: seen.addingTimeInterval(-3)) {
                DispatchQueue.main.asyncAfter(deadline: .now() + (age < 4 ? 4 - age : 5)) {
                    self.post(card, request: request, thread: thread, attempt: attempt + 1)
                }
                return
            }
        }
        RequestCenter.shared.post(card, open: { CodexApp.open(thread: thread) }, respond: Self.responder(thread, request))
    }

    /// What the card says and offers, by the kind of request. Unknown kinds still get a card
    /// that opens the chat, so nothing waits unnoticed.
    static func card(_ request: [String: Any], thread: String, key: String, title: String) -> AgentRequest? {
        let method = request["method"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]
        let open = RequestChoice(id: "open", title: "Открыть чат", role: .open)
        let approve = [RequestChoice(id: "accept", title: "Разрешить", role: .allow),
                       RequestChoice(id: "acceptForSession", title: "На всю сессию", role: .allow),
                       RequestChoice(id: "decline", title: "Отклонить", role: .decline),
                       open,
                       RequestChoice(id: "cancel", title: "Отклонить и остановить", role: .decline, extra: true)]
        func make(_ headline: String, _ detail: String?, _ choices: [RequestChoice]) -> AgentRequest {
            AgentRequest(key: key, provider: .codex, chat: "«\(title)»", headline: headline, detail: detail,
                         choices: choices, appBundleIDs: [CodexApp.bundleId], threadId: thread)
        }
        func lines(_ parts: [String?]) -> String? {
            let text = parts.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
        switch method {
        case "item/commandExecution/requestApproval":
            let cwd = (params["cwd"] as? String).map { "в " + ($0 as NSString).abbreviatingWithTildeInPath }
            let network = (params["networkApprovalContext"] as? [String: Any])?["host"] as? String
            return make(network != nil ? "Codex просит доступ в сеть" : "Codex хочет выполнить команду",
                        lines([params["command"] as? String, network.map { "сеть: \($0)" }, cwd, params["reason"] as? String]), approve)
        case "item/fileChange/requestApproval":
            let root = (params["grantRoot"] as? String).map { "запись в " + ($0 as NSString).abbreviatingWithTildeInPath }
            return make("Codex хочет изменить файлы", lines([root, params["reason"] as? String]), approve)
        case "item/permissions/requestApproval":
            return make("Codex просит дополнительные права", lines([describe(params["permissions"]), params["reason"] as? String]),
                        [RequestChoice(id: "grant", title: "Разрешить", role: .allow),
                         RequestChoice(id: "grantSession", title: "На всю сессию", role: .allow),
                         RequestChoice(id: "deny", title: "Отклонить", role: .decline), open])
        case "item/tool/requestUserInput":
            let questions = params["questions"] as? [[String: Any]] ?? []
            // One question with ready answers fits a card; a secret one or a form never does.
            if questions.count == 1, let question = questions.first, JSON.bool(question["isSecret"]) != true,
               let options = question["options"] as? [[String: Any]], !options.isEmpty {
                var choices = options.enumerated().compactMap { index, option -> RequestChoice? in
                    guard let label = option["label"] as? String else { return nil }
                    let note = (option["description"] as? String).flatMap { $0.isEmpty ? nil : " — " + $0 } ?? ""
                    return RequestChoice(id: "option:\(index)", title: label + note)
                }
                choices.append(RequestChoice(id: "open", title: JSON.bool(question["isOther"]) == true ? "Свой ответ в чате" : "Открыть чат", role: .open))
                return make("Codex спрашивает", question["question"] as? String, choices)
            }
            let text = questions.compactMap { $0["question"] as? String }.joined(separator: "\n")
            return make(questions.count > 1 ? "Codex задал \(questions.count) вопроса" : "Codex спрашивает", text.isEmpty ? nil : text, [open])
        case "mcpServer/elicitation/request":
            let server = params["serverName"] as? String ?? "MCP"
            let message = params["message"] as? String
            // A plain confirmation (no form to fill) can be answered here.
            let schema = params["requestedSchema"] as? [String: Any]
            let fields = (schema?["properties"] as? [String: Any])?.isEmpty ?? true
            if fields && params["mode"] as? String != "url" {
                return make("\(server) просит подтверждения", message,
                            [RequestChoice(id: "elicit:accept", title: "Подтвердить", role: .allow),
                             RequestChoice(id: "elicit:decline", title: "Отклонить", role: .decline), open])
            }
            return make("\(server) просит заполнить данные", message, [open])
        case "item/tool/call":
            // The app's own pickers (a folder to work in and the like); an orphaned one is not news.
            return nil
        default:
            return make("Codex ждёт вашего действия", nil, [open])
        }
    }

    private static func describe(_ raw: Any?) -> String? {
        guard let profile = raw as? [String: Any] else { return nil }
        var parts: [String] = []
        if JSON.bool((profile["network"] as? [String: Any])?["enabled"]) == true { parts.append("доступ в сеть") }
        if let fs = profile["fileSystem"] as? [String: Any] {
            for path in fs["write"] as? [String] ?? [] { parts.append("запись: " + (path as NSString).abbreviatingWithTildeInPath) }
            for path in fs["read"] as? [String] ?? [] { parts.append("чтение: " + (path as NSString).abbreviatingWithTildeInPath) }
            for entry in fs["entries"] as? [[String: Any]] ?? [] {
                let access = entry["access"] as? String ?? ""
                let pathObject = entry["path"] as? [String: Any]
                let path = pathObject?["path"] as? String ?? pathObject?["pattern"] as? String ?? (pathObject?["value"] as? String) ?? "?"
                parts.append("\(access == "write" ? "запись" : access == "read" ? "чтение" : access): \((path as NSString).abbreviatingWithTildeInPath)")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    // MARK: Answering

    /// Sends the pressed answer, after a fresh read shows this very request still waiting with
    /// the same content the card showed.
    static func responder(_ thread: String, _ shown: [String: Any]) -> RequestCenter.Responder {
        { choice in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try send(choice, thread: thread, shown: shown) })
                }
            }
        }
    }

    private static func send(_ choice: RequestChoice, thread: String, shown: [String: Any]) throws {
        let connection = CodexIPCConnection(timeout: 8)
        try connection.open()
        defer { connection.close() }
        let state = try connection.snapshot(thread)
        let current = (state["requests"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        guard let live = current.first(where: { JSON.canonical(["id": $0["id"] ?? NSNull()]) == JSON.canonical(["id": shown["id"] ?? NSNull()]) }),
              JSON.canonical(live) == JSON.canonical(shown) else {
            throw CodexIPCError.app("Этот запрос уже закрыт или изменился.")
        }
        let id = shown["id"] ?? NSNull()
        let params = shown["params"] as? [String: Any] ?? [:]
        let method = shown["method"] as? String ?? ""
        var base: [String: Any] = ["conversationId": thread, "requestId": id]
        let command: String
        switch (method, choice.id) {
        case ("item/commandExecution/requestApproval", let decision) where ["accept", "acceptForSession", "decline", "cancel"].contains(decision):
            command = "thread-follower-command-approval-decision"
            base["decision"] = decision
        case ("item/fileChange/requestApproval", let decision) where ["accept", "acceptForSession", "decline", "cancel"].contains(decision):
            command = "thread-follower-file-approval-decision"
            base["decision"] = decision
        case ("item/permissions/requestApproval", "grant"), ("item/permissions/requestApproval", "grantSession"):
            command = "thread-follower-permissions-request-approval-response"
            base["response"] = ["permissions": params["permissions"] ?? [String: Any](), "scope": choice.id == "grant" ? "turn" : "session"]
        case ("item/permissions/requestApproval", "deny"):
            command = "thread-follower-permissions-request-approval-response"
            base["response"] = ["permissions": [String: Any](), "scope": "turn"]
        case ("item/tool/requestUserInput", let option) where option.hasPrefix("option:"):
            guard let index = Int(option.dropFirst("option:".count)),
                  let question = (params["questions"] as? [[String: Any]])?.first, let qid = question["id"] as? String,
                  let options = question["options"] as? [[String: Any]], options.indices.contains(index),
                  let label = options[index]["label"] as? String else { throw CodexIPCError.app("Вариант ответа не найден.") }
            command = "thread-follower-submit-user-input"
            base["response"] = ["answers": [qid: ["answers": [label]]]]
        case ("mcpServer/elicitation/request", "elicit:accept"), ("mcpServer/elicitation/request", "elicit:decline"):
            command = "thread-follower-submit-mcp-server-elicitation-response"
            base["response"] = ["action": choice.id == "elicit:accept" ? "accept" : "decline", "content": NSNull()]
        default:
            throw CodexIPCError.app("Такой ответ здесь не поддерживается.")
        }
        AgentActivity.trace("codex request \(thread): \(command) \(choice.id)")
        try connection.answer(command, params: base)
    }
}
