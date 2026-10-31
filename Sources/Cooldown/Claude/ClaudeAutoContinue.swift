import AppKit
import Foundation

/// Continues the chosen Claude Desktop chats when the plan window comes back. Claude has no local
/// API for an ordinary chat, so the message is typed into the chat the same way a person would:
/// through Accessibility, after checking the chat is open and the message box is empty. If that is
/// not possible the usual "Продолжить" card is shown instead; nothing is ever typed into a draft.
///
/// A reset is handled once. The attempt is written to `ClaudeChatList` before the first keystroke,
/// so a crash, a restart or a repeated limit check cannot send a second message for that reset.
@MainActor
final class ClaudeAutoContinue: ObservableObject {
    static let shared = ClaudeAutoContinue()

    @Published private(set) var running = false
    @Published private(set) var lastSummary: String?

    private var task: Task<Void, Never>?
    private var reset = Date()

    /// A fresh reading shows work can go on: no window is spent and Claude does not report a limit.
    static func allowsWork(_ snapshot: LimitSnapshot?, now: Date = Date()) -> Bool {
        guard let snapshot, now.timeIntervalSince(snapshot.fetchedAt) < 20 * 60, !snapshot.limitReached else { return false }
        let windows = [snapshot.session, snapshot.weekly].compactMap { $0 } + snapshot.extras
        guard !windows.isEmpty else { return false }
        return windows.allSatisfy { $0.isExpired(at: now) || $0.usedPercent < 98 }
    }

    /// An attempt was written but Cooldown quit before the result was. After a restart the outcome
    /// is unknown: show the chat's card and let the person check, instead of sending again.
    func recover() {
        var found = false
        for entry in ClaudeChatList.shared.entries where entry.lastOutcome == "trying" {
            ClaudeChatList.shared.markAutoResult(entry.chat, outcome: "uncertain")
            let card = ClaudeChatList.shared.card(for: entry)
            ToastController.shared.show(ToastContent(
                key: card.key, kind: card.kind, provider: card.provider,
                title: L("Проверьте «%@»", "\(entry.chat.title)"),
                body: L("Не удалось подтвердить, что Claude принял сообщение. Проверьте чат — повторно оно не отправится."),
                actions: [.openClaude], life: .sticky))
            found = true
        }
        if found { lastSummary = L("Есть чат с неподтверждённым продолжением. Проверьте его.") }
    }

    /// Called once the five-hour window has really started over. `reset` is the moment the app
    /// waited for; it identifies this reset in the stored entries.
    func limitReset(at reset: Date) {
        guard !AppModel.shared.demoActive, !ClaudeChatList.shared.entries.isEmpty else { return }
        guard Settings.claudeAutoContinue else {
            showCards()
            return
        }
        guard ClaudeSender.hasPermission else {
            lastSummary = L("Нужно разрешение «Универсальный доступ», чтобы продолжить чат автоматически.")
            showCards()
            return
        }
        self.reset = reset
        task?.cancel()
        task = Task { [weak self] in
            // Claude has just come back; let its own window settle before typing.
            try? await Task.sleep(for: .seconds(3))
            await self?.run()
        }
    }

    private func run() async {
        guard !running else { return }
        guard !ToastController.screenLocked else {
            // Typing into a locked Mac cannot work. Wait; the person does not need to press
            // anything when they come back.
            retry(after: 60)
            return
        }
        guard ToastController.idleSeconds > 30 else {
            // Do not pull Claude forward while the person is typing in another app.
            retry(after: 20)
            return
        }
        guard Settings.claudeAutoContinue else { showCards(); return }
        guard ClaudeSender.hasPermission else {
            lastSummary = L("Нужно разрешение «Универсальный доступ», чтобы продолжить чат автоматически.")
            showCards()
            return
        }

        var snapshot = AppModel.shared.claude.snapshot
        if snapshot == nil || Date().timeIntervalSince(snapshot!.fetchedAt) > 20 * 60 {
            _ = await AppModel.shared.claude.refreshLimits(force: true)
            snapshot = AppModel.shared.claude.snapshot
        }
        guard Self.allowsWork(snapshot) else {
            lastSummary = L("Лимит Claude ещё не восстановился полностью. Проверю позже.")
            retry(after: 10 * 60)
            return
        }

        let entries = ClaudeChatList.shared.entries
        let pending = entries.filter { !ClaudeChatList.shared.autoTried($0.chat, reset: reset) }
        guard !pending.isEmpty else {
            ClaudeChatList.shared.cardsWaiting = false
            return
        }

        running = true
        ClaudeChatList.shared.cardsWaiting = false
        defer {
            running = false
        }
        AgentActivity.trace("claude auto: \(pending.count) chat(s) after reset \(Int(reset.timeIntervalSince1970))")

        var sent = 0
        var failed = 0
        var continued: [String] = []
        for entry in pending {
            guard !Task.isCancelled else { return }
            guard Settings.claudeAutoContinue else { showCards(); return }
            guard ClaudeChatList.shared.entries.contains(where: { $0.id == entry.id }) else { continue }
            if ClaudeChatList.shared.autoTried(entry.chat, reset: reset) { continue }
            if ToastController.screenLocked { retry(after: 60); return }

            var attempted = false
            do {
                try ClaudeChatList.shared.markAutoAttempt(entry.chat, reset: reset)
                attempted = true
                ToastController.shared.dismiss(key: "claude-chat-\(entry.id)")
                try await ClaudeSender.continueChat(entry.chat, promptForPermission: false, onlyIfStopped: true)
                ClaudeChatList.shared.markAutoResult(entry.chat, outcome: "sent")
                sent += 1
                continued.append("«\(entry.chat.title)»")
            } catch {
                // Finished on its own before the limit: nothing to continue; off the list, with a word.
                if let send = error as? ClaudeSender.SendError, case .notStopped = send {
                    if attempted { ClaudeChatList.shared.markAutoResult(entry.chat, outcome: "finished") }
                    ClaudeChatList.shared.remove(entry)
                    AgentActivity.trace("claude auto \(entry.id): not stopped by the limit, left alone")
                    ToastController.shared.show(ToastContent(
                        key: "claude-chat-\(entry.id)", kind: .info, provider: .claude,
                        title: L("«%@» не нужно продолжать", "\(entry.chat.title)"),
                        body: error.localizedDescription,
                        actions: [.continueClaudeChat(entry.chat), .openClaude], life: .auto(20)))
                    continue
                }
                let outcome: String
                if let send = error as? ClaudeSender.SendError, case .notConfirmed = send { outcome = "uncertain" } else { outcome = "failed" }
                if attempted { ClaudeChatList.shared.markAutoResult(entry.chat, outcome: outcome) }
                failed += 1
                let card = ClaudeChatList.shared.card(for: entry)
                let uncertain = outcome == "uncertain"
                ToastController.shared.show(ToastContent(
                    key: card.key, kind: card.kind, provider: card.provider,
                    title: uncertain ? L("Проверьте «%@»", "\(entry.chat.title)") : L("Не удалось продолжить «%@»", "\(entry.chat.title)"),
                    body: uncertain ? error.localizedDescription : error.localizedDescription + "\n" + L("Нажмите «Продолжить», когда будете за Mac."),
                    actions: uncertain ? [.openClaude] : card.actions, life: .sticky))
                AgentActivity.trace("claude auto \(entry.id): \(outcome) — \(error.localizedDescription)")
                if let send = error as? ClaudeSender.SendError, case .noPermission = send {
                    showCards()
                    return
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }

        if !continued.isEmpty {
            // The reset card offered "Продолжить"; that is done now. Say so in the same card — shown
            // even though Claude is in front, since Cooldown itself just brought it there.
            ToastController.shared.reveal(ToastContent(
                key: "reset-claude", kind: .reset, provider: .claude, title: L("Лимит Claude восстановился"),
                body: L("Cooldown продолжил: %@", continued.joined(separator: ", ")),
                actions: [.openClaude], life: .auto(30)))
        }
        lastSummary = failed == 0
            ? L("Продолжено чатов: %@.", "\(sent)")
            : L("Продолжено: %@, не вышло: %@.", "\(sent)", "\(failed)")
        AgentActivity.trace("claude auto: \(lastSummary ?? "")")
    }

    private func retry(after delay: TimeInterval) {
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.run()
        }
    }

    /// No automatic way this time: the old cards, with the same phone delivery as before.
    private func showCards() {
        let list = ClaudeChatList.shared
        guard !list.entries.isEmpty else { return }
        list.cardsWaiting = true
        if ToastController.shared.canShow && !QuietHours.active {
            list.limitReset()
        } else {
            list.resetCards().forEach { PhoneLink.shared.forward($0) }
        }
    }
}
