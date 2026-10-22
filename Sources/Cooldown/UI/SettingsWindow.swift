import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: The window

/// Settings in a window of their own, laid out like System Settings: categories on the left,
/// grouped options on the right. While it is open Cooldown shows in the Dock and ⌘-Tab, so the
/// window is as easy to get back to as any other.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    let navigation = SettingsNavigation()
    private var window: NSWindow?

    func show(_ pane: SettingsPane? = nil) {
        if let pane { navigation.pane = pane }
        if window == nil { window = make() }
        StatusController.shared?.close()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    var isOpen: Bool { window?.isVisible == true }

    func setTitle(_ title: String) { window?.title = title }

    private func make() -> NSWindow {
        let root = SettingsRoot(navigation: navigation).environmentObject(AppModel.shared)
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = L("Настройки Cooldown")
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "settings")
        window.setContentSize(NSSize(width: 780, height: 580))
        window.contentMinSize = NSSize(width: 680, height: 460)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("CooldownSettings")
        if !window.setFrameUsingName("CooldownSettings") { window.center() }
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu bar app: no Dock icon once the window is gone.
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var pane: SettingsPane = .general
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, menubar, notifications, quiet, codex, claude, updates, data, diagnostics, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("Основные")
        case .menubar: return L("Строка меню")
        case .notifications: return L("Уведомления")
        case .quiet: return L("Тишина")
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .updates: return L("Обновления")
        case .data: return L("Статистика")
        case .diagnostics: return L("Диагностика")
        case .about: return L("О Cooldown")
        }
    }

    var subtitle: String {
        switch self {
        case .general: return L("Что уже работает, запуск и частота проверок")
        case .menubar: return L("Как выглядит значок и что он показывает")
        case .notifications: return L("Карточки, баннеры и звуки")
        case .quiet: return L("Фокусировка и тихие часы")
        case .codex: return L("Программа, хуки и автопродолжение")
        case .claude: return L("Источники лимитов, Claude Desktop и Claude Code")
        case .updates: return L("Новые версии с GitHub")
        case .data: return L("История, таблица и демо")
        case .diagnostics: return L("Проверить, что всё работает")
        case .about: return L("Версия, лицензия и благодарности")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .menubar: return "menubar.rectangle"
        case .notifications: return "bell.badge.fill"
        case .quiet: return "moon.fill"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .claude: return "sparkle"
        case .updates: return "arrow.down.circle.fill"
        case .data: return "chart.bar.fill"
        case .diagnostics: return "stethoscope"
        case .about: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: return Color(white: 0.55)
        case .menubar: return Color(red: 0.22, green: 0.5, blue: 0.98)
        case .notifications: return Color(red: 0.98, green: 0.27, blue: 0.3)
        case .quiet: return Color(red: 0.36, green: 0.33, blue: 0.9)
        case .codex: return Color(red: 0.25, green: 0.36, blue: 0.92)
        case .claude: return Color(red: 0.86, green: 0.47, blue: 0.32)
        case .updates: return Color(red: 0.2, green: 0.72, blue: 0.4)
        case .data: return Color(red: 0.62, green: 0.36, blue: 0.9)
        case .diagnostics: return Color(red: 0.1, green: 0.66, blue: 0.7)
        case .about: return Color(white: 0.45)
        }
    }

    /// Words to find this pane by in the sidebar's search.
    var keywords: String {
        switch self {
        case .general: return L("готовность разрешения автозапуск вход горячая клавиша частота проверка лимитов")
        case .menubar: return L("значок проценты линии свечение активность")
        case .notifications: return L("карточки баннеры звуки лимит сброс задачи запросы разрешения итоги проекты")
        case .quiet: return L("фокус не беспокоить сон ночь тихие часы")
        case .codex: return L("codex путь хуки автопродолжение")
        case .claude: return L("claude code desktop usage аккаунт строка статуса хуки окно")
        case .updates: return L("версия github обновить скачивать")
        case .data: return L("csv таблица экспорт пересобрать демо iphone home assistant")
        case .diagnostics: return L("проверка отчёт ошибки не работает тест")
        case .about: return L("лицензия mit благодарности выйти")
        }
    }
}

// MARK: Layout

private struct SettingsRoot: View {
    @ObservedObject var navigation: SettingsNavigation
    @State private var search = ""

    private var panes: [SettingsPane] {
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return SettingsPane.allCases }
        return SettingsPane.allCases.filter { "\($0.title) \($0.subtitle) \($0.keywords)".lowercased().contains(term) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { navigation.pane }, set: { if let pane = $0 { navigation.pane = pane } })) {
                ForEach(panes) { pane in
                    Label {
                        Text(pane.title)
                    } icon: {
                        PaneIcon(pane: pane, size: 22)
                    }
                    .tag(pane)
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: L("Поиск"))
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            PaneView(pane: navigation.pane)
                .id(navigation.pane)
        }
        .frame(minWidth: 680, minHeight: 460)
        // Like System Settings: the window is named after the open category.
        .onChange(of: navigation.pane, initial: true) { _, pane in SettingsWindow.shared.setTitle(pane.title) }
    }
}

private struct PaneIcon: View {
    let pane: SettingsPane
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(pane.color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: pane.symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: pane.color.opacity(0.25), radius: size * 0.1, y: size * 0.04)
    }
}

private struct PaneView: View {
    let pane: SettingsPane

    var body: some View {
        Form {
            if pane != .about {
            Section {
                HStack(spacing: 14) {
                    PaneIcon(pane: pane, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pane.title).font(.system(size: 20, weight: .bold))
                        Text(pane.subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            }
            switch pane {
            case .general: GeneralPane()
            case .menubar: MenuBarPane()
            case .notifications: NotificationsPane()
            case .quiet: QuietPane()
            case .codex: CodexPane()
            case .claude: ClaudePane()
            case .updates: UpdatesPane()
            case .data: DataPane()
            case .diagnostics: DiagnosticsPane()
            case .about: AboutPane()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// A switch with a line of explanation under its title, the way System Settings writes them.
private struct OptionToggle: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
            if let detail { Text(detail) }
        }
        .toggleStyle(.switch)
    }
}

private struct Footnote: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Основные

private struct GeneralPane: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(SettingsKey.refreshInterval) private var refreshInterval: Double = 60
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var problem: String?

    var body: some View {
        Section(L("Готовность")) { ReadinessRows() }
        Section {
            OptionToggle(title: L("Открывать при входе в систему"), detail: L("Cooldown запустится сам после перезагрузки Mac."), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do { try LoginItem.set(enabled) } catch {
                        problem = L("Автозапуск: %@", "\(error.localizedDescription)")
                        launchAtLogin = LoginItem.isEnabled
                    }
                }
            Picker(selection: $refreshInterval) {
                Text(L("Каждые 30 секунд")).tag(30.0)
                Text(L("Каждую минуту")).tag(60.0)
                Text(L("Каждые 2 минуты")).tag(120.0)
                Text(L("Каждые 5 минут")).tag(300.0)
            } label: {
                Text(L("Проверять лимиты, пока окно открыто"))
                Text(L("В остальное время Cooldown узнаёт о работе агентов по событиям и не тратит ресурсы."))
            }
            .onChange(of: refreshInterval) { _, _ in model.schedule() }
            LabeledContent(L("Открыть Cooldown")) {
                Text("⌃⌥C").font(.system(.body, design: .rounded).weight(.semibold)).foregroundStyle(.secondary)
            }
            LabeledContent(L("Быстрое меню")) { Text(L("Правый клик по значку")).foregroundStyle(.secondary) }
            if let problem { Footnote(text: problem) }
        } header: { Text(L("Запуск")) }
    }
}

/// What works and what still needs a click, one row each, with the fix right there.
private struct ReadinessRows: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var usage = ClaudeUsageStatus.shared
    @StateObject private var state = ReadinessState()

    var body: some View {
        Group {
            row(L("Лимиты Codex"), symbol: "gauge.with.dots.needle.67percent", ok: model.codex.snapshot != nil, detail: model.codex.limitError)
            row(L("Лимиты Claude"), symbol: "gauge.with.dots.needle.33percent", ok: model.claude.snapshot != nil && !usage.needsPermission,
                detail: usage.needsPermission ? L("Нужно разрешение для Claude Code — на главном окне, вкладка Claude.") : model.claude.limitError)
            row(L("Автопродолжение Codex"), symbol: "arrow.triangle.2.circlepath", ok: model.relayAvailable, detail: model.relayError)
            row(L("Уведомления"), symbol: "bell", ok: state.notifications ?? true,
                detail: state.notifications == false ? L("Выключены в Системных настройках.") : nil) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
            }
            row(L("Универсальный доступ"), symbol: "accessibility", ok: state.accessibility,
                detail: state.accessibility ? nil : L("Нужен, чтобы видеть ответы Claude Desktop, продолжать чаты и отвечать на запросы. Если Cooldown там уже включён, удалите запись кнопкой «−» и нажмите «Исправить» снова.")) {
                ClaudeSender.requestPermission()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
        .onAppear { state.start() }
        .onDisappear { state.stop() }
    }

    private func row(_ title: String, symbol: String, ok: Bool, detail: String?, fix: (() -> Void)? = nil) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !ok, let detail { Footnote(text: detail) }
            }
            Spacer()
            if ok {
                Label(L("Работает"), systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(Theme.mint)
                    .help(L("Работает"))
            } else if let fix {
                Button(L("Исправить"), action: fix)
            } else {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.amber)
            }
        }
    }
}

/// Permissions get granted in System Settings while this pane is open: keep looking.
@MainActor
private final class ReadinessState: ObservableObject {
    @Published var notifications: Bool?
    @Published var accessibility = ClaudeSender.hasPermission
    private var task: Task<Void, Never>?

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                self?.notifications = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                self?.accessibility = ClaudeSender.hasPermission
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() { task?.cancel() }
}

// MARK: Строка меню

private struct MenuBarPane: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(SettingsKey.showPercent) private var showPercent = true
    @AppStorage(SettingsKey.menuSource) private var menuSource = "lowest"
    @AppStorage(SettingsKey.showActivity) private var showActivity = true
    @State private var image: NSImage?

    var body: some View {
        Section {
            HStack {
                Spacer()
                // The icon as it is in the menu bar right now.
                HStack(spacing: 14) {
                    Image(systemName: "wifi").foregroundStyle(.white.opacity(0.85))
                    if let image { Image(nsImage: image) }
                    Text(Date(), format: .dateTime.hour().minute()).foregroundStyle(.white.opacity(0.9))
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 16)
                .frame(height: 30)
                .background(Capsule().fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)))
                .environment(\.colorScheme, .dark)
                Spacer()
            }
            .padding(.vertical, 10)
        } footer: {
            Footnote(text: L("Так значок выглядит сейчас. Верхняя линия — Codex, нижняя — Claude; длина — сколько осталось на 5 часов."))
        }
        Section {
            OptionToggle(title: L("Проценты рядом с линиями"), isOn: $showPercent)
            Picker(L("Показывать"), selection: $menuSource) {
                Text(L("Codex и Claude")).tag("lowest")
                Text(L("Только Codex")).tag("codex")
                Text(L("Только Claude")).tag("claude")
            }
            OptionToggle(title: L("Показывать, когда агент работает"),
                         detail: L("По линии работающего агента пробегает мягкий свет; оранжевая точка — агент ждёт вашего решения."),
                         isOn: $showActivity)
        }
        .onChange(of: showPercent) { _, _ in model.updateMenuImage(animated: false) }
        .onChange(of: menuSource) { _, _ in model.updateMenuImage(animated: true) }
        .onChange(of: showActivity) { _, _ in model.activityChanged() }
        .onAppear { image = model.menuImage }
        .onReceive(model.menuImageChanges.throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true)) { image = $0 }
    }
}

// MARK: Уведомления

private struct NotificationsPane: View {
    @AppStorage(SettingsKey.toasts) private var toasts = true
    @AppStorage(SettingsKey.cardsWhenFront) private var cardsWhenFront = false
    @AppStorage(SettingsKey.notifyThresholds) private var notifyThresholds = true
    @AppStorage(SettingsKey.notifyReset) private var notifyReset = true
    @AppStorage(SettingsKey.notifyPace) private var notifyPace = true
    @AppStorage(SettingsKey.notifyFinished) private var notifyFinished = true
    @AppStorage(SettingsKey.notifyAttention) private var notifyAttention = true
    @AppStorage(SettingsKey.notifyTasks) private var notifyTasks = true
    @AppStorage(SettingsKey.weeklySummary) private var weeklySummary = true
    @AppStorage(SettingsKey.notifyProjects) private var notifyProjects = true
    @AppStorage(SettingsKey.soundFinished) private var soundFinished = false
    @AppStorage(SettingsKey.soundAttention) private var soundAttention = false
    @AppStorage(SettingsKey.soundReset) private var soundReset = false

    var body: some View {
        Section {
            OptionToggle(title: L("Карточки под значком"), detail: L("Стеклянные карточки с кнопками. Выключено — обычные баннеры macOS."), isOn: $toasts)
            OptionToggle(title: L("Даже если агент на экране"),
                         detail: L("Выключено: пока вы в Codex или Claude, Cooldown считает, что вы видите всё сами. Событие всё равно попадёт в ленту."),
                         isOn: $cardsWhenFront)
            HStack {
                Spacer()
                Button(L("Показать примеры карточек")) { ToastController.shared.showExamples() }
            }
        } header: { Text(L("Как показывать")) }
        Section(L("Лимиты")) {
            OptionToggle(title: L("Осталось 20% и 5%"), detail: L("Только когда вас нет за Mac или карточка может что-то изменить."), isOn: $notifyThresholds)
            OptionToggle(title: L("Лимит восстановился"), isOn: $notifyReset)
            OptionToggle(title: L("Лимит кончится раньше сброса"), detail: L("Если в вашем темпе окно закончится до времени сброса."), isOn: $notifyPace)
        }
        Section(L("Агенты")) {
            OptionToggle(title: L("Агент закончил задачу"), detail: L("Для задач дольше минуты, с последними словами агента."), isOn: $notifyFinished)
            OptionToggle(title: L("Агент ждёт вашего решения"),
                         detail: L("Разрешения и вопросы Codex, Claude Code и чатов Claude — с кнопками ответа прямо на карточке."),
                         isOn: $notifyAttention)
            OptionToggle(title: L("Автопродолжение"), detail: L("Задача ждёт сброса, продолжена или требует проверки."), isOn: $notifyTasks)
        }
        Section(L("Сводки")) {
            OptionToggle(title: L("Итоги недели"), detail: L("В воскресенье вечером."), isOn: $weeklySummary)
            OptionToggle(title: L("Проект съедает много недели"), detail: L("Только для Codex."), isOn: $notifyProjects)
        }
        Section {
            OptionToggle(title: L("Задача закончена"), isOn: $soundFinished)
                .onChange(of: soundFinished) { _, on in if on { CardSound.play(for: .finished) } }
            OptionToggle(title: L("Агент ждёт вас"), isOn: $soundAttention)
                .onChange(of: soundAttention) { _, on in if on { CardSound.play(for: .attention) } }
            OptionToggle(title: L("Лимит восстановился"), isOn: $soundReset)
                .onChange(of: soundReset) { _, on in if on { CardSound.play(for: .reset) } }
        } header: { Text(L("Звук карточки")) } footer: { Footnote(text: L("Включённый звук сразу проигрывается, чтобы его можно было услышать.")) }
    }
}

// MARK: Тишина

private struct QuietPane: View {
    @AppStorage(SettingsKey.quietWithFocus) private var quietWithFocus = true
    @AppStorage(SettingsKey.quietHours) private var quietHours = false
    @AppStorage(SettingsKey.quietFrom) private var quietFrom = 23 * 60
    @AppStorage(SettingsKey.quietTo) private var quietTo = 8 * 60
    private let hours = Array(stride(from: 0, to: 24 * 60, by: 60))

    var body: some View {
        Section {
            OptionToggle(title: L("Молчать при фокусировке"),
                         detail: L("Пока включён «Не беспокоить», «Сон» или другой режим, всё копится в ленте, а потом приходит короткая сводка."),
                         isOn: $quietWithFocus)
        }
        Section {
            OptionToggle(title: L("Тихие часы"), detail: L("Ночью без карточек и баннеров; утром — сводка."), isOn: $quietHours)
            if quietHours {
                Picker(L("С"), selection: $quietFrom) { ForEach(hours, id: \.self) { Text(Self.text($0)).tag($0) } }
                Picker(L("До"), selection: $quietTo) { ForEach(hours, id: \.self) { Text(Self.text($0)).tag($0) } }
            }
        } footer: {
            Footnote(text: L("Карточки с запросами агентов в тишину тоже не показываются: запрос подождёт и будет в ленте."))
        }
    }

    static func text(_ minutes: Int) -> String { String(format: "%02d:00", minutes / 60) }
}

// MARK: Codex

private struct CodexPane: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(SettingsKey.codexPath) private var codexPath = ""

    var body: some View {
        Section {
            PathRow(label: L("Программа codex"), path: CodexPaths.binary(override: codexPath)?.path, choose: {
                if let path = chooseFile() {
                    codexPath = path
                    Task { await model.refreshLimits() }
                }
            })
            LabeledContent(L("Приложение Codex")) {
                Text(CodexApp.url.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? L("не найдено"))
                    .foregroundStyle(CodexApp.url == nil ? Theme.amber : .secondary)
            }
        } header: { Text(L("Где Codex")) } footer: {
            Footnote(text: L("Лимиты Codex идут из его файлов сессий, пока он работает, и из `codex app-server` — в остальное время."))
        }
        Section {
            HookRow(agent: .codex)
        } header: { Text(L("Хуки")) } footer: {
            Footnote(text: L("Codex сам сообщает Cooldown, когда начал и закончил работу или ждёт разрешения. Хук только дописывает строку в файл и выходит; хуки других программ остаются как были."))
        }
        Section {
            LabeledContent(L("Под наблюдением")) {
                Text(L("%@ из %@", "\(model.watches.filter(\.enabled).count)", "\(model.watches.count)")).foregroundStyle(.secondary)
            }
            if let error = model.relayError { Footnote(text: error) }
            HStack {
                Spacer()
                Button(L("Открыть задачи")) {
                    AppModel.shared.selected = .codex
                    StatusController.shared?.open()
                }
            }
        } header: { Text(L("Автопродолжение")) } footer: {
            Footnote(text: L("Задача, упёршаяся в лимит, продолжается сама сразу после сброса — одно сообщение на раунд, без одобрений за вас. Включается для каждой задачи на вкладке «Задачи»."))
        }
    }
}

// MARK: Claude

private struct ClaudePane: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(SettingsKey.claudeUsageCLI) private var claudeUsageCLI = true
    @AppStorage(SettingsKey.watchClaudeWindow) private var watchClaudeWindow = true
    @AppStorage(SettingsKey.claudePath) private var claudePath = ""
    @State private var statusLine = ClaudeStatusLine.isInstalled
    @State private var message: String?

    var body: some View {
        Section {
            OptionToggle(title: L("Через Claude Code"),
                         detail: L("Cooldown открывает экран /usage в Claude Code и сразу закрывает. Запросов к модели нет, токены не тратятся; лимиты общие для всей подписки."),
                         isOn: $claudeUsageCLI)
                .onChange(of: claudeUsageCLI) { _, _ in Task { await model.refreshLimits() } }
            ClaudeAccountRow(web: ClaudeWeb.shared)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Строка статуса Claude Code"))
                    Footnote(text: statusLine ? L("Подключена, прежняя команда работает дальше.") : L("Даёт самые свежие цифры, пока вы работаете в Claude Code."))
                }
                Spacer()
                Button(statusLine ? L("Отключить") : L("Подключить")) { toggleStatusLine() }
            }
            if let message { Footnote(text: message) }
        } header: { Text(L("Откуда брать лимиты")) }
        Section {
            OptionToggle(title: L("Следить за ответами в чатах"),
                         detail: L("Через «Универсальный доступ» Cooldown видит, что Claude пишет ответ или просит разрешение. Ничего не уходит в сеть."),
                         isOn: $watchClaudeWindow)
        } header: { Text("Claude Desktop") }
        Section {
            HookRow(agent: .claude)
            PathRow(label: L("Программа claude"), path: ClaudePaths.binary(override: claudePath)?.path, choose: {
                if let path = chooseFile() { claudePath = path }
            })
        } header: { Text("Claude Code") } footer: {
            Footnote(text: L("Хуки сообщают, когда Claude Code работает, и приносят его запросы разрешений в карточки, пока вы в другом приложении. В самом терминале он спрашивает как обычно."))
        }
    }

    private func toggleStatusLine() {
        do {
            if statusLine { try ClaudeStatusLine.uninstall() } else { try ClaudeStatusLine.install() }
            statusLine = ClaudeStatusLine.isInstalled
            message = statusLine ? L("Подключена. Копия settings.json сохранена рядом с ним.") : L("Строка статуса возвращена как была.")
        } catch {
            message = L("Не получилось: %@", "\(error.localizedDescription)")
        }
    }
}

private struct ClaudeAccountRow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var web: ClaudeWeb

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Аккаунт claude.ai"))
                Footnote(text: status)
            }
            Spacer()
            if web.isConnected {
                Button(L("Выйти")) { Task { await web.signOut(); await model.refreshLimits() } }
            } else {
                Button(L("Войти")) { web.showLogin() }
            }
        }
    }

    private var status: String {
        switch web.state {
        case .connected(let plan): return plan.map { L("Подключён, план %@.", "\($0)") } ?? L("Подключён.")
        case .connecting: return L("Жду входа в окне claude.ai.")
        case .signedOut: return L("Вход истёк, войдите снова.")
        case .disconnected: return L("Необязательно: добавляет лимиты по моделям и список чатов.")
        }
    }
}

// MARK: Обновления

private struct UpdatesPane: View {
    @AppStorage(SettingsKey.updateMode) private var updateMode = Settings.updateMode
    @ObservedObject private var updater = GitHubUpdater.shared

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cooldown \(GitHubUpdater.current)").font(.headline)
                    if let available = updater.available {
                        Text(updater.readyVersion == available.version ? L("Версия %@ загружена и готова", "\(available.version)") : L("Доступна версия %@", "\(available.version)"))
                            .font(.callout).foregroundStyle(Theme.mint)
                    } else {
                        Text(updater.state ?? L("Установлена эта версия")).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if updater.available != nil {
                    Button(L("Обновить")) { Task { await updater.install() } }.buttonStyle(.borderedProminent)
                } else {
                    Button(updater.checking ? L("Проверяю…") : L("Проверить")) { Task { await updater.check(manual: true) } }
                        .disabled(updater.checking)
                }
            }
            .padding(.vertical, 2)
        }
        Section {
            Picker(L("Новые версии"), selection: $updateMode) {
                Text(L("Не проверять")).tag("off")
                Text(L("Только скачивать")).tag("download")
                Text(L("Скачивать и ставить")).tag("auto")
            }
            .pickerStyle(.radioGroup)
            .onChange(of: updateMode) { _, _ in updater.modeChanged() }
        } footer: {
            Footnote(text: updateMode == "off"
                     ? L("Cooldown сам не проверяет новые версии; кнопка «Проверить» работает всегда.")
                     : updateMode == "download"
                     ? L("Новая версия загружается и проверяется заранее, а ставится одним нажатием — на карточке или здесь.")
                     : L("Новая версия ставится сама, когда Mac пару минут без дела. Перед установкой проверяются контрольная сумма и подпись тем же сертификатом."))
        }
        if let release = updater.available, !release.notes.isEmpty {
            Section(L("Что нового в %@", "\(release.version)")) {
                Text(release.notes.components(separatedBy: "\n---").first ?? release.notes)
                    .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button(L("Открыть на GitHub")) { updater.openReleasePage() }.buttonStyle(.link)
            }
        }
    }
}

// MARK: Статистика

private struct DataPane: View {
    @EnvironmentObject private var model: AppModel
    @State private var message: String?
    @State private var rebuilding = false

    var body: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Таблица по дням"))
                    Footnote(text: L("Токены, деньги и доля недели для Codex и Claude — CSV для Numbers или Excel."))
                }
                Spacer()
                Button(L("Сохранить…")) { exportCSV() }
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Пересобрать статистику"))
                    Footnote(text: L("Заново прочитать историю сессий, если цифры кажутся неверными."))
                }
                Spacer()
                Button(rebuilding ? L("Читаю…") : L("Пересобрать")) {
                    rebuilding = true
                    Task {
                        await model.codex.scan(fullRebuild: true)
                        await model.claude.scan(fullRebuild: true)
                        rebuilding = false
                        message = L("Статистика пересобрана.")
                    }
                }
                .disabled(rebuilding)
            }
            if let message { Footnote(text: message) }
        } header: { Text(L("История")) } footer: {
            Footnote(text: L("Подробности — из сессий Codex и Claude Code за 45 дней; итоги по дням для «Года работы» хранятся дольше. Всё только на этом Mac."))
        }
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Демо"))
                    Footnote(text: L("За минуту по шагам на выдуманных данных: лимит кончается, задача ждёт и продолжается. Ваши данные потом вернутся."))
                }
                Spacer()
                Button(L("Показать")) {
                    StatusController.shared?.open()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { DemoController.shared.start() }
                }
            }
        }
        if HomeAssistant.featureEnabled {
            Section(L("iPhone через Home Assistant")) { HomeAssistantRow() }
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "cooldown-\(DailyLog.key(Date())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var rows = ["date,codex_tokens,codex_usd,codex_week_percent,codex_done,claude_tokens,claude_usd,claude_week_percent,claude_done,claude_chats"]
        for (key, day) in DailyLog.shared.days.sorted(by: { $0.key < $1.key }) {
            rows.append([key, "\(day.codexTokens)", String(format: "%.2f", day.codexDollars), String(format: "%.1f", day.codexWeek), "\(day.codexDone)",
                         "\(day.claudeTokens)", String(format: "%.2f", day.claudeDollars), String(format: "%.1f", day.claudeWeek), "\(day.claudeDone)",
                         "\(day.chats)"].joined(separator: ","))
        }
        do {
            try (rows.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            message = L("Сохранено: %@", "\(url.lastPathComponent)")
        } catch {
            message = L("Не сохранилось: %@", "\(error.localizedDescription)")
        }
    }
}

// MARK: Диагностика

private struct DiagnosticsPane: View {
    @ObservedObject private var diagnostics = Diagnostics.shared
    @State private var copied = false

    var body: some View {
        Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.headline)
                    Footnote(text: L("Cooldown по очереди пробует каждое звено: приложения, лимиты, хуки, окно Claude, уведомления, обновления и свои правила безопасности. Ничего не отправляет и не меняет."))
                }
                Spacer()
                Button {
                    diagnostics.run()
                } label: {
                    if diagnostics.running { ProgressView().controlSize(.small) } else { Text(diagnostics.checks.isEmpty ? L("Проверить всё") : L("Проверить снова")) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(diagnostics.running)
            }
            .padding(.vertical, 2)
        }
        if !diagnostics.checks.isEmpty {
            Section {
                ForEach(diagnostics.checks) { check in
                    HStack(alignment: .top, spacing: 10) {
                        icon(check.verdict).frame(width: 18).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title)
                            if !check.detail.isEmpty { Footnote(text: check.detail) }
                            if let advice = check.advice {
                                Text(advice).font(.caption).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                        if let millis = check.millis, millis > 300 {
                            Text(String(format: L("%.1f с"), Double(millis) / 1000)).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                        }
                    }
                }
            } footer: {
                HStack {
                    Spacer()
                    Button(copied ? L("Скопировано") : L("Скопировать отчёт")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnostics.report, forType: .string)
                        copied = true
                    }
                    .disabled(diagnostics.running)
                }
            }
        }
    }

    private var headline: String {
        if diagnostics.running { return L("Проверяю…") }
        guard diagnostics.finished != nil else { return L("Проверка всех связей") }
        let summary = diagnostics.summary
        if summary.failed == 0 && summary.warnings == 0 { return L("Всё работает") }
        var parts: [String] = []
        if summary.failed > 0 { parts.append(L("не работает: %@", "\(summary.failed)")) }
        if summary.warnings > 0 { parts.append(L("стоит посмотреть: %@", "\(summary.warnings)")) }
        return parts.joined(separator: ", ").capitalizedFirst
    }

    @ViewBuilder
    private func icon(_ verdict: Diagnostics.Verdict) -> some View {
        switch verdict {
        case .running: ProgressView().controlSize(.mini)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.mint)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.signal)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}

// MARK: О Cooldown

private struct AboutPane: View {
    private var repo: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "CooldownUpdateRepo") as? String).flatMap { URL(string: "https://github.com/\($0)") }
    }

    var body: some View {
        Section {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                Text("Cooldown").font(.system(size: 22, weight: .bold))
                Text(L("Версия %@", "\(GitHubUpdater.current)")).foregroundStyle(.secondary)
                Text(L("Лимиты, работа агентов и автопродолжение для Codex и Claude — в строке меню."))
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).font(.callout)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        Section {
            if let repo { Link(destination: repo) { LabeledContent(L("Исходный код"), value: "GitHub") } }
            LabeledContent(L("Лицензия"), value: "MIT")
            LabeledContent(L("Автопродолжение Codex")) {
                Link(L("по мотивам codex-auto-resume (MIT)"), destination: URL(string: "https://github.com/progressrdx/codex-auto-resume")!)
            }
        }
        Section {
            HStack {
                Spacer()
                Button(L("Выйти из Cooldown"), role: .destructive) { NSApp.terminate(nil) }
            }
        }
    }
}

// MARK: Shared rows

private func chooseFile() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    return panel.runModal() == .OK ? panel.url?.path : nil
}

private struct PathRow: View {
    let label: String
    let path: String?
    let choose: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? L("не найдена"))
                    .font(.caption)
                    .foregroundStyle(path == nil ? Theme.amber : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(L("Изменить…"), action: choose)
        }
    }
}

private struct HookRow: View {
    let agent: AgentHooks.Agent
    @State private var status: AgentHooks.Status = .off
    @State private var error: String?
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent == .claude ? L("Хуки Claude Code") : L("Хуки Codex"))
                    HStack(spacing: 5) {
                        Circle().fill(dot).frame(width: 7, height: 7)
                        Text(caption).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(status == .off ? L("Подключить") : L("Отключить")) { toggle() }
            }
            if case .needsTrust = status {
                Footnote(text: L("Откройте Codex: он попросит проверить новые хуки — разрешите хуки Cooldown. В терминале то же делает команда /hooks."))
            }
            if let error { Footnote(text: error) }
        }
        .onAppear { status = AgentHooks.status(agent) }
        .onReceive(timer) { _ in
            let fresh = AgentHooks.status(agent)
            if fresh != status { status = fresh }
        }
    }

    private var dot: Color {
        switch status {
        case .off: return .secondary.opacity(0.5)
        case .on: return Theme.mint
        case .needsTrust: return Theme.amber
        }
    }

    private var caption: String {
        switch status {
        case .off: return L("Не подключены")
        case .on: return HookEventReader.shared.lastEvent[agent].map { L("Работают · последнее событие %@", "\(Format.relative($0))") } ?? L("Подключены")
        case .needsTrust: return L("Ждут вашего разрешения в Codex")
        }
    }

    private func toggle() {
        error = nil
        do {
            if status == .off { try AgentHooks.install(agent) } else { try AgentHooks.uninstall(agent) }
        } catch {
            self.error = error.localizedDescription
        }
        status = AgentHooks.status(agent)
    }
}

private struct HomeAssistantRow: View {
    @ObservedObject private var ha = HomeAssistant.shared
    @AppStorage(SettingsKey.haURL) private var url = ""
    @AppStorage(SettingsKey.haDevice) private var device = ""
    @AppStorage(SettingsKey.haLive) private var live = true
    @AppStorage(SettingsKey.haNotify) private var notify = true
    @State private var token = ""
    @State private var hasToken = !(HomeAssistant.token ?? "").isEmpty
    @State private var busy = false

    var body: some View {
        TextField(L("Адрес"), text: $url, prompt: Text("http://localhost:8123"))
        HStack {
            SecureField(L("Токен"), text: $token, prompt: Text(hasToken ? L("Сохранён в Связке ключей") : L("Долгосрочный токен")))
            Button(L("Сохранить")) {
                HomeAssistant.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
                token = ""
                hasToken = !(HomeAssistant.token ?? "").isEmpty
                run()
            }
            .disabled(token.isEmpty)
        }
        if !ha.devices.isEmpty {
            Picker("iPhone", selection: $device) {
                ForEach(ha.devices, id: \.self) { Text($0.replacingOccurrences(of: "mobile_app_", with: "")).tag($0) }
            }
        }
        OptionToggle(title: L("Live Activity с лимитами"), isOn: $live)
        OptionToggle(title: L("Уведомления, когда вы не за Mac"), isOn: $notify)
        HStack {
            Spacer()
            Button(busy ? L("Отправляю…") : L("Проверить на iPhone")) { run() }.disabled(busy || !hasToken)
            Button(L("Виджет в Scriptable")) {
                do {
                    let address = try HomeAssistant.shared.installWidget()
                    ha.status = L("Скрипт «Cooldown» добавлен в Scriptable через iCloud (адрес %@).", "\(address)")
                } catch { ha.status = error.localizedDescription }
            }
            .disabled(!hasToken)
        }
        if let status = ha.status { Footnote(text: status) }
    }

    private func run() {
        busy = true
        Task {
            await HomeAssistant.shared.test()
            busy = false
        }
    }
}
