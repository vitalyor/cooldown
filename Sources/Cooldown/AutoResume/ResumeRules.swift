import CryptoKit
import Foundation

/// The decisions of auto-continue as pure functions of what Codex reports, so they can be
/// tested without the app. Everything here errs on the side of not sending.
enum ResumeRules {
    enum Action: Equatable { case send, wait, stop }

    struct Verdict: Equatable {
        let action: Action
        /// One of the task states of `ResumeStatus`.
        let taskState: String
        let reason: String
        /// The failed turn a continuation would answer (only for `send`).
        var failedTurn: String? = nil
        var model: String? = nil
    }

    // MARK: Turns

    enum Latest {
        case none
        case turn([String: Any])
        /// History is partial, in an unknown form, or the newest turn cannot be told apart.
        case unclear
    }

    /// The turns the state holds, oldest first, and which one is the newest.
    static func turns(_ state: [String: Any]) -> (all: [[String: Any]], latest: Latest) {
        if let raw = state["turnHistory"], !JSON.isNull(raw) {
            guard let history = raw as? [String: Any], history["kind"] as? String == "canonical",
                  let body = history["history"] as? [String: Any], let islands = body["islands"] as? [Any],
                  let entities = body["entitiesByKey"] as? [String: Any] else { return ([], .unclear) }
            var all: [[String: Any]] = []
            for island in islands {
                for entry in (island as? [String: Any])?["entries"] as? [Any] ?? [] {
                    if let key = (entry as? [String: Any])?["value"] as? String, let turn = entities[key] as? [String: Any] {
                        all.append(turn)
                    }
                }
            }
            // Only the newest island can hold the newest turn, and only if nothing newer exists.
            guard let newest = islands.last as? [String: Any] else { return (all, islands.isEmpty ? .none : .unclear) }
            guard ((newest["newerBoundary"] as? [String: Any])?["status"] as? String) == "exhausted",
                  let entries = newest["entries"] as? [Any] else { return (all, .unclear) }
            guard let last = entries.last else { return (all, islands.count == 1 ? .none : .unclear) }
            guard let key = (last as? [String: Any])?["value"] as? String, let turn = entities[key] as? [String: Any] else {
                return (all, .unclear)
            }
            return (all, .turn(turn))
        }
        if let list = state["turns"] as? [Any] {
            let all = list.compactMap { $0 as? [String: Any] }
            guard let last = list.last else { return ([], .none) }
            guard let turn = last as? [String: Any] else { return (all, .unclear) }
            return (all, .turn(turn))
        }
        return ([], .unclear)
    }

    static func turnId(_ turn: [String: Any]) -> String? { JSON.nonEmptyString(turn["turnId"]) ?? JSON.nonEmptyString(turn["id"]) }

    /// Only Codex's own error code says the usage limit stopped a turn; the text never does.
    static func failedOnUsageLimit(_ turn: [String: Any]) -> Bool {
        guard turn["status"] as? String == "failed", let error = turn["error"] as? [String: Any] else { return false }
        let codes: Set<String> = ["usageLimitExceeded", "UsageLimitExceeded"]
        switch error["codexErrorInfo"] {
        case let code as String: return codes.contains(code)
        case let tagged as [String: Any]: return tagged.keys.count == 1 && codes.contains(tagged.keys.first ?? "")
        default: return false
        }
    }

    // MARK: Requests

    /// The app's folder picker left behind by an older, interrupted turn of the same conversation
    /// is not waiting for anyone. It is only ignored, never answered or removed.
    private static let leftoverTool: [String?] = ["codex_app", "setup_codex_context_picker"]

    static func isLeftover(_ request: [String: Any], thread: String, turns: [[String: Any]], latest: String?) -> Bool {
        guard request["method"] as? String == "item/tool/call", let params = request["params"] as? [String: Any],
              [params["namespace"] as? String, params["tool"] as? String] == leftoverTool,
              (params["threadId"] as? String)?.lowercased() == thread.lowercased(),
              let turn = JSON.nonEmptyString(params["turnId"]), let latest, turn != latest else { return false }
        return turns.contains { turnId($0) == turn && $0["status"] as? String == "interrupted" }
    }

    // MARK: Deciding from the live state

    /// Send, wait or stop, from one live snapshot of the conversation.
    static func decide(_ state: [String: Any], thread: String) -> Verdict {
        let model = JSON.nonEmptyString(state["latestModel"])
        func verdict(_ action: Action, _ taskState: String, _ reason: String, failed: String? = nil) -> Verdict {
            Verdict(action: action, taskState: taskState, reason: reason, failedTurn: failed, model: model)
        }
        guard state["hostId"] as? String == "local" else {
            return verdict(.stop, "unsupported", L("Диалог идёт не на этом Mac."))
        }
        let saved = JSON.bool(state["ephemeral"]) == false
            || (state["ephemeral"] == nil && JSON.nonEmptyString(state["rolloutPath"]) != nil)
        guard saved else { return verdict(.stop, "unsupported", L("Диалог не сохраняется, такой продолжить нельзя.")) }
        if (state["resumeState"] as? String) != "resumed" {
            return verdict(.wait, "connecting", L("Codex ещё загружает диалог."))
        }
        let (all, latest) = turns(state)
        var latestTurn: [String: Any]?
        if case .turn(let turn) = latest { latestTurn = turn }
        let latestId = latestTurn.flatMap(turnId)

        // No list at all is not the same as an empty one: then nobody can say nothing is waiting.
        let listed = state["requests"] as? [Any]
        if listed == nil {
            return verdict(.stop, "unknown", L("Codex не сообщил, ждёт ли диалог ответа."))
        }
        let waiting = (listed ?? []).filter { raw in
            guard let request = raw as? [String: Any] else { return true }
            return !isLeftover(request, thread: thread, turns: all, latest: latestId)
        }
        if !waiting.isEmpty {
            return verdict(.stop, "needs_attention", L("Codex ждёт вашего ответа в диалоге."))
        }
        if says(state, "threadGoalResumeConfirmation") {
            return verdict(.stop, "needs_attention", L("Codex просит подтвердить продолжение цели."))
        }
        let goal = goalState(state["threadGoal"])
        if goal == .inactive {
            return verdict(.stop, "needs_attention", L("Цель диалога не активна — решите, что с ней делать."))
        }
        if says(state, "queuedFollowUps") {
            return verdict(.stop, "needs_attention", L("В очереди есть ваше сообщение — Codex отправит его сам."))
        }
        guard let runtime = state["threadRuntimeStatus"] as? [String: Any], let kind = runtime["type"] as? String else {
            return verdict(.stop, "unknown", L("Codex не сообщил состояние диалога."))
        }
        switch kind {
        case "active":
            if says(runtime, "activeFlags") {
                return verdict(.stop, "needs_attention", L("Codex ждёт чего-то от вас."))
            }
            return verdict(.wait, "running", L("Codex работает над задачей."))
        case "idle", "systemError":
            break
        default:
            return verdict(.wait, "connecting", L("Codex меняет состояние диалога."))
        }
        switch latest {
        case .none: return verdict(.stop, "empty", L("В диалоге ещё нет задач."))
        case .unclear: return verdict(.stop, "unknown", L("Не видно, какая задача в диалоге последняя."))
        case .turn: break
        }
        guard let turn = latestTurn, let id = latestId else {
            return verdict(.stop, "unknown", L("У последней задачи нет номера."))
        }
        let status = turn["status"] as? String ?? ""
        switch status {
        case "inProgress":
            return verdict(.wait, "running", L("Codex работает над задачей."))
        case "completed":
            if goal == .active { return verdict(.wait, "running", L("Codex продолжает работу над целью.")) }
            return verdict(.stop, "idle", L("Задача завершена."))
        case "interrupted":
            return verdict(.stop, "interrupted", L("Задачу прервали."))
        case "failed":
            if failedOnUsageLimit(turn) {
                return verdict(.send, "quota_limited", L("Задача остановилась: закончился лимит."), failed: id)
            }
            return verdict(.stop, "other_failure", L("Задача остановилась с ошибкой, не из-за лимита."))
        default:
            return verdict(.stop, "unknown", L("Незнакомое состояние последней задачи."))
        }
    }

    private enum Goal { case none, active, inactive }

    /// No goal, an active one, or one in any other condition (paused, done, of an unknown form).
    private static func goalState(_ raw: Any?) -> Goal {
        if JSON.isNull(raw) { return .none }
        return (raw as? [String: Any])?["status"] as? String == "active" ? .active : .inactive
    }

    /// Whether a field holds something (a flag set, a non-empty list).
    private static func says(_ object: [String: Any], _ key: String) -> Bool { JSON.truthy(object[key]) }

    /// The parts of the state that decide what a continuation would do. If any of them changes
    /// between deciding to send and sending, the decision no longer holds.
    static func fingerprint(_ state: [String: Any]) -> String? {
        var parts: [String: Any] = [:]
        for key in ["cwd", "latestModel", "latestReasoningEffort", "latestCollaborationMode", "currentPermissions",
                    "latestThreadSettings", "threadGoal", "requests", "queuedFollowUps", "threadRuntimeStatus", "resumeState"] {
            parts[key] = state[key] ?? NSNull()
        }
        if case .turn(let turn) = turns(state).latest {
            parts["latestTurn"] = ["id": turnId(turn) ?? NSNull(), "status": turn["status"] ?? NSNull(), "error": turn["error"] ?? NSNull()]
        } else {
            parts["latestTurn"] = NSNull()
        }
        guard let data = JSON.canonical(parts) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Saved history (watching only, never sending)

    /// What the saved history (`thread/read`) says. It may allow watching, never sending.
    static func judgeHistory(_ thread: [String: Any]) -> (state: String, reason: String) {
        if JSON.bool(thread["ephemeral"]) == true { return ("unsupported", L("Диалог не сохраняется, такой продолжить нельзя.")) }
        guard let turns = thread["turns"] as? [Any] else { return ("unknown", L("Не удалось прочитать историю диалога.")) }
        guard let last = turns.last else { return ("empty", L("В диалоге ещё нет задач.")) }
        guard let turn = last as? [String: Any], turnId(turn) != nil else { return ("unknown", L("Не видно, какая задача в диалоге последняя.")) }
        let status = turn["status"] as? String ?? ""
        switch status {
        case "completed": return ("idle", L("Задача завершена."))
        case "interrupted": return ("interrupted", L("Задачу прервали."))
        case "inProgress": return ("running", L("По сохранённой истории задача ещё выполняется."))
        case "failed":
            if failedOnUsageLimit(turn) { return ("quota_limited", L("Задача остановилась: закончился лимит.")) }
            return ("other_failure", L("Задача остановилась с ошибкой, не из-за лимита."))
        default:
            return ("unknown", L("Незнакомое состояние последней задачи."))
        }
    }

    /// The id of the newest saved turn, if the history is readable.
    static func latestSavedTurn(_ thread: [String: Any]) -> String? {
        ((thread["turns"] as? [Any])?.last as? [String: Any]).flatMap(turnId)
    }

    // MARK: Limits

    enum Limits: Equatable {
        case available
        /// Still used up: look again at this moment (just after the reset).
        case notYet(Date)
        /// The numbers are not current yet: look again at this moment.
        case stale(Date)
        /// Something only the person can sort out (spend control, unknown buckets, odd data).
        case blocked(String)
    }

    /// Whether Codex's own limits say work can go on now. Only a fresh reading counts.
    static func judgeLimits(_ result: [String: Any], now: Date) -> Limits {
        var bucket: [String: Any]?
        let byId = result["rateLimitsByLimitId"] as? [String: Any] ?? [:]
        let single = result["rateLimits"] as? [String: Any]
        if let own = byId["codex"] as? [String: Any] {
            bucket = own
        } else if byId.isEmpty {
            bucket = single
        } else if byId.count == 1, let single, let only = byId.values.first as? [String: Any],
                  JSON.canonical(only) == JSON.canonical(single) {
            bucket = single
        } else {
            return .blocked(L("Codex сообщил несколько лимитов, и неясно, какой относится к задаче."))
        }
        guard let bucket else { return .blocked(L("Codex не сообщил лимиты.")) }
        if JSON.truthy(bucket["spendControlReached"]) {
            return .blocked(L("Достигнут лимит расходов аккаунта — нужно ваше решение."))
        }
        if !JSON.isNull(bucket["individualLimit"]) {
            return .blocked(L("На аккаунте действует отдельный лимит — нужно ваше решение."))
        }
        // Only the ordinary window limit may be waited out; any other kind needs the person.
        let flaggedAsReached: Bool
        switch bucket["rateLimitReachedType"] {
        case nil, is NSNull: flaggedAsReached = false
        case let kind as String where kind == "rate_limit_reached": flaggedAsReached = true
        default: return .blocked(L("Codex сообщил незнакомый вид ограничения."))
        }
        guard let primary = bucket["primary"], !JSON.isNull(primary) else {
            return .blocked(L("Codex не сообщил окно лимита."))
        }
        var windows: [(used: Double, resets: Date)] = []
        for raw in [primary as Any?, bucket["secondary"]] {
            guard let raw, !JSON.isNull(raw) else { continue }
            guard let window = raw as? [String: Any], let used = JSON.number(window["usedPercent"]), (0...100).contains(used),
                  let resets = JSON.number(window["resetsAt"]), resets > 0,
                  let minutes = JSON.number(window["windowDurationMins"]), minutes > 0 else {
                return .blocked(L("Codex прислал лимиты в незнакомом виде."))
            }
            windows.append((used, Date(timeIntervalSince1970: resets)))
        }
        let full = windows.filter { $0.used >= 100 }
        if let reset = full.map(\.resets).max() {
            return .notYet(max(reset.addingTimeInterval(5), now.addingTimeInterval(60)))
        }
        if flaggedAsReached || windows.contains(where: { $0.resets <= now }) {
            return .stale(now.addingTimeInterval(60))
        }
        return .available
    }

    // MARK: Never twice

    enum Gate: Equatable {
        case proceed
        /// A continuation for this very turn went out moments ago; the app may not show it yet.
        case justSent
        /// A continuation for this turn went out long ago and the turn is still the newest.
        case alreadySent
        /// A send with an unknown outcome is on record: nothing more goes out automatically.
        case uncertain
        case budget
    }

    /// Whether a continuation for `turn` may be prepared at all, from what is on record.
    static func gate(_ data: ResumeData, thread: String, turn: String, maxResumes: Int, now: Date) -> Gate {
        if data.pending(thread) != nil { return .uncertain }
        if let record = data.send(for: thread, turn: turn) {
            return now.timeIntervalSince(record.time) < 120 ? .justSent : .alreadySent
        }
        if data.attempts(thread) >= maxResumes { return .budget }
        return .proceed
    }

    /// Why a watch cannot be switched on, from what is on record; nil if it can. `latestTurn` is
    /// the conversation's newest turn as just read: an unconfirmed send stays blocking until the
    /// conversation has moved past the turn it answered (the person took over).
    static func startRefusal(_ data: ResumeData, thread: String, maxResumes: Int, latestTurn: String?) -> String? {
        if let pending = data.pending(thread), latestTurn == nil || latestTurn == pending.failedTurn {
            return L("Прошлое продолжение не подтвердилось. Откройте диалог и проверьте его — автоматически туда ничего не отправится, пока вы сами не продолжите работу.")
        }
        let used = data.attempts(thread)
        if used >= maxResumes {
            return L("Попытки для этого диалога уже использованы (%@ из %@). Увеличьте число попыток.", "\(used)", "\(maxResumes)")
        }
        return nil
    }

    // MARK: The message

    static var continuation: String {
        L("Лимит снова доступен. Продолжи, пожалуйста, прерванную работу в этой же сессии. Сначала проверь, что уже сделано и что сейчас в рабочей папке. Не повторяй выполненные шаги, не расширяй задачу и не обходи подтверждения. Если работа уже закончена или нужно моё решение — прямо скажи об этом и остановись.")
    }

    static func isThreadId(_ text: String) -> Bool {
        UUID(uuidString: text) != nil && text.count == 36
    }
}
