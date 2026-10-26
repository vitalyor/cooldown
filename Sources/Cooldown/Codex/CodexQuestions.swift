import Foundation

/// Questions Codex asks with ready answers while it goes on working ("request_user_input_async"):
/// the app shows them above the message box. They are not requests the app holds open, only an
/// item in the conversation, answered by a message — so they are read from the session file and
/// answered the way the app does: a message with the chosen answer.
@MainActor
enum CodexQuestions {
    struct Question: Equatable {
        var title: String
        var options: [String]
    }

    static func key(_ thread: String, _ call: String) -> String { "codexq|\(thread)|\(call)" }

    /// Questions in a session-file line (an item Codex completed with `delivery: async`), if any.
    nonisolated static func asked(in line: [String: Any]) -> (call: String, questions: [Question])? {
        guard let payload = line["payload"] as? [String: Any], payload["type"] as? String == "item_completed",
              let item = payload["item"] as? [String: Any], item["delivery"] as? String == "async",
              let call = item["id"] as? String, let raw = item["questions"] as? [[String: Any]] else { return nil }
        let questions = raw.compactMap { q -> Question? in
            guard let title = q["title"] as? String, !title.isEmpty else { return nil }
            return Question(title: title, options: (q["options"] as? [String]) ?? [])
        }
        return questions.isEmpty ? nil : (call, questions)
    }

    /// Calls answered by a message (the app's reply carries the question's call id).
    nonisolated static func answered(in text: String) -> [String] {
        guard text.contains("send_user_message_question_reply") else { return [] }
        var calls: [String] = []
        var rest = Substring(text)
        while let r = rest.range(of: "call_") {
            let tail = rest[r.lowerBound...]
            let id = tail.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if id.count > 8 { calls.append(String(id)) }
            rest = tail.dropFirst(5)
        }
        return calls
    }

    /// The card: the question with its answers; "Открыть чат" for anything else.
    static func show(thread: String, title: String, call: String, questions: [Question]) {
        let key = key(thread, call)
        if RequestCenter.shared.isPending(key) { return }
        func choices(_ q: Question) -> [RequestChoice] {
            q.options.enumerated().map { RequestChoice(id: "option:\($0.offset)", title: String($0.element.prefix(60))) }
                + [RequestChoice(id: "open", title: L("Ответить в чате"), role: .open)]
        }
        var request = AgentRequest(key: key, provider: .codex, chat: title.isEmpty ? L("Диалог Codex") : "«\(title)»",
                                   headline: L("Codex спрашивает"), detail: questions[0].title, choices: choices(questions[0]),
                                   appBundleIDs: [CodexApp.bundleId], threadId: thread)
        if questions.count > 1 {
            request.choices = [RequestChoice(id: "open", title: L("Ответить в чате"), role: .open)]
            request.steps = questions.map { RequestStep(headline: L("Codex спрашивает"), detail: $0.title, choices: choices($0)) }
        }
        RequestCenter.shared.post(request, open: { CodexApp.open(thread: thread) }) { choice in
            let picks: [Int]
            if choice.id.hasPrefix("answers:") {
                picks = choice.id.dropFirst("answers:".count).split(separator: ",").compactMap { Int($0) }
            } else if let one = Int(choice.id.dropFirst("option:".count)) {
                picks = [one]
            } else { throw CodexIPCError.app(L("Такой ответ здесь не поддерживается.")) }
            guard picks.count == questions.count,
                  zip(questions, picks).allSatisfy({ $0.options.indices.contains($1) }) else {
                throw CodexIPCError.app(L("Ответы не совпадают с вопросами."))
            }
            let text = reply(call: call, questions: questions, picks: picks)
            await deliver(thread: thread, text: text, key: key)
        }
    }

    /// The turn is over: the app no longer shows its questions, so neither does Cooldown.
    static func turnEnded(thread: String) {
        RequestCenter.shared.resolveAll(prefix: "codexq|\(thread)|", except: [])
    }

    static func resolve(thread: String, calls: [String]) {
        for call in calls { RequestCenter.shared.resolved(key(thread, call)) }
    }

    /// The same message the app sends when an answer is picked there.
    nonisolated static func reply(call: String, questions: [Question], picks: [Int]) -> String {
        let rows: [[String: String]] = zip(questions.indices, zip(questions, picks)).map { index, pair in
            let item = (try? String(data: JSONSerialization.data(withJSONObject: ["request_user_input_async", call, index]), encoding: .utf8)) ?? ""
            return ["questionItemId": item, "question": pair.0.title, "answer": pair.0.options[pair.1]]
        }
        let json = (try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return "<send_user_message_question_reply>\n\(json)\n</send_user_message_question_reply>\n"
    }

    /// Into the running turn at once, as the app does. If Codex does not take it that way, the
    /// answer goes as a message once the turn is over (up to fifteen minutes).
    private static func deliver(thread: String, text: String, key: String) async {
        do {
            try await AutoResume.shared.answerQuestion(thread, text: text)
            AgentActivity.trace("codex question \(key): answer sent")
            return
        } catch {
            AgentActivity.trace("codex question \(key): not taken at once (\(error.localizedDescription)); waiting for the turn to end")
        }
        let deadline = Date().addingTimeInterval(15 * 60)
        while Date() < deadline {
            do {
                try await AutoResume.shared.reply(thread, text: text)
                AgentActivity.trace("codex question \(key): answer sent")
                return
            } catch is CodexBusy {
                try? await Task.sleep(for: .seconds(5))
            } catch {
                AgentActivity.trace("codex question \(key): \(error.localizedDescription)")
                Notifier.shared.post(id: "codexq-failed-\(key)", title: L("Ответ не ушёл в Codex"), body: error.localizedDescription)
                return
            }
        }
        Notifier.shared.post(id: "codexq-late-\(key)", title: L("Ответ не ушёл в Codex"),
                             body: L("Codex работал без перерыва 15 минут. Ответьте в чате."))
    }
}

/// Codex is in the middle of a turn: a new message has to wait.
struct CodexBusy: LocalizedError {
    var errorDescription: String? { L("Codex ещё работает в этом чате. Ответьте, когда он закончит.") }
}
