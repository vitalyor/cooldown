import AppKit
import Foundation

/// Restarts Codex or Claude Desktop when their connection to Cooldown is broken and nobody can
/// reach the Mac — but never while something is going on in them. Quits them the normal way (as
/// ⌘Q does: they save what they need), never kills them, opens them again in the background and
/// checks that Cooldown sees them again.
@MainActor
final class AgentRestart {
    static let shared = AgentRestart()

    private var waiting: [ProviderID: Task<Void, Never>] = [:]
    private var running = Set<ProviderID>()

    /// What is going on in the app right now, in words; empty when it is safe to restart it.
    func busy(_ provider: ProviderID) async -> [String] {
        var reasons: [String] = []
        let sessions = AgentActivity.shared.sessions.values.filter { $0.provider == provider }
        for session in sessions {
            let name = session.title.isEmpty ? provider.displayName : "«\(session.title)»"
            reasons.append(session.state == .waiting ? L("%@ ждёт вашего ответа", name) : L("%@ сейчас работает", name))
        }
        let prefixes = provider == .codex ? ["codex|", "codexq|"] : ["claude"]
        if prefixes.contains(where: { RequestCenter.shared.hasPending(prefix: $0) }) {
            reasons.append(L("есть вопрос или запрос без ответа"))
        }
        switch provider {
        case .codex:
            // Something written to a conversation within the last minute: a turn is still going.
            if let recent = CodexThreadIndex.updated(since: Date().addingTimeInterval(-60)), recent.contains(where: \.isUser),
               sessions.isEmpty {
                reasons.append(L("Codex только что писал в диалог"))
            }
        case .claude:
            if ClaudeAutoContinue.shared.running { reasons.append(L("Cooldown продолжает чат")) }
        case .antigravity: break
            if await ClaudeSender.draftInOpenChat() == true { reasons.append(L("в поле ввода Claude есть неотправленный текст")) }
        }
        return reasons
    }

    /// Restarts now if nothing is going on; otherwise, with `whenFree`, as soon as it is (within
    /// two hours). Returns a sentence for the person.
    @discardableResult
    func restart(_ provider: ProviderID, whenFree: Bool, from origin: String) async -> String {
        guard isRunning(provider) else {
            open(provider)
            return L("%@ не был запущен — открываю.", provider.displayName)
        }
        let reasons = await busy(provider)
        if !reasons.isEmpty {
            guard whenFree else {
                return L("Не перезапускаю: %@.", reasons.joined(separator: "; "))
            }
            waitAndRestart(provider, from: origin)
            return L("Сейчас нельзя: %@. Перезапущу, когда освободится.", reasons.joined(separator: "; "))
        }
        return await restartNow(provider, from: origin)
    }

    private func waitAndRestart(_ provider: ProviderID, from origin: String) {
        waiting[provider]?.cancel()
        waiting[provider] = Task { [weak self] in
            let deadline = Date().addingTimeInterval(2 * 3600)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                if await self.busy(provider).isEmpty {
                    let result = await self.restartNow(provider, from: origin)
                    self.report(provider, result)
                    return
                }
            }
        }
    }

    private func restartNow(_ provider: ProviderID, from origin: String) async -> String {
        guard !running.contains(provider) else { return L("%@ уже перезапускается.", provider.displayName) }
        running.insert(provider)
        defer { running.remove(provider) }
        AgentActivity.trace("restart \(provider.rawValue) (\(origin)): quitting")
        let before = NSWorkspace.shared.frontmostApplication
        for app in apps(provider) { app.terminate() }
        // As ⌘Q: the app may ask nothing and take a few seconds. It is never killed.
        for _ in 0..<60 where isRunning(provider) { try? await Task.sleep(for: .milliseconds(500)) }
        guard !isRunning(provider) else {
            AgentActivity.trace("restart \(provider.rawValue): did not quit")
            return L("%@ не закрылся за 30 секунд — возможно, он что-то спросил на экране. Ничего не делал принудительно.", provider.displayName)
        }
        try? await Task.sleep(for: .seconds(2))
        open(provider)
        // Whatever the person was in stays in front.
        if let before, before.bundleIdentifier != Bundle.main.bundleIdentifier {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { _ = before.activate() }
        }
        let ok = await verify(provider)
        AgentActivity.trace("restart \(provider.rawValue): \(ok ? "back" : "not confirmed")")
        EventLog.shared.add(CooldownEvent(kind: ok ? .info : .attention, provider: provider,
                                          title: ok ? L("%@ перезапущен", provider.displayName) : L("%@ перезапущен, связь не подтвердилась", provider.displayName),
                                          body: origin))
        if ok && provider == .codex { AutoResume.shared.pokeAll(after: 5) }
        return ok ? L("%@ перезапущен, связь с Cooldown восстановлена.", provider.displayName)
                  : L("%@ открыт заново, но Cooldown пока его не видит. Проверю ещё раз через минуту.", provider.displayName)
    }

    /// Back and talking to Cooldown: Codex answers on its local socket; Claude shows a window.
    private func verify(_ provider: ProviderID) async -> Bool {
        for _ in 0..<45 {
            try? await Task.sleep(for: .seconds(2))
            switch provider {
            case .codex:
                let ok = await Task.detached { () -> Bool in
                    let connection = CodexIPCConnection(timeout: 5)
                    defer { connection.close() }
                    return (try? connection.open()) != nil
                }.value
                if ok { return true }
            case .claude:
                if let app = ClaudeSender.claudeApp, app.isFinishedLaunching, ClaudeSender.window(of: app) != nil { return true }
            case .antigravity: return false
            }
        }
        return false
    }

    private func report(_ provider: ProviderID, _ text: String) {
        let content = ToastContent(key: "restart-\(provider.rawValue)", kind: .info, provider: provider,
                                   title: L("Перезапуск %@", provider.displayName), body: text, life: .auto(15))
        ToastController.shared.show(content)
    }

    private func apps(_ provider: ProviderID) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: provider == .codex ? CodexApp.bundleId : ClaudeApp.bundleID)
    }

    private func isRunning(_ provider: ProviderID) -> Bool { !apps(provider).isEmpty }

    private func open(_ provider: ProviderID) {
        let id = provider == .codex ? CodexApp.bundleId : ClaudeApp.bundleID
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) ?? (provider == .codex ? CodexApp.url : nil) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
