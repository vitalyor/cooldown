import AppKit
import Foundation
import UserNotifications

/// "Check everything": each link of the chain tried for real, with a plain verdict and what to do.
/// The report names no files of the person beyond the tools Cooldown uses, with the home folder
/// written as ~.
@MainActor
final class Diagnostics: ObservableObject {
    static let shared = Diagnostics()

    enum Verdict { case running, ok, warning, failed, skipped }

    struct Check: Identifiable {
        let id: String
        var title: String
        var verdict: Verdict = .running
        var detail = ""
        var advice: String?
        var millis: Int?
    }

    @Published private(set) var checks: [Check] = []
    @Published private(set) var running = false
    @Published private(set) var finished: Date?

    var summary: (ok: Int, warnings: Int, failed: Int) {
        (checks.filter { $0.verdict == .ok }.count, checks.filter { $0.verdict == .warning }.count, checks.filter { $0.verdict == .failed }.count)
    }

    private func set(_ id: String, _ verdict: Verdict, _ detail: String, advice: String? = nil, since start: Date? = nil) {
        guard let index = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[index].verdict = verdict
        checks[index].detail = Self.private(detail)
        checks[index].advice = advice
        checks[index].millis = start.map { Int(Date().timeIntervalSince($0) * 1000) }
    }

    /// The home folder as ~, so a report can be shared.
    static func `private`(_ text: String) -> String {
        text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    func run() {
        guard !running else { return }
        running = true
        finished = nil
        let plan: [(String, String)] = [
            ("codex-app", "Приложение Codex"), ("codex-ipc", "Связь с окнами Codex"), ("codex-limits", "Лимиты Codex"),
            ("codex-hooks", "Хуки Codex"), ("autoresume", "Автопродолжение"),
            ("claude-binary", "Claude Code"), ("claude-usage", "Лимиты Claude"), ("claude-hooks", "Хуки Claude Code"),
            ("claude-window", "Окно Claude Desktop"), ("notifications", "Уведомления"), ("updates", "Обновления с GitHub"),
            ("selftest", "Правила безопасности"),
        ]
        checks = plan.map { Check(id: $0.0, title: $0.1) }
        Task {
            await codex()
            await claude()
            await system()
            running = false
            finished = Date()
        }
    }

    private func codex() async {
        var start = Date()
        if let url = CodexApp.url {
            do {
                try CodexApp.checkVersion()
                set("codex-app", .ok, (url.path as NSString).abbreviatingWithTildeInPath, since: start)
            } catch {
                set("codex-app", .failed, error.localizedDescription, advice: "Обновите приложение Codex.", since: start)
            }
        } else {
            set("codex-app", .warning, "Не установлено", advice: "Без приложения Codex не работают автопродолжение и карточки запросов; лимиты читаются через codex.")
        }

        start = Date()
        if !CodexApp.isRunning {
            set("codex-ipc", .skipped, "Codex не запущен — проверю, когда он будет открыт.")
        } else {
            let result: Result<Void, Error> = await Task.detached {
                Result { let connection = CodexIPCConnection(timeout: 5); try connection.open(); connection.close() }
            }.value
            switch result {
            case .success: set("codex-ipc", .ok, "Подключение есть" + (CodexRequestWatcher.shared.live ? ", запросы видны" : ""), since: start)
            case .failure(let error): set("codex-ipc", .failed, error.localizedDescription, advice: "Перезапустите приложение Codex.", since: start)
            }
        }

        start = Date()
        do {
            let snapshot = try await CodexLimits.fetch(binaryOverride: Settings.codexPath)
            let left = snapshot.session.map { "осталось \(Format.percent($0.remainingPercent))" } ?? "окно не начато"
            set("codex-limits", .ok, left, since: start)
        } catch {
            set("codex-limits", .failed, error.localizedDescription, advice: "Проверьте, что codex вошёл в аккаунт (codex login) и есть сеть.", since: start)
        }

        switch AgentHooks.status(.codex) {
        case .off: set("codex-hooks", .warning, "Не подключены", advice: "Подключите в «Настройки → Codex»: события придут сразу, а не по файлам.")
        case .on: set("codex-hooks", .ok, HookEventReader.shared.lastEvent[.codex].map { "Последнее событие \(Format.relative($0))" } ?? "Подключены")
        case .needsTrust(let count): set("codex-hooks", .warning, "\(count) ждут разрешения в Codex", advice: "Откройте Codex и разрешите хуки Cooldown (/hooks).")
        }

        let watches = AppModel.shared.watches
        let uncertain = watches.filter { $0.status == "uncertain" }.count
        set("autoresume", uncertain > 0 ? .warning : .ok,
            "Под наблюдением \(watches.filter(\.enabled).count) из \(watches.count)" + (uncertain > 0 ? ", неподтверждённых отправок: \(uncertain)" : ""),
            advice: uncertain > 0 ? "Посмотрите эти задачи в Codex: повторно Cooldown их не отправит." : nil)
    }

    private func claude() async {
        var start = Date()
        guard let binary = ClaudePaths.binary(override: Settings.claudePath) else {
            set("claude-binary", .warning, "Не найден", advice: "Установите Claude Code или откройте вкладку Code в Claude Desktop один раз.")
            set("claude-usage", .skipped, "Нужен Claude Code")
            set("claude-hooks", .skipped, "Нужен Claude Code")
            await window()
            return
        }
        let version: String = await Task.detached {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return "" }
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
        set("claude-binary", version.isEmpty ? .warning : .ok,
            (version.isEmpty ? "" : version + " · ") + (binary.path as NSString).abbreviatingWithTildeInPath, since: start)

        start = Date()
        if Settings.claudeUsageCLI {
            do {
                let snapshot = try await ClaudeUsageCLI.shared.read(binary: binary, force: true)
                let left = snapshot.session.map { "осталось \(Format.percent($0.remainingPercent))" } ?? "окно не начато"
                set("claude-usage", .ok, "/usage: " + left, since: start)
            } catch {
                set("claude-usage", .failed, error.localizedDescription, advice: "Запустите claude в Терминале и проверьте вход; затем повторите проверку.", since: start)
            }
        } else {
            set("claude-usage", .skipped, "Чтение через Claude Code выключено")
        }

        switch AgentHooks.status(.claude) {
        case .off: set("claude-hooks", .warning, "Не подключены", advice: "Подключите в «Настройки → Claude»: Cooldown увидит работу Claude Code и принесёт его запросы в карточки.")
        default:
            let update = AgentHooks.needsUpdate(.claude)
            set("claude-hooks", update ? .warning : .ok,
                update ? "Нет хука разрешений" : (HookEventReader.shared.lastEvent[.claude].map { "Последнее событие \(Format.relative($0))" } ?? "Подключены"),
                advice: update ? "Отключите и подключите хуки заново в «Настройки → Claude»." : nil)
        }
        await window()
    }

    private func window() async {
        let start = Date()
        guard let app = ClaudeSender.claudeApp else { set("claude-window", .skipped, "Claude Desktop не запущен"); return }
        guard ClaudeSender.hasPermission else {
            set("claude-window", .failed, "Нет «Универсального доступа»", advice: "«Настройки → Основные → Готовность» → «Исправить».")
            return
        }
        let pid = app.processIdentifier
        let chat: String? = await Task.detached {
            let root = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            for window in (ClaudeSender.value(root, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
                var stack = [window]
                var visited = 0
                while let element = stack.popLast(), visited < 4000 {
                    visited += 1
                    if let chat = ClaudeSender.chat(of: element) { return chat.title }
                    stack.append(contentsOf: ClaudeSender.children(element))
                }
            }
            return nil
        }.value
        set("claude-window", chat == nil ? .warning : .ok,
            chat.map { "Виден чат «\($0)»" } ?? "Окно читается, но открытого чата не видно",
            advice: chat == nil ? "Откройте любой чат в Claude Desktop и повторите." : nil, since: start)
    }

    private func system() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        set("notifications", allowed ? .ok : .warning, allowed ? "Разрешены" : "Выключены в Системных настройках",
            advice: allowed ? nil : "Без них Cooldown не сможет сообщить, когда экран заблокирован.")

        var start = Date()
        let updater = GitHubUpdater.shared
        await updater.check(manual: true, announce: false)
        if let available = updater.available {
            set("updates", .warning, "Доступна \(available.version), установлена \(GitHubUpdater.current)", advice: "«Настройки → Обновления».", since: start)
        } else if let state = updater.state, state.contains("Нет связи") || state.contains("Не удалось") {
            set("updates", .failed, state, since: start)
        } else {
            set("updates", .ok, "Установлена последняя \(GitHubUpdater.current)", since: start)
        }

        start = Date()
        let failures = SelfTest.run()
        set("selftest", failures.isEmpty ? .ok : .failed,
            failures.isEmpty ? "Все проверки пройдены" : failures.joined(separator: "; "),
            advice: failures.isEmpty ? nil : "Пришлите этот отчёт разработчику.", since: start)
    }

    /// Plain text for copying.
    var report: String {
        var lines = ["Cooldown \(GitHubUpdater.current) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "Проверено: \((finished ?? Date()).formatted(date: .abbreviated, time: .shortened))", ""]
        for check in checks {
            let mark: String
            switch check.verdict {
            case .ok: mark = "✓"
            case .warning: mark = "!"
            case .failed: mark = "✗"
            case .skipped: mark = "–"
            case .running: mark = "…"
            }
            var line = "\(mark) \(check.title): \(check.detail)"
            if let millis = check.millis, millis > 300 { line += " (\(millis) мс)" }
            lines.append(line)
            if let advice = check.advice { lines.append("    → \(advice)") }
        }
        return lines.joined(separator: "\n")
    }
}
