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
        expect(AppLanguage.pluralIndex(1, forms: 3) == 0 && AppLanguage.pluralIndex(3, forms: 3) == 1
               && AppLanguage.pluralIndex(11, forms: 3) == 2 && AppLanguage.pluralIndex(22, forms: 3) == 1, "plural forms")
        expect(Format.word(5, "a|b|c") == "c" || Format.word(5, "a|b|c") == "b", "plural words")
        // iPhone: what goes where, and nothing private reaches the Live Activity.
        let request = ToastContent(key: "req-x", kind: .attention, provider: .codex, title: "Секретный чат", body: "rm -rf build", // l10n:skip
                                   choices: [RequestChoice(id: "allow", title: "OK", role: .allow), // l10n:skip
                                             RequestChoice(id: "open", title: "Open", role: .open)]) // l10n:skip
        let requestCard = PhoneLink.card(request)
        expect(requestCard.actions.map(\.id) == ["choice:allow"], "phone gets the answers, not 'open'")
        expect(requestCard.actions.first?.auth == true, "allowing needs Face ID")
        let item = PhoneLink.liveItem(requestCard)
        expect(!item.title.contains("Секретный") && !item.title.contains("rm -rf"), "Lock Screen title is general") // l10n:skip
        expect(PhoneLink.shared.delivery(request, card: requestCard, away: false) == .live, "a request goes to the Live Activity")
        let finished = ToastContent(key: "finished-x", kind: .finished, provider: .codex, title: "T", body: "B",
                                    actions: [.openCodexThread("t1")])
        let finishedCard = PhoneLink.card(finished)
        expect(finishedCard.actions.map(\.id) == ["reply"] && finishedCard.actions.first?.input == true, "a finished chat can be answered")
        expect(PhoneLink.shared.delivery(finished, card: finishedCard, away: false) == .none, "nothing on the phone while at the Mac")
        expect(PhoneLink.shared.delivery(finished, card: finishedCard, away: true) != .none, "finished reaches the phone when away")
        let pace = ToastContent(key: "pace-codex", kind: .info, provider: .codex, title: "T", body: "B")
        expect(PhoneLink.shared.delivery(pace, card: PhoneLink.card(pace), away: true) == .none, "numbers stay off the phone")
        let opener = AgentActivity.Opener.codexThread("t2")
        expect(PhoneLink.actionID(.continueAfterReset(opener)) == "afterReset", "continue after reset is a phone button")
        expect(PhoneLink.actionID(.remindBeforeReset(.codex, Date())) == nil, "reminders stay on the Mac")

        return failures
    }
}
