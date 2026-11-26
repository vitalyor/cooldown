import AppKit
import Foundation

/// Where people's own tool managers put a command, beyond the usual folders.
enum ToolPaths {
    static func userInstalled(_ name: String) -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        func versions(_ root: String, _ tail: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: root)) ?? [])
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { "\(root)/\($0)/\(tail)/\(name)" }
        }
        return ["\(home)/.volta/bin/\(name)", "\(home)/.asdf/shims/\(name)", "\(home)/.local/share/mise/shims/\(name)",
                "\(home)/Library/pnpm/\(name)", "\(home)/.yarn/bin/\(name)"]
            + versions("\(home)/.nvm/versions/node", "bin")
            + versions("\(home)/Library/Application Support/fnm/node-versions", "installation/bin")
    }
}

/// Getting Claude Code and Codex ready on any Mac: what is there, installing what is not (only when
/// the person presses the button), and signing in from the app. Whatever cannot be done here ends
/// in step-by-step instructions. Sign-in state is asked of the tools; no token is ever read here.
@MainActor
final class AgentSetup: ObservableObject {
    enum Stage: Equatable { case checking, missing, installing, signedOut, signingIn, ready }

    struct Agent: Equatable {
        var stage: Stage = .checking
        var problem: String?
        var loginURL: URL?
        var asksForCode = false
    }

    static let shared = AgentSetup()
    @Published private(set) var agents: [ProviderID: Agent] = [.claude: Agent(), .codex: Agent()]
    @Published private(set) var skipped: Set<ProviderID> = Set(ProviderID.agents.filter { UserDefaults.standard.bool(forKey: "setupSkipped.\($0.rawValue)") })

    private struct Login { let process: Process; let input: Pipe }
    private var logins: [ProviderID: Login] = [:]
    private var cancelled: Set<ProviderID> = []
    private var buffers: [ProviderID: String] = [:]

    func agent(_ provider: ProviderID) -> Agent { agents[provider] ?? Agent() }

    /// Waiting for the person, and they have not said they don't use this agent.
    func needsHelp(_ provider: ProviderID) -> Bool {
        guard !skipped.contains(provider) else { return false }
        return agent(provider).stage == .missing || agent(provider).stage == .signedOut
    }

    func setSkipped(_ provider: ProviderID, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: "setupSkipped.\(provider.rawValue)")
        if value { skipped.insert(provider) } else { skipped.remove(provider) }
        AppModel.shared.shownChanged()
    }

    /// Marked "I don't use it", yet the agent is at work: it is in use after all. Its tab comes back,
    /// and a card says so (and where to hide it again).
    func noticeInUse(_ provider: ProviderID) {
        guard skipped.contains(provider) else { return }
        setSkipped(provider, false)
        AgentActivity.trace("\(provider.rawValue): seen at work, shown again")
        ToastController.shared.show(ToastContent(key: "shown-\(provider.rawValue)", kind: .info, provider: provider,
                                                 title: L("%@ снова на виду", provider.displayName),
                                                 body: L("%@ работает, поэтому вкладка и линия в строке меню вернулись. Скрыть снова можно в настройках.", provider.toolName),
                                                 actions: [.openPanel, .openSettings(provider == .codex ? .codex : .claude)], life: .auto(12)))
    }

    func binary(_ provider: ProviderID) -> URL? {
        provider == .claude ? ClaudePaths.binary(override: Settings.claudePath) : CodexPaths.binary(override: Settings.codexPath)
    }

    // MARK: What is there

    func refresh() async {
        for provider in ProviderID.agents where ![.installing, .signingIn].contains(agent(provider).stage) { await check(provider) }
    }

    private func check(_ provider: ProviderID) async {
        // Asking the agent whether it is signed in may reach its servers: not while the route is wrong.
        guard RouteGuard.allows(provider) else { return }
        guard let binary = binary(provider) else {
            agents[provider]?.stage = .missing
            return
        }
        let signedIn: Bool
        if provider == .claude {
            let result = await Self.capture(binary, ["auth", "status", "--json"], timeout: 20)
            // A version too old to answer: what decides is whether limits can be read at all.
            signedIn = Self.claudeSignedIn(result.output) ?? (AppModel.shared.claude.snapshot != nil)
        } else {
            signedIn = await Self.capture(binary, ["login", "status"], timeout: 20).status == 0
        }
        let wasReady = agent(provider).stage == .ready
        agents[provider]?.stage = signedIn ? .ready : .signedOut
        if signedIn {
            agents[provider]?.problem = nil
            if !wasReady, agent(provider).stage == .ready { limitsMayHaveChanged() }
        }
    }

    private func limitsMayHaveChanged() {
        guard !AppModel.shared.isRenderMode else { return }
        AppModel.shared.forceNext = true
        Task { await AppModel.shared.refreshLimits() }
    }

    nonisolated static func claudeSignedIn(_ output: String) -> Bool? {
        guard let start = output.firstIndex(of: "{"), let data = String(output[start...]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["loggedIn"] as? Bool
    }

    /// The sign-in address a tool prints, once the whole of it has arrived.
    nonisolated static func signInLink(in output: String) -> URL? {
        guard let range = output.range(of: #"https://[^\s]+(?=\s)"#, options: .regularExpression) else { return nil }
        return URL(string: String(output[range]))
    }

    nonisolated private static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["CLAUDE_CODE_ENABLE_CFC"] = "false" // no look into browsers' folders (macOS 27 blames Cooldown)
        return environment
    }

    nonisolated static func capture(_ binary: URL, _ arguments: [String], timeout: TimeInterval) async -> (status: Int32, output: String) {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            var environment = environment
            // The tool's own folder first: an npm install under nvm/fnm needs its `node` beside it.
            let own = [binary.deletingLastPathComponent().path, binary.resolvingSymlinksInPath().deletingLastPathComponent().path]
            environment["PATH"] = (own + [environment["PATH"] ?? ""]).joined(separator: ":")
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return (-1, "") }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }

    // MARK: Installing (only ever from the button)

    func install(_ provider: ProviderID) {
        guard agent(provider).stage == .missing else { return }
        agents[provider]?.stage = .installing
        agents[provider]?.problem = nil
        Task {
            let result = await Self.capture(URL(fileURLWithPath: "/bin/bash"), ["-o", "pipefail", "-c", SetupGuide.silentInstall(provider)], timeout: 900)
            AgentActivity.trace("setup: install \(provider.rawValue) exit \(result.status)")
            await check(provider)
            if agent(provider).stage == .missing {
                agents[provider]?.problem = L("Не получилось установить автоматически: сервер загрузки не ответил или недоступен из вашей сети. Попробуйте включить VPN и нажать ещё раз, либо откройте подробную инструкцию ниже.")
            }
        }
    }

    // MARK: Signing in

    func signIn(_ provider: ProviderID) {
        guard let binary = binary(provider), logins[provider] == nil else { return }
        let process = Process()
        process.executableURL = binary
        process.arguments = provider == .claude ? ["auth", "login", "--claudeai"] : ["login"]
        process.environment = Self.environment
        let output = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = input
        output.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task { @MainActor in AgentSetup.shared.received(text, from: provider) }
        }
        process.terminationHandler = { _ in
            output.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in await AgentSetup.shared.loginEnded(provider) }
        }
        buffers[provider] = ""
        cancelled.remove(provider)
        agents[provider]?.stage = .signingIn
        agents[provider]?.problem = nil
        agents[provider]?.loginURL = nil
        agents[provider]?.asksForCode = false
        do {
            try process.run()
            logins[provider] = Login(process: process, input: input)
            DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak process] in if process?.isRunning == true { process?.terminate() } }
        } catch {
            agents[provider]?.stage = .signedOut
            agents[provider]?.problem = error.localizedDescription
        }
    }

    private func received(_ text: String, from provider: ProviderID) {
        let buffer = (buffers[provider] ?? "") + text
        buffers[provider] = String(buffer.suffix(8192))
        if agent(provider).loginURL == nil { agents[provider]?.loginURL = Self.signInLink(in: buffer) }
        if buffer.contains("Paste code") { agents[provider]?.asksForCode = true }
    }

    func sendCode(_ code: String, to provider: ProviderID) {
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let login = logins[provider] else { return }
        try? login.input.fileHandleForWriting.write(contentsOf: Data((clean + "\n").utf8))
    }

    func cancelSignIn(_ provider: ProviderID) {
        cancelled.insert(provider)
        logins[provider]?.process.terminate()
    }

    private func loginEnded(_ provider: ProviderID) async {
        logins[provider] = nil
        agents[provider]?.loginURL = nil
        agents[provider]?.asksForCode = false
        agents[provider]?.stage = .checking
        await check(provider)
        if agent(provider).stage == .signedOut, !cancelled.contains(provider) {
            agents[provider]?.problem = L("Вход не завершён. Нажмите «Войти» ещё раз или откройте подробную инструкцию ниже.")
        }
    }

    // MARK: The Terminal way

    /// Opens Terminal running the same steps. A .command file needs no automation permission.
    func openInTerminal(_ provider: ProviderID) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cooldown-setup-\(provider.rawValue).command")
        do { try Self.runInTerminal(SetupGuide.terminalScript(provider, installed: binary(provider) != nil), at: url) } catch {
            agents[provider]?.problem = error.localizedDescription
        }
    }

    /// Claude Code's own first-run setup (text style, sign-in), in Cooldown's folder for /usage.
    func openClaudeFirstRun() {
        openClaude(L("Пройдите первую настройку Claude Code: выберите тему, войдите в аккаунт и, если спросит, разрешите работать в этой папке. Когда появится поле ввода, наберите /exit."),
                   [[]])
    }

    /// From an Anthropic Console key to the Claude subscription: sign out, then sign in with claude.ai.
    func openClaudeSubscriptionLogin() {
        openClaude(L("Claude Code выйдет из входа по API-ключу и откроет браузер. Войдите тем аккаунтом Claude, где есть подписка Pro или Max, и вернитесь сюда."),
                   [["auth", "logout"], ["auth", "login", "--claudeai"]])
    }

    private func openClaude(_ steps: String, _ runs: [[String]]) {
        guard let binary = binary(.claude) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cooldown-claude-fix.command")
        try? Self.runInTerminal(SetupGuide.claudeScript(binary: binary, folder: ClaudeUsageCLI.workFolder, steps: steps, runs: runs), at: url)
    }

    private static func runInTerminal(_ script: String, at url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }
}

/// The commands and the written instructions, in one place.
enum SetupGuide {
    static func install(_ provider: ProviderID) -> String {
        provider == .claude ? "curl -fsSL https://claude.ai/install.sh | bash" : "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
    }

    static func silentInstall(_ provider: ProviderID) -> String {
        provider == .claude ? install(provider) : "curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh"
    }

    static func homebrew(_ provider: ProviderID) -> String { "brew install --cask \(provider == .claude ? "claude-code" : "codex")" }

    static func signIn(_ provider: ProviderID) -> String {
        // Works for the official installer (~/.local/bin) and for Homebrew alike.
        provider == .claude ? "PATH=\"$HOME/.local/bin:$PATH\" claude auth login" : "PATH=\"$HOME/.local/bin:$PATH\" codex login"
    }

    static func check(_ provider: ProviderID) -> String {
        provider == .claude ? "PATH=\"$HOME/.local/bin:$PATH\" claude auth status --text" : "PATH=\"$HOME/.local/bin:$PATH\" codex login status"
    }

    private static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func terminalScript(_ provider: ProviderID, installed: Bool) -> String {
        let done = L("Готово. Вернитесь в Cooldown и нажмите «Проверить снова». Это окно можно закрыть.")
        var lines = ["#!/bin/zsh", "clear"]
        if !installed { lines += ["echo \(quoted(L("Устанавливаю %@…", provider.toolName)))", install(provider)] }
        lines += ["echo", "echo \(quoted(L("Сейчас откроется браузер. Подтвердите вход и вернитесь сюда.")))", signIn(provider),
                  "echo", "echo \(quoted(done))", "rm -f \"$0\""]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Claude Code run by hand in Terminal, in Cooldown's folder for /usage, once per entry of `runs`.
    static func claudeScript(binary: URL, folder: URL, steps: String, runs: [[String]]) -> String {
        let done = L("Готово. Вернитесь в Cooldown и нажмите «Проверить снова». Это окно можно закрыть.")
        let failed = L("Не получилось: сообщение Claude Code выше. Можно запустить ещё раз кнопкой в Cooldown; это окно можно закрыть.")
        let path = "PATH=\(quoted(binary.deletingLastPathComponent().path)):\"$PATH\""
        // One after another, and "done" only if every step went well (a cancelled sign-in is not done).
        let commands = runs.map { ([path, quoted(binary.path)] + $0.map(quoted)).joined(separator: " ") }.joined(separator: " && ")
        return ["#!/bin/zsh", "clear", "print -r -- \(quoted(steps))", "print", "cd \(quoted(folder.path)) || exit 1",
                "if \(commands); then", "  print; print -r -- \(quoted(done))", "else", "  print; print -r -- \(quoted(failed))", "fi",
                "rm -f \"$0\""].joined(separator: "\n") + "\n"
    }

    /// What to paste into any AI assistant that can run commands. In English on purpose: every
    /// assistant reads it, and it is told to answer in the person's language.
    @MainActor static func assistantPrompt() -> String {
        func state(_ provider: ProviderID) -> String {
            switch AgentSetup.shared.agent(provider).stage {
            case .missing: return "not found"
            case .signedOut: return "installed, not signed in"
            case .ready: return "ready"
            default: return "unknown"
            }
        }
        return """
        Please set up the tools that the Mac app Cooldown needs. Talk to me in the language I use with you, and explain each step simply: I may not be technical.

        Current state on this Mac, as Cooldown sees it:
        - Claude Code: \(state(.claude))
        - Codex CLI: \(state(.codex))

        Do only what is needed for the tools I use (ask me if you are not sure which):
        1. Check what is there: `PATH="$HOME/.local/bin:$PATH" command -v claude codex brew`.
        2. Install what is missing with the official installer. No administrator password is expected.
           Claude Code: `curl -fsSL https://claude.ai/install.sh | bash`
           Codex: `curl -fsSL https://chatgpt.com/codex/install.sh | sh`
           If a download is refused (for example HTTP 403), the service may not be available from my network: ask me to turn on a VPN and retry. If Homebrew is installed, these also work: `brew install --cask claude-code`, `brew install --cask codex`.
        3. Sign in. These open my browser, and I must confirm there myself:
           Claude Code: `PATH="$HOME/.local/bin:$PATH" claude auth login`
           Codex: `PATH="$HOME/.local/bin:$PATH" codex login`
        4. Verify: `PATH="$HOME/.local/bin:$PATH" claude auth status --text` and `PATH="$HOME/.local/bin:$PATH" codex login status`.
        5. Tell me to return to Cooldown and press "Check again".

        Rules: never ask me for a password, token or API key, and never read credential files. Do not change any other settings on this Mac. Claude Code needs a paid Claude plan (the free plan does not include it); if that is the problem, tell me so plainly.
        """ // l10n:skip
    }
}

extension ProviderID {
    var toolName: String { self == .claude ? "Claude Code" : "Codex" }
}
