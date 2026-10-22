import AppKit
import Charts
import SwiftUI

/// The week as one picture: what was done, what it cost, which projects took the most and the
/// best day. Saved as a PNG, opened in Preview to keep or send.
@MainActor
enum WeeklyReport {
    struct Summary {
        struct Day: Identifiable {
            var date: Date
            var codex: Int
            var claude: Int
            var id: Date { date }
        }
        var start: Date
        var end: Date
        var days: [Day]
        var codexTokens: Int
        var claudeTokens: Int
        var dollars: Double
        var done: Int
        var exhausted: Int
        var projects: [ShareRow]
        var best: Day? { days.max { $0.codex + $0.claude < $1.codex + $1.claude }.flatMap { $0.codex + $0.claude > 0 ? $0 : nil } }
        var isEmpty: Bool { codexTokens + claudeTokens == 0 && done == 0 }
    }

    /// The last seven days up to `now`.
    static func summary(now: Date = Date()) -> Summary {
        let calendar = Calendar.current
        let log = DailyLog.shared
        var days: [Summary.Day] = []
        var dollars = 0.0, done = 0
        for offset in (0..<7).reversed() {
            let date = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -offset, to: now)!)
            let day = log.day(date)
            days.append(.init(date: date, codex: day.codexTokens, claude: day.claudeTokens))
            dollars += day.codexDollars + day.claudeDollars
            done += day.codexDone + day.claudeDone
        }
        let model = AppModel.shared
        let exhausted = Stats.exhaustedWindows(model.codex.samples, .week, now: now) + Stats.exhaustedWindows(model.claude.samples, .week, now: now)
        return Summary(start: days.first!.date, end: now, days: days,
                       codexTokens: days.reduce(0) { $0 + $1.codex }, claudeTokens: days.reduce(0) { $0 + $1.claude },
                       dollars: dollars, done: done, exhausted: exhausted,
                       projects: Array(Stats.projects(model.codex.buckets + model.claude.buckets, .week, now: now).prefix(4)))
    }

    static var folder: URL {
        let folder = Settings.appSupport.appendingPathComponent("reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Draws the report and saves it; nil when there was nothing this week.
    static func render(now: Date = Date()) -> URL? {
        let summary = summary(now: now)
        guard !summary.isEmpty else { return nil }
        let renderer = ImageRenderer(content: WeeklyReportView(summary: summary).environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.nsImage, let png = RenderMode.pngData(image) else { return nil }
        let name = "cooldown-week-\(DailyLog.key(summary.start))-\(DailyLog.key(summary.end)).png"
        let url = folder.appendingPathComponent(name)
        do { try png.write(to: url) } catch { return nil }
        return url
    }

    /// Makes the report and opens it in Preview.
    static func show() {
        guard let url = render() else {
            ToastController.shared.show(ToastContent(key: "report-empty", kind: .info, provider: nil, title: "Неделя пока пустая",
                                                     body: "За последние семь дней работы Codex и Claude Code не было.", life: .auto(6)))
            return
        }
        NSWorkspace.shared.open(url)
    }
}

/// The picture itself: dark, calm, made to be shared.
struct WeeklyReportView: View {
    let summary: WeeklyReport.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Итоги недели").font(.system(size: 30, weight: .bold))
                    Text("\(summary.start.formatted(.dateTime.day().month(.wide))) — \(summary.end.formatted(.dateTime.day().month(.wide)))")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Cooldown").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                figure(Format.tokens(summary.codexTokens), "токенов Codex", Theme.tint(for: .codex))
                figure(Format.tokens(summary.claudeTokens), "токенов Claude Code", Theme.tint(for: .claude))
                figure("\(summary.done)", "задач закончено", Theme.mint)
                figure(summary.dollars >= 1 ? "≈" + Pricing.format(summary.dollars) : "—", "по ценам API", Theme.amber)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("По дням").font(.system(size: 15, weight: .semibold))
                Chart {
                    ForEach(summary.days) { day in
                        BarMark(x: .value("День", day.date, unit: .day), y: .value("Токены", day.codex))
                            .foregroundStyle(by: .value("Агент", "Codex"))
                        BarMark(x: .value("День", day.date, unit: .day), y: .value("Токены", day.claude))
                            .foregroundStyle(by: .value("Агент", "Claude Code"))
                    }
                }
                .chartForegroundStyleScale(["Codex": Theme.tint(for: .codex), "Claude Code": Theme.tint(for: .claude)])
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                .chartYAxis { AxisMarks { value in AxisValueLabel { if let count = value.as(Int.self) { Text(Format.tokensAxis(count)) } } } }
                .chartLegend(position: .top, alignment: .trailing)
                .frame(height: 170)
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.06)))
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Проекты").font(.system(size: 15, weight: .semibold))
                    if summary.projects.isEmpty {
                        Text("Нет данных").foregroundStyle(.secondary)
                    }
                    ForEach(summary.projects) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(row.name).lineLimit(1)
                                Spacer()
                                Text(Format.percent(row.percent)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.system(size: 13))
                            GeometryReader { geometry in
                                Capsule().fill(Theme.cobalt.opacity(0.85)).frame(width: max(4, geometry.size.width * row.share))
                            }
                            .frame(height: 5)
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.06)))
                VStack(alignment: .leading, spacing: 12) {
                    if let best = summary.best {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Самый плотный день").font(.system(size: 13)).foregroundStyle(.secondary)
                                Text(best.date.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.system(size: 15, weight: .semibold))
                                Text("\(Format.tokens(best.codex + best.claude)) токенов").font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "flame.fill").foregroundStyle(Theme.coral) }
                    }
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Упирались в лимит").font(.system(size: 13)).foregroundStyle(.secondary)
                            Text(summary.exhausted == 0 ? "ни разу" : "\(summary.exhausted) \(Format.plural(summary.exhausted, "раз", "раза", "раз"))")
                                .font(.system(size: 15, weight: .semibold))
                        }
                    } icon: { Image(systemName: "gauge.with.dots.needle.100percent").foregroundStyle(Theme.amber) }
                }
                .padding(18)
                .frame(width: 250, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.06)))
            }
        }
        .padding(30)
        .frame(width: 720)
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: [Color(red: 0.08, green: 0.09, blue: 0.16), Color(red: 0.05, green: 0.05, blue: 0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private func figure(_ value: String, _ caption: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
            Text(caption).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}
