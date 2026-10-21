import AppKit
import Combine
import SwiftUI

enum ScanState: Equatable {
    case idle
    case scanning(Double)
}

/// Everything known about one agent: its current limits and its usage history.
@MainActor
final class ProviderStore: ObservableObject {
    let id: ProviderID

    @Published private(set) var snapshot: LimitSnapshot?
    @Published private(set) var limitError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var buckets: [TokenBucket] = []
    @Published private(set) var samples: [LimitSample] = []
    @Published private(set) var scanState: ScanState = .idle

    var allowSave = true
    private let store: HistoryStore
    private var history = HistoryFile()
    private var scanning = false
    private let fetcher: () async throws -> LimitSnapshot
    private let makeScanner: () -> HistoryScanning

    init(id: ProviderID, fetch: @escaping () async throws -> LimitSnapshot, scanner: @escaping () -> HistoryScanning) {
        self.id = id
        self.fetcher = fetch
        self.makeScanner = scanner
        self.store = HistoryStore(provider: id)
    }

    var tint: Color { Theme.tint(for: id) }

    func load() {
        history = store.load()
        publish()
    }

    /// Reads the limits; returns the fresh snapshot, or nil if reading failed.
    /// How long a reading is good for before the source is asked again (nil: always ask).
    var freshFor: (() -> TimeInterval)?
    private var lastAsked = Date.distantPast

    @discardableResult
    func refreshLimits(force: Bool = false) async -> LimitSnapshot? {
        guard !isRefreshing, !inDemo else { return nil }
        if !force, let freshFor, let snapshot, Date().timeIntervalSince(max(lastAsked, snapshot.fetchedAt)) < freshFor() {
            return nil
        }
        lastAsked = Date()
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fresh = try await fetcher()
            guard !inDemo else { return nil }   // the demo took over while this was reading
            withAnimation(.smooth(duration: 0.6)) { snapshot = fresh }
            limitError = nil
            let live = ([fresh.session, fresh.weekly].compactMap { $0 }).map {
                LimitSample(t: fresh.fetchedAt, kind: $0.kind, used: $0.usedPercent, resetsAt: $0.resetsAt)
            }
            history.add(samples: live)
            samples = history.samples
            save()
            return fresh
        } catch {
            limitError = error.localizedDescription
            return nil
        }
    }

    func scan(fullRebuild: Bool = false) async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        if fullRebuild {
            history.buckets = []
            history.cursors = [:]
        }
        let cursors = history.cursors
        let firstRun = cursors.isEmpty
        if firstRun { scanState = .scanning(0) }
        let scanner = makeScanner()
        let provider = id
        let output = await Task.detached(priority: .utility) { () -> ScanOutput in
            scanner.scan(cursors: cursors) { fraction in
                guard firstRun else { return }
                Task { @MainActor in AppModel.shared.store(provider).progress(fraction) }
            }
        }.value
        history.merge(output)
        history.prune(now: Date())
        publish()
        scanState = .idle
        save()
    }

    /// A reading that arrived by itself (Codex writes its limits into the session files with
    /// every reply), taken as is: no need to start Codex to ask.
    func apply(_ fresh: LimitSnapshot) {
        guard !inDemo, snapshot.map({ fresh.fetchedAt > $0.fetchedAt }) ?? true else { return }
        snapshot = fresh
        limitError = nil
        history.add(samples: [fresh.session, fresh.weekly].compactMap { $0 }.map {
            LimitSample(t: fresh.fetchedAt, kind: $0.kind, used: $0.usedPercent, resetsAt: $0.resetsAt)
        })
        samples = history.samples
    }

    /// Readings from elsewhere (Claude Desktop's own record) added to the history once.
    func importSamples(_ extra: [LimitSample]) {
        guard !extra.isEmpty else { return }
        history.add(samples: extra)
        samples = history.samples
        save()
    }

    fileprivate func progress(_ fraction: Double) {
        if scanning { scanState = .scanning(fraction) }
    }

    private func publish() {
        buckets = history.buckets
        samples = history.samples
    }

    private func save() {
        guard allowSave else { return }
        store.save(history)
    }

    // MARK: Demo

    private var realSnapshot: LimitSnapshot?
    private var realSamples: [LimitSample] = []
    private(set) var inDemo = false

    func enterDemo() {
        guard !inDemo else { return }
        inDemo = true
        realSnapshot = snapshot
        realSamples = samples
    }

    func setDemo(_ fake: LimitSnapshot, samples fakeSamples: [LimitSample]) {
        snapshot = fake
        samples = fakeSamples
        limitError = nil
    }

    func leaveDemo() {
        guard inDemo else { return }
        inDemo = false
        snapshot = realSnapshot
        samples = realSamples
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let codex = ProviderStore(id: .codex,
                              fetch: { try await CodexLimits.fetch(binaryOverride: Settings.codexPath) },
                              scanner: { CodexHistoryScanner(root: CodexPaths.sessions) })
    let claude = ProviderStore(id: .claude,
                               fetch: { try await ClaudeLimits.fetch() },
                               scanner: { ClaudeHistoryScanner(root: ClaudePaths.projects) })
    let claudeTasks = ClaudeTaskManager()

    @Published var selected: ProviderID {
        didSet { UserDefaults.standard.set(selected.rawValue, forKey: SettingsKey.selectedProvider) }
    }
    /// Counts openings of the window, so views can replay their entrance.
    @Published private(set) var openCount = 0

    // Codex auto-continue (built in, see AutoResume).
    @Published private(set) var watches: [ResumeWatch] = []
    @Published private(set) var relayError: String?
    @Published private(set) var threads: [CodexConversation] = []
    @Published private(set) var threadsError: String?
    @Published private(set) var loadingThreads = false

    /// The menu bar picture. Not @Published: it changes many times a second while an agent works,
    /// and publishing would redraw the whole window each time.
    private(set) var menuImage = GaugeIcon.image(lines: [MenuLine(remaining: nil, color: GaugeIcon.codex, mark: GaugeIcon.codexMark), MenuLine(remaining: nil, color: GaugeIcon.claude, mark: GaugeIcon.claudeMark)], attention: false, showText: true) {
        didSet { menuImageChanges.send(menuImage) }
    }
    let menuImageChanges = PassthroughSubject<NSImage, Never>()

    var isRenderMode = false

    private var timers: [Timer] = []
    private var lastThreadsLoad: Date?
    private var previousStatuses: [String: String] = [:]
    private(set) var displayedLines: [MenuLine] = []
    private var menuAnimation: Timer?
    private var subscriptions = Set<AnyCancellable>()

    init() {
        selected = ProviderID(rawValue: UserDefaults.standard.string(forKey: SettingsKey.selectedProvider) ?? "") ?? .codex
    }

    func store(_ id: ProviderID) -> ProviderStore { id == .codex ? codex : claude }

    /// Auto-continue needs the Codex desktop app (its local socket) — nothing else to install.
    var relayAvailable: Bool { CodexApp.url != nil }

    // MARK: Lifecycle

    func start() {
        codex.load()
        claude.load()
        claudeTasks.load()
        // Codex: while it works, its session files bring the limits with every reply; asking
        // `codex app-server` (a process of its own) is needed only when the window is open or
        // things have been quiet for a while.
        codex.freshFor = {
            let model = AppModel.shared
            if model.panelVisible { return Settings.refreshInterval }
            return AgentActivity.shared.working(.codex).isEmpty ? 10 * 60 : 5 * 60
        }
        claudeTasks.onChange = { [weak self] task, _ in self?.notifyClaudeTask(task) }
        claudeTasks.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            DispatchQueue.main.async { self?.updateMenuImage(animated: false) }
        }.store(in: &subscriptions)
        updateMenuImage(animated: false)
        historyWatch = FolderWatch([CodexPaths.sessions.path, CodexPaths.home.appendingPathComponent("archived_sessions").path,
                                    ClaudePaths.projects.path], latency: 10) {
            MainActor.assumeIsolated { AppModel.shared.historyDirty = true }
        }
        schedule()
        CodexFinishWatcher.shared.start()
        HookEventReader.shared.start()
        FocusWatch.start()
        UpdateWatch.start()
        GitHubUpdater.shared.start()
        GitHubUpdater.shared.greetIfUpdated()
        AutoResume.shared.onChange = { rows in AppModel.shared.resumeChanged(rows) }
        AutoResume.shared.start()
        CodexRequestWatcher.shared.start()
        ClaudeDesktopWatcher.shared.start()
        // Keep the hook script current if hooks are installed (it is tiny and versioned with the app).
        if AgentHooks.Agent.allCases.contains(where: { AgentHooks.status($0) != .off }) { try? AgentHooks.writeScript() }
        // Hooks from an earlier version get the newer events (Claude Code's permission cards).
        if AgentHooks.needsUpdate(.claude) { try? AgentHooks.install(.claude) }
        ClaudeAsks.shared.start()
        claude.importSamples(ClaudeDesktopUsage.samples(fitting: claude.samples))
        DailyLog.shared.start()
        Task { await refreshAll() }
    }

    func prepareForRender(scan: Bool) async {
        codex.load()
        claude.load()
        claudeTasks.load()
        codex.allowSave = scan
        claude.allowSave = scan
        DailyLog.shared.load()
        if scan {
            await codex.scan()
            await claude.scan()
        }
        await refreshLimits()
        await refreshRelay()
        await loadThreads(force: true)
        await claudeTasks.loadSessions()
    }

    func schedule() {
        timers.forEach { $0.invalidate() }
        timers = [
            Timer.every(Settings.refreshInterval) { _ in
                Task { @MainActor in await AppModel.shared.refreshLimits() }
            },
            Timer.every(60) { _ in
                Task { @MainActor in
                    let model = AppModel.shared
                    // History is re-read only when the agents' folders changed (or every half hour).
                    if model.historyDirty || Date().timeIntervalSince(model.lastScan) > 30 * 60 {
                        model.historyDirty = false
                        model.lastScan = Date()
                        await model.codex.scan()
                        await model.claude.scan()
                        DailyLog.shared.refresh()
                        Insights.checkProjects(model.codex)
                    }
                    if !model.demoActive { model.claudeTasks.tick(limits: model.claude.snapshot) }
                }
            },
            Timer.every(30) { _ in
                Task { @MainActor in
                    MorningSummary.check()
                    Insights.checkWeek()
                    Insights.checkDay()
                    if ClaudeChatList.shared.cardsWaiting, ToastController.shared.canShow, !QuietHours.active,
                       ToastController.idleSeconds < 60 {
                        ClaudeChatList.shared.cardsWaiting = false
                        ClaudeChatList.shared.limitReset()
                    }
                    AppModel.shared.checkResets()
                }
            },
        ]
    }

    func refreshAll() async {
        async let limits: Void = refreshLimits()
        async let codexHistory: Void = codex.scan()
        async let claudeHistory: Void = claude.scan()
        async let relay: Void = refreshRelay()
        _ = await (limits, codexHistory, claudeHistory, relay)
        DailyLog.shared.refresh()
        claudeTasks.tick(limits: claude.snapshot)
    }

    /// Whether Cooldown's window is on screen (not published: views that poll check it).
    var panelVisible = false

    func panelOpened() {
        panelVisible = true
        openCount += 1
        Task { await refreshLimits() }
    }

    // MARK: Limits

    /// Set by the refresh button: the next reading asks every source.
    var forceNext = false

    func refreshLimits() async {
        let force = forceNext
        forceNext = false
        async let codexFresh = codex.refreshLimits(force: force)
        async let claudeFresh = claude.refreshLimits(force: force)
        let (a, b) = await (codexFresh, claudeFresh)
        if let a { checkThresholds(a) }
        if let b { checkThresholds(b) }
        if !isRenderMode {
            Insights.checkPace(codex)
            Insights.checkPace(claude)
        }
        ScheduledRunner.shared.tick(limits: codex.snapshot)
        if !demoActive {
            HomeAssistant.shared.updateLive(.codex, snapshot: codex.snapshot)
            HomeAssistant.shared.updateLive(.claude, snapshot: claude.snapshot)
            HomeAssistant.shared.publishSensors()
        }
        updateMenuImage(animated: true)
        activityChanged()   // the tooltip carries the fresh forecast
    }

    private func checkThresholds(_ fresh: LimitSnapshot) {
        guard !isRenderMode, let session = fresh.session, !session.isExpired(at: Date()) else { return }
        let name = fresh.provider.displayName
        if session.usedPercent >= 90 { Settings.setPendingReset(fresh.provider, session.resetsAt) }
        // Claude ran out: remember the chat in use, so "Продолжить" goes back to that one.
        if fresh.provider == .claude, session.usedPercent >= 99, ClaudeSender.pendingChat == nil {
            ClaudeSender.rememberChatForReset()
        }
        guard Settings.notifyThresholds else { return }
        // At the Mac the percentages in the menu bar already say this; only notify when away.
        if ToastController.shared.canShow { return }
        let remaining = session.remainingPercent
        let crossed = [20.0, 5.0].filter { remaining <= $0 }
        guard let lowest = crossed.min() else { return }
        let window = "\(fresh.provider.rawValue)-\(Int(session.resetsAt.timeIntervalSince1970))"
        let key = "\(window)-\(Int(lowest))"
        var notified = Settings.notifiedKeys
        guard !notified.contains(key) else { return }
        notified += crossed.map { "\(window)-\(Int($0))" }
        Settings.notifiedKeys = notified
        Notifier.shared.post(id: key, title: "\(name): осталось \(Format.percent(remaining))",
                             body: "Лимит на 5 часов заканчивается. Сброс в \(Format.time(session.resetsAt)).",
                             toast: ToastCatalog.limitLow(fresh.provider, remaining: remaining, reset: session.resetsAt))
    }

    func checkResets() {
        guard !demoActive else { return }
        for provider in ProviderID.allCases {
            guard let pending = Settings.pendingReset(provider), Date() >= pending else { continue }
            Settings.setPendingReset(provider, nil)
            // Watched Codex tasks re-read the limits right away (they also wake at the reset by themselves).
            if provider == .codex { AutoResume.shared.pokeAll(after: 15) }
            // Chats chosen for Claude get their own "Продолжить «…»?" cards.
            if provider == .claude, !isRenderMode, !ClaudeChatList.shared.entries.isEmpty {
                EventLog.shared.add(CooldownEvent(kind: .reset, provider: .claude, title: "Лимит Claude восстановлен",
                                                  body: "Ждут продолжения: " + ClaudeChatList.shared.entries.map { "«\($0.chat.title)»" }.joined(separator: ", ")))
                if ToastController.shared.canShow && !QuietHours.active {
                    ClaudeChatList.shared.limitReset()
                    continue
                }
                // Away: the cards wait until someone is back at the Mac.
                ClaudeChatList.shared.cardsWaiting = true
            }
            if Settings.notifyReset && !isRenderMode {
                Notifier.shared.post(id: "reset-\(provider.rawValue)-\(Int(pending.timeIntervalSince1970))",
                                     title: "Лимит \(provider.displayName) восстановлен",
                                     body: provider == .claude ? "Окно на 5 часов сбросилось. Нажмите, чтобы открыть Claude."
                                                               : "Окно на 5 часов сбросилось, можно продолжать работу.",
                                     opensClaude: provider == .claude,
                                     toast: ToastCatalog.limitReset(provider))
            }
        }
        updateMenuImage(animated: true)
    }


    // MARK: Demo

    private var realWatches: [ResumeWatch] = []
    private var realThreads: [CodexConversation] = []
    var demoActive: Bool { DemoController.shared.active }

    func enterDemo() {
        codex.enterDemo()
        claude.enterDemo()
        realWatches = watches
        realThreads = threads
    }

    func setDemoTasks(_ rows: [ResumeWatch], threads fake: [CodexConversation]) {
        watches = rows
        threads = fake
        relayError = nil
        updateMenuImage(animated: false)
    }

    func leaveDemo() {
        codex.leaveDemo()
        claude.leaveDemo()
        watches = realWatches
        threads = realThreads
        updateMenuImage(animated: true)
        Task { await refreshAll() }
    }

    var historyDirty = true
    var lastScan = Date.distantPast
    private var historyWatch: FolderWatch?

    func refreshRelay() async {
        guard !demoActive else { return }
        resumeChanged(await AutoResume.shared.watches())
    }

    /// Watches changed (pushed by AutoResume the moment they do — no polling).
    func resumeChanged(_ rows: [ResumeWatch]) {
        guard !demoActive else { return }
        relayError = CodexApp.url == nil ? "Не найдено приложение Codex — автопродолжение работает через него." : nil
        notifyRelayChanges(rows)
        if rows != watches { withAnimation(.smooth) { watches = rows } }
        if rows.contains(where: { knownTitle($0.threadId) == nil }) { Task { await loadThreads(force: false) } }
        updateMenuImage(animated: false)
    }

    /// A screen to show the next time the window draws (from the menu, a card or the hot key).
    @Published var route: Screen?

    /// A dialog picked on the Tasks tab, opened straight away by the add-task screen.
    @Published var pendingThread: CodexConversation?

    func loadThreads(force: Bool, maxAge: TimeInterval = 600) async {
        if demoActive { return }
        if !force, let last = lastThreadsLoad, Date().timeIntervalSince(last) < maxAge { return }
        guard !loadingThreads else { return }
        loadingThreads = true
        defer { loadingThreads = false }
        lastThreadsLoad = Date()
        do {
            threads = try await AutoResume.shared.conversations()
            threadsError = nil
        } catch {
            threadsError = ResumeError.friendly(error)
        }
    }

    func knownTitle(_ id: String) -> String? { threads.first { $0.id == id }?.title }
    func title(for id: String) -> String { knownTitle(id) ?? "Диалог \(id.prefix(8))" }

    func check(_ id: String) async throws -> ResumeCheck { try await AutoResume.shared.check(id) }

    func startTask(_ id: String, maxResumes: Int) async throws {
        try await AutoResume.shared.start(id, maxResumes: maxResumes)
        await loadThreads(force: true)
    }

    func stopTask(_ id: String) async throws {
        await AutoResume.shared.stop(id)
    }

    private func notifyRelayChanges(_ rows: [ResumeWatch]) {
        for watch in rows {
            let old = previousStatuses[watch.threadId]
            previousStatuses[watch.threadId] = watch.status
            guard let old, old != watch.status else { continue }
            notifyTask(provider: .codex, id: watch.threadId, title: title(for: watch.threadId), status: watch.status, reason: watch.reason)
        }
    }

    private func notifyClaudeTask(_ task: ClaudeTask) {
        notifyTask(provider: .claude, id: task.id, title: task.title, status: task.status, reason: task.reason)
    }

    private func notifyTask(provider: ProviderID, id: String, title: String, status: String, reason: String) {
        guard Settings.notifyTasks, !isRenderMode else { return }
        let name = "«\(title)»"
        switch status {
        case "resumed":
            Notifier.shared.post(id: "task-\(id)-\(Int(Date().timeIntervalSince1970))", title: "\(provider.displayName): задача продолжена",
                                 body: "\(name): лимит восстановился, продолжение отправлено.",
                                 toast: ToastCatalog.taskResumed(provider, title: title))
        case "waiting_quota":
            Notifier.shared.post(id: "task-\(id)-wait-\(Int(Date().timeIntervalSince1970) / 3600)", title: "\(provider.displayName): задача ждёт сброса",
                                 body: "\(name) продолжится автоматически после сброса лимита.",
                                 toast: ToastCatalog.taskWaiting(provider, title: title, until: store(provider).snapshot?.session?.resetsAt))
        case "stopped":
            // Finished turns are announced by the session watcher, with the agent's own last words.
            break
        case let state where TaskStatus.needsAttention(state):
            Notifier.shared.post(id: "task-\(id)-\(state)", title: "\(provider.displayName): задача ждёт проверки", body: "\(name): \(reason)",
                                 toast: ToastCatalog.taskAttention(provider, title: title, reason: reason))
        case "budget":
            Notifier.shared.post(id: "task-\(id)-budget", title: "\(provider.displayName): попытки закончились",
                                 body: "\(name): автопродолжение остановлено.",
                                 toast: ToastCatalog.taskBudget(provider, title: title))
        default:
            break
        }
    }

    // MARK: Menu bar

    var needsAttention: Bool {
        watches.contains { $0.enabled && TaskStatus.needsAttention($0.status) }
            || claudeTasks.tasks.contains { TaskStatus.needsAttention($0.status) && $0.updated > Date().addingTimeInterval(-86400) }
    }

    /// The 5-hour window, as the big number in the window shows; the week only if there is no session.
    private func sessionRemaining(_ snapshot: LimitSnapshot?, _ now: Date) -> Double? {
        snapshot?.session?.remaining(at: now) ?? snapshot?.weekly?.remaining(at: now)
    }

    /// One line per agent shown in the menu bar: both by default, or just the chosen one.
    private func menuLines() -> [MenuLine] {
        let now = Date()
        let codexLine = MenuLine(remaining: sessionRemaining(codex.snapshot, now), color: GaugeIcon.codex, mark: GaugeIcon.codexMark,
                                 glyph: GaugeIcon.codexGlyph, activity: menuActivity(.codex))
        let claudeLine = MenuLine(remaining: sessionRemaining(claude.snapshot, now), color: GaugeIcon.claude, mark: GaugeIcon.claudeMark,
                                  glyph: GaugeIcon.claudeGlyph, activity: menuActivity(.claude))
        switch Settings.menuSource {
        case "codex": return [codexLine]
        case "claude": return [claudeLine]
        default: return [codexLine, claudeLine]
        }
    }

    private func menuActivity(_ provider: ProviderID) -> MenuLine.Activity {
        guard Settings.showActivity, !demoActive else { return .idle }
        let activity = AgentActivity.shared
        if !activity.waiting(provider).isEmpty { return .waiting }
        return activity.working(provider).isEmpty ? .idle : .working
    }

    /// What the agents are doing, for the menu bar item's tooltip.
    private(set) var menuTooltip = "Cooldown" {
        didSet { if menuTooltip != oldValue { menuTooltipChanges.send(menuTooltip) } }
    }
    let menuTooltipChanges = PassthroughSubject<String, Never>()


    /// Called by AgentActivity whenever a session starts, waits or ends.
    func activityChanged() {
        updateMenuImage(animated: false)
        var lines: [String] = []
        for provider in ProviderID.allCases {
            let activity = AgentActivity.shared
            for session in activity.waiting(provider) { lines.append("\(provider.displayName) ждёт вас: \(session.title)") }
            for session in activity.working(provider) {
                lines.append("\(provider.displayName) работает: \(session.title.isEmpty ? "без названия" : session.title)")
            }
        }
        // Then each agent's 5-hour limit and how long it lasts at the current pace.
        let now = Date()
        for store in [codex, claude] {
            guard let window = store.snapshot?.session, !window.isExpired(at: now) else { continue }
            var line = "\(store.id.displayName): осталось \(Format.percent(window.remainingPercent))"
            switch Forecaster.make(window: window, samples: store.samples, now: now).outcome {
            case .runsOut(let at): line += ", при таком темпе хватит до \(Format.clock(at))"
            case .lasts: line += ", хватит до сброса в \(Format.clock(window.resetsAt))"
            default: line += ", сброс в \(Format.clock(window.resetsAt))"
            }
            lines.append(line)
        }
        menuTooltip = lines.isEmpty ? "Cooldown" : lines.joined(separator: "\n")
    }

    func updateMenuImage(animated: Bool) {
        let target = menuLines()
        let attention = needsAttention
        let showText = Settings.showPercent
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        menuAnimation?.invalidate()
        let from = displayedLines
        let moves = from.count == target.count && zip(from, target).contains { pair in
            guard let a = pair.0.remaining, let b = pair.1.remaining else { return false }
            return abs(a - b) >= 1
        }
        guard animated, !isRenderMode, moves else {
            displayedLines = target
            menuImage = GaugeIcon.image(lines: target, attention: attention, showText: showText, still: still)
            return
        }
        let started = Date()
        menuAnimation = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { timer in
            Task { @MainActor in
                let progress = min(1, Date().timeIntervalSince(started) / 0.9)
                let eased = 1 - pow(1 - progress, 3)
                let lines = zip(from, target).map { pair -> MenuLine in
                    var line = pair.1
                    if let a = pair.0.remaining, let b = pair.1.remaining { line.remaining = a + (b - a) * eased }
                    return line
                }
                let model = AppModel.shared
                model.displayedLines = lines
                model.menuImage = GaugeIcon.image(lines: lines, attention: attention, showText: showText, still: still)
                if progress >= 1 { timer.invalidate() }
            }
        }
    }
}

/// Task states shared by Codex auto-continue and Cooldown's own Claude tasks.
enum TaskStatus {
    static func title(_ status: String) -> String {
        switch status {
        case "starting": return "Запускается"
        case "watching": return "Задача выполняется"
        case "waiting_quota": return "Ждёт сброса лимита"
        case "waiting_connection": return "Ждёт подключения"
        case "needs_attention": return "Нужно ваше решение"
        case "resumed": return "Продолжение отправлено"
        case "stopped": return "Завершено"
        case "paused": return "Выключено вами"
        case "uncertain": return "Отправка не подтверждена"
        case "blocked": return "Нужна проверка"
        case "budget": return "Попытки закончились"
        case "changed": return "Задача изменилась"
        case "retrying": return "Повторная проверка"
        default: return "Статус неизвестен"
        }
    }

    static func needsAttention(_ status: String) -> Bool {
        ["needs_attention", "blocked", "uncertain", "changed"].contains(status)
    }
}
