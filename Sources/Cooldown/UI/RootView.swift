import SwiftUI

enum Screen: Equatable {
    case home
    case addTask
    case schedule
    case feed
}

enum MainTab: String, CaseIterable, Identifiable {
    case limits
    case stats
    case tasks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .limits: return L("Лимиты")
        case .stats: return L("Статистика")
        case .tasks: return L("Задачи")
        }
    }

    var symbol: String {
        switch self {
        case .limits: return "gauge.with.dots.needle.67percent"
        case .stats: return "chart.bar.xaxis"
        case .tasks: return "arrow.triangle.2.circlepath"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var screen: Screen
    @State private var tab: MainTab
    @State private var stats: StatsTab
    @State private var range: StatsRange
    private let render: Bool

    /// Starting points for `--snapshot` design checks.
    static var debugTab: MainTab?
    /// Showcase screenshots: the demo's data without its guide banner.
    static var hideDemoBanner = false
    static var debugScreen: Screen?

    init(screen: Screen = .home, tab: MainTab = .limits, stats: StatsTab = .limits, range: StatsRange = .day, render: Bool = false) {
        _screen = State(initialValue: Self.debugScreen ?? screen)
        _tab = State(initialValue: Self.debugTab ?? tab)
        _stats = State(initialValue: stats)
        _range = State(initialValue: range)
        self.render = render
    }

    var body: some View {
        ZStack(alignment: .top) {
            switch screen {
            case .home:
                HomeView(screen: $screen, tab: $tab, stats: $stats, range: $range, render: render)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            case .addTask:
                AddTaskScreen(screen: $screen, provider: model.selected, render: render)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .schedule:
                ScheduleScreen(screen: $screen)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .feed:
                FeedScreen(screen: $screen)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: StatusController.size.width, height: render ? nil : StatusController.size.height, alignment: .top)
        .animation(.smooth(duration: 0.32), value: screen)
        .onChange(of: model.openCount) { _, _ in
            if let route = model.route {
                screen = route
                model.route = nil
            } else if screen != .home && Self.debugScreen == nil {
                screen = .home
            }
        }
        .onChange(of: model.route) { _, route in
            if let route { screen = route; model.route = nil }
        }
    }
}

private struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var demo = DemoController.shared
    @Binding var screen: Screen
    @Binding var tab: MainTab
    @Binding var stats: StatsTab
    @Binding var range: StatsRange
    let render: Bool

    var body: some View {
        let store = model.store(model.selected)
        VStack(spacing: 0) {
            Header(screen: $screen)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)
            if demo.active && !RootView.hideDemoBanner {
                DemoBanner(demo: demo)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Group {
                switch tab {
                case .limits: LimitsTab(store: store, screen: $screen, render: render)
                case .stats: StatsTabView(store: store, tab: $stats, range: $range, render: render)
                case .tasks: TasksTab(store: store, tasks: model.claudeTasks, screen: $screen, render: render)
                }
            }
            .id("\(tab.rawValue)-\(model.selected.rawValue)")
            .transition(.opacity)
            .background {
                // Keys while the window is open: ⌘1–3 tabs, ⌘← ⌘→ Codex / Claude.
                Group {
                    Button("") { tab = .limits }.keyboardShortcut("1", modifiers: .command)
                    Button("") { tab = .stats }.keyboardShortcut("2", modifiers: .command)
                    Button("") { tab = .tasks }.keyboardShortcut("3", modifiers: .command)
                    Button("") { model.selected = .codex }.keyboardShortcut(.leftArrow, modifiers: .command)
                    Button("") { model.selected = .claude }.keyboardShortcut(.rightArrow, modifiers: .command)
                }
                .opacity(0)
                .allowsHitTesting(false)
            }
            if render { Spacer(minLength: 0) }
        }
        .frame(maxHeight: render ? nil : .infinity, alignment: .top)
        .overlay(alignment: .bottom) {
            TabBar(tab: $tab, tint: store.tint)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        }
        .animation(.smooth(duration: 0.25), value: tab)
        .animation(.smooth(duration: 0.25), value: model.selected)
        .animation(.smooth(duration: 0.3), value: demo.active)
        .onChange(of: demo.index) { _, _ in if demo.active { tab = demo.step.tab } }
        .onChange(of: demo.active) { _, now in if now { tab = demo.step.tab } }
        .onAppear { if demo.active { tab = RootView.debugTab ?? demo.step.tab } }
    }
}

/// The guide shown on top while the demo runs: what is happening now, and how far along it is.
private struct DemoBanner: View {
    @ObservedObject var demo: DemoController

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(L("ДЕМО · %@ из %@", "\(demo.index + 1)", "\(demo.steps.count)"))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.amber)
                Spacer()
                if demo.index + 1 < demo.steps.count {
                    Button(L("Дальше")) { demo.next() }.buttonStyle(.link).font(.caption)
                }
                Button(L("Выйти")) { demo.stop() }.buttonStyle(.link).font(.caption)
            }
            Text(demo.step.title).font(.system(size: 14, weight: .semibold))
            Text(demo.step.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if demo.step.seconds.isFinite {
                GeometryReader { geometry in
                    Capsule().fill(Color.primary.opacity(0.1))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Theme.amber).frame(width: geometry.size.width * demo.progress)
                        }
                }
                .frame(height: 3)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.amber.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.amber.opacity(0.35), lineWidth: 1))
        .id(demo.index)
        .transition(.opacity)
    }
}

private struct Header: View {
    @EnvironmentObject private var model: AppModel
    @Binding var screen: Screen

    var body: some View {
        HStack(spacing: 8) {
            GlassSegments(options: ProviderID.allCases, selection: $model.selected, tint: { Theme.tint(for: $0) }) { provider, selected in
                ProviderLabel(store: model.store(provider), selected: selected)
            }
            .frame(width: 200)
            Spacer()
            FeedButton(screen: $screen)
            RefreshButton(codex: model.codex, claude: model.claude)
            GlassIconButton(symbol: "gearshape", help: L("Настройки (⌘,)")) { SettingsWindow.shared.show() }
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}

private struct ProviderLabel: View {
    @ObservedObject var store: ProviderStore
    let selected: Bool

    var body: some View {
        let remaining = store.snapshot?.lowestRemaining(at: Date())
        HStack(spacing: 6) {
            Circle()
                .fill(remaining.map { Theme.level(remaining: $0, tint: store.tint) } ?? Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(store.id.displayName)
                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? .primary : .secondary)
        }
    }
}

private struct RefreshButton: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var codex: ProviderStore
    @ObservedObject var claude: ProviderStore

    var body: some View {
        GlassIconButton(symbol: "arrow.clockwise", help: L("Обновить сейчас"), spinning: codex.isRefreshing || claude.isRefreshing) {
            ClaudeLimits.forceNext = true
            model.forceNext = true
            Task { await model.refreshAll() }
        }
    }
}

private struct TabBar: View {
    @EnvironmentObject private var model: AppModel
    @Binding var tab: MainTab
    let tint: Color

    var body: some View {
        GlassSegments(options: MainTab.allCases, selection: $tab, tint: { _ in tint }) { option, selected in
            HStack(spacing: 5) {
                Image(systemName: option.symbol).font(.system(size: 12, weight: .semibold))
                Text(option.title).font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .fixedSize()
                if option == .tasks, activeTasks > 0 {
                    Text("\(activeTasks)")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(tint.opacity(0.3)))
                }
            }
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.vertical, 3)
        }
    }

    private var activeTasks: Int {
        model.selected == .codex ? model.watches.filter(\.enabled).count : model.claudeTasks.tasks.filter(\.enabled).count
    }
}

/// Scrolling content of a tab; leaves room for the floating tab bar.
struct TabScroll<Content: View>: View {
    let render: Bool
    @ViewBuilder var content: Content

    var body: some View {
        let stack = VStack(alignment: .leading, spacing: 14) { content }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 78)
        if render {
            stack
        } else {
            ScrollView(.vertical, showsIndicators: false) { stack }
                .scrollEdgeEffectStyle(.soft, for: .bottom)
        }
    }
}

/// The bell in the header: the event feed, with a dot when something new happened.
private struct FeedButton: View {
    @ObservedObject private var log = EventLog.shared
    @Binding var screen: Screen

    var body: some View {
        GlassIconButton(symbol: log.unseen > 0 ? "bell.badge" : "bell", help: L("События")) { screen = .feed }
            .overlay(alignment: .topTrailing) {
                if log.unseen > 0 {
                    Text("\(min(log.unseen, 9))")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Theme.signal))
                        .offset(x: 2, y: -2)
                }
            }
    }
}
