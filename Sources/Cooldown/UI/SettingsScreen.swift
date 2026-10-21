import AppKit
import UniformTypeIdentifiers
import Combine
import SwiftUI
import UserNotifications

struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    @Binding var screen: Screen
    let render: Bool

    @AppStorage(SettingsKey.showPercent) private var showPercent = true
    @AppStorage(SettingsKey.menuSource) private var menuSource = "lowest"
    @AppStorage(SettingsKey.refreshInterval) private var refreshInterval: Double = 60
    @AppStorage(SettingsKey.notifyThresholds) private var notifyThresholds = true
    @AppStorage(SettingsKey.notifyReset) private var notifyReset = true
    @AppStorage(SettingsKey.notifyTasks) private var notifyTasks = true
    @AppStorage(SettingsKey.toasts) private var toasts = true
    @AppStorage(SettingsKey.notifyFinished) private var notifyFinished = true
    @AppStorage(SettingsKey.quietHours) private var quietHours = false
    @AppStorage(SettingsKey.quietFrom) private var quietFrom = 23 * 60
    @AppStorage(SettingsKey.quietTo) private var quietTo = 8 * 60
    private let hourOptions = Array(stride(from: 0, to: 24 * 60, by: 60))
    private func hourText(_ minutes: Int) -> String { String(format: "%02d:00", minutes / 60) }
    @AppStorage(SettingsKey.notifyAttention) private var notifyAttention = true
    @AppStorage(SettingsKey.watchClaudeWindow) private var watchClaudeWindow = true
    @AppStorage(SettingsKey.showActivity) private var showActivity = true
    @AppStorage(SettingsKey.quietWithFocus) private var quietWithFocus = true
    @AppStorage(SettingsKey.cardsWhenFront) private var cardsWhenFront = false
    @AppStorage(SettingsKey.notifyPace) private var notifyPace = true
    @AppStorage(SettingsKey.notifyProjects) private var notifyProjects = true
    @AppStorage(SettingsKey.weeklySummary) private var weeklySummary = true
    @AppStorage(SettingsKey.soundFinished) private var soundFinished = false
    @AppStorage(SettingsKey.soundAttention) private var soundAttention = false
    @AppStorage(SettingsKey.soundReset) private var soundReset = false
    @AppStorage(SettingsKey.claudeUsageCLI) private var claudeUsageCLI = true
    @AppStorage(SettingsKey.relayPath) private var relayPath = ""
    @AppStorage(SettingsKey.codexPath) private var codexPath = ""
    @AppStorage(SettingsKey.claudePath) private var claudePath = ""
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var statusLine = ClaudeStatusLine.isInstalled
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BackBar(title: "Настройки") { screen = .home }
                .padding(.horizontal, 14)
                .padding(.top, 14)
            let content = VStack(alignment: .leading, spacing: 16) {
                group("Готовность") { ReadinessList() }
                group("Значок в панели") {
                    Toggle("Проценты рядом с линиями", isOn: $showPercent).toggleStyle(.switch)
                    Divider().opacity(0.5)
                    Picker("Показывать", selection: $menuSource) {
                        Text("Codex и Claude").tag("lowest")
                        Text("Codex").tag("codex")
                        Text("Claude").tag("claude")
                    }
                    Divider().opacity(0.5)
                    Toggle("Показывать, когда агент работает", isOn: $showActivity)
                        .toggleStyle(.switch)
                        .onChange(of: showActivity) { _, _ in model.activityChanged() }
                    Text("По линии работающего агента пробегает мягкий свет; оранжевая точка у значка — агент ждёт вашего решения. Наведите на значок, чтобы увидеть, кто чем занят.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                group("Обновление и уведомления") {
                    Picker("Проверять лимиты", selection: $refreshInterval) {
                        Text("Каждые 30 секунд").tag(30.0)
                        Text("Каждую минуту").tag(60.0)
                        Text("Каждые 2 минуты").tag(120.0)
                        Text("Каждые 5 минут").tag(300.0)
                    }
                    Divider().opacity(0.5)
                    Toggle("Когда остаётся 20% и 5% (если вы не за Mac)", isOn: $notifyThresholds).toggleStyle(.switch)
                    Toggle("Когда лимит восстановился", isOn: $notifyReset).toggleStyle(.switch)
                    Toggle("О задачах автопродолжения", isOn: $notifyTasks).toggleStyle(.switch)
                    Toggle("Карточки под значком вместо баннеров", isOn: $toasts).toggleStyle(.switch)
                    Toggle("Когда агент закончил задачу дольше минуты", isOn: $notifyFinished).toggleStyle(.switch)
                    Toggle("Когда агент ждёт вашего решения", isOn: $notifyAttention).toggleStyle(.switch)
                    Toggle("Если лимит кончится раньше сброса", isOn: $notifyPace).toggleStyle(.switch)
                    Toggle("Когда проект съедает много недели", isOn: $notifyProjects).toggleStyle(.switch)
                    Toggle("Итоги недели в воскресенье вечером", isOn: $weeklySummary).toggleStyle(.switch)
                    Toggle("Карточки, даже если агент на экране", isOn: $cardsWhenFront).toggleStyle(.switch)
                    Text("Выключено: если вы в Codex или Claude и остаётесь там, Cooldown считает, что вы всё видели сами, и карточку не показывает (событие всё равно попадёт в «События»).")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider().opacity(0.5)
                    HStack(spacing: 6) {
                        Text("Звук карточки:")
                        Toggle("закончил", isOn: $soundFinished).toggleStyle(.button)
                        Toggle("ждёт", isOn: $soundAttention).toggleStyle(.button)
                        Toggle("лимит", isOn: $soundReset).toggleStyle(.button)
                    }
                    .font(.callout)
                    .onChange(of: soundFinished) { _, on in if on { CardSound.play(for: .finished) } }
                    .onChange(of: soundAttention) { _, on in if on { CardSound.play(for: .attention) } }
                    .onChange(of: soundReset) { _, on in if on { CardSound.play(for: .reset) } }
                    Divider().opacity(0.5)
                    Toggle("Молчать при фокусировке", isOn: $quietWithFocus).toggleStyle(.switch)
                    Text("Пока включён «Не беспокоить», «Сон» или другой режим фокусировки, всё копится в «Событиях», а потом придёт короткая сводка.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Тихие часы", isOn: $quietHours).toggleStyle(.switch)
                    if quietHours {
                        HStack {
                            Text("с")
                            Picker("", selection: $quietFrom) { ForEach(hourOptions, id: \.self) { Text(hourText($0)).tag($0) } }.labelsHidden().frame(width: 80)
                            Text("до")
                            Picker("", selection: $quietTo) { ForEach(hourOptions, id: \.self) { Text(hourText($0)).tag($0) } }.labelsHidden().frame(width: 80)
                            Spacer()
                        }
                        Text("Ночью без карточек и баннеров. Всё попадёт в «События», а утром придёт короткая сводка.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Показать примеры карточек") {
                        StatusController.shared?.close()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { ToastController.shared.showExamples() }
                    }.buttonStyle(.link)
                    Divider().opacity(0.5)
                    Toggle("Открывать при входе в систему", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { _, enabled in
                            do { try LoginItem.set(enabled) } catch {
                                message = "Автозапуск: \(error.localizedDescription)"
                                launchAtLogin = LoginItem.isEnabled
                            }
                        }
                }
                group("Claude") {
                    Toggle("Лимиты через Claude Code", isOn: $claudeUsageCLI)
                        .toggleStyle(.switch)
                        .onChange(of: claudeUsageCLI) { _, _ in Task { await model.refreshLimits() } }
                    Text("Cooldown открывает экран /usage в Claude Code раз в пару минут и закрывает его. Запросов к модели нет, токены не тратятся. Лимиты общие, поэтому видно и расход в Claude Desktop.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider().opacity(0.5)
                    ClaudeAccountRow(web: ClaudeWeb.shared)
                    Divider().opacity(0.5)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Строка статуса Claude Code")
                            Text(statusLine ? "Подключена, прежняя команда работает дальше." : "Не подключена. Нужна, только если вы работаете в Claude Code.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button(statusLine ? "Отключить" : "Подключить") { toggleStatusLine() }.buttonStyle(.glass)
                    }
                    Divider().opacity(0.5)
                    Toggle("Следить за ответами в Claude Desktop", isOn: $watchClaudeWindow).toggleStyle(.switch)
                    Text("Через «Универсальный доступ» Cooldown видит, что Claude пишет ответ в открытом чате, и скажет, когда закончит. Ничего не отправляет и не уходит в сеть.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider().opacity(0.5)
                    PathRow(label: "Программа claude", path: ClaudePaths.binary(override: claudePath)?.path ?? "не найдена",
                            ok: ClaudePaths.binary(override: claudePath) != nil) {
                        if let path = choose(directory: false) { claudePath = path }
                    }
                }
                group("Хуки агентов") {
                    HookRow(agent: .claude)
                    Divider().opacity(0.5)
                    HookRow(agent: .codex)
                    Text("Codex и Claude Code сами сообщают Cooldown, когда начали и закончили работу или ждут разрешения. Так карточки приходят сразу, а Claude Code тоже виден. Хук только дописывает строку в файл и выходит, работу агента не задерживает; хуки Coucou и других программ остаются как были.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if HomeAssistant.featureEnabled {
                    group("iPhone через Home Assistant") {
                        HomeAssistantRow()
                    }
                }
                group("Codex") {
                    PathRow(label: "Программа codex", path: CodexPaths.binary(override: codexPath)?.path ?? "не найдена",
                            ok: CodexPaths.binary(override: codexPath) != nil) {
                        if let path = choose(directory: false) {
                            codexPath = path
                            Task { await model.refreshLimits() }
                        }
                    }
                    Divider().opacity(0.5)
                    PathRow(label: "Папка Relay для автопродолжения", path: Settings.relayPath, ok: model.relayAvailable) {
                        if let path = choose(directory: true) {
                            relayPath = path
                            Task { await model.refreshRelay() }
                        }
                    }
                }
                group("Статистика") {
                    Text("Подробная статистика — из истории сессий Codex и Claude Code за 45 дней, итоги по дням для «Года работы» хранятся дольше. Всё только на этом Mac.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Сохранить по дням в таблицу (CSV)…") { exportCSV() }.buttonStyle(.link)
                    Button("Пересобрать статистику") {
                        Task {
                            await model.codex.scan(fullRebuild: true)
                            await model.claude.scan(fullRebuild: true)
                        }
                    }
                    .buttonStyle(.glass)
                }
                group("Как это работает") {
                    Text("Демо за минуту проигрывает всё по шагам на выдуманных данных: лимит кончается, задача ждёт и продолжается, приходят уведомления. Ничего никуда не отправляется, ваши данные потом вернутся.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button {
                        screen = .home
                        DemoController.shared.start()
                    } label: { Label("Показать демо", systemImage: "play.circle").frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.amber)
                }
                if let message { Note(symbol: "info.circle", text: message) }
                HStack {
                    Text("Cooldown \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Выйти из Cooldown") { NSApp.terminate(nil) }.buttonStyle(.glass)
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 16)

            if render { content } else { ScrollView(.vertical, showsIndicators: false) { content } }
        }
        .frame(maxHeight: render ? nil : .infinity, alignment: .top)
        .onChange(of: showPercent) { _, _ in model.updateMenuImage(animated: false) }
        .onChange(of: menuSource) { _, _ in model.updateMenuImage(animated: true) }
        .onChange(of: refreshInterval) { _, _ in model.schedule() }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: title)
            Well { content() }
        }
    }

    private func toggleStatusLine() {
        do {
            if statusLine { try ClaudeStatusLine.uninstall() } else { try ClaudeStatusLine.install() }
            statusLine = ClaudeStatusLine.isInstalled
            message = statusLine ? "Строка статуса подключена. Копия settings.json сохранена рядом с ним."
                                 : "Строка статуса возвращена как была."
        } catch {
            message = "Не получилось: \(error.localizedDescription)"
        }
    }

    /// Day-by-day totals as a table any spreadsheet opens.
    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "cooldown-\(DailyLog.key(Date())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var rows = ["date,codex_tokens,codex_usd,codex_week_percent,codex_done,claude_tokens,claude_usd,claude_week_percent,claude_done,claude_chats"]
        for (key, day) in DailyLog.shared.days.sorted(by: { $0.key < $1.key }) {
            rows.append([key, "\(day.codexTokens)", String(format: "%.2f", day.codexDollars), String(format: "%.1f", day.codexWeek), "\(day.codexDone)",
                         "\(day.claudeTokens)", String(format: "%.2f", day.claudeDollars), String(format: "%.1f", day.claudeWeek), "\(day.claudeDone)",
                         "\(day.chats)"].joined(separator: ","))
        }
        do {
            try (rows.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            message = "Сохранено: \(url.lastPathComponent)"
        } catch {
            message = "Не сохранилось: \(error.localizedDescription)"
        }
    }

    private func choose(directory: Bool) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

private struct ClaudeAccountRow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var web: ClaudeWeb

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Аккаунт claude.ai")
                Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if web.isConnected {
                Button("Выйти") { Task { await web.signOut(); await model.refreshLimits() } }.buttonStyle(.glass)
            } else {
                Button("Войти") { web.showLogin() }.buttonStyle(.glassProminent).tint(Theme.coral)
            }
        }
    }

    private var status: String {
        switch web.state {
        case .connected(let plan): return plan.map { "Подключён, план \($0). Лимиты и активность Claude Desktop." } ?? "Подключён. Лимиты и активность Claude Desktop."
        case .connecting: return "Жду входа в окне claude.ai."
        case .signedOut: return "Вход истёк, войдите снова."
        case .disconnected: return "Не подключён. Необязательно: лимиты уже идут через Claude Code."
        }
    }
}

private struct PathRow: View {
    let label: String
    let path: String
    let ok: Bool
    let choose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                Spacer()
                Button("Изменить…", action: choose).buttonStyle(.link)
            }
            Text(path)
                .font(.caption)
                .foregroundStyle(ok ? Color.secondary : Theme.amber)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Live Activity с лимитами на экране блокировки и уведомления о событиях, когда вы не за Mac. Доставляет приложение Home Assistant на iPhone.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("http://localhost:8123", text: $url).textFieldStyle(.roundedBorder)
            HStack {
                SecureField(hasToken ? "Токен сохранён в Связке ключей" : "Долгосрочный токен", text: $token)
                    .textFieldStyle(.roundedBorder)
                Button("Сохранить") {
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
            Toggle("Live Activity с лимитами", isOn: $live).toggleStyle(.switch)
            Toggle("Уведомления, когда вы не за Mac", isOn: $notify).toggleStyle(.switch)
            HStack {
                Button(busy ? "Отправляю…" : "Проверить на iPhone") { run() }
                    .buttonStyle(.glass)
                    .disabled(busy || !hasToken)
                Button("Виджет в Scriptable") {
                    do {
                        let address = try HomeAssistant.shared.installWidget()
                        ha.status = "Скрипт «Cooldown» добавлен в Scriptable через iCloud (адрес \(address)). На iPhone: долгое нажатие на экран → добавить виджет Scriptable → в настройках виджета выбрать скрипт Cooldown."
                    } catch { ha.status = error.localizedDescription }
                }
                .buttonStyle(.glass)
                .disabled(!hasToken)
            }
            if let status = ha.status {
                Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func run() {
        busy = true
        Task {
            await HomeAssistant.shared.test()
            busy = false
        }
    }
}

/// What works and what still needs a click, with the click right there.
private struct ReadinessList: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var usage = ClaudeUsageStatus.shared
    @State private var notifications: Bool?
    @State private var accessibility = ClaudeSender.hasPermission
    @State private var login = LoginItem.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Лимиты Codex", ok: model.codex.snapshot != nil, detail: model.codex.limitError)
            row("Лимиты Claude", ok: model.claude.snapshot != nil && !usage.needsPermission,
                detail: usage.needsPermission ? "Нужно разрешение для Claude Code — на вкладке Claude «Лимиты»." : model.claude.limitError)
            row("Автопродолжение Codex", ok: model.relayAvailable, detail: model.relayError)
            row("Уведомления", ok: notifications ?? true, detail: notifications == false ? "Выключены в Системных настройках." : nil) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
            }
            row("«Продолжить» для Claude", ok: accessibility,
                detail: accessibility ? nil : "Нужен «Универсальный доступ». Если Cooldown там уже включён, это запись от старой сборки: удалите её кнопкой «−» и нажмите «Исправить» ещё раз.") {
                ClaudeSender.requestPermission()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            row("Открывать при входе", ok: login, detail: nil) {
                try? LoginItem.set(true)
                login = LoginItem.isEnabled
            }
            Text("Горячая клавиша: ⌃⌥C открывает Cooldown. Правый клик по значку — быстрое меню.")
                .font(.caption).foregroundStyle(.secondary)
        }
        // Permissions are granted in System Settings while this screen is open: keep checking.
        .task {
            while !Task.isCancelled {
                // Hidden window: nothing to show, nothing to check.
                if !AppModel.shared.panelVisible { try? await Task.sleep(for: .seconds(2)); continue }
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                notifications = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                accessibility = ClaudeSender.hasPermission
                login = LoginItem.isEnabled
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func row(_ title: String, ok: Bool, detail: String?, fix: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Theme.mint : Theme.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if !ok, let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            if !ok, let fix { Button("Исправить", action: fix).buttonStyle(.link).font(.caption) }
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
                    Text(agent == .claude ? "Claude Code" : "Codex")
                    Text(caption).font(.caption).foregroundStyle(status == .off ? Color.secondary : statusColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(status == .off ? "Подключить" : "Отключить") { toggle() }.buttonStyle(.glass)
            }
            if case .needsTrust = status {
                Text("Откройте Codex: он попросит проверить новые хуки — разрешите хуки Cooldown. В терминале то же самое делает команда /hooks в codex.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Note(symbol: "exclamationmark.triangle.fill", text: error, color: Theme.amber) }
        }
        .onAppear { status = AgentHooks.status(agent) }
        .onReceive(timer) { _ in
            guard AppModel.shared.panelVisible else { return }
            let fresh = AgentHooks.status(agent)
            if fresh != status { status = fresh }
        }
    }

    private var caption: String {
        switch status {
        case .off: return "Не подключены"
        case .on: return HookEventReader.shared.lastEvent[agent].map { "Работают · последнее событие \(Format.relative($0))" } ?? "Подключены"
        case .needsTrust: return "Ждут вашего разрешения в Codex"
        }
    }

    private var statusColor: Color { status == .on ? Theme.mint : Theme.amber }

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
