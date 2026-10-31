import Darwin
import CooldownLink
import Foundation
import XCTest
@testable import Cooldown

/// Checks of pure rules that used to live only in `--selftest`. The XCTest target can import the
/// executable target on this toolchain, so these run with `swift test` and in CI as well.
final class CodexRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func bucket(_ used: Double, resets: Double = 1_800_003_600,
                        change: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        var value: [String: Any] = [
            "limitId": "codex",
            "primary": ["usedPercent": used, "resetsAt": resets, "windowDurationMins": 300],
            "secondary": ["usedPercent": 10, "resetsAt": 1_800_500_000, "windowDurationMins": 10080],
            "rateLimitReachedType": NSNull(), "spendControlReached": false, "individualLimit": NSNull(),
        ]
        change(&value)
        return ["rateLimits": value, "rateLimitsByLimitId": ["codex": value]]
    }

    func testOrdinaryUsageAllowedIsRequired() {
        XCTAssertEqual(ResumeRules.judgeLimits(bucket(40), now: now), .available)
        XCTAssertEqual(ResumeRules.judgeLimits(bucket(40) { $0["ordinaryUsageAllowed"] = true }, now: now), .available)
        XCTAssertEqual(ResumeRules.judgeLimits(bucket(40) { $0["ordinaryUsageAllowed"] = false }, now: now),
                       .notYet(Date(timeIntervalSince1970: 1_800_003_605)))
        XCTAssertEqual(ResumeRules.judgeLimits(bucket(40) { $0["ordinaryUsageAllowed"] = NSNull() }, now: now),
                       .stale(now.addingTimeInterval(60)))
    }

    func testFullWindowWaitsForItsReset() {
        XCTAssertEqual(ResumeRules.judgeLimits(bucket(100), now: now),
                       .notYet(Date(timeIntervalSince1970: 1_800_003_605)))
        XCTAssertEqual(ResumeRules.judgeLimits(bucket(100, resets: 1_799_999_990), now: now),
                       .notYet(now.addingTimeInterval(60)))
    }

    func testReplyOnlyToIdleOrInterrupted() {
        let idle: [String: Any] = [
            "hostId": "local", "ephemeral": false, "resumeState": "resumed", "cwd": "/tmp",
            "requests": [Any](), "threadGoal": NSNull(), "queuedFollowUps": NSNull(),
            "threadRuntimeStatus": ["type": "idle"],
            "turnHistory": ["kind": "canonical", "history": [
                "islands": [["entries": [["key": "k", "value": "k"]], "newerBoundary": ["status": "exhausted"]]],
                "entitiesByKey": ["k": ["turnId": "t", "status": "completed"]],
            ]],
        ]
        XCTAssertTrue(ResumeRules.canReply(idle, thread: "01a1301d-cd1b-70f3-b49a-501ba6c9b04d"))
        var running = idle
        running["threadRuntimeStatus"] = ["type": "active", "activeFlags": [Any]()]
        XCTAssertFalse(ResumeRules.canReply(running, thread: "01a1301d-cd1b-70f3-b49a-501ba6c9b04d"))
        var interrupted = idle
        interrupted["turnHistory"] = ["kind": "canonical", "history": [
            "islands": [["entries": [["key": "k", "value": "k"]], "newerBoundary": ["status": "exhausted"]]],
            "entitiesByKey": ["k": ["turnId": "t", "status": "interrupted"]],
        ]]
        XCTAssertTrue(ResumeRules.canReply(interrupted, thread: "01a1301d-cd1b-70f3-b49a-501ba6c9b04d"))
        var loading = idle
        loading["resumeState"] = "loading"
        XCTAssertFalse(ResumeRules.canReply(loading, thread: "01a1301d-cd1b-70f3-b49a-501ba6c9b04d"))
        var unknown = idle
        unknown["threadRuntimeStatus"] = nil
        XCTAssertFalse(ResumeRules.canReply(unknown, thread: "01a1301d-cd1b-70f3-b49a-501ba6c9b04d"))
    }

    func testWholeLinesLeavesPartialTail() {
        XCTAssertEqual(CodexFinishWatcher.wholeLines(Data("a\nb\n".utf8), limit: 8).consumed, 4)
        XCTAssertEqual(CodexFinishWatcher.wholeLines(Data("a\nb".utf8), limit: 8).consumed, 2)
        let oversized = CodexFinishWatcher.wholeLines(Data("abc".utf8), limit: 3)
        XCTAssertEqual(oversized.consumed, 3)
        XCTAssertTrue(oversized.oversized)
        XCTAssertEqual(CodexFinishWatcher.wholeLines(Data(), limit: 8).consumed, 0)
    }
}

final class ClaudeRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(_ used: Double, at minutesAgo: Double, reset: Date) -> LimitSnapshot {
        LimitSnapshot(provider: .claude, plan: nil,
                      session: LimitWindow(kind: .session, usedPercent: used, durationMinutes: 300, resetsAt: reset),
                      weekly: nil, fetchedAt: now.addingTimeInterval(-minutesAgo * 60), source: "test")
    }

    func testMergeUsesFreshReadings() {
        let reset = now.addingTimeInterval(3600)
        XCTAssertEqual(ClaudeLimits.merge([reading(98, at: 8, reset: reset), reading(3, at: 0, reset: reset)], now: now)?.session?.usedPercent, 3)
        XCTAssertEqual(ClaudeLimits.merge([reading(40, at: 1, reset: reset), reading(38, at: 0, reset: reset)], now: now)?.session?.usedPercent, 40)
        XCTAssertNil(ClaudeLimits.merge([reading(40, at: 90, reset: reset)], now: now))
    }

    @MainActor
    func testAutoContinueNeedsFreshUnspentWindow() {
        func snapshot(_ session: Double, _ weekly: Double, age: Double = 60,
                      weeklyReset: Date? = nil) -> LimitSnapshot {
            LimitSnapshot(provider: .claude, plan: nil,
                          session: LimitWindow(kind: .session, usedPercent: session, durationMinutes: 300,
                                               resetsAt: now.addingTimeInterval(3600)),
                          weekly: LimitWindow(kind: .weekly, usedPercent: weekly, durationMinutes: 10080,
                                              resetsAt: weeklyReset ?? now.addingTimeInterval(86400)),
                          fetchedAt: now.addingTimeInterval(-age), source: "test")
        }
        XCTAssertTrue(ClaudeAutoContinue.allowsWork(snapshot(1, 10), now: now))
        XCTAssertFalse(ClaudeAutoContinue.allowsWork(snapshot(99, 10), now: now))
        XCTAssertFalse(ClaudeAutoContinue.allowsWork(snapshot(1, 99), now: now))
        XCTAssertFalse(ClaudeAutoContinue.allowsWork(snapshot(1, 10, age: 30 * 60), now: now))
        XCTAssertFalse(ClaudeAutoContinue.allowsWork(nil, now: now))
        XCTAssertTrue(ClaudeAutoContinue.allowsWork(snapshot(1, 99, weeklyReset: now.addingTimeInterval(-60)), now: now))
    }
}

final class LocalRulesTests: XCTestCase {
    func testStatsHasNoWebChatsTab() {
        XCTAssertEqual(StatsTab.options(for: .claude), [.limits, .tokens, .projects])
        XCTAssertEqual(StatsTab.options(for: .codex), [.limits, .tokens, .projects])
    }
}

final class MCPConfigTests: XCTestCase {
    func testInstallAndRemoveKeepOtherServers() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cooldown-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = folder.appendingPathComponent("claude_desktop_config.json")
        let original: [String: Any] = ["mcpServers": ["other": ["command": "/bin/echo", "args": ["hi"]]]]
        try JSONSerialization.data(withJSONObject: original, options: [.prettyPrinted]).write(to: config)
        setenv("COOLDOWN_CLAUDE_CONFIG", config.path, 1)
        defer { unsetenv("COOLDOWN_CLAUDE_CONFIG") }

        try CooldownMCP.install()
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
        var servers = root?["mcpServers"] as? [String: Any]
        XCTAssertNotNil(servers?["cooldown"])
        XCTAssertNotNil(servers?["other"])

        try CooldownMCP.uninstall()
        root = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
        servers = root?["mcpServers"] as? [String: Any]
        XCTAssertNil(servers?["cooldown"])
        XCTAssertNotNil(servers?["other"])
    }
}

final class SmallRulesTests: XCTestCase {
    func testRequestAnswerRoundTrip() {
        let answers: [RequestAnswer] = [.option(2), .text("my words")] // l10n:skip
        let encoded = RequestAnswer.encode(answers)
        XCTAssertEqual(RequestAnswer.decode(encoded), answers)
        XCTAssertNil(RequestAnswer(choice: "not-an-answer"))
    }

    @MainActor
    func testPhoneDoesNotInterruptWhileAtTheMac() {
        let card = LinkCard(key: "q", kind: "attention", provider: "codex", title: "Q", body: "",
                            actions: [LinkAction(id: "choice:allow", title: "Allow", style: .primary)])
        let content = ToastContent(key: "q", kind: .attention, provider: .codex, title: "Q", body: "")
        XCTAssertEqual(PhoneLink.shared.delivery(content, card: card, away: false), .none)
    }

    @MainActor
    func testPhoneCardKeepsTextInputRole() {
        let content = ToastContent(key: "q", kind: .attention, provider: .codex, title: "Q", body: "",
                                   choices: [RequestChoice(id: "input", title: "Answer", role: .input)])
        let card = PhoneLink.card(content)
        XCTAssertEqual(card.actions.first(where: { $0.id == "choice:input" })?.input, true)
    }

    @MainActor
    func testFailureCardIsStickyAndWarning() {
        let card = ToastCatalog.failure("Title", "Body")
        XCTAssertEqual(card.kind, .warning)
        XCTAssertEqual(card.life, .sticky)
        XCTAssertEqual(card.title, "Title")
    }

    func testRandomBytesHaveRequestedLength() {
        XCTAssertEqual(LinkCrypto.random(32).count, 32)
        XCTAssertNotEqual(LinkCrypto.random(16), LinkCrypto.random(16))
    }
}

final class ClaudeTaskRecoveryTests: XCTestCase {
    func testManualContinuationLeavesNothingToResume() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-task-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("session.jsonl")
        let stop: [String: Any] = [
            "type": "assistant", "uuid": "stop-1", "timestamp": "2026-10-27T08:00:00.000Z",
            "message": ["model": "<synthetic>", "content": [["type": "text", "text": "You hit your limit. Resets at 3pm."]]],
        ]
        let user: [String: Any] = ["type": "user", "uuid": "user-2", "timestamp": "2026-10-27T08:01:00.000Z",
                                   "message": ["content": "continue"]]
        let answer: [String: Any] = ["type": "assistant", "uuid": "answer-2", "timestamp": "2026-10-27T08:02:00.000Z",
                                     "message": ["model": "claude", "content": [["type": "text", "text": "done"]], "stop_reason": "end_turn"]]
        func write(_ value: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: value)
            if FileManager.default.fileExists(atPath: file.path) {
                let handle = try FileHandle(forWritingTo: file); handle.seekToEndOfFile(); handle.write(data); handle.write(Data("\n".utf8)); try handle.close()
            } else { try data.write(to: file) }
        }
        try write(stop)
        if case .limited = ClaudeTaskManager.state(of: file, modified: Date().addingTimeInterval(-120)) {} else {
            return XCTFail("the synthetic limit stop was not recognized")
        }
        try write(user)
        try write(answer)
        if case .idle = ClaudeTaskManager.state(of: file, modified: Date().addingTimeInterval(-120)) {} else {
            XCTFail("a manually continued session must not be resumed again")
        }
    }
}

final class StartupRecoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCodexIsOpenedOnlyOnceAndOnlyAfterTheLimit() {
        XCTAssertTrue(StartupRecovery.shouldOpenCodex(isRunning: false, spentUntil: nil, lastAsked: nil, now: now))
        XCTAssertFalse(StartupRecovery.shouldOpenCodex(isRunning: true, spentUntil: nil, lastAsked: nil, now: now))
        XCTAssertFalse(StartupRecovery.shouldOpenCodex(isRunning: false, spentUntil: now.addingTimeInterval(3600), lastAsked: nil, now: now))
        XCTAssertFalse(StartupRecovery.shouldOpenCodex(isRunning: false, spentUntil: nil, lastAsked: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(StartupRecovery.shouldOpenCodex(isRunning: false, spentUntil: nil, lastAsked: now.addingTimeInterval(-121), now: now))
    }
}

final class ClaudeSendSafetyTests: XCTestCase {
    @MainActor
    func testTypingRequiresReadableEmptyComposer() async throws {
        XCTAssertThrowsError(try ClaudeSender.requireEmptyInput(nil))
        XCTAssertThrowsError(try ClaudeSender.requireEmptyInput("unfinished draft"))
        XCTAssertNoThrow(try ClaudeSender.requireEmptyInput(""))
        XCTAssertNoThrow(try ClaudeSender.requireEmptyInput(" \n\t"))
    }

    @MainActor
    func testReturnRequiresTheWholeMessage() async throws {
        let message = "Continue this task 👋\nKeep the draft safe."
        XCTAssertNoThrow(try ClaudeSender.requireTypedInput(message, message: message))
        for text in [nil, "", "Continue", message + " extra"] as [String?] {
            XCTAssertThrowsError(try ClaudeSender.requireTypedInput(text, message: message))
        }
    }

    @MainActor
    func testChangedTextDoesNotConfirmSendUntilComposerClears() async throws {
        var reads = 0
        try await ClaudeSender.confirmSent(readInput: {
            reads += 1
            return reads == 1 ? "partial message" : ""
        }, isFront: { true })
        XCTAssertEqual(reads, 2)
    }

    @MainActor
    func testUnchangedComposerTimesOutWithoutSuccess() async {
        do {
            try await ClaudeSender.confirmSent(readInput: { "still in composer" }, isFront: { true })
            XCTFail("a nonempty composer must not confirm a send")
        } catch {
            guard case ClaudeSender.SendError.notConfirmed = error else { return XCTFail("unexpected error: \(error)") }
        }
    }

    @MainActor
    func testUnreadableComposerOrLostFocusLeavesSendUnconfirmed() async {
        for front in [true, false] {
            do {
                try await ClaudeSender.confirmSent(readInput: { nil }, isFront: { front })
                XCTFail("an unknown result must not confirm a send")
            } catch {
                guard case ClaudeSender.SendError.notConfirmed = error else { return XCTFail("unexpected error: \(error)") }
            }
        }
    }
}

final class ClaudeAttemptPersistenceTests: XCTestCase {
    @MainActor
    func testAttemptSurvivesReloadAndFailedWriteDoesNotChangeMemory() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cooldown-attempt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("chats.json")
        let known = folder.appendingPathComponent("known.json")
        let chat = ClaudeChat(id: "test-chat", title: "Test")
        let initial = [ClaudeChatList.Entry(chat: chat)]
        try JSONEncoder().encode(initial).write(to: file)
        let reset = Date()
        let list = ClaudeChatList(url: file, knownURL: known)
        try list.markAutoAttempt(chat, reset: reset)

        let reloaded = ClaudeChatList(url: file, knownURL: known)
        XCTAssertEqual(reloaded.entries.first?.lastOutcome, "trying")
        XCTAssertTrue(reloaded.autoTried(chat, reset: reset))

        let before = list.entries
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try list.markAutoAttempt(chat, reset: reset.addingTimeInterval(3600)))
        XCTAssertEqual(list.entries, before)
        XCTAssertThrowsError(try list.markAutoAttempt(ClaudeChat(id: "removed", title: "Removed"), reset: reset))
    }
}

final class ScheduledPersistenceTests: XCTestCase {
    @MainActor
    func testEveryActiveTaskSurvivesBeyondHistoryLimit() async throws {
        var tasks: [ScheduledTask] = []
        for index in 0..<45 {
            tasks.append(ScheduledTask(prompt: "waiting \(index)", folder: "/tmp", canEdit: false))
            var ended = ScheduledTask(prompt: "ended \(index)", folder: "/tmp", canEdit: false)
            ended.state = [.done, .failed, .cancelled][index % 3]
            tasks.append(ended)
        }
        var running = ScheduledTask(prompt: "running", folder: "/tmp", canEdit: false)
        running.state = .running
        tasks.append(running)

        let saved = ScheduledRunner.savedTasks(tasks)
        let restored = try JSONDecoder().decode([ScheduledTask].self, from: JSONEncoder().encode(saved))
        let active = tasks.filter { $0.state == .waiting || $0.state == .running }
        XCTAssertEqual(restored.filter { $0.state == .waiting || $0.state == .running }, active)
        XCTAssertEqual(restored.filter { $0.state != .waiting && $0.state != .running },
                       Array(tasks.filter { $0.state != .waiting && $0.state != .running }.prefix(30)))
        XCTAssertEqual(restored.count, active.count + 30)
        let retained = Set(restored.map(\.id))
        XCTAssertEqual(restored, tasks.filter { retained.contains($0.id) })
        XCTAssertTrue(ScheduledRunner.savedTasks([]).isEmpty)
    }
}

final class HookGroupPreservationTests: XCTestCase {
    func testUpdateAndRemovalPreserveOtherHandlersAndGroupSettings() throws {
        let foreign: [String: Any] = ["type": "command", "command": "/bin/echo other", "timeout": 17]
        let ours: [String: Any] = ["type": "command", "command": "/old/cooldown-hook claude"]
        let group: [String: Any] = ["matcher": "Bash", "custom": true, "hooks": [foreign, ours, foreign]]
        let replacement: [String: Any] = ["type": "command", "command": "/new/cooldown-hook claude"]
        let updated = try XCTUnwrap(AgentHooks.updatedGroup(group, handler: replacement))
        XCTAssertEqual(updated["matcher"] as? String, "Bash")
        XCTAssertEqual(updated["custom"] as? Bool, true)
        XCTAssertEqual(JSON.canonical(updated["hooks"]!), JSON.canonical([foreign, replacement, foreign]))
        let removed = try XCTUnwrap(AgentHooks.updatedGroup(group, handler: nil))
        XCTAssertEqual(JSON.canonical(removed["hooks"]!), JSON.canonical([foreign, foreign]))
        XCTAssertEqual(AgentHooks.foreignPermissionHook(in: [group]), "/bin/echo other")
        XCTAssertNil(AgentHooks.updatedGroup(["hooks": [ours]], handler: nil))
        XCTAssertEqual(JSON.canonical(AgentHooks.updatedGroup(["hooks": [foreign]], handler: nil)!), JSON.canonical(["hooks": [foreign]]))
    }
}

final class AutoResumeStopPersistenceTests: XCTestCase {
    func testStopReportsUnreadableStateAndPersistsSuccessfulStop() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cooldown-stop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ResumeStore(folder: folder, legacy: nil)
        let id = "01a1301d-cd1b-70f3-b49a-501ba6c9b04d"
        try store.update { data in
            data.watches.append(ResumeData.Watch(threadId: id, enabled: true, maxResumes: 2,
                                                 status: "watching", reason: "test", updated: Date()))
        }
        let file = folder.appendingPathComponent("state.json")
        let saved = try Data(contentsOf: file)
        try Data("{broken".utf8).write(to: file)
        let resume = AutoResume(store: store)
        do {
            try await resume.stop(id)
            XCTFail("a failed state write must not be reported as a successful stop")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: file), Data("{broken".utf8))
        try saved.write(to: file)
        try await resume.stop(id)
        XCTAssertEqual(try store.load().watch(id)?.enabled, false)
        XCTAssertEqual(try store.load().watch(id)?.status, "paused")
    }
}

final class ClaudeHookResponseTests: XCTestCase {
    @MainActor
    func testFailedResponseWriteThrowsAndDoesNotOverwriteFirstAnswer() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cooldown-response-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let response = folder.appendingPathComponent("test.res")
        try ClaudeAsks.writeResponse(Data("first".utf8), to: response)
        XCTAssertEqual(try Data(contentsOf: response), Data("first".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: response.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((mode?.intValue ?? 0) & 0o777, 0o600)
        XCTAssertThrowsError(try ClaudeAsks.writeResponse(Data("second".utf8), to: response))
        XCTAssertEqual(try Data(contentsOf: response), Data("first".utf8))
        XCTAssertThrowsError(try ClaudeAsks.writeResponse(Data(), to: folder.appendingPathComponent("missing/answer.res")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["test.res"])
    }
}

final class LiveActivityPrivacyTests: XCTestCase {
    @MainActor
    func testButtonLabelsNeverCopyAgentProvidedText() async throws {
        let secret = "private client name and project"
        let permission = LinkCard(key: "private-card", kind: "attention", provider: "codex", title: secret, body: secret,
                                  actions: [LinkAction(id: "choice:accept", title: secret, style: .primary, auth: true)])
        let live = PhoneLink.liveItem(permission)
        XCTAssertEqual(live.buttons.first?.title, String(L("Разрешить").prefix(26)))
        XCTAssertEqual(live.buttons.first?.auth, true)
        let serialized = String(decoding: try LinkJSON.encoder.encode(live), as: UTF8.self)
        XCTAssertFalse(serialized.contains(secret))
        let question = LinkCard(key: "question", kind: "attention", provider: "codex", title: secret, body: secret,
                                actions: [LinkAction(id: "choice:option:0", title: secret)])
        XCTAssertNil(PhoneLink.liveButtons(question))
        let content = ToastContent(key: "question", kind: .attention, provider: .codex, title: secret, body: secret)
        guard case .alert = PhoneLink.shared.delivery(content, card: question, away: true) else {
            return XCTFail("custom choices need an encrypted notification, not a clear-text Live Activity")
        }
    }
}

final class RequestAnswerConcurrencyTests: XCTestCase {
    @MainActor
    func testTwoPressesStartOnlyOneResponder() async {
        let previous = UserDefaults.standard.object(forKey: SettingsKey.notifyAttention)
        UserDefaults.standard.set(false, forKey: SettingsKey.notifyAttention)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: SettingsKey.notifyAttention) }
            else { UserDefaults.standard.removeObject(forKey: SettingsKey.notifyAttention) }
        }
        let center = RequestCenter()
        let key = "test-concurrent-answer"
        let choice = RequestChoice(id: "allow", title: "Allow", role: .allow)
        let request = AgentRequest(key: key, provider: .codex, chat: "Test", headline: "Test", choices: [choice], appBundleIDs: [])
        var started = 0
        var waiting: CheckedContinuation<Void, Never>?
        center.post(request, open: {}, respond: { _ in
            started += 1
            await withCheckedContinuation { waiting = $0 }
        })
        center.answer(key, choice)
        center.answer(key, choice)
        for _ in 0..<100 where waiting == nil { await Task.yield() }
        XCTAssertEqual(started, 1)
        waiting?.resume()
        for _ in 0..<100 where center.isPending(key) { await Task.yield() }
        XCTAssertFalse(center.isPending(key))
    }
}

final class CodexFallbackNotificationTests: XCTestCase {
    @MainActor
    func testMissingLiveStateDoesNotDelayPermissionCard() async {
        XCTAssertEqual(AgentActivity.permissionDelay(.codex, openRequests: nil), 0)
        XCTAssertEqual(AgentActivity.permissionDelay(.codex, openRequests: 1), 20)
        XCTAssertEqual(AgentActivity.permissionDelay(.codex, openRequests: 0), 20)
        XCTAssertEqual(AgentActivity.permissionDelay(.claude, openRequests: nil), 20)
    }
}

final class ClaudeUsageSignalTests: XCTestCase {
    func testTurnFinishedSignalBelongsToUsageActor() async {
        let usage = ClaudeUsageCLI()
        let initial = await usage.turnFinished
        XCTAssertFalse(initial)
        await usage.noteTurnFinished()
        let finished = await usage.turnFinished
        XCTAssertTrue(finished)
    }
}

final class ScheduledWriteSafetyTests: XCTestCase {
    @MainActor
    func testFailedQueueEditsDoNotChangeInMemoryTasks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cooldown-queue-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("tasks.json")
        let task = ScheduledTask(prompt: "test", folder: "/tmp", canEdit: false)
        try ScheduledRunner.persist([task], to: file)
        let runner = ScheduledRunner(url: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try runner.add(prompt: "new", folder: "/tmp", canEdit: false))
        XCTAssertThrowsError(try runner.cancel(task.id))
        XCTAssertThrowsError(try runner.remove(task.id))
        XCTAssertEqual(runner.tasks, [task])
        try FileManager.default.removeItem(at: file)
        try runner.cancel(task.id)
        XCTAssertEqual(ScheduledRunner(url: file).tasks.first?.state, .cancelled)
    }

    @MainActor
    func testRecordedLaunchIsNotRequeuedAfterRestart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cooldown-launch-record-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("tasks.json")
        var task = ScheduledTask(prompt: "test", folder: "/tmp", canEdit: false)
        task.state = .running
        task.started = Date()
        try ScheduledRunner.persist([task], to: file)
        let recovered = ScheduledRunner(url: file)
        XCTAssertEqual(recovered.tasks.first?.state, .failed)
        XCTAssertTrue(recovered.waiting.isEmpty)
    }
}
