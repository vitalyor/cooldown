import Combine
import Foundation

/// A guided, made-up run of everything Cooldown does: limits running out, notifications,
/// a task waiting for the reset and continuing, a task that needs attention, and Claude's
/// "Продолжить" button. Real data is put aside while it runs and restored afterwards;
/// nothing is sent anywhere, and five hours pass in a few seconds.
@MainActor
final class DemoController: ObservableObject {
    static let shared = DemoController()

    struct Step {
        var title: String
        var text: String
        var seconds: Double
        var provider: ProviderID
        var tab: MainTab
    }

    @Published private(set) var active = false
    @Published private(set) var index = 0
    @Published private(set) var progress: Double = 0

    let steps: [Step] = [
        Step(title: "Codex работает над задачей",
             text: "Задача «Рефакторинг парсера» подключена к автопродолжению. Cooldown следит за лимитом: в окне — кольцо, в строке меню — линия Codex.",
             seconds: 7, provider: .codex, tab: .limits),
        Step(title: "Лимит тратится",
             text: "Чем меньше остаётся, тем короче линия и тем теплее её цвет: зелёный, жёлтый, оранжевый. Когда останется 20%, придёт уведомление.",
             seconds: 9, provider: .codex, tab: .limits),
        Step(title: "Лимит кончился",
             text: "При 5% придёт второе уведомление. На нуле Codex останавливается, а задача переходит в «Ждёт сброса лимита». Ваш Mac можно оставить в покое.",
             seconds: 8, provider: .codex, tab: .tasks),
        Step(title: "Ждём сброса",
             text: "В жизни это до пяти часов, в демо они пролетают за секунды. Cooldown знает точное время сброса и проверяет его сам.",
             seconds: 7, provider: .codex, tab: .tasks),
        Step(title: "Лимит восстановился, задача продолжена",
             text: "Сразу после сброса Cooldown отправляет в тот же диалог Codex «продолжай» и сообщает об этом уведомлением. Задача снова выполняется.",
             seconds: 9, provider: .codex, tab: .tasks),
        Step(title: "Задаче нужно ваше внимание",
             text: "Если Codex задал вопрос или ждёт разрешения, Cooldown не жмёт за вас. Появляется оранжевая точка в строке меню и уведомление: откройте задачу и решите сами.",
             seconds: 9, provider: .codex, tab: .tasks),
        Step(title: "Claude Desktop: лимит кончается",
             text: "Лимиты Claude общие для чатов, Cowork и Claude Code. Cooldown читает их через Claude Code, токены на это не тратятся.",
             seconds: 9, provider: .claude, tab: .limits),
        Step(title: "Claude: лимит восстановился",
             text: "Приходит уведомление с кнопкой «Продолжить». По нажатию Cooldown отправил бы сообщение в открытый чат Claude. В демо ничего не отправляется, но кнопку можно нажать.",
             seconds: 12, provider: .claude, tab: .tasks),
        Step(title: "Вот и всё",
             text: "Codex Cooldown продолжает сам, Claude — по одному вашему нажатию. Нажмите «Выйти», и вернутся ваши настоящие данные.",
             seconds: .infinity, provider: .codex, tab: .limits),
    ]

    var step: Step { steps[index] }

    private var timer: Timer?
    private var stepStarted = Date()
    private var fired: Set<String> = []
    private let taskID = "demo-refactor-parser"

    // MARK: Control

    func start() {
        guard !active else { return }
        fired = []
        AppModel.shared.enterDemo()
        active = true
        go(to: 0)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            Task { @MainActor in DemoController.shared.tick() }
        }
    }

    func jump(to step: Int) { if active, steps.indices.contains(step) { go(to: step) } }

    func next() { if index + 1 < steps.count { go(to: index + 1) } }

    func stop() {
        guard active else { return }
        timer?.invalidate()
        timer = nil
        active = false
        AppModel.shared.leaveDemo()
    }

    private func go(to newIndex: Int) {
        index = newIndex
        stepStarted = Date()
        progress = 0
        AppModel.shared.selected = step.provider
        apply(fraction: 0)
    }

    private func tick() {
        guard active else { return }
        let elapsed = Date().timeIntervalSince(stepStarted)
        if step.seconds.isFinite {
            progress = min(1, elapsed / step.seconds)
            apply(fraction: progress)
            if progress >= 1 { next() }
        }
    }

    // MARK: The story

    private func apply(fraction t: Double) {
        let model = AppModel.shared
        let now = Date()
        var codexLeft = 46.0, claudeLeft = 72.0
        var codexReset = now.addingTimeInterval(2.4 * 3600)
        var status = "watching", reason = "Codex работает, Cooldown следит за лимитом."
        var attempts = 0

        switch index {
        case 0:
            codexLeft = 46 - 4 * t
        case 1:
            codexLeft = 42 - 24 * t
            if codexLeft <= 20 { notify("c20", "Codex: осталось 20%", "Лимит на 5 часов заканчивается. Сброс в \(Format.time(codexReset)).") }
        case 2:
            codexLeft = max(0, 18 - 18 * min(1, t * 1.6))
            if codexLeft <= 5 { notify("c5", "Codex: осталось 5%", "Лимит на 5 часов заканчивается. Сброс в \(Format.time(codexReset)).") }
            if codexLeft <= 0 {
                status = "waiting_quota"
                reason = "Лимит исчерпан. Продолжу в \(Format.time(codexReset))."
                notify("cwait", "Codex: задача ждёт сброса", "«Рефакторинг парсера» продолжится автоматически в \(Format.time(codexReset)).")
            }
        case 3:
            codexLeft = 0
            codexReset = now.addingTimeInterval(max(1, (1 - t) * 5 * 3600))
            status = "waiting_quota"
            reason = "Лимит исчерпан. Продолжу в \(Format.time(codexReset))."
        case 4:
            codexLeft = 100 - 3 * t
            codexReset = now.addingTimeInterval(5 * 3600)
            status = t < 0.5 ? "resumed" : "watching"
            reason = t < 0.5 ? "Отправлено: «Продолжай с того места, где остановился»." : "Codex снова работает."
            attempts = 1
            notify("creset", "Лимит Codex восстановлен", "Окно на 5 часов сбросилось, можно продолжать работу.")
            notify("cresumed", "Codex: задача продолжена", "«Рефакторинг парсера»: лимит восстановился, продолжение отправлено.")
        case 5:
            codexLeft = 97 - 6 * t
            codexReset = now.addingTimeInterval(5 * 3600)
            attempts = 1
            if t > 0.25 {
                status = "needs_attention"
                reason = "Codex спрашивает разрешение выполнить команду. Откройте диалог и ответьте."
                notify("cattn", "Codex: задача ждёт проверки", "«Рефакторинг парсера»: Codex спрашивает разрешение выполнить команду.")
            }
        case 6:
            codexLeft = 90; attempts = 1
            claudeLeft = max(0, 32 - 32 * min(1, t * 1.3))
            if claudeLeft <= 20 { notify("l20", "Claude: осталось 20%", "Лимит на 5 часов заканчивается.") }
        case 7:
            codexLeft = 90; attempts = 1
            claudeLeft = 100
            if t > 0.1 {
                notify("lreset", "Лимит Claude восстановлен",
                       "Окно на 5 часов сбросилось. «Продолжить» отправит сообщение в открытый чат Claude.", claude: true)
            }
        default:
            codexLeft = 90; claudeLeft = 100; attempts = 1
        }

        let claudeReset = index >= 7 ? now.addingTimeInterval(5 * 3600) : now.addingTimeInterval(1.7 * 3600)
        model.codex.setDemo(snapshot(.codex, left: codexLeft, reset: codexReset, week: 64, credits: 3),
                            samples: history(left: codexLeft, reset: codexReset, now: now))
        model.claude.setDemo(snapshot(.claude, left: claudeLeft, reset: claudeReset, week: 81, credits: nil),
                             samples: history(left: claudeLeft, reset: claudeReset, now: now))
        let watch = RelayWatch(threadId: taskID, enabled: index < 8, maxResumes: 3, status: status, reason: reason,
                               updated: now, attempts: attempts, processGone: false)
        model.setDemoTasks([watch], threads: [RelayThread(id: taskID, title: "Рефакторинг парсера", cwd: nil, updatedAt: now, archived: false)])
    }

    private func snapshot(_ provider: ProviderID, left: Double, reset: Date, week: Double, credits: Int?) -> LimitSnapshot {
        var snapshot = LimitSnapshot(provider: provider, plan: "Демо", session: nil, weekly: nil, fetchedAt: Date(), source: "демо")
        snapshot.session = LimitWindow(kind: .session, usedPercent: 100 - left, durationMinutes: 300, resetsAt: reset)
        snapshot.weekly = LimitWindow(kind: .weekly, usedPercent: 100 - week, durationMinutes: 10080,
                                      resetsAt: Date().addingTimeInterval(3.5 * 86400))
        snapshot.resetCredits = credits
        snapshot.limitReached = left <= 0
        return snapshot
    }

    /// A believable curve for the forecast chart, ending at the current value.
    private func history(left: Double, reset: Date, now: Date) -> [LimitSample] {
        let start = reset.addingTimeInterval(-5 * 3600)
        let span = max(600, now.timeIntervalSince(start))
        return (0...30).map { i in
            let f = Double(i) / 30
            let used = (100 - left) * pow(f, 1.15)
            return LimitSample(t: start.addingTimeInterval(span * f), kind: .session, used: used, resetsAt: reset)
        }
    }

    private func notify(_ key: String, _ title: String, _ body: String, claude: Bool = false) {
        guard !fired.contains(key) else { return }
        fired.insert(key)
        Notifier.shared.post(id: "demo-\(key)-\(Int(Date().timeIntervalSince1970))", title: "Демо · \(title)", body: body,
                             opensClaude: claude, demo: true)
    }

    func reset() { fired = [] }
}
