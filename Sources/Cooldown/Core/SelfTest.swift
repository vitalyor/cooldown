import Foundation

/// Cooldown's own checks of the rules that must never break: run with `Cooldown --selftest`
/// (the release script runs it before publishing) and from Settings → Diagnostics.
@MainActor
enum SelfTest {
    static func run() -> [String] {
        var failures = ResumeSelfTest.run()
        func expect(_ condition: Bool, _ name: String) { if !condition { failures.append(name) } }

        // Codex requests: only changes to the requests make Cooldown look again.
        expect(CodexRequestWatcher.touchesRequests([["op": "replace", "path": ["requests", 0], "value": 1]]), "patch to requests is noticed")
        expect(!CodexRequestWatcher.touchesRequests([["op": "replace", "path": ["turns", 3, "items"], "value": 1]]), "streaming text is ignored")
        expect(CodexRequestWatcher.touchesRequests([["op": "replace", "path": [Any](), "value": 1]]), "whole-state patch is noticed")
        expect(CodexRequestWatcher.touchesRequests("unknown format"), "unknown patch format is noticed")

        let thread = ResumeSelfTest.thread
        let command: [String: Any] = ["id": 7, "method": "item/commandExecution/requestApproval",
                                      "params": ["command": "ls", "cwd": "/tmp", "threadId": thread, "turnId": "t", "itemId": "i", "startedAtMs": 1]]
        let card = CodexRequestWatcher.card(command, thread: thread, key: "k", title: "T")
        expect(card?.choices.contains { $0.id == "accept" && $0.role == .allow } == true, "command card offers allow")
        expect(card?.choices.contains { $0.id == "decline" } == true, "command card offers decline")
        expect(card?.choices.contains { $0.role == .open } == true, "command card opens the chat")
        expect(CodexRequestWatcher.card(["id": 1, "method": "item/tool/call", "params": [:]], thread: thread, key: "k", title: "T") == nil,
               "app's own pickers make no card")
        expect(CodexRequestWatcher.card(["id": 1, "method": "future/thing", "params": [:]], thread: thread, key: "k", title: "T")?.choices.map(\.role) == [.open],
               "unknown requests only open the chat")
        let secret: [String: Any] = ["id": 2, "method": "item/tool/requestUserInput",
                                     "params": ["questions": [["id": "q", "question": "Token?", "isSecret": true, "options": [["label": "a", "description": ""]]]]]]
        expect(CodexRequestWatcher.card(secret, thread: thread, key: "k", title: "T")?.choices.map(\.role) == [.open], "secret questions only open the chat")
        let two: [String: Any] = ["id": 3, "method": "item/tool/requestUserInput",
                                  "params": ["questions": [["id": "a", "question": "A?", "options": [["label": "x", "description": ""]]],
                                                           ["id": "b", "question": "B?", "options": [["label": "y", "description": ""]]]]]]
        expect(CodexRequestWatcher.card(two, thread: thread, key: "k", title: "T")?.steps.count == 2, "two questions become two steps")
        expect(CodexRequestWatcher.requestKey(thread, true) == nil, "a boolean is not a request id")

        // Claude limits: a reset shows at once; within one moment the highest reading wins.
        let now = Date()
        func reading(_ used: Double, at minutesAgo: Double, reset: Date) -> LimitSnapshot {
            LimitSnapshot(provider: .claude, plan: nil,
                          session: LimitWindow(kind: .session, usedPercent: used, durationMinutes: 300, resetsAt: reset), weekly: nil,
                          fetchedAt: now.addingTimeInterval(-minutesAgo * 60), source: "t")
        }
        let reset = now.addingTimeInterval(3600)
        expect(ClaudeLimits.merge([reading(98, at: 8, reset: reset), reading(3, at: 0, reset: reset)], now: now)?.session?.usedPercent == 3,
               "a reset is not hidden by an older reading")
        expect(ClaudeLimits.merge([reading(40, at: 1, reset: reset), reading(38, at: 0, reset: reset)], now: now)?.session?.usedPercent == 40,
               "readings taken together: the highest wins")

        // /usage: only the last drawing counts.
        let screen = "Current session 98% used Resets 9:30pm Current week (all models) 77% used Resets Oct 23 at 7pm Refreshing… "
            + "Current session 3% used Resets 12:50am Current week (all models) 1% used Resets Oct 23 at 7pm"
        let latest = ClaudeUsageCLI.latestScreen(screen)
        expect(!latest.contains("98%"), "the cached drawing is skipped")
        expect(ClaudeUsageCLI.parse(latest, now: now)?.session?.usedPercent == 3, "the fresh drawing is read")

        // Russian plural forms.
        expect(Format.plural(1, "задача", "задачи", "задач") == "задача" && Format.plural(3, "задача", "задачи", "задач") == "задачи"
               && Format.plural(11, "задача", "задачи", "задач") == "задач" && Format.plural(22, "задача", "задачи", "задач") == "задачи",
               "plural forms")
        return failures
    }
}
