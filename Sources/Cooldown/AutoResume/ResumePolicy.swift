import CryptoKit
import Foundation

/// Strict readers for JSON decoded by JSONSerialization, where `true` and `1` are both NSNumber
/// and `null` is NSNull. Every check below fails closed on a type it does not expect.
enum JSON {
    static func isNull(_ value: Any?) -> Bool { value == nil || value is NSNull }

    static func isBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func bool(_ value: Any?) -> Bool? { isBool(value) ? (value as? NSNumber)?.boolValue : nil }

    /// A finite number that is not a boolean.
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isBool(number) else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    /// Python's truthiness, for fields the protocol fills with "something or nothing".
    static func truthy(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull: return false
        case let number as NSNumber: return number.doubleValue != 0
        case let text as String: return !text.isEmpty
        case let list as [Any]: return !list.isEmpty
        case let object as [String: Any]: return !object.isEmpty
        default: return true
        }
    }

    static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// Canonical bytes (sorted keys) for hashing.
    static func canonical(_ value: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

/// The pure decisions of auto-continue for Codex. Unknown state never authorizes a message:
/// everything below answers "stop" or "wait" unless the evidence is exact.
enum ResumePolicy {
    struct Decision: Equatable {
        enum Action: String { case resume, wait, stop }
        var action: Action
        var reason: String
        var turnId: String = ""
        var taskState: String = "unknown"
    }

    struct Unsupported: Error { let reason: String }

    /// The latest turn of a conversation: the canonical history's last entry when its newest edge
    /// is known to be complete, otherwise the legacy `turns` list.
    static func latestTurn(_ state: [String: Any]) throws -> [String: Any] {
        let turn: Any?
        if let history = state["turnHistory"] as? [String: Any], history["kind"] as? String == "canonical" {
            guard let hist = history["history"] as? [String: Any],
                  let islands = hist["islands"] as? [Any], let tail = islands.last as? [String: Any] else {
                throw Unsupported(reason: "Нет проверяемой актуальной истории сессии")
            }
            guard (tail["newerBoundary"] as? [String: Any])?["status"] as? String == "exhausted" else {
                throw Unsupported(reason: "Хвост истории неполон; нельзя определить последний раунд")
            }
            guard let entries = tail["entries"] as? [Any], let last = entries.last as? [String: Any] else {
                throw Unsupported(reason: "Последний фрагмент истории пуст")
            }
            if let key = last["value"] as? String { turn = (hist["entitiesByKey"] as? [String: Any])?[key] } else { turn = nil }
        } else {
            guard let turns = state["turns"] as? [Any], !turns.isEmpty else { throw Unsupported(reason: "Отсутствует раунд сессии") }
            turn = turns.last
        }
        guard let result = turn as? [String: Any] else { throw Unsupported(reason: "Неподдерживаемая структура истории сессии") }
        return result
    }

    /// A usage-limit failure, by the protocol's enum value only, never by matching text.
    static func quotaFailure(_ turn: [String: Any]) -> Bool {
        guard let error = turn["error"] as? [String: Any], let info = error["codexErrorInfo"] as? String else { return false }
        return info == "usageLimitExceeded" || info == "UsageLimitExceeded"
    }

    /// Only a verified orphan of Codex's cancelled folder picker: exact tool, same conversation,
    /// an older interrupted turn in the same contiguous canonical tail. Nothing is answered or removed.
    static func interruptedContextPicker(_ state: [String: Any], _ request: Any) -> Bool {
        guard let request = request as? [String: Any], request["method"] as? String == "item/tool/call",
              let params = request["params"] as? [String: Any],
              params["namespace"] as? String == "codex_app", params["tool"] as? String == "setup_codex_context_picker",
              let id = state["id"] as? String, params["threadId"] as? String == id,
              let turnId = JSON.nonEmptyString(params["turnId"]),
              let history = state["turnHistory"] as? [String: Any], history["kind"] as? String == "canonical",
              let hist = history["history"] as? [String: Any],
              let islands = hist["islands"] as? [Any], let tail = islands.last as? [String: Any],
              let entities = hist["entitiesByKey"] as? [String: Any],
              let boundary = tail["newerBoundary"] as? [String: Any], boundary["status"] as? String == "exhausted",
              let entries = tail["entries"] as? [Any], entries.count >= 2 else { return false }
        var turns: [[String: Any]] = []
        for entry in entries {
            guard let entry = entry as? [String: Any], let key = entry["value"] as? String,
                  let turn = entities[key] as? [String: Any], turn["turnId"] is String else { return false }
            turns.append(turn)
        }
        if turns.last?["turnId"] as? String == turnId { return false }
        let matches = turns.dropLast().filter { $0["turnId"] as? String == turnId }
        return matches.count == 1 && matches[0]["status"] as? String == "interrupted"
    }

    /// Positive evidence of a regular saved session: an explicit `ephemeral: false`, or (newer
    /// builds without the flag) a non-empty saved history path.
    static func persistentSession(_ state: [String: Any]) -> Bool {
        if state.keys.contains("ephemeral") { return JSON.bool(state["ephemeral"]) == false }
        guard let rollout = state["rolloutPath"] as? String else { return false }
        return !rollout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func decide(_ state: [String: Any]?) -> Decision {
        guard let state, state["hostId"] as? String == "local" else {
            return Decision(action: .stop, reason: "Поддерживаются только сессии локального приложения", taskState: "unsupported")
        }
        guard persistentSession(state) else {
            return Decision(action: .stop, reason: "Временные сессии и сессии неизвестного типа не поддерживаются", taskState: "unsupported")
        }
        guard state["resumeState"] as? String == "resumed" else {
            return Decision(action: .wait, reason: "Диалог ещё загружается, ждём синхронизации состояния", taskState: "connecting")
        }
        guard let requests = state["requests"] as? [Any] else {
            return Decision(action: .stop, reason: "Нет состояния подтверждения/ввода пользователя")
        }
        if requests.contains(where: { !interruptedContextPicker(state, $0) }) {
            return Decision(action: .stop, reason: "Задача ждёт подтверждения или ввода пользователя", taskState: "needs_attention")
        }
        if JSON.truthy(state["threadGoalResumeConfirmation"]) {
            return Decision(action: .stop, reason: "Для возобновления задачи нужно подтверждение пользователя", taskState: "needs_attention")
        }
        let goal = state["threadGoal"]
        let goalActive = (goal as? [String: Any])?["status"] as? String == "active"
        if !JSON.isNull(goal) && !goalActive {
            return Decision(action: .stop, reason: "Цель задачи приостановлена, заблокирована или завершена", taskState: "needs_attention")
        }
        if JSON.truthy(state["queuedFollowUps"]) {
            return Decision(action: .stop, reason: "Есть сообщение пользователя в очереди", taskState: "needs_attention")
        }
        guard let runtime = state["threadRuntimeStatus"] as? [String: Any] else {
            return Decision(action: .stop, reason: "Нет состояния выполнения")
        }
        let runtimeType = runtime["type"] as? String
        if runtimeType == "active" {
            if JSON.truthy(runtime["activeFlags"]) {
                return Decision(action: .stop, reason: "Задача ждёт подтверждения, ввода или других предварительных условий", taskState: "needs_attention")
            }
            return Decision(action: .wait, reason: "Задача выполняется; если она прервётся из-за исчерпания лимита, Cooldown дождётся его восстановления", taskState: "running")
        }
        // A real usage-limit failure shows as systemError, not idle. Only these two terminal
        // containers may be read; transitional types keep the watch but never authorize a send.
        guard runtimeType == "idle" || runtimeType == "systemError" else {
            return Decision(action: .wait, reason: "Состояние выполнения синхронизируется; наблюдение сохранено, перепроверка позже", taskState: "connecting")
        }
        let turn: [String: Any]
        do { turn = try latestTurn(state) } catch let error as Unsupported {
            return Decision(action: .stop, reason: error.reason)
        } catch {
            return Decision(action: .stop, reason: "Неподдерживаемая структура истории сессии")
        }
        guard let turnId = JSON.nonEmptyString(turn["turnId"]) else {
            return Decision(action: .stop, reason: "У последнего раунда нет стабильного идентификатора")
        }
        switch turn["status"] as? String {
        case "inProgress":
            return Decision(action: .wait, reason: "Состояние выполнения раунда синхронизируется", taskState: "running")
        case "completed":
            if goalActive {
                return Decision(action: .wait, reason: "Цель долгой задачи ещё выполняется, ждём следующего шага приложения; лишних сообщений не отправляется",
                                turnId: turnId, taskState: "running")
            }
            return Decision(action: .stop, reason: "Раунд завершён, выполняющихся задач сейчас нет — наблюдение не нужно", turnId: turnId, taskState: "idle")
        case "interrupted":
            return Decision(action: .stop, reason: "Раунд остановлен; автоматически перезапущен не будет", turnId: turnId, taskState: "interrupted")
        case "failed" where quotaFailure(turn):
            return Decision(action: .resume, reason: "Задача приостановлена из-за исчерпания лимита; после восстановления лимита продолжится в том же диалоге",
                            turnId: turnId, taskState: "quota_limited")
        default:
            return Decision(action: .stop, reason: "Это не ошибка исчерпания лимита со структурированными доказательствами", turnId: turnId, taskState: "other_failure")
        }
    }

    static let fingerprintKeys = ["id", "hostId", "cwd", "latestModel", "latestReasoningEffort", "latestCollaborationMode",
                                  "currentPermissions", "latestThreadSettings", "threadGoal", "threadGoalResumeConfirmation",
                                  "requests", "queuedFollowUps", "threadRuntimeStatus", "resumeState"]

    /// Binds the work and its execution settings; titles and token counters do not count.
    static func fingerprint(_ state: [String: Any]) throws -> String {
        var data: [String: Any] = [:]
        for key in fingerprintKeys { data[key] = state[key] ?? NSNull() }
        data["turn"] = try latestTurn(state)
        guard let bytes = JSON.canonical(data) else { throw Unsupported(reason: "Состояние задачи нельзя однозначно сравнить") }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    struct Quota: Equatable {
        var ready: Bool
        /// When to read the limits again; nil means waiting cannot help.
        var nextCheck: Double?
        var reason: String
    }

    /// Whether the account has headroom now. Always re-read after a reset: a reset time alone
    /// never implies headroom.
    static func quotaStatus(_ response: [String: Any], now: Double, limitId: String? = nil) -> Quota {
        func no(_ next: Double?, _ reason: String) -> Quota { Quota(ready: false, nextCheck: next, reason: reason) }
        var bucket: [String: Any]?
        if let buckets = response["rateLimitsByLimitId"] as? [String: Any], !buckets.isEmpty {
            if limitId == nil && Set(buckets.keys) != ["codex"] { return no(nil, "Несколько групп лимитов; нужно выбрать одну явно") }
            bucket = buckets[limitId ?? "codex"] as? [String: Any]
        } else {
            bucket = response["rateLimits"] as? [String: Any]
            if let limitId, bucket?["limitId"] as? String != limitId { bucket = nil }
        }
        guard let bucket else { return no(nil, "Выбранная группа лимитов отсутствует") }
        if JSON.truthy(bucket["spendControlReached"]) || !JSON.isNull(bucket["individualLimit"]) {
            return no(nil, "У аккаунта есть отдельное ограничение использования, нужна ручная проверка")
        }
        let reached = bucket["rateLimitReachedType"]
        if !JSON.isNull(reached) && reached as? String != "rate_limit_reached" {
            return no(nil, "У аккаунта есть ограничение лимита вне окон")
        }
        let primary = bucket["primary"]
        if JSON.isNull(primary) { return no(nil, "Нет данных основного окна лимита") }
        var exhausted: [Double] = []
        for window in [primary, bucket["secondary"]] where !JSON.isNull(window) {
            guard let window = window as? [String: Any] else { return no(nil, "Неподдерживаемая структура окна лимита") }
            guard let used = JSON.number(window["usedPercent"]), (0...100).contains(used),
                  let reset = JSON.number(window["resetsAt"]), reset > 0,
                  let duration = JSON.number(window["windowDurationMins"]), duration > 0 else {
                return no(nil, "Данные лимита неполны, время доступности предполагать нельзя")
            }
            if used >= 100 { exhausted.append(reset) } else if reset <= now { return no(now + 60, "Данные лимита устарели, перечитаем через минуту") }
        }
        if let latest = exhausted.max() {
            return no(max(now + 60, latest + 15), "Лимита всё ещё недостаточно, проверим снова сразу после сброса")
        }
        if !JSON.isNull(reached) { return no(now + 60, "Сервис всё ещё помечает лимит как исчерпанный, проверим через минуту") }
        return Quota(ready: true, nextCheck: now, reason: "Во всех окнах выбранной группы лимитов есть остаток")
    }
}
