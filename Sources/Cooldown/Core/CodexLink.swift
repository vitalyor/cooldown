import Foundation

/// The state of Cooldown's connection to the Codex app, and what to do when it breaks: the app
/// answers "no window has it" for every conversation (its local socket restarted and the windows
/// did not come back). Nothing in Cooldown can mend that from outside except restarting the app,
/// so it says so once, offers the button (also on the phone) and, if allowed, restarts it by
/// itself as soon as nothing is going on in it.
@MainActor
enum CodexLink {
    private static var noted = Date.distantPast
    static var isBroken: Bool { noted != .distantPast }

    static func broken() {
        guard Date().timeIntervalSince(noted) > 30 * 60 else { return }
        noted = Date()
        AgentActivity.trace("codex link broken: Codex answers for no conversation")
        let auto = Settings.autoRestartAgents
        ToastController.shared.show(ToastContent(
            key: "codex-link", kind: .attention, provider: .codex,
            title: L("Codex перестал отвечать Cooldown"),
            body: auto ? L("Вопросы и автопродолжение не работают, пока его не перезапустить. Cooldown сделает это сам, как только в Codex ничего не будет идти.")
                       : L("Вопросы и автопродолжение не работают, пока его не перезапустить."),
            actions: [.restartAgent(.codex), .openCodex], life: .sticky))
        if auto {
            Task { _ = await AgentRestart.shared.restart(.codex, whenFree: true, from: L("сам: связь прервалась")) }
        }
    }

    /// Answers go through again: the card is no longer needed.
    static func works() {
        guard noted != .distantPast else { return }
        noted = .distantPast
        ToastController.shared.dismiss(key: "codex-link")
    }
}
