import Charts
import SwiftUI

struct LimitsTab: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: ProviderStore
    @Binding var screen: Screen
    let render: Bool

    var body: some View {
        TabScroll(render: render) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(now: context.date)
            }
        }
    }

    @ObservedObject private var usage = ClaudeUsageStatus.shared

    @ViewBuilder
    private func content(now: Date) -> some View {
        if store.id == .claude, usage.needsPermission {
            ClaudeUsagePermission()
        }
        if let snapshot = store.snapshot {
            VStack(alignment: .leading, spacing: 14) {
                HeroRings(snapshot: snapshot, tint: store.tint, now: now, render: render)
                if !snapshot.extras.isEmpty { ExtraWindows(windows: snapshot.extras, tint: store.tint, now: now) }
                if let session = snapshot.session, !session.isExpired(at: now), session.remaining(at: now) < 0.5 {
                    ResetPlan(provider: store.id, reset: session.resetsAt, now: now, screen: $screen)
                }
                if let session = snapshot.session, !session.isExpired(at: now) {
                    ForecastWell(session: session, weekly: snapshot.weekly, samples: store.samples, tint: store.tint, now: now)
                } else if snapshot.session != nil {
                    Well {
                        Note(symbol: "sparkles", text: L("Лимит на 5 часов восстановился. Новое окно начнётся с первого запроса."), color: Theme.mint)
                    }
                }
                SourceLine(snapshot: snapshot, error: store.limitError, now: now)
            }
        } else if store.id == .claude, store.limitError == ClaudeError.notConnected.localizedDescription || store.limitError == nil {
            ClaudeConnect(screen: $screen)
        } else if store.id == .claude, usage.needsPermission {
            EmptyView()
        } else if let error = store.limitError {
            Well {
                Note(symbol: "exclamationmark.triangle.fill", text: error, color: Theme.amber)
                Button(L("Открыть настройки")) { SettingsWindow.shared.show(store.id == .codex ? .codex : .claude) }.buttonStyle(.link)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Читаю лимиты %@…", "\(store.id.displayName)")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        }
    }
}

/// Two rings, 5 hours outside and the week inside, filling up when the window opens.
/// The limit is spent: when work can go on, and what to set up for that moment.
private struct ResetPlan: View {
    let provider: ProviderID
    let reset: Date
    let now: Date
    @Binding var screen: Screen
    @State private var reminder: Date?

    var body: some View {
        Well {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "clock.badge.checkmark").foregroundStyle(Theme.tint(for: provider))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Снова можно работать в %@", "\(Format.clock(reset))")).font(.system(size: 14, weight: .semibold))
                    Text(L("Через %@.", "\(Format.duration(max(60, reset.timeIntervalSince(now))))")).font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                if let reminder {
                    Button { ResetReminder.cancel(provider); self.reminder = nil } label: {
                        Label(L("Напомню в %@", "\(Format.clock(reminder))"), systemImage: "bell.fill")
                    }
                    .buttonStyle(.glass)
                    .help(L("Нажмите, чтобы отменить"))
                } else if ResetReminder.possible(before: reset) {
                    Button {
                        ResetReminder.set(provider, reset: reset)
                        reminder = ResetReminder.when(provider)
                    } label: { Label(L("Напомнить за 10 минут"), systemImage: "bell") }
                    .buttonStyle(.glass)
                }
                if provider == .codex {
                    Button { screen = .schedule } label: { Label(L("Задача на момент сброса"), systemImage: "calendar.badge.clock") }
                        .buttonStyle(.glass)
                }
            }
            .font(.callout)
        }
        .onAppear { reminder = ResetReminder.when(provider) }
    }
}

private struct HeroRings: View {
    @EnvironmentObject private var model: AppModel
    let snapshot: LimitSnapshot
    let tint: Color
    let now: Date
    let render: Bool
    @State private var shown: Double = 0
    /// The week's ring (or its line in the legend) under the pointer: the big number shows the week.
    @State private var weekFocused = false

    var body: some View {
        let session = snapshot.session?.remaining(at: now)
        let weekly = snapshot.weekly?.remaining(at: now)
        let showWeek = weekly != nil && (weekFocused || session == nil)
        let main = (showWeek ? weekly : session) ?? 0
        let sessionColor = Theme.level(remaining: session ?? 100, tint: tint)
        let weeklyColor = Theme.level(remaining: weekly ?? 100, tint: Theme.mint)
        let fill = render ? 1 : shown

        HStack(spacing: 20) {
            ZStack {
                Ring(fraction: (session ?? 0) / 100 * fill, color: sessionColor, width: 15)
                    .frame(width: 148, height: 148)
                    .opacity(weekFocused && session != nil ? 0.45 : 1)
                Ring(fraction: (weekly ?? 0) / 100 * fill, color: weeklyColor, width: 10)
                    .frame(width: 108, height: 108)
                VStack(spacing: 0) {
                    Text(Format.percent(main))
                        .font(Theme.number(32))
                        .contentTransition(.numericText(value: main))
                    Text(showWeek && session != nil ? L("неделя") : L("осталось"))
                        .font(.caption)
                        .foregroundStyle(showWeek && session != nil ? weeklyColor : .secondary)
                        .contentTransition(.opacity)
                }
            }
            .frame(width: 148, height: 148)
            .contentShape(Circle())
            .onContinuousHover { phase in
                // The inner ring and the space inside it belong to the week; the outer ring to 5 hours.
                var week = false
                if case .active(let point) = phase {
                    week = hypot(point.x - 74, point.y - 74) < 57
                }
                setWeekFocus(week)
            }
            VStack(alignment: .leading, spacing: 14) {
                if let window = snapshot.session {
                    Legend(color: sessionColor, title: L("5 часов"), value: window.remaining(at: now), window: window, now: now)
                }
                if let window = snapshot.weekly {
                    Legend(color: weeklyColor, title: L("Неделя"), value: window.remaining(at: now), window: window, now: now)
                        .contentShape(Rectangle())
                        .onHover { setWeekFocus($0) }
                }
                if let credits = snapshot.resetCredits, credits > 0 {
                    Label(L("%@ в запасе", "\(Format.count(credits, L("сброс|сброса|сбросов")))"), systemImage: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(L("Бесплатные сбросы лимита. Использовать их можно в Codex командой /usage."))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .onAppear { animateIn() }
        .onChange(of: model.openCount) { _, _ in animateIn() }
    }

    private func setWeekFocus(_ value: Bool) {
        guard value != weekFocused else { return }
        withAnimation(.smooth(duration: 0.25)) { weekFocused = value }
    }

    private func animateIn() {
        guard !render else { return }
        shown = 0
        withAnimation(.spring(response: 1.1, dampingFraction: 0.85).delay(0.08)) { shown = 1 }
    }
}

private struct Ring: View {
    let fraction: Double
    let color: Color
    let width: CGFloat

    var body: some View {
        ZStack {
            Circle().inset(by: width / 2).stroke(color.opacity(0.14), lineWidth: width)
            if fraction > 0.004 {
            Circle()
                .inset(by: width / 2)
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(AngularGradient(colors: [color.opacity(0.65), color], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * max(0.01, fraction))),
                        style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.35), radius: 6)
            }
        }
    }
}

private struct Legend: View {
    let color: Color
    let title: String
    let value: Double
    let window: LimitWindow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.callout)
                Text(Format.percent(value)).font(.callout.weight(.semibold)).monospacedDigit()
                    .contentTransition(.numericText(value: value))
            }
            Text(window.isExpired(at: now) ? L("восстановлен") : L("сброс %@", "\(Format.time(window.resetsAt, now: now))"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 13)
        }
    }
}

private struct ExtraWindows: View {
    let windows: [LimitWindow]
    let tint: Color
    let now: Date

    var body: some View {
        Well(padding: 12) {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                let remaining = window.remaining(at: now)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(window.label ?? L("Неделя")).font(.callout)
                        Spacer()
                        Text(L("осталось %@", "\(Format.percent(remaining))")).font(.callout).monospacedDigit()
                    }
                    Bar(value: 100 - remaining, color: Theme.level(remaining: remaining, tint: Theme.mint))
                }
            }
        }
    }
}

struct Bar: View {
    let value: Double
    let color: Color
    var projected: Double? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if let projected, projected > value {
                    Capsule().fill(color.opacity(0.25)).frame(width: geometry.size.width * min(100, projected) / 100)
                }
                Capsule().fill(color).frame(width: max(4, geometry.size.width * min(100, value) / 100))
            }
        }
        .frame(height: 6)
    }
}

private struct ForecastWell: View {
    let session: LimitWindow
    let weekly: LimitWindow?
    let samples: [LimitSample]
    let tint: Color
    let now: Date

    var body: some View {
        let forecast = Forecaster.make(window: session, samples: samples, now: now)
        Well {
            HStack(alignment: .firstTextBaseline) {
                Text(L("Прогноз на 5 часов")).font(.system(size: 13, weight: .semibold))
                Spacer()
                if forecast.ratePerHour > 0 {
                    Text(L("%@ в час", "\(Format.percent(forecast.ratePerHour))")).font(.caption).foregroundStyle(.secondary)
                }
            }
            RunwayChart(window: session, samples: samples, forecast: forecast, tint: tint, now: now)
                .frame(height: 100)
            ForecastNote(forecast: forecast, window: session, now: now)
            if let hours = Pace.hoursLeft(session, samples: samples, now: now) {
                let untilReset = session.resetsAt.timeIntervalSince(now) / 3600
                Label(hours >= untilReset
                      ? L("В вашем обычном темпе лимита хватит до сброса — можно браться за большое.")
                      : L("В вашем обычном темпе осталось примерно на %@ работы; сброс в %@.", "\(Format.duration(hours * 3600))", "\(Format.clock(session.resetsAt))"),
                      systemImage: "figure.walk")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let weekly, !weekly.isExpired(at: now) {
                Divider().opacity(0.6)
                WeeklyForecast(window: weekly, samples: samples, now: now)
            }
        }
    }
}

private struct WeeklyForecast: View {
    let window: LimitWindow
    let samples: [LimitSample]
    let now: Date

    var body: some View {
        let forecast = Forecaster.make(window: window, samples: samples, now: now)
        let projected: Double? = {
            switch forecast.outcome {
            case .lasts(let value): return value
            case .runsOut: return 100
            default: return nil
            }
        }()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Неделя")).font(.callout.weight(.medium))
                Spacer()
                Text(line(forecast)).font(.caption).foregroundStyle(.secondary)
            }
            Bar(value: window.usedPercent, color: Theme.level(remaining: window.remainingPercent, tint: Theme.mint), projected: projected)
            if let advice = pace() {
                Label(advice, systemImage: "calendar")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            if let usual = Pace.usualWeekShare(window, samples: samples, now: now) {
                let difference = window.usedPercent - usual
                Label(abs(difference) < 5
                      ? L("Как обычно: к этому моменту недели уходит около %@.", "\(Format.percent(usual))")
                      : difference > 0
                        ? L("Тяжелее обычного: обычно к этому моменту %@, сейчас %@.", "\(Format.percent(usual))", "\(Format.percent(window.usedPercent))")
                        : L("Легче обычного: обычно к этому моменту %@, сейчас %@.", "\(Format.percent(usual))", "\(Format.percent(window.usedPercent))"),
                      systemImage: "chart.line.uptrend.xyaxis")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A daily budget that makes the week last until its reset, and what today took so far.
    private func pace() -> String? {
        guard !window.isExpired(at: now) else { return nil }
        let left = window.remaining(at: now)
        let days = window.resetsAt.timeIntervalSince(now) / 86400
        guard days > 0.25, left > 0 else { return nil }
        let perDay = left / max(1, days.rounded(.up))
        let startOfDay = Calendar.current.startOfDay(for: now)
        let today = samples
            .filter { $0.kind == .weekly && Calendar.current.isDate($0.resetsAt, equalTo: window.resetsAt, toGranularity: .minute) }
            .filter { $0.t >= startOfDay }
            .sorted { $0.t < $1.t }
        let spent = today.first.map { max(0, window.usedPercent - $0.used) }
        var text = L("Чтобы хватило до сброса: до %@ в день", "\(Format.percent(perDay))")
        if let spent, spent >= 0.5 {
            text += spent > perDay * 1.2 ? L(", сегодня уже %@ — стоит притормозить", "\(Format.percent(spent))")
                                         : L(", сегодня %@", "\(Format.percent(spent))")
        }
        return text + "."
    }

    private func line(_ forecast: Forecast) -> String {
        switch forecast.outcome {
        case .exhausted: return L("исчерпана")
        case .idle: return L("сейчас не расходуется")
        case .lasts(let value): return L("к сбросу около %@", "\(Format.percent(value))")
        case .runsOut(let at): return L("закончится %@", "\(Format.time(at, now: now))")
        }
    }
}

struct RunwayChart: View {
    let window: LimitWindow
    let samples: [LimitSample]
    let forecast: Forecast
    let tint: Color
    let now: Date

    var body: some View {
        let points = Forecaster.points(for: window, samples: samples, now: now)
        let color = Theme.level(remaining: window.remainingPercent, tint: tint)
        let runsOutAt: Date? = { if case .runsOut(let at) = forecast.outcome { return at } else { return nil } }()

        Chart {
            if let runsOutAt {
                RectangleMark(xStart: .value(L("Кончится"), runsOutAt), xEnd: .value(L("Сброс"), window.resetsAt),
                              yStart: .value("", 0), yEnd: .value("", 100))
                    .foregroundStyle(Theme.signal.opacity(0.12))
            }
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                AreaMark(x: .value(L("Время"), point.t), y: .value(L("Потрачено"), point.used))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.3), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
            }
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value(L("Время"), point.t), y: .value(L("Потрачено"), point.used), series: .value(L("Линия"), L("факт")))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let end = forecast.projectionEnd, end.t > now {
                LineMark(x: .value(L("Время"), now), y: .value(L("Потрачено"), window.usedPercent), series: .value(L("Линия"), L("прогноз")))
                    .foregroundStyle(color.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                LineMark(x: .value(L("Время"), end.t), y: .value(L("Потрачено"), end.used), series: .value(L("Линия"), L("прогноз")))
                    .foregroundStyle(color.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            PointMark(x: .value(L("Время"), now), y: .value(L("Потрачено"), window.usedPercent))
                .foregroundStyle(color)
                .symbolSize(34)
        }
        .chartXScale(domain: window.start...window.resetsAt)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(.caption2) }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) { Text(Format.clock(date)).font(.caption2) }
                }
            }
        }
    }
}

struct ForecastNote: View {
    let forecast: Forecast
    let window: LimitWindow
    let now: Date

    var body: some View {
        switch forecast.outcome {
        case .exhausted:
            Note(symbol: "pause.circle.fill",
                 text: L("Лимит исчерпан. Работа сможет продолжиться после сброса в %@.", "\(Format.time(window.resetsAt, now: now))"),
                 color: Theme.signal)
        case .idle:
            Note(symbol: "moon.zzz", text: L("Сейчас лимит не расходуется."))
        case .lasts(let usedAtReset):
            Note(symbol: "checkmark.circle",
                 text: L("Хватит до сброса: к %@ будет потрачено около %@.", "\(Format.clock(window.resetsAt))", "\(Format.percent(usedAtReset))"),
                 color: Theme.mint)
        case .runsOut(let at):
            Note(symbol: "exclamationmark.triangle.fill",
                 text: L("Лимит закончится в %@, за %@ до сброса.", "\(Format.clock(at))", "\(Format.duration(window.resetsAt.timeIntervalSince(at)))"),
                 color: window.remainingPercent <= 25 ? Theme.signal : Theme.amber)
        }
    }
}

private struct SourceLine: View {
    let snapshot: LimitSnapshot
    let error: String?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error {
                Note(symbol: "exclamationmark.triangle", text: L("Не удалось обновить: %@", "\(error)"), color: Theme.amber)
                    .font(.caption)
            }
            let age = now.timeIntervalSince(snapshot.fetchedAt)
            let when = age < 60 ? L("Данные свежие") : L("Данные %@ назад", "\(Format.duration(age))")
            Text(snapshot.source.map { L("%@, источник: %@.", "\(when)", "\($0)") } ?? "\(when).")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
    }
}

/// Shown on the Claude side until its limits have a source.
private struct ClaudeConnect: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var web = ClaudeWeb.shared
    @Binding var screen: Screen
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Подключите Claude")).font(.system(size: 17, weight: .semibold))
                Text(L("Чаты, Cowork и вкладка Code в Claude Desktop считаются в лимитах вашего аккаунта claude.ai. Cooldown прочитает их оттуда, как страница «Использование» в настройках Claude."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Well {
                Label(L("Аккаунт claude.ai"), systemImage: "person.crop.circle").font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 4) {
                    point(L("Лимиты на 5 часов и неделю, отдельно по моделям"))
                    point(L("Активность: диалоги по дням, модели и проекты"))
                    point(L("Только чтение: Cooldown ничего не пишет в чаты"))
                }
                Text(L("Откроется окно claude.ai: войдите так же, как в браузере. Если вход через Google не пустит, выберите вход по почте."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { web.showLogin() } label: {
                    Text(web.state == .connecting ? L("Жду входа в открытом окне…") : L("Войти в claude.ai")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.coral)
                .controlSize(.large)
            }
            if !ClaudeStatusLine.isInstalled {
                Well {
                    Label(L("Только для Claude Code"), systemImage: "terminal").font(.system(size: 13, weight: .semibold))
                    Text(L("Строка статуса Claude Code передаёт лимиты, пока работает Claude Code, без входа в аккаунт. Прежняя строка статуса продолжит работать."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { connectStatusLine() } label: { Text(L("Подключить строку статуса")).frame(maxWidth: .infinity) }
                        .buttonStyle(.glass)
                }
            }
            if let message {
                Note(symbol: failed ? "exclamationmark.triangle.fill" : "checkmark.circle", text: message,
                     color: failed ? Theme.amber : Theme.mint)
            }
        }
    }

    private func point(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.coral)
            Text(text).font(.callout)
        }
    }

    private func connectStatusLine() {
        do {
            try ClaudeStatusLine.install()
            message = L("Строка статуса подключена. Лимиты появятся после следующего ответа Claude Code.")
            failed = false
        } catch {
            message = L("Не получилось: %@", "\(error.localizedDescription)")
            failed = true
        }
    }
}

/// Asks once, inside Cooldown, to let Claude Code run in Cooldown's empty folder, which is what
/// reading the /usage screen needs. Nothing to type anywhere.
private struct ClaudeUsagePermission: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var usage = ClaudeUsageStatus.shared

    var body: some View {
        Well {
            Label(L("Лимиты Claude"), systemImage: "gauge.with.dots.needle.67percent")
                .font(.system(size: 13, weight: .semibold))
            Text(L("Cooldown открывает в Claude Code экран /usage, как если бы вы набрали команду сами. Запросов к модели нет, токены не тратятся. Лимиты общие для подписки, поэтому учитывается и расход в Claude Desktop."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L("Claude Code один раз спросит, можно ли ему работать в папке. Это пустая служебная папка Cooldown."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { allow() } label: {
                HStack(spacing: 8) {
                    if usage.allowing { ProgressView().controlSize(.small) }
                    Text(usage.allowing ? L("Подключаю…") : L("Разрешить и подключить"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.coral)
            .controlSize(.large)
            .disabled(usage.allowing)
            if let problem = usage.problem {
                Note(symbol: "exclamationmark.triangle.fill", text: problem, color: Theme.amber)
            }
        }
    }

    private func allow() {
        guard let binary = ClaudePaths.binary(override: Settings.claudePath) else {
            usage.problem = ClaudeUsageCLI.UsageError.missing.localizedDescription
            return
        }
        usage.allowing = true
        usage.problem = nil
        Task {
            do { _ = try await ClaudeUsageCLI.shared.allowFolder(binary: binary) } catch {
                usage.problem = error.localizedDescription
            }
            usage.allowing = false
            await model.refreshLimits()
        }
    }
}
