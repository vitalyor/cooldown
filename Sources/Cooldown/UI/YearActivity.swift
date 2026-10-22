import SwiftUI

/// A year of work at a glance, one square per day, as on a GitHub profile: the deeper the colour,
/// the more the agent did that day. Tap a square for the day's numbers.
struct YearActivityCard: View {
    @ObservedObject private var log = DailyLog.shared
    let provider: ProviderID
    let render: Bool
    @State private var metric: Metric
    @State private var selected: Date?

    init(provider: ProviderID, render: Bool) {
        self.provider = provider
        self.render = render
        // Claude Desktop leaves no token counts on disk; its share of the weekly limit is known.
        _metric = State(initialValue: provider == .claude ? .week : .tokens)
    }

    enum Metric: String, CaseIterable, Identifiable {
        case week, tokens, dollars, done
        var id: String { rawValue }
        var title: String {
            switch self {
            case .week: return L("% недели")
            case .tokens: return L("Токены")
            case .dollars: return "≈ $ API"
            case .done: return L("Задачи")
            }
        }
    }

    private static let cell: CGFloat = 9
    private static let gap: CGFloat = 2
    /// The window is narrow: about half a year shows at once, the rest scrolls in from the left.
    private static let visibleWidth: CGFloat = StatusController.size.width - 28 - 28 - 22
    private static let weeks = 53
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2          // weeks start on Monday
        calendar.locale = AppLanguage.locale
        return calendar
    }()

    var body: some View {
        let columns = Self.columns(now: Date())
        let values = columns.flatMap { $0 }.compactMap { $0 }.map(value)
        let top = values.max() ?? 0
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("Год работы")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("", selection: $metric) {
                    ForEach(Metric.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .trailing, spacing: Self.gap) {
                    Color.clear.frame(height: 12)
                    ForEach(0..<7, id: \.self) { row in
                        Text(row == 0 ? L("пн") : row == 2 ? L("ср") : row == 4 ? L("пт") : "")
                            .font(.system(size: 8.5)).foregroundStyle(.secondary)
                            .frame(height: Self.cell)
                    }
                }
                grid(columns, top: top)
            }
            footer(columns, values: values)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.well))
    }

    @ViewBuilder
    private func grid(_ columns: [[Date?]], top: Double) -> some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Self.gap) {
                ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                    Text(monthLabel(column, index: index, columns: columns))
                        .font(.system(size: 8.5)).foregroundStyle(.secondary)
                        .fixedSize()
                        .frame(width: Self.cell, height: 10, alignment: .leading)
                }
            }
            HStack(spacing: Self.gap) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    VStack(spacing: Self.gap) {
                        ForEach(0..<7, id: \.self) { row in
                            if let date = column[row] {
                                square(date, top: top)
                            } else {
                                Color.clear.frame(width: Self.cell, height: Self.cell)
                            }
                        }
                    }
                }
            }
        }
        .padding(.trailing, 2)
        if render {
            content.frame(width: Self.visibleWidth, alignment: .trailing).clipped()
        } else {
            ScrollView(.horizontal, showsIndicators: false) { content }
                .defaultScrollAnchor(.trailing)
                .frame(width: Self.visibleWidth)
        }
    }

    private func square(_ date: Date, top: Double) -> some View {
        let amount = value(date)
        let isSelected = selected.map { Self.calendar.isDate($0, inSameDayAs: date) } ?? false
        return RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(color(amount, top: top))
            .frame(width: Self.cell, height: Self.cell)
            .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(Color.primary.opacity(isSelected ? 0.7 : 0), lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { selected = isSelected ? nil : date }
            .help(tooltip(date))
    }

    /// Five steps like GitHub's: empty, then four shades; square-root scale so light days show.
    private func color(_ amount: Double, top: Double) -> Color {
        guard amount > 0, top > 0 else { return Color.primary.opacity(0.07) }
        let share = (amount / top).squareRoot()
        let level = share > 0.75 ? 1.0 : share > 0.5 ? 0.75 : share > 0.25 ? 0.5 : 0.3
        return Theme.tint(for: provider).opacity(level)
    }

    private func value(_ date: Date) -> Double {
        let day = log.day(date)
        switch (metric, provider) {
        case (.week, .codex): return day.codexWeek
        case (.week, .claude): return day.claudeWeek
        case (.tokens, .codex): return Double(day.codexTokens)
        case (.tokens, .claude): return Double(day.claudeTokens)
        case (.dollars, .codex): return day.codexDollars
        case (.dollars, .claude): return day.claudeDollars
        case (.done, .codex): return Double(day.codexDone)
        case (.done, .claude): return Double(day.claudeDone + day.chats)
        }
    }

    private func describe(_ date: Date) -> String {
        let day = log.day(date)
        let tokens = provider == .codex ? day.codexTokens : day.claudeTokens
        let dollars = provider == .codex ? day.codexDollars : day.claudeDollars
        let done = provider == .codex ? day.codexDone : day.claudeDone
        let week = provider == .codex ? day.codexWeek : day.claudeWeek
        var parts: [String] = []
        if week > 0 { parts.append(L("%@ недельного лимита", "\(Format.percent(week))")) }
        if tokens > 0 { parts.append(L("%@ токенов", "\(Format.tokens(tokens))")) }
        if parts.isEmpty { parts.append(L("без работы")) }
        if dollars > 0 { parts.append("≈\(Pricing.format(dollars))") }
        if done > 0 { parts.append(Format.count(done, L("задача|задачи|задач"))) }
        if provider == .claude, day.chats > 0 { parts.append(Format.count(day.chats, L("чат|чата|чатов"))) }
        return parts.joined(separator: " · ")
    }

    private func tooltip(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).locale(AppLanguage.locale)) + ": " + describe(date)
    }

    @ViewBuilder
    private func footer(_ columns: [[Date?]], values: [Double]) -> some View {
        if let selected {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(selected.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(AppLanguage.locale)))
                    .font(.caption.weight(.semibold))
                Text(describe(selected)).font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            let days = columns.flatMap { $0 }.compactMap { $0 }
            let active = days.filter { value($0) > 0 }
            Text(summary(days: days, active: active))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if log.backfilling {
            Text(L("Собираю прошлые месяцы из файлов на диске…")).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func summary(days: [Date], active: [Date]) -> String {
        guard !active.isEmpty else { return L("Здесь появится каждый день работы %@.", "\(provider.displayName)") }
        // Current streak: consecutive active days ending today (or yesterday).
        var streak = 0
        var cursor = Self.calendar.startOfDay(for: Date())
        if value(cursor) == 0 { cursor = Self.calendar.date(byAdding: .day, value: -1, to: cursor)! }
        while value(cursor) > 0 {
            streak += 1
            cursor = Self.calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        var byWeekday = [Int: Double]()
        for day in active { byWeekday[Self.calendar.component(.weekday, from: day), default: 0] += value(day) }
        let busiest = byWeekday.max { $0.value < $1.value }.map { Self.calendar.weekdaySymbols[$0.key - 1] }
        var parts = [L("%@ с работой за год", "\(Format.count(active.count, L("день|дня|дней")))")]
        if streak > 1 { parts.append(L("подряд %@", "\(Format.count(streak, L("день|дня|дней")))")) }
        if let busiest { parts.append(L("чаще всего: %@", "\(busiest)")) }
        return parts.joined(separator: " · ")
    }

    private func monthLabel(_ column: [Date?], index: Int, columns: [[Date?]]) -> String {
        guard let first = column.compactMap({ $0 }).first else { return "" }
        let month = Self.calendar.component(.month, from: first)
        if index > 0, let previous = columns[index - 1].compactMap({ $0 }).first,
           Self.calendar.component(.month, from: previous) == month { return "" }
        if index == 0 { return "" }
        return Self.calendar.shortStandaloneMonthSymbols[month - 1].replacingOccurrences(of: ".", with: "")
    }

    /// 53 week columns, Monday at the top; days after today are empty.
    static func columns(now: Date) -> [[Date?]] {
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let first = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: weekStart)!
        return (0..<weeks).map { week in
            (0..<7).map { row in
                let date = calendar.date(byAdding: .day, value: week * 7 + row, to: first)!
                return date > today ? nil : date
            }
        }
    }
}
