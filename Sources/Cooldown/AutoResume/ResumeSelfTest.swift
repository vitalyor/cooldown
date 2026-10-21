import Foundation

/// The safety cases of codex-auto-resume's test suite, ported: run with `Cooldown --resume-selftest`.
/// Every case is about one thing — unknown or changed state never leads to a message.
enum ResumeSelfTest {
    static let thread = "11111111-1111-4111-8111-111111111111"

    static func state(_ status: String = "failed", error: Any? = "usageLimitExceeded", turnId: String = "t1") -> [String: Any] {
        let turn: [String: Any] = ["turnId": turnId, "status": status, "error": ["codexErrorInfo": error ?? NSNull()], "items": [Any]()]
        return ["id": thread, "hostId": "local", "ephemeral": false, "resumeState": "resumed", "requests": [Any](),
                "threadGoal": NSNull(), "threadGoalResumeConfirmation": NSNull(), "threadRuntimeStatus": ["type": "idle"],
                "latestModel": "same-model", "currentPermissions": ["profile": "existing"], "cwd": "/work", "turns": [Any](),
                "turnHistory": ["kind": "canonical", "history": [
                    "entitiesByKey": ["entity": turn],
                    "islands": [["entries": [["key": "key", "value": "entity"]], "newerBoundary": ["status": "exhausted"]]],
                    "isComplete": true]]]
    }

    static func quota(_ primary: Any = 10, _ secondary: Any = 10, reset: Double = 2000, weeklyReset: Double = 8000) -> [String: Any] {
        ["rateLimitsByLimitId": ["codex": [
            "primary": ["usedPercent": primary, "windowDurationMins": 300, "resetsAt": reset],
            "secondary": ["usedPercent": secondary, "windowDurationMins": 10080, "resetsAt": weeklyReset],
            "spendControlReached": false, "individualLimit": NSNull(), "rateLimitReachedType": NSNull()]]]
    }

    /// Adds a verified orphan of the folder picker before the failed turn.
    static func withPicker(_ base: [String: Any]) -> [String: Any] {
        var data = base
        var history = data["turnHistory"] as! [String: Any]
        var hist = history["history"] as! [String: Any]
        var entities = hist["entitiesByKey"] as! [String: Any]
        entities["old-picker"] = ["turnId": "old-picker-turn", "status": "interrupted", "items": [Any]()]
        var islands = hist["islands"] as! [[String: Any]]
        var tail = islands[islands.count - 1]
        var entries = tail["entries"] as! [[String: Any]]
        entries.insert(["key": "old-key", "value": "old-picker"], at: 0)
        tail["entries"] = entries
        islands[islands.count - 1] = tail
        hist["islands"] = islands
        hist["entitiesByKey"] = entities
        hist["isComplete"] = false
        history["history"] = hist
        data["turnHistory"] = history
        data["requests"] = [["method": "item/tool/call", "params": ["threadId": thread, "turnId": "old-picker-turn",
                                                                      "namespace": "codex_app", "tool": "setup_codex_context_picker"]]]
        return data
    }

    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ name: String) { if !condition { failures.append(name) } }
        let decide = ResumePolicy.decide

        expect(decide(state()).action == .resume, "structured quota failure resumes")
        for (status, label) in [("failed", "quota_limited"), ("completed", "idle"), ("interrupted", "interrupted")] {
            expect(decide(state(status)).taskState == label, "classification \(status)")
        }
        var active = state(); active["threadRuntimeStatus"] = ["type": "active", "activeFlags": [Any]()]
        expect(decide(active).taskState == "running" && decide(active).action == .wait, "active waits")
        active["threadRuntimeStatus"] = ["type": "active", "activeFlags": ["waitingOnApproval"]]
        expect(decide(active).action == .stop, "active approval stops")

        var system = withPicker(state()); system["threadRuntimeStatus"] = ["type": "systemError"]
        expect(decide(system).action == .resume && decide(system).turnId == "t1", "systemError quota resumes")
        for error in ["Other", NSNull(), ["usageLimitExceeded": [String: Any]()], "Unauthorized"] as [Any] {
            var s = state(error: error); s["threadRuntimeStatus"] = ["type": "systemError"]
            expect(decide(s).action == .stop, "systemError other error stops \(error)")
            expect(decide(state(error: error)).action == .stop, "non-quota error stops \(error)")
        }
        for runtime in [["type": "initializing"], ["type": "unknown"], [String: Any]()] as [[String: Any]] {
            var s = state(); s["threadRuntimeStatus"] = runtime
            expect(decide(s).action == .wait && decide(s).taskState == "connecting", "transitional runtime waits")
        }
        for status in ["completed", "interrupted", "unknown"] { expect(decide(state(status)).action == .stop, "normal stop \(status)") }
        let blockers: [(String, Any)] = [("requests", [["type": "approval"]]), ("threadGoal", ["status": "paused"]),
                                         ("threadGoal", ["status": "complete"]), ("threadGoalResumeConfirmation", ["required": true]),
                                         ("ephemeral", true), ("hostId", "remote"), ("queuedFollowUps", ["message"])]
        for (field, value) in blockers {
            var s = state(); s[field] = value
            expect(decide(s).action == .stop, "blocks on \(field)")
        }
        // The folder-picker exception: exact, and never covers approvals.
        expect(decide(withPicker(state())).action == .resume, "verified picker does not block")
        for (field, value) in [("namespace", "other"), ("tool", "approve_request"), ("threadId", "other-thread"),
                               ("turnId", "missing"), ("turnId", "t1")] {
            var s = withPicker(state())
            var requests = s["requests"] as! [[String: Any]]
            var params = requests[0]["params"] as! [String: Any]
            params[field] = value
            requests[0]["params"] = params
            s["requests"] = requests
            expect(decide(s).action == .stop, "picker exact \(field)=\(value)")
        }
        for method in ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval",
                       "item/tool/requestUserInput", "unknown"] {
            var s = withPicker(state())
            var requests = s["requests"] as! [[String: Any]]
            requests[0]["method"] = method
            s["requests"] = requests
            expect(decide(s).action == .stop, "picker never covers \(method)")
        }
        var extra = withPicker(state()); extra["requests"] = (extra["requests"] as! [Any]) + [["type": "approval"]]
        expect(decide(extra).action == .stop, "picker plus another request stops")
        var noBoundary = state()
        if var history = noBoundary["turnHistory"] as? [String: Any], var hist = history["history"] as? [String: Any],
           var islands = hist["islands"] as? [[String: Any]] {
            islands[0]["newerBoundary"] = ["status": "unknown"]
            hist["islands"] = islands; history["history"] = hist; noBoundary["turnHistory"] = history
        }
        expect(decide(noBoundary).action == .stop, "incomplete history stops")
        for key in ["requests", "threadRuntimeStatus", "ephemeral"] {
            var s = state(); s.removeValue(forKey: key)
            expect(decide(s).action == .stop, "missing \(key) stops")
        }
        var rollout = state(); rollout.removeValue(forKey: "ephemeral")
        rollout["rolloutPath"] = "/home/user/.codex/sessions/rollout.jsonl"
        expect(decide(rollout).taskState != "unsupported", "rollout path counts as saved")
        for bad in [NSNull(), "", "   ", 123, ["x"]] as [Any] {
            var s = rollout; s["rolloutPath"] = bad
            expect(decide(s).taskState == "unsupported", "bad rollout \(bad)")
        }
        rollout["ephemeral"] = true
        expect(decide(rollout).taskState == "unsupported", "explicit ephemeral wins")
        var legacy = state()
        let turn = try? ResumePolicy.latestTurn(legacy)
        legacy.removeValue(forKey: "turnHistory"); legacy["turns"] = [turn as Any]
        expect(decide(legacy).action == .resume, "legacy history")

        // Fingerprint: settings count, titles and counters do not.
        var printed = state()
        let original = try? ResumePolicy.fingerprint(printed)
        printed["title"] = "new title"; printed["latestTokenUsageInfo"] = ["total": 123]
        expect((try? ResumePolicy.fingerprint(printed)) == original, "fingerprint ignores title")
        printed["currentPermissions"] = ["profile": "changed"]
        expect((try? ResumePolicy.fingerprint(printed)) != original, "fingerprint tracks permissions")

        // Quota.
        expect(ResumePolicy.quotaStatus(quota(), now: 1000).ready, "available quota")
        let weekly = ResumePolicy.quotaStatus(quota(100, 100), now: 1000)
        expect(!weekly.ready && weekly.nextCheck == 8015, "weekly limit overrides short reset")
        let stale = ResumePolicy.quotaStatus(quota(reset: 900), now: 1000)
        expect(!stale.ready && stale.nextCheck == 1060, "expired quota must refresh")
        for value in [NSNull(), true, Double.nan, -1, 101, "10"] as [Any] {
            expect(!ResumePolicy.quotaStatus(quota(value), now: 1000).ready, "bad quota \(value) fails closed")
        }
        var buckets = quota()
        var byId = buckets["rateLimitsByLimitId"] as! [String: Any]
        byId["other"] = byId["codex"]; buckets["rateLimitsByLimitId"] = byId
        expect(ResumePolicy.quotaStatus(buckets, now: 1000).nextCheck == nil, "several buckets need a choice")
        expect(ResumePolicy.quotaStatus(buckets, now: 1000, limitId: "codex").ready, "chosen bucket")
        var spend = quota()
        var spendIds = spend["rateLimitsByLimitId"] as! [String: Any]
        var codex = spendIds["codex"] as! [String: Any]
        codex["spendControlReached"] = true; spendIds["codex"] = codex; spend["rateLimitsByLimitId"] = spendIds
        let spendStatus = ResumePolicy.quotaStatus(spend, now: 1000)
        expect(!spendStatus.ready && spendStatus.nextCheck == nil, "spend control is not waitable")

        // Saved history may allow watching, never sending.
        for (status, error) in [("inProgress", NSNull() as Any), ("failed", "usageLimitExceeded" as Any)] {
            let saved: [String: Any] = ["id": thread, "ephemeral": false, "turns": [["id": "turn-1", "status": status, "error": ["codexErrorInfo": error]]]]
            expect((try? AutoResume.storedAssessment(saved, id: thread))?.canMonitor == true, "history allows watching \(status)")
        }
        for status in ["completed", "interrupted", "failed", "unknown"] {
            let saved: [String: Any] = ["id": thread, "ephemeral": false, "turns": [["id": "turn-1", "status": status, "error": ["codexErrorInfo": NSNull()]]]]
            expect((try? AutoResume.storedAssessment(saved, id: thread))?.canMonitor == false, "history refuses \(status)")
        }
        expect((try? AutoResume.storedAssessment(["id": "different", "turns": [Any]()], id: thread)) == nil, "history of another thread throws")
        return failures
    }
}
