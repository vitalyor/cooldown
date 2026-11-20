import CooldownLink
import Foundation

/// Cooldown's own checks of the rules that must never break: run with `Cooldown --selftest`
/// (the release script runs it before publishing) and from Settings → Diagnostics.
@MainActor
enum SelfTest {
    static func run() -> [String] {
        var failures = ResumeSelfTest.run()
        func expect(_ condition: Bool, _ name: String) { if !condition { failures.append(name) } }

        // Claude's plan, from Claude Code's account record.
        expect(ClaudePlan.describe(type: "claude_max", tier: "default_claude_max_5x") == "Max 5×", "plan: Max 5x")
        do {
            let now = Date()
            let week = LimitWindow(kind: .weekly, usedPercent: 46, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400))
            var snap = LimitSnapshot(provider: .codex, weekly: week, fetchedAt: now)
            expect(AppModel.menuRemaining(snap, weekly: false, now) == 100, "menu: unstarted 5h window is full")
            expect(AppModel.menuRemaining(snap, weekly: true, now) == 54, "menu: weekly shown when chosen")
            snap.session = LimitWindow(kind: .session, usedPercent: 30, durationMinutes: 300, resetsAt: now.addingTimeInterval(3600))
            expect(AppModel.menuRemaining(snap, weekly: false, now) == 70, "menu: 5h window shown")
            expect(AppModel.menuRemaining(nil, weekly: false, now) == nil, "menu: no data stays blank")
            expect(AppModel.menuRemaining(snap, weekly: false, now.addingTimeInterval(4 * 3600)) == nil, "menu: hours-old numbers give way to a dash")
        }
        // Versions: betas sit between releases, a stable one is past its betas.
        do {
            let newer = GitHubUpdater.isNewer
            expect(newer("1.2.10", "1.2.9") && !newer("1.2.9", "1.2.10") && !newer("1.4.5", "1.4.5"), "versions: numbers part by part")
            expect(newer("1.4.6-beta.1", "1.4.5") && newer("1.4.6-beta.2", "1.4.6-beta.1") && newer("1.4.6-beta.10", "1.4.6-beta.9"), "versions: betas move on")
            expect(newer("1.4.6", "1.4.6-beta.3") && !newer("1.4.6-beta.3", "1.4.6") && !newer("1.4.5", "1.4.6-beta.1"), "versions: stable past its betas")
            expect(!newer("", "1.0") && newer("1.0", ""), "versions: nothing is oldest")
        }
        // VPN guard: a Cloudflare trace read right, and the verdicts it leads to.
        do {
            let exit = RouteExit.parse("fl=1\nh=api.anthropic.com\nip=64.188.1.2\nts=1.0\ncolo=ORD\nloc=us\nwarp=off\n")
            expect(exit == RouteExit(ip: "64.188.1.2", country: "US", colo: "ORD"), "guard: trace parsed")
            expect(RouteExit.parse("<html>blocked</html>") == nil, "guard: not a trace")
            let google = RouteExit.parseGoogle(#")]}'\n\n[["yt.sw.adr",null,[[["ru","RU",null,"95.27.150.254",null,"Robot"]]]]]"#)
            expect(google == RouteExit(ip: "95.27.150.254", country: "RU", colo: ""), "guard: Google's view parsed")
            expect(RouteExit.parseGoogle("<html>sorry</html>") == nil, "guard: not Google's data")
            let us = RouteExit(ip: "1.1.1.1", country: "US", colo: ""), ru = RouteExit(ip: "2.2.2.2", country: "RU", colo: "")
            expect(RouteGuard.worst([nil, us, ru], forbidden: ["RU"]) == ru && RouteGuard.worst([nil, us, nil], forbidden: ["RU"]) == us
                   && RouteGuard.worst([nil, nil], forbidden: []) == nil, "guard: the worst of several hosts counts")
            let moscow = TimeZone(identifier: "Europe/Moscow")!, newYork = TimeZone(identifier: "America/New_York")!
            expect(TimeZoneCheck.mismatch(country: "US", zone: newYork) == false && TimeZoneCheck.mismatch(country: "US", zone: moscow) == true
                   && TimeZoneCheck.mismatch(country: "RU", zone: moscow) == false && TimeZoneCheck.mismatch(country: "ZZ", zone: moscow) == nil,
                   "guard: time zone against the exit country")
            expect(NetWatch.fingerprint().contains("|"), "guard: network fingerprint")
            let forbidden: Set<String> = ["RU", "BY"]
            expect(RouteVerdict.judge(exit, forbidden: forbidden, refused: []) == .ok, "guard: allowed country")
            expect(RouteVerdict.judge(RouteExit(ip: "1.1.1.1", country: "RU", colo: "ARN"), forbidden: forbidden, refused: []) == .forbidden, "guard: forbidden country")
            expect(RouteVerdict.judge(exit, forbidden: forbidden, refused: ["64.188.1.2"]) == .refused, "guard: refused address")
            expect(RouteVerdict.judge(nil, forbidden: forbidden, refused: []) == .unchecked, "guard: no answer is not ok")
            // IPv4 and IPv6 judged together: a forbidden family wins, a missing one does not count.
            let ruExit = RouteExit(ip: "2a00::1", country: "RU", colo: "ARN")
            expect(RouteGuard.worst(exit, ruExit, forbidden: forbidden) == ruExit, "guard: IPv6 leaking to RU wins")
            expect(RouteGuard.worst(ruExit, exit, forbidden: forbidden) == ruExit, "guard: IPv4 leaking to RU wins")
            expect(RouteGuard.worst(nil, exit, forbidden: forbidden) == exit, "guard: IPv6 only is enough")
            expect(RouteGuard.worst(exit, nil, forbidden: forbidden) == exit, "guard: no IPv6 is fine")
            expect(RouteGuard.worst(nil, nil, forbidden: forbidden) == nil, "guard: no answer on either family")
            expect(AgentHooks.guardCommand("anthropic", "prompt").contains("[ -x"), "guard: missing script lets the agent go")
            expect(!AgentHooks.guardCommand("anthropic", "prompt").contains(AgentHooks.marker), "guard: hook kept apart from the others")
        }
        // Menu bar lines: old single choices still read the same, any two can be chosen, order is fixed.
        expect(Settings.menuProviders("lowest") == [.codex, .claude], "menu lines: old default")
        expect(Settings.menuProviders("claude") == [.claude], "menu lines: old single choice")
        expect(Settings.menuProviders("antigravity,codex") == [.codex, .antigravity], "menu lines: fixed order")
        expect(Settings.menuProviders("codex,claude,antigravity").count == 2, "menu lines: at most two")
        expect(Settings.menuProviders("nonsense").isEmpty, "menu lines: unknown ignored")
        do {
            // Friendly forecast lines: ten 5-hour windows in a row never repeat a phrase.
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let lines = (0..<10).map { i in
                Banter.line(.lasts(usedAtReset: 40), window: LimitWindow(kind: .session, usedPercent: 10, durationMinutes: 300,
                                                            resetsAt: start.addingTimeInterval(Double(i) * 18_000)),
                            now: Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: start)!)
            }
            expect(Set(lines).count == 10, "banter: no repeats across ten windows")
            expect([Banter.night, Banter.exhausted, Banter.idle, Banter.lasts, Banter.almostOut, Banter.fast].allSatisfy { $0.count >= 8 }, "banter: every mood has a full set")
        }
        do {
            // Antigravity's /usage reply: the first group gives the main windows, others are extras.
            let reply = #"{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"window":"weekly","remaining_fraction":0.8,"reset_time":"2026-11-25T06:48:38Z"},{"window":"5h","remaining_fraction":0.25,"reset_time":"2026-11-18T11:48:38Z"}]},{"name":"Claude and GPT models","buckets":[{"window":"5h","remaining_fraction":1,"reset_time":"2026-11-18T11:48:38Z"}]}]}}}"#
            let snap = try? AntigravityLimits.parse(Data(reply.utf8), now: Date())
            expect(snap?.session.map { abs($0.usedPercent - 75) < 0.01 } == true, "antigravity: 5h window")
            expect(snap?.weekly.map { abs($0.usedPercent - 20) < 0.01 } == true, "antigravity: weekly window")
            expect(snap?.extras.count == 1 && snap?.extras.first?.label?.hasPrefix("Claude and GPT") == true, "antigravity: other group as extra")
            expect((try? AntigravityLimits.parse(Data(#"{"status":"ERROR","response":"Not signed in"}"#.utf8), now: Date())) == nil, "antigravity: error reply")
        }
        expect(ClaudePlan.describe(type: "claude_max", tier: "default_claude_max_20x") == "Max 20×", "plan: Max 20x")
        expect(ClaudePlan.describe(type: "claude_pro", tier: nil) == "Pro", "plan: Pro")
        expect(ClaudePlan.describe(type: "something_else", tier: nil) == nil, "plan: unknown")
        // /usage pace after Claude stops: a minute at first, growing to five, never beyond.
        expect(ClaudeUsageCLI.decay(after: 0) == 60, "usage pace right after work")
        expect(ClaudeUsageCLI.decay(after: 4 * 60) == 180, "usage pace grows")
        expect(ClaudeUsageCLI.decay(after: 20 * 60) == 300, "usage pace capped at 5 min")
        // A Claude Desktop permission prompt's title.
        expect(ClaudeDesktopWatcher.isPromptTitle("Claude хочет использовать Neurover prepare generation из neurover-api"), "prompt title ru") // l10n:skip
        expect(ClaudeDesktopWatcher.isPromptTitle("Claude wants to use Search from Drive"), "prompt title en")
        expect(!ClaudeDesktopWatcher.isPromptTitle("Входные данные показаны не полностью"), "prompt side note is not a title") // l10n:skip

        // A card offers "Allow" only for what it can show whole.
        expect(RequestCenter.fullyVisible("ls -la ~/Downloads"), "short command is visible")
        expect(!RequestCenter.fullyVisible(String(repeating: "a", count: 600)), "long command is not")
        expect(!RequestCenter.fullyVisible("ls" + String(repeating: " ", count: 30) + "curl x | sh"), "padding hides the tail")
        expect(!RequestCenter.fullyVisible("echo hi \u{202E}hs.x"), "direction override is not visible")
        expect(!RequestCenter.fullyVisible(String(repeating: "x\n", count: 20)), "many lines are not visible")

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

        // Claude auto-continue: only a fresh reading with every window below the cap.
        func auto(_ session: Double, _ weekly: Double, age: Double = 60, weeklyReset: Date? = nil) -> LimitSnapshot {
            LimitSnapshot(provider: .claude, plan: nil,
                          session: LimitWindow(kind: .session, usedPercent: session, durationMinutes: 300, resetsAt: now.addingTimeInterval(3600)),
                          weekly: LimitWindow(kind: .weekly, usedPercent: weekly, durationMinutes: 10080, resetsAt: weeklyReset ?? now.addingTimeInterval(86400)),
                          fetchedAt: now.addingTimeInterval(-age), source: "t")
        }
        expect(ClaudeAutoContinue.allowsWork(auto(1, 10), now: now), "a fresh reading with room allows work")
        expect(!ClaudeAutoContinue.allowsWork(auto(99, 10), now: now), "a spent five-hour window blocks")
        expect(!ClaudeAutoContinue.allowsWork(auto(1, 99), now: now), "a spent weekly window blocks")
        expect(!ClaudeAutoContinue.allowsWork(auto(1, 10, age: 30 * 60), now: now), "an old reading does not")
        expect(!ClaudeAutoContinue.allowsWork(nil, now: now), "no reading does not")
        expect(ClaudeAutoContinue.allowsWork(auto(1, 99, weeklyReset: now.addingTimeInterval(-60)), now: now),
               "a weekly window past its reset is full again")

        // /usage: only the last drawing counts.
        let screen = "Current session 98% used Resets 9:30pm Current week (all models) 77% used Resets Oct 23 at 7pm Refreshing… "
            + "Current session 3% used Resets 12:50am Current week (all models) 1% used Resets Oct 23 at 7pm"
        let latest = ClaudeUsageCLI.latestScreen(screen)
        expect(!latest.contains("98%"), "the cached drawing is skipped")
        expect(ClaudeUsageCLI.parse(latest, now: now)?.session?.usedPercent == 3, "the fresh drawing is read")

        // /usage: a redraw that lost the session line (the screen grew) still gives both windows,
        // and the cached numbers before "Refreshing…" are never used.
        let stream = "Current session 98% used Resets 9:30pm Current week (all models) 77% used Resets Oct 23 at 7pm Refreshing… "
            + "Current session 4% used Resets 12:50am Current week (all models) 2% used Resets Oct 23 at 7pm What's contributing… "
        let redraw = "Current week (all models) 2% used Resets Oct 23 at 7pm Current week (Fable) 0% used Resets Oct 23 at 7pm"
        let both = ClaudeUsageCLI.read(stream: stream + redraw, redraw: redraw, now: now)
        expect(both?.session?.usedPercent == 4, "session found outside the redraw")
        expect(both?.weekly?.usedPercent == 2, "week from the redraw")
        expect(both?.extras.count == 1, "per-model week kept")
        let cachedOnly = ClaudeUsageCLI.read(stream: "Current session 98% used Resets 9:30pm Refreshing… Current week (all models) 2% used Resets Oct 23 at 7pm",
                                             redraw: nil, now: now)
        expect(cachedOnly?.session == nil && cachedOnly?.weekly?.usedPercent == 2, "cached session is not used")

        // Russian plural forms.
        expect(AppLanguage.pluralIndex(1, forms: 3) == 0 && AppLanguage.pluralIndex(3, forms: 3) == 1
               && AppLanguage.pluralIndex(11, forms: 3) == 2 && AppLanguage.pluralIndex(22, forms: 3) == 1, "plural forms")
        expect(Format.word(5, "a|b|c") == "c" || Format.word(5, "a|b|c") == "b", "plural words")
        // Codex's whole percents: "100" alone is not a spent limit.
        expect(!AgentActivity.isSpent(.codex, remaining: 0, limitReached: false, stopped: false), "codex 100% alone is not spent")
        expect(AgentActivity.isSpent(.codex, remaining: 0, limitReached: true, stopped: false), "codex says reached")
        expect(AgentActivity.isSpent(.codex, remaining: 0, limitReached: false, stopped: true), "codex turn stopped by the limit")
        expect(AgentActivity.isSpent(.claude, remaining: 0, limitReached: false, stopped: false), "claude at 100% is spent")
        // Setup reads the tools' answers, and only those.
        expect(AgentSetup.claudeSignedIn(#"{"loggedIn": true, "authMethod": "claude.ai"}"#) == true, "claude signed in")
        expect(AgentSetup.claudeSignedIn(#"{"loggedIn": false}"#) == false, "claude signed out")
        expect(AgentSetup.claudeSignedIn("unknown command") == nil, "claude too old to say")
        expect(AgentSetup.signInLink(in: "If your browser did not open, visit: https://a.example/x?y=1\nPaste") == URL(string: "https://a.example/x?y=1"), "sign-in link")
        expect(AgentSetup.signInLink(in: "visit: https://a.example/partial") == nil, "a link still arriving is not used")
        expect(SetupGuide.silentInstall(.codex).contains("CODEX_NON_INTERACTIVE=1"), "Codex installer asks nothing")
        // Cards lead to the place they are about.
        expect(ToastCatalog.taskWaiting(.claude, title: "T", until: nil).actions == [.open(.tasks)], "a waiting task opens Tasks") // l10n:skip
        expect(ToastCatalog.taskAttention(.claude, title: "T", reason: "").actions == [.openClaude], "a Claude task opens Claude") // l10n:skip
        expect(ToastCatalog.taskAttention(.codex, title: "T", reason: "").actions == [.openCodex], "a Codex task opens Codex") // l10n:skip
        // iPhone: what goes where, and nothing private reaches the Live Activity.
        let request = ToastContent(key: "req-x", kind: .attention, provider: .codex, title: "Секретный чат", body: "rm -rf build", // l10n:skip
                                   choices: [RequestChoice(id: "allow", title: "OK", role: .allow), // l10n:skip
                                             RequestChoice(id: "open", title: "Open", role: .open)]) // l10n:skip
        let requestCard = PhoneLink.card(request)
        expect(requestCard.actions.map(\.id) == ["choice:allow"], "phone gets the answers, not 'open'")
        expect(requestCard.actions.first?.auth == true, "allowing needs Face ID")
        let item = PhoneLink.liveItem(requestCard)
        expect(!item.title.contains("Секретный") && !item.title.contains("rm -rf"), "Lock Screen title is general") // l10n:skip
        expect(PhoneLink.shared.delivery(request, card: requestCard, away: false) == .none, "a request stays off the phone while at the Mac")
        let finished = ToastContent(key: "finished-x", kind: .finished, provider: .codex, title: "T", body: "B",
                                    actions: [.openCodexThread("t1")])
        let finishedCard = PhoneLink.card(finished)
        expect(finishedCard.actions.map(\.id) == ["reply"] && finishedCard.actions.first?.input == true, "a finished chat can be answered")
        expect(PhoneLink.shared.delivery(finished, card: finishedCard, away: false) == .none, "nothing on the phone while at the Mac")
        expect(PhoneLink.shared.delivery(finished, card: finishedCard, away: true) != .none, "finished reaches the phone when away")
        // As Insights posts it (kind .attention): still a number, not a call to act.
        let pace = ToastContent(key: "pace-codex", kind: .attention, provider: .codex, title: "T", body: "B")
        expect(PhoneLink.shared.delivery(pace, card: PhoneLink.card(pace), away: true) == .none, "numbers stay off the phone")
        let opener = AgentActivity.Opener.codexThread("t2")
        expect(PhoneLink.actionID(.continueAfterReset(opener)) == "afterReset", "continue after reset is a phone button")
        expect(PhoneLink.actionID(.remindBeforeReset(.codex, Date())) == nil, "reminders stay on the Mac")

        let list = ClaudeChatList.shared
        let wasWaiting = list.cardsWaiting
        list.cardsWaiting = true
        list.cardClosed("finished-claude:x")
        expect(list.cardsWaiting, "other cards leave the Continue offer open")
        list.cardClosed("claude-chat-x")
        expect(!list.cardsWaiting, "a closed Continue card is not offered again")
        list.cardsWaiting = wasWaiting
        let link = PhoneLink.shared
        let t0 = Date().addingTimeInterval(-600)
        let first = link.work([LinkAgent(provider: "codex", working: true, since: t0)], now: Date())
        let pause = link.work([LinkAgent(provider: "codex", working: true, since: Date())], now: Date().addingTimeInterval(20))
        expect(first?.first?.since == t0.timeIntervalSince1970 && pause?.first?.since == t0.timeIntervalSince1970,
               "a short pause between turns keeps one stretch of work")
        expect(link.work([], now: Date().addingTimeInterval(120)) == nil, "work that stopped leaves the Live Activity")
        let long = ToastContent(key: "finished-codex:x", kind: .finished, provider: .codex, title: "T", body: String(repeating: "ж", count: 5000)) // l10n:skip
        // A turn still open in a Codex session file is found with its own start time; an ended one is not.
        let openNow = Date()
        let open = "{\"timestamp\":\"2026-10-26T05:00:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"}}\n" // l10n:skip
        expect(CodexFinishWatcher.openTurnStart(open, fallback: openNow) == Date(timeIntervalSince1970: 1_792_990_800), "an open Codex turn keeps its real start time")
        expect(CodexFinishWatcher.openTurnStart(open + "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n", fallback: openNow) == nil, "an ended Codex turn is not picked up") // l10n:skip
        // The session reader only moves over whole lines; a partial tail waits for the next look.
        let twoLines = Data("a\nb\n".utf8), partialLine = Data("a\nb".utf8)
        expect(CodexFinishWatcher.wholeLines(twoLines, limit: 8).consumed == 4, "whole lines are consumed")
        expect(CodexFinishWatcher.wholeLines(partialLine, limit: 8).consumed == 2, "a partial last line is left alone")
        expect(CodexFinishWatcher.wholeLines(Data("abc".utf8), limit: 3) == (3, true), "an oversized line is skipped")
        expect(CodexFinishWatcher.wholeLines(Data(), limit: 8).consumed == 0, "an empty read consumes nothing")
        // Codex's questions asked while it works: found in the session file, answered like the app does.
        let askLine: [String: Any] = ["timestamp": "2026-10-26T05:01:59.181Z", "type": "event_msg", "payload": ["type": "item_completed", // l10n:skip
            "item": ["type": "AgentMessage", "id": "call_054e5eb10ca6", "delivery": "async", // l10n:skip
                     "questions": [["title": "SSH or web?", "options": ["SSH", "Web"]]]]]] // l10n:skip
        let asked = CodexQuestions.asked(in: askLine)
        expect(asked?.call == "call_054e5eb10ca6" && asked?.questions.first?.options == ["SSH", "Web"], "a Codex question with answers is read from its session file") // l10n:skip
        let plaque = [CodexQuestions.Question(title: "A?", options: ["x", "y"]), CodexQuestions.Question(title: "B?", options: [])] // l10n:skip
        let picked = RequestAnswer.decode(RequestAnswer.encode([.option(1), .text("my words")])) // l10n:skip
        expect(picked == [.option(1), .text("my words")] && CodexQuestions.texts(plaque, picked ?? []) == ["y", "my words"], // l10n:skip
               "a card with several questions sends all answers together, typed ones included")
        if let asked {
            let text = CodexQuestions.reply(call: asked.call, questions: asked.questions, answers: CodexQuestions.texts(asked.questions, [.option(1)]) ?? [])
            expect(text.hasPrefix("<send_user_message_question_reply>\n[") && text.contains("\"answer\":\"Web\"") // l10n:skip
                   && text.contains("request_user_input_async") && CodexQuestions.answered(in: text) == [asked.call], // l10n:skip
                   "the answer to a Codex question is the app's own reply, and it is recognised as answered")
        }
        expect(PhoneLink.card(long).body.count <= PhoneLink.maxBody, "a card fits inside the push, so the phone needs no network to show it")
        return failures
    }
}
