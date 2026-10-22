import AppKit
import SwiftUI

/// One row in a task list, the same for Codex (Relay) and Claude.
struct TaskItem: Identifiable, Equatable {
    var id: String
    var title: String
    var status: String
    var reason: String
    var attempts: Int
    var maxResumes: Int
    var enabled: Bool
    var updated: Date
}

struct TasksTab: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: ProviderStore
    @ObservedObject var tasks: ClaudeTaskManager
    @Binding var screen: Screen
    let render: Bool

    var body: some View {
        let items = self.items
        let active = items.filter(\.enabled)
        let recent = items.filter { !$0.enabled }.sorted { $0.updated > $1.updated }.prefix(4)

        TabScroll(render: render) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Автопродолжение").font(.system(size: 17, weight: .semibold))
                    .task { if store.id == .codex { await model.loadThreads(force: false, maxAge: 60) } }
                Text(store.id == .codex
                     ? "Задача, которая упёрлась в лимит, продолжится в том же диалоге Codex сразу после сброса."
                     : "Что Cooldown делает, когда лимит Claude восстанавливается.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)

            if store.id == .claude {
                AgentNowSection(provider: .claude)
                ClaudeDesktopCard()
                ClaudeChatsSection(screen: $screen)
                if usesClaudeCode {
                    SectionTitle(text: "Claude Code — продолжает сам")
                    Text("Сессии Claude Code в терминале или во вкладке Code. После сброса лимита Cooldown продолжит их сам, без вашего нажатия.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
            }

            if store.id == .codex, let error = model.relayError {
                Well { Note(symbol: "exclamationmark.triangle", text: error, color: Theme.amber) }
            }

            if store.id == .codex || usesClaudeCode {
                if active.isEmpty {
                    Well {
                        VStack(spacing: 6) {
                            Image(systemName: "hourglass").font(.system(size: 22, weight: .light)).foregroundStyle(.secondary)
                            Text("Сейчас ни одна задача не ждёт сброса.").font(.callout).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                } else {
                    Well(padding: 12) {
                        ForEach(Array(active.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().opacity(0.5) }
                            TaskRow(item: item, provider: store.id)
                        }
                    }
                }

                if store.id == .codex, !working.isEmpty {
                    SectionTitle(text: "Сейчас работают в Codex")
                    Well(padding: 12) {
                        ForEach(Array(working.enumerated()), id: \.element.id) { index, thread in
                            if index > 0 { Divider().opacity(0.5) }
                            HStack(spacing: 10) {
                                Circle().fill(Theme.mint).frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(thread.title).lineLimit(1)
                                    Text("\(Stats.projectName(thread.cwd ?? "")), \(thread.updatedAt.map { Format.relative($0) } ?? "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Button("Подключить") {
                                    model.pendingThread = thread
                                    screen = .addTask
                                }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                            }
                        }
                    }
                    Text("Эти диалоги без автопродолжения. «Подключить» — и если упрутся в лимит, Cooldown продолжит их после сброса.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }

                Button {
                    AddTaskScreen.wantsClaudeCode = store.id == .claude
                    screen = .addTask
                } label: {
                    Label(store.id == .claude ? "Добавить сессию Claude Code" : "Добавить задачу", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(store.tint)
                .controlSize(.large)
                .disabled(store.id == .codex && !model.relayAvailable)
            }

            if store.id == .codex {
                ScheduledSection(screen: $screen)
            }

            if !recent.isEmpty {
                SectionTitle(text: "Недавние")
                Well(padding: 12) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().opacity(0.5) }
                        TaskRow(item: item, provider: store.id)
                    }
                }
            }
        }
    }

    /// Claude Code (terminal or the Code tab) used in the last two weeks: only then its sessions matter.
    /// Claude Code in real use: tasks set up, or sessions of the person's own in the last two
    /// weeks (Cooldown's own /usage reads do not count).
    private var usesClaudeCode: Bool {
        let since = Date().addingTimeInterval(-14 * 86400)
        let own = Settings.appSupport.path
        return !tasks.tasks.isEmpty || store.buckets.contains { $0.key.hour > since && !$0.key.project.hasPrefix(own) && !$0.counts.isZero }
    }

    /// Codex dialogs active in the last half hour that are not under auto-continue yet.
    private var working: [CodexConversation] {
        let watched = Set(model.watches.filter(\.enabled).map(\.threadId))
        let since = Date().addingTimeInterval(-30 * 60)
        return model.threads
            .filter { !$0.archived && !watched.contains($0.id) && ($0.updatedAt ?? .distantPast) > since }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            .prefix(4).map { $0 }
    }

    private var items: [TaskItem] {
        if store.id == .codex {
            return model.watches.map {
                TaskItem(id: $0.threadId, title: model.title(for: $0.threadId), status: $0.status, reason: $0.reason,
                         attempts: $0.attempts, maxResumes: $0.maxResumes, enabled: $0.enabled, updated: $0.updated)
            }
        }
        return tasks.tasks.map {
            TaskItem(id: $0.id, title: $0.title, status: $0.status, reason: $0.reason, attempts: $0.attempts,
                     maxResumes: $0.maxResumes, enabled: $0.enabled, updated: $0.updated)
        }
    }
}

/// Claude Desktop chats and Cowork live on the server and are not continued automatically:
/// Cooldown says when the limit is back and opens Claude.
private struct ClaudeDesktopCard: View {
    @AppStorage(SettingsKey.notifyReset) private var notifyReset = true
    @AppStorage(SettingsKey.claudeContinueText) private var continueText = ""
    @State private var sending = false
    @State private var result: String?
    @State private var failed = false

    var body: some View {
        Well {
            Label("Чаты Claude — продолжение одним нажатием", systemImage: "bubble.left.and.text.bubble.right")
                .font(.system(size: 13, weight: .semibold))
            Text("Когда лимит восстановится, придёт карточка «Продолжить». Нажмёте её, и Cooldown найдёт нужный чат и отправит туда сообщение ниже. Без вашего нажатия ничего не отправляется.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Сообщать, когда лимит восстановился", isOn: $notifyReset).toggleStyle(.switch)
            TextField(ClaudeSender.defaultText, text: $continueText, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button { send() } label: {
                    Label(sending ? "Отправляю…" : "Продолжить сейчас", systemImage: "paperplane").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.coral)
                .disabled(sending)
                Button { ClaudeApp.open() } label: { Label("Открыть", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.glass)
            }
            if !ClaudeSender.hasPermission {
                Text("Для отправки macOS один раз попросит разрешение «Универсальный доступ».")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let result {
                Note(symbol: failed ? "exclamationmark.triangle.fill" : "checkmark.circle", text: result,
                     color: failed ? Theme.amber : Theme.mint)
            }
        }
    }

    private func send() {
        sending = true
        result = nil
        Task {
            do {
                try await ClaudeSender.continueChat()
                failed = false
                result = "Отправлено в открытый чат Claude."
            } catch {
                failed = true
                result = error.localizedDescription
            }
            sending = false
        }
    }
}

enum ClaudeApp {
    static let bundleID = "com.anthropic.claudefordesktop"

    static func open() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else if let url = URL(string: "https://claude.ai") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct TaskRow: View {
    @EnvironmentObject private var model: AppModel
    let item: TaskItem
    let provider: ProviderID
    @State private var confirming = false
    @State private var stopping = false
    @State private var error: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(status: item.status, enabled: item.enabled, tint: Theme.tint(for: provider)).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1).foregroundStyle(item.enabled ? .primary : .secondary)
                Text("\(TaskStatus.title(item.status)), попыток \(item.attempts) из \(item.maxResumes), \(Format.relative(item.updated))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if TaskStatus.needsAttention(item.status) || (item.enabled && provider == .claude) {
                    Text(item.reason)
                        .font(.caption)
                        .foregroundStyle(TaskStatus.needsAttention(item.status) ? Theme.amber : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error { Text(error).font(.caption).foregroundStyle(Theme.signal) }
            }
            Spacer(minLength: 4)
            if item.enabled {
                Button(confirming ? "Точно?" : "Выключить") { stop() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .tint(confirming ? Theme.signal : nil)
                    .disabled(stopping)
            }
        }
        .animation(.smooth(duration: 0.2), value: confirming)
    }

    private func stop() {
        guard confirming else {
            confirming = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { confirming = false }
            return
        }
        stopping = true
        Task {
            if provider == .codex {
                do { try await model.stopTask(item.id); error = nil } catch { self.error = ResumeError.friendly(error) }
            } else {
                model.claudeTasks.stop(item.id)
            }
            stopping = false
            confirming = false
        }
    }
}

private struct StatusDot: View {
    let status: String
    let enabled: Bool
    let tint: Color
    @State private var breathing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(waiting && breathing ? 0.35 : 1)
            .onAppear {
                guard waiting else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathing = true }
            }
    }

    private var waiting: Bool { enabled && status == "waiting_quota" }

    private var color: Color {
        guard enabled else { return .secondary.opacity(0.5) }
        if TaskStatus.needsAttention(status) { return Theme.amber }
        switch status {
        case "waiting_quota", "waiting_connection", "retrying": return tint
        case "resumed", "watching": return Theme.mint
        default: return .secondary
        }
    }
}

// MARK: Adding a task

struct AddTaskScreen: View {
    @EnvironmentObject private var model: AppModel
    @Binding var screen: Screen
    let provider: ProviderID
    let render: Bool
    /// Claude: Desktop chats by default; Claude Code sessions when asked for.
    @State private var claudeCode = AddTaskScreen.wantsClaudeCode

    static var wantsClaudeCode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BackBar(title: provider == .claude && !claudeCode ? "Чат для продолжения" : "Новая задача, \(provider.displayName)") {
                AddTaskScreen.wantsClaudeCode = false
                screen = .home
            }
            if provider == .codex {
                CodexAddFlow(screen: $screen, render: render)
            } else if claudeCode {
                ClaudeAddFlow(tasks: model.claudeTasks, screen: $screen, render: render)
            } else {
                ClaudeChatPicker(screen: $screen)
            }
        }
        .padding(14)
        .frame(maxHeight: render ? nil : .infinity, alignment: .top)
    }
}

private struct PickerList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let render: Bool
    let choose: (Item) -> Void
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        let list = LazyVStack(spacing: 2) {
            ForEach(render ? Array(items.prefix(7)) : items) { item in
                Button { choose(item) } label: { row(item) }.buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.well))
        if render { list } else { ScrollView(.vertical, showsIndicators: false) { list } }
    }
}

private struct PickerRow: View {
    let title: String
    let subtitle: String
    var badge: String? = nil
    var badgeColor: Color = .secondary
    var dimmed = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).lineLimit(1)
            HStack(spacing: 6) {
                Text(subtitle)
                if let badge { Text(badge).foregroundStyle(badgeColor) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .opacity(dimmed ? 0.55 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct ConsentBlock: View {
    let provider: ProviderID
    @Binding var maxResumes: Int
    @Binding var confirmed: Bool
    let busy: Bool
    let start: () -> Void

    var body: some View {
        Well {
            Stepper(value: $maxResumes, in: 1...10) { Text("Попыток продолжения: \(maxResumes)") }
            Text("Каждая попытка — одно сообщение в диалог после сброса лимита. Прошлые попытки по этой задаче тоже считаются.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $confirmed) {
                Text(provider == .codex
                     ? "Продолжать только эту задачу. Cooldown может открыть её диалог в Codex. Отправленное не отзывается, разрешения не выдаются за вас."
                     : "Продолжать только эту сессию. Claude продолжит её в фоне; ответ появится, когда вы снова откроете сессию. Разрешения не выдаются за вас.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
        }
        Button(action: start) {
            Text(busy ? "Включаю…" : "Включить автопродолжение").frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.tint(for: provider))
        .controlSize(.large)
        .disabled(!confirmed || busy)
    }
}

private struct CodexAddFlow: View {
    @EnvironmentObject private var model: AppModel
    @Binding var screen: Screen
    let render: Bool
    @State private var query = ""
    @State private var selected: CodexConversation?
    @State private var result: ResumeCheck?
    @State private var checking = false
    @State private var error: String?
    @State private var maxResumes = 2
    @State private var confirmed = false
    @State private var starting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selected { detail(selected) } else { picker }
        }
        .task {
            if let pending = model.pendingThread {
                model.pendingThread = nil
                choose(pending)
            }
            await model.loadThreads(force: false)
        }
        .animation(.smooth(duration: 0.25), value: selected)
        .animation(.smooth(duration: 0.25), value: result)
    }

    private var candidates: [CodexConversation] {
        let watched = Set(model.watches.filter(\.enabled).map(\.threadId))
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.threads
            .filter { !$0.archived && !watched.contains($0.id) }
            .filter { term.isEmpty || $0.title.lowercased().contains(term) || Stats.projectName($0.cwd ?? "").lowercased().contains(term) }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Найти диалог по названию или проекту", text: $query)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
            if let error = model.threadsError { Note(symbol: "exclamationmark.triangle", text: error, color: Theme.amber) }
            if model.loadingThreads && model.threads.isEmpty {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Загружаю диалоги Codex…").foregroundStyle(.secondary) }
                    .padding(.vertical, 20)
            }
            PickerList(items: candidates, render: render, choose: choose) { thread in
                PickerRow(title: thread.title,
                          subtitle: "\(Stats.projectName(thread.cwd ?? "")), \(thread.updatedAt.map { Format.relative($0) } ?? "")")
            }
        }
    }

    private func detail(_ thread: CodexConversation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Well {
                Text(thread.title).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(Stats.projectName(thread.cwd ?? "")).font(.caption).foregroundStyle(.secondary)
                if checking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Проверяю задачу, для длинных диалогов до 15 секунд.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let result {
                    Text(ResumeStatus.taskStateTitle(result.taskState))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(result.canMonitor ? Theme.mint : Theme.amber)
                    Text(result.reason).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let result, result.canMonitor {
                ConsentBlock(provider: .codex, maxResumes: $maxResumes, confirmed: $confirmed, busy: starting) { start(thread) }
            } else if result != nil {
                Button("Выбрать другой диалог") { reset() }.buttonStyle(.glass)
            }
            if let error { Note(symbol: "exclamationmark.triangle.fill", text: error, color: Theme.signal) }
        }
    }

    private func choose(_ thread: CodexConversation) {
        selected = thread
        result = nil
        error = nil
        confirmed = false
        checking = true
        Task {
            do {
                let check = try await model.check(thread.id)
                if selected?.id == thread.id { result = check }
            } catch {
                if selected?.id == thread.id { self.error = ResumeError.friendly(error) }
            }
            checking = false
        }
    }

    private func start(_ thread: CodexConversation) {
        starting = true
        error = nil
        Task {
            do {
                try await model.startTask(thread.id, maxResumes: maxResumes)
                reset()
                screen = .home
            } catch {
                self.error = ResumeError.friendly(error)
                result = nil
                confirmed = false
            }
            starting = false
        }
    }

    private func reset() {
        selected = nil
        result = nil
        error = nil
        confirmed = false
        checking = false
    }
}

private struct ClaudeAddFlow: View {
    @ObservedObject var tasks: ClaudeTaskManager
    @Binding var screen: Screen
    let render: Bool
    @State private var query = ""
    @State private var selected: ClaudeSession?
    @State private var maxResumes = 2
    @State private var confirmed = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selected { detail(selected) } else { picker }
        }
        .task { await tasks.loadSessions() }
        .animation(.smooth(duration: 0.25), value: selected)
    }

    private var candidates: [ClaudeSession] {
        let watched = Set(tasks.tasks.filter(\.enabled).map(\.id))
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()
        return tasks.sessions
            .filter { !watched.contains($0.id) }
            .filter { term.isEmpty || $0.title.lowercased().contains(term) || Stats.projectName($0.cwd).lowercased().contains(term) }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Найти сессию по названию или проекту", text: $query)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
            if tasks.loadingSessions && tasks.sessions.isEmpty {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Ищу сессии Claude Code…").foregroundStyle(.secondary) }
                    .padding(.vertical, 20)
            } else if tasks.sessions.isEmpty {
                Well { Text("За последние 30 дней сессий Claude Code на этом Mac не было.").font(.callout).foregroundStyle(.secondary) }
            }
            PickerList(items: candidates, render: render, choose: { selected = $0; confirmed = false; error = nil }) { session in
                PickerRow(title: session.title,
                          subtitle: "\(Stats.projectName(session.cwd)), \(Format.relative(session.updated))",
                          badge: session.state.canWatch ? session.state.title : nil,
                          badgeColor: session.state == .running ? Theme.mint : Theme.coral,
                          dimmed: !session.state.canWatch)
            }
        }
    }

    private func detail(_ session: ClaudeSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Well {
                Text(session.title).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(Stats.projectName(session.cwd)).font(.caption).foregroundStyle(.secondary)
                Text(session.state.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(session.state.canWatch ? Theme.mint : Theme.amber)
                Text(explanation(session.state)).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if session.state.canWatch {
                ConsentBlock(provider: .claude, maxResumes: $maxResumes, confirmed: $confirmed, busy: false) { add(session) }
            } else {
                Button("Выбрать другую сессию") { selected = nil }.buttonStyle(.glass)
            }
            if let error { Note(symbol: "exclamationmark.triangle.fill", text: error, color: Theme.signal) }
        }
    }

    private func explanation(_ state: ClaudeSessionState) -> String {
        switch state {
        case .running: return "Сессия сейчас работает. Если её остановит лимит, Cooldown дождётся сброса и продолжит."
        case .limited: return "Сессия остановлена лимитом. Cooldown продолжит её, как только лимит восстановится."
        case .idle: return "Сессия закончила работу сама, продолжать нечего."
        case .unknown: return "Не удалось понять состояние сессии."
        }
    }

    private func add(_ session: ClaudeSession) {
        do {
            try tasks.add(session, maxResumes: maxResumes)
            selected = nil
            screen = .home
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Claude Desktop chats chosen for continuing after a reset.
private struct ClaudeChatsSection: View {
    @ObservedObject private var list = ClaudeChatList.shared
    @Binding var screen: Screen
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(text: "Чаты для продолжения")
                Spacer()
                Button {
                    AddTaskScreen.wantsClaudeCode = false
                    screen = .addTask
                } label: { Label("Выбрать чат", systemImage: "plus") }
                    .buttonStyle(.link).font(.caption)
            }
            if list.entries.isEmpty {
                Text("Выберите чаты Claude, которые нужно продолжить, когда лимит восстановится. Если не выбрать, Cooldown сам запомнит чат, в котором кончился лимит.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            } else {
                Well(padding: 12) {
                    ForEach(Array(list.entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().opacity(0.5) }
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "bubble.left.fill").foregroundStyle(Theme.coral).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.chat.title).lineLimit(2)
                                Text(subtitle(entry)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Menu {
                                Button("Продолжить сейчас") { send(entry) }
                                Button("Убрать") { list.remove(entry) }
                            } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 28, height: 22)
                        }
                    }
                }
                if list.entries.count >= 2 {
                    Button {
                        Task { await list.continueAll(list.entries.map(\.chat)) }
                    } label: {
                        Label(list.continuing ? "Продолжаю…" : "Продолжить все сейчас", systemImage: "paperplane").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .disabled(list.continuing)
                }
                Text("Когда лимит восстановится, придёт карточка «Продолжить» (для нескольких чатов — одна, «Продолжить все»). Нажмёте — Cooldown сам найдёт каждый чат, даже если вы ушли в другой, проверит его и отправит сообщение.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            if let error { Note(symbol: "exclamationmark.triangle.fill", text: error, color: Theme.amber) }
        }
    }

    private func subtitle(_ entry: ClaudeChatList.Entry) -> String {
        var parts: [String] = [entry.automatic ? "запомнен при исчерпании лимита" : "выбран вами"]
        if let sent = entry.lastSent { parts.append("продолжен \(Format.relative(sent))") }
        return parts.joined(separator: " · ")
    }

    private func send(_ entry: ClaudeChatList.Entry) {
        error = nil
        Task {
            do { try await ClaudeSender.continueChat(entry.chat) } catch { self.error = error.localizedDescription }
        }
    }
}

/// Pick chats from Claude's sidebar.
private struct ClaudeChatPicker: View {
    @ObservedObject private var list = ClaudeChatList.shared
    @ObservedObject private var web = ClaudeWeb.shared
    @Binding var screen: Screen
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Найти чат по названию или проекту", text: $query)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
            if list.availableSource != .web && !ClaudeSender.hasPermission {
                Note(symbol: "exclamationmark.triangle.fill", text: "Чтобы видеть чаты Claude, нужен «Универсальный доступ» для Cooldown (Настройки → Готовность) или вход в claude.ai.", color: Theme.amber)
            } else if list.available.isEmpty && !list.loadingAvailable {
                Well {
                    Text("Откройте Claude Desktop — Cooldown возьмёт список чатов из его боковой панели.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Обновить") { list.refreshAvailable() }.buttonStyle(.glass)
                }
            }
            if list.availableSource == .window && !web.isConnected {
                Text("Здесь чаты из боковой панели Claude и те, что Cooldown уже видел открытыми. Полный список со всеми проектами — после входа в claude.ai в настройках.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            if let current = list.current, !list.entries.contains(where: { $0.chat.matches(current) }), query.isEmpty {
                Button {
                    list.add(current)
                    screen = .home
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "scope").foregroundStyle(Theme.coral)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(current.title).lineLimit(1)
                            Text("Открыт сейчас в Claude")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.well))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if list.loadingAvailable && list.available.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
            PickerList(items: candidates, render: false, choose: { item in
                list.add(item)
                screen = .home
            }) { item in
                PickerRow(title: item.chat.title, subtitle: subtitle(item))
            }
        }
        .onAppear { list.refreshAvailable() }
    }

    private func subtitle(_ item: ClaudeChatList.Known) -> String {
        var parts: [String] = []
        if let project = item.project { parts.append(project) }
        if let updated = item.updated { parts.append(Format.relative(updated)) }
        else if !item.chat.id.isEmpty { parts.append("открывался \(Format.relative(item.chat.seen))") }
        else { parts.append("из боковой панели") }
        return parts.joined(separator: " · ")
    }

    private var candidates: [ClaudeChatList.Known] {
        var chosen = list.entries.map(\.chat)
        if query.isEmpty, let current = list.current { chosen.append(current) }   // shown on top already
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()
        return list.available.filter { item in
            !chosen.contains { $0.matches(item.chat) }
                && (term.isEmpty || item.chat.title.lowercased().contains(term) || (item.project?.lowercased().contains(term) ?? false))
        }
        .prefix(300).map { $0 }
    }
}


/// What an agent is doing right now (from hooks, session files and Claude's window).
private struct AgentNowSection: View {
    @ObservedObject private var activity = AgentActivity.shared
    let provider: ProviderID

    var body: some View {
        let items = activity.waiting(provider) + activity.working(provider)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(text: "Сейчас в \(provider.displayName)")
                Well(padding: 12) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { Divider().opacity(0.5) }
                        HStack(spacing: 10) {
                            Circle().fill(session.state == .waiting ? Theme.amber : Theme.mint).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title.isEmpty ? "Без названия" : session.title).lineLimit(1)
                                Text(detail(session)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private func detail(_ session: AgentActivity.Session) -> String {
        let place = session.source == .window ? "Claude Desktop" : session.key.hasPrefix("chat:") ? "Claude Desktop" : provider == .claude ? "Claude Code" : "Codex"
        if session.state == .waiting { return "\(place) · ждёт вашего решения" + (session.reason.map { ": \($0)" } ?? "") }
        let minutes = Int(Date().timeIntervalSince(session.started) / 60)
        return "\(place) · работает" + (minutes > 0 ? " \(minutes) мин" : "")
    }
}
