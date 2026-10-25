import Foundation

/// Checks of the auto-continue rules on made-up states, without talking to the Codex app.
enum ResumeSelfTest {
    static let thread = "01a1301d-cd1b-70f3-b49a-501ba6c9b04d"

    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ name: String) { if !condition { failures.append("auto-continue: " + name) } }

        // A live state in the newer form (turn history), with the latest turn as given.
        func state(_ latest: [String: Any], older: [[String: Any]] = [], change: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
            var entities: [String: Any] = [:]
            var entries: [[String: Any]] = []
            for (index, turn) in (older + [latest]).enumerated() {
                entities["k\(index)"] = turn
                entries.append(["key": "k\(index)", "value": "k\(index)"])
            }
            var value: [String: Any] = [
                "id": thread, "hostId": "local", "ephemeral": false, "resumeState": "resumed", "cwd": "/tmp/project",
                "latestModel": "gpt-test", "requests": [Any](), "threadGoal": NSNull(), "queuedFollowUps": NSNull(),
                "threadGoalResumeConfirmation": NSNull(), "threadRuntimeStatus": ["type": "systemError"],
                "turnHistory": ["kind": "canonical", "history": [
                    "islands": [["entries": entries, "newerBoundary": ["status": "exhausted"]]],
                    "entitiesByKey": entities]],
            ]
            change(&value)
            return value
        }
        let limitFailure: [String: Any] = ["turnId": "turn-9", "status": "failed", "error": ["codexErrorInfo": "usageLimitExceeded", "message": "limit"]]
        func decide(_ value: [String: Any]) -> ResumeRules.Verdict { ResumeRules.decide(value, thread: thread) }

        // Deciding.
        let ready = decide(state(limitFailure))
        expect(ready.action == .send && ready.taskState == "quota_limited" && ready.failedTurn == "turn-9", "a turn stopped by the limit is continued")
        expect(decide(state(["turnId": "t", "status": "failed", "error": ["codexErrorInfo": "UsageLimitExceeded"]])).action == .send,
               "the other spelling of the limit code counts")
        expect(decide(state(["turnId": "t", "status": "failed", "error": ["codexErrorInfo": "other", "message": "usage limit exceeded"]])).taskState == "other_failure",
               "the limit is never read from text")
        expect(decide(state(["turnId": "t", "status": "inProgress"])).action == .wait, "a running turn is waited for")
        expect(decide(state(["turnId": "t", "status": "completed"], change: { $0["threadRuntimeStatus"] = ["type": "idle"] })).taskState == "idle",
               "a finished turn stops the watch")
        expect(decide(state(["turnId": "t", "status": "completed"], change: { $0["threadGoal"] = ["status": "active"] })).action == .wait,
               "a finished turn with an active goal is waited for")
        expect(decide(state(limitFailure) { $0["threadGoal"] = ["status": "paused"] }).taskState == "needs_attention", "an inactive goal needs the person")
        expect(decide(state(["turnId": "t", "status": "interrupted"])).taskState == "interrupted", "an interrupted turn is left alone")
        expect(decide(state(limitFailure) { $0["hostId"] = "remote" }).taskState == "unsupported", "only conversations on this Mac")
        expect(decide(state(limitFailure) { $0["ephemeral"] = true }).taskState == "unsupported", "unsaved conversations are not supported")
        expect(decide(state(limitFailure) { $0["ephemeral"] = nil; $0["rolloutPath"] = "/x.jsonl" }).action == .send, "a saved file counts as persistent")
        expect(decide(state(limitFailure) { $0["ephemeral"] = nil }).taskState == "unsupported", "unknown persistence is not supported")
        expect(decide(state(limitFailure) { $0["resumeState"] = "loading" }).taskState == "connecting", "a loading conversation is waited for")
        expect(decide(state(limitFailure) { $0["requests"] = nil }).action == .stop, "missing requests stop")
        expect(decide(state(limitFailure) { $0["queuedFollowUps"] = [["text": "next"]] }).taskState == "needs_attention", "a queued message stops")
        expect(decide(state(limitFailure) { $0["queuedFollowUps"] = [Any]() }).action == .send, "an empty queue is no queue")
        expect(decide(state(limitFailure) { $0["threadGoalResumeConfirmation"] = true }).taskState == "needs_attention", "a confirmation stops")
        expect(decide(state(limitFailure) { $0["threadRuntimeStatus"] = ["type": "active", "activeFlags": ["waitingOnApproval"]] }).taskState == "needs_attention",
               "a blocked active turn needs the person")
        expect(decide(state(limitFailure) { $0["threadRuntimeStatus"] = ["type": "active", "activeFlags": [Any]()] }).taskState == "running",
               "an active turn is waited for")
        expect(decide(state(limitFailure) { $0["threadRuntimeStatus"] = ["type": "starting"] }).taskState == "connecting", "transitional runtime waits")
        expect(decide(state(limitFailure) { $0["threadRuntimeStatus"] = nil }).action == .stop, "missing runtime stops")
        expect(decide(state(["status": "failed", "error": ["codexErrorInfo": "usageLimitExceeded"]])).action == .stop, "a turn without id stops")
        expect(decide(state(limitFailure) {
            var history = $0["turnHistory"] as! [String: Any]
            var body = history["history"] as! [String: Any]
            var islands = body["islands"] as! [[String: Any]]
            islands[0]["newerBoundary"] = ["status": "hasMore"]
            body["islands"] = islands; history["history"] = body; $0["turnHistory"] = history
        }).taskState == "unknown", "a partial history is not trusted")
        expect(decide(state(limitFailure) { $0["turnHistory"] = nil; $0["turns"] = [["turnId": "a", "status": "completed"], limitFailure] }).failedTurn == "turn-9",
               "the older turns array works too")

        // Requests and the known leftover.
        let approval: [String: Any] = ["id": 4, "method": "item/commandExecution/requestApproval", "params": ["threadId": thread]]
        expect(decide(state(limitFailure) { $0["requests"] = [approval] }).taskState == "needs_attention", "a pending approval stops")
        func picker(_ turn: String) -> [String: Any] {
            ["id": "p", "method": "item/tool/call",
             "params": ["namespace": "codex_app", "tool": "setup_codex_context_picker", "threadId": thread, "turnId": turn]]
        }
        let interrupted: [String: Any] = ["turnId": "turn-3", "status": "interrupted"]
        let completed: [String: Any] = ["turnId": "turn-4", "status": "completed"]
        expect(decide(state(limitFailure, older: [interrupted]) { $0["requests"] = [picker("turn-3")] }).action == .send,
               "the picker left by an older interrupted turn is ignored")
        expect(decide(state(limitFailure, older: [completed]) { $0["requests"] = [picker("turn-4")] }).taskState == "needs_attention",
               "a picker of a completed turn still counts")
        expect(decide(state(limitFailure, older: [interrupted]) { $0["requests"] = [picker("turn-9")] }).taskState == "needs_attention",
               "a picker of the latest turn still counts")
        expect(decide(state(limitFailure, older: [interrupted]) { $0["requests"] = [picker("turn-3"), approval] }).taskState == "needs_attention",
               "the leftover does not hide a real request")

        // What must not change while waiting.
        let base = ResumeRules.fingerprint(state(limitFailure))
        expect(base != nil && base == ResumeRules.fingerprint(state(limitFailure)), "the same state gives the same fingerprint")
        expect(base != ResumeRules.fingerprint(state(limitFailure) { $0["latestModel"] = "other" }), "a model change is noticed")
        expect(base != ResumeRules.fingerprint(state(limitFailure) { $0["cwd"] = "/elsewhere" }), "a folder change is noticed")
        expect(base == ResumeRules.fingerprint(state(limitFailure) { $0["unreadMessageCount"] = 3 }), "unrelated fields do not matter")

        // Saved history allows watching, never sending.
        expect(ResumeRules.judgeHistory(["ephemeral": false, "turns": [["id": "a", "status": "failed", "error": ["codexErrorInfo": "usageLimitExceeded"]]]]).state == "quota_limited",
               "saved history sees the limit")
        expect(ResumeRules.judgeHistory(["ephemeral": false, "turns": [Any]()]).state == "empty", "an empty history")
        expect(ResumeRules.judgeHistory(["ephemeral": false]).state == "unknown", "an unreadable history")

        // Limits.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func bucket(_ used: Double, resets: Double = 1_800_003_600, change: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
            var value: [String: Any] = ["limitId": "codex", "primary": ["usedPercent": used, "resetsAt": resets, "windowDurationMins": 300],
                                        "secondary": ["usedPercent": 10, "resetsAt": 1_800_500_000, "windowDurationMins": 10080],
                                        "rateLimitReachedType": NSNull(), "spendControlReached": false, "individualLimit": NSNull()]
            change(&value)
            return ["rateLimits": value, "rateLimitsByLimitId": ["codex": value]]
        }
        expect(ResumeRules.judgeLimits(bucket(40), now: now) == .available, "limits available")
        expect(ResumeRules.judgeLimits(bucket(100), now: now) == .notYet(Date(timeIntervalSince1970: 1_800_003_605)), "a full window waits for its reset")
        expect(ResumeRules.judgeLimits(bucket(100, resets: 1_799_999_990), now: now) == .notYet(now.addingTimeInterval(60)), "a passed reset waits at least a minute")
        expect(ResumeRules.judgeLimits(bucket(30, resets: 1_799_999_000), now: now) == .stale(now.addingTimeInterval(60)), "a passed reset below 100% is stale")
        expect(ResumeRules.judgeLimits(bucket(30) { $0["rateLimitReachedType"] = "rate_limit_reached" }, now: now) == .stale(now.addingTimeInterval(60)),
               "still flagged as reached waits")
        if case .blocked = ResumeRules.judgeLimits(bucket(30) { $0["spendControlReached"] = true }, now: now) {} else { failures.append("auto-continue: spend control blocks") }
        if case .blocked = ResumeRules.judgeLimits(bucket(30) { $0["individualLimit"] = ["x": 1] }, now: now) {} else { failures.append("auto-continue: an individual limit blocks") }
        if case .blocked = ResumeRules.judgeLimits(bucket(30) { $0["rateLimitReachedType"] = "workspace_owner_limit" }, now: now) {} else { failures.append("auto-continue: unknown reached type blocks") }
        if case .blocked = ResumeRules.judgeLimits(bucket(30) { $0["primary"] = NSNull() }, now: now) {} else { failures.append("auto-continue: missing window blocks") }
        if case .blocked = ResumeRules.judgeLimits(bucket(30) { $0["primary"] = ["usedPercent": "30", "resetsAt": 1, "windowDurationMins": 300] }, now: now) {} else {
            failures.append("auto-continue: invalid window blocks")
        }
        let other = (bucket(30)["rateLimits"] as! [String: Any])
        if case .blocked = ResumeRules.judgeLimits(["rateLimitsByLimitId": ["a": other, "b": other]], now: now) {} else { failures.append("auto-continue: unclear buckets block") }
        var both = bucket(40)
        both["rateLimitsByLimitId"] = ["codex": bucket(40)["rateLimits"]!, "other": bucket(100)["rateLimits"]!]
        expect(ResumeRules.judgeLimits(both, now: now) == .available, "Codex's own bucket is chosen")
        expect(ResumeRules.judgeLimits(["rateLimits": bucket(100)["rateLimits"]!], now: now) != .available, "a single bucket works too")

        // Never twice, and an unknown outcome blocks for good.
        var data = ResumeData()
        expect(ResumeRules.gate(data, thread: thread, turn: "turn-9", maxResumes: 2, now: now) == .proceed, "a first send may go")
        data.sends.append(.init(threadId: thread, failedTurn: "turn-9", messageId: "m1", state: "confirmed", newTurn: "turn-10", time: now))
        expect(ResumeRules.gate(data, thread: thread, turn: "turn-9", maxResumes: 5, now: now.addingTimeInterval(30)) == .justSent, "just sent: keep watching")
        expect(ResumeRules.gate(data, thread: thread, turn: "turn-9", maxResumes: 5, now: now.addingTimeInterval(600)) == .alreadySent, "one continuation per failed turn")
        expect(ResumeRules.gate(data, thread: thread, turn: "turn-11", maxResumes: 1, now: now) == .budget, "attempts run out")
        expect(ResumeRules.gate(data, thread: thread, turn: "turn-11", maxResumes: 2, now: now) == .proceed, "a new failure may be continued")
        data.sends.append(.init(threadId: thread, failedTurn: "turn-11", messageId: "m2", state: "pending", newTurn: nil, time: now))
        expect(ResumeRules.gate(data, thread: thread, turn: "turn-12", maxResumes: 9, now: now.addingTimeInterval(9999)) == .uncertain, "an unknown outcome blocks sending")
        expect(ResumeRules.startRefusal(data, thread: thread, maxResumes: 9, latestTurn: "turn-11") != nil, "an unknown outcome blocks starting again")
        expect(ResumeRules.startRefusal(data, thread: thread, maxResumes: 9, latestTurn: nil) != nil, "an unknown outcome blocks without fresh data")
        expect(ResumeRules.startRefusal(data, thread: thread, maxResumes: 9, latestTurn: "turn-14") == nil, "the person took over: may start again")
        expect(ResumeRules.startRefusal(data, thread: thread, maxResumes: 2, latestTurn: "turn-14") != nil, "used attempts block starting")

        // The store keeps a send intent across a restart, and one copy holds a conversation.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cooldown-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ResumeStore(folder: folder, legacy: nil)
        do {
            try store.update { $0.sends.append(.init(threadId: thread, failedTurn: "t", messageId: "m", state: "pending", newTurn: nil, time: now)) }
            let again = try ResumeStore(folder: folder, legacy: nil).load()
            expect(again.pending(thread)?.messageId == "m", "a send intent survives a restart")
            var info = stat()
            expect(stat(folder.path, &info) == 0 && info.st_mode & 0o777 == 0o700, "the store folder is private")
            expect(stat(folder.appendingPathComponent("state.json").path, &info) == 0 && info.st_mode & 0o777 == 0o600, "the store file is private")
        } catch {
            failures.append("auto-continue: store works (\(error.localizedDescription))")
        }
        let other1 = ResumeStore(folder: folder, legacy: nil)
        expect(store.claim(thread), "a conversation can be claimed")
        expect(!other1.claim(thread), "a claimed conversation is refused to another copy")
        store.release(thread)
        expect(other1.claim(thread), "a released conversation can be claimed")
        other1.release(thread)

        // Small helpers the other parts rely on.
        expect(JSON.isBool(true as NSNumber) && !JSON.isBool(1 as NSNumber), "booleans are not numbers")
        expect(JSON.canonical(["b": 1, "a": 2]) == JSON.canonical(["a": 2, "b": 1]), "stable serialisation")
        expect(ResumeRules.isThreadId(thread) && !ResumeRules.isThreadId("01a1301d"), "only exact ids")
        expect(CodexConversation(id: "x", name: "  ", preview: nil, cwd: nil, updatedAt: nil, archived: false).title == L("Без названия"), "untitled")
        return failures
    }
}
