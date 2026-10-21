import Charts
import SwiftUI

struct StatsTabView: View {
    @ObservedObject var store: ProviderStore
    @Binding var tab: StatsTab
    @Binding var range: StatsRange
    let render: Bool

    var body: some View {
        TabScroll(render: render) {
            YearActivityCard(provider: store.id, render: render).id(store.id)
            // Sections on their own row: four of them plus the period would not fit the window.
            Picker("Раздел", selection: $tab) {
                ForEach(StatsTab.options(for: store.id)) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                Text("Период").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(StatsRange.allCases) { option in
                        Button(option.title) { range = option }
                    }
                } label: {
                    Text(range.title)
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .fixedSize()
            }

            if case .scanning(let fraction) = store.scanState {
                Well {
                    Text("Собираю статистику из истории \(store.id.displayName)…").font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: fraction).controlSize(.small)
                }
            }

            Group {
                switch StatsTab.options(for: store.id).contains(tab) ? tab : .limits {
                case .limits: LimitsHistory(store: store, range: range)
                case .chats: ChatsHistory(web: ClaudeWeb.shared, range: range)
                case .tokens: TokensHistory(store: store, range: range)
                case .projects: ProjectsBreakdown(store: store, range: range)
                }
            }
            .id("\(tab.rawValue)-\(range.rawValue)")
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.25), value: tab)
        .animation(.smooth(duration: 0.25), value: range)
    }
}

/// Tick marks on whole hours or days, kept away from both edges so no label is clipped.
private func ticks(_ range: StatsRange, now: Date) -> [Date] {
    let calendar = Calendar.current
    let from = now.addingTimeInterval(-range.interval)
    let margin = range.interval * 0.07
    let step: (Calendar.Component, Int) = range == .day ? (.hour, 6) : (.day, range == .week ? 1 : 7)
    var tick = range == .day
        ? calendar.dateInterval(of: .hour, for: from)?.end ?? from
        : calendar.startOfDay(for: from.addingTimeInterval(86400))
    if range == .day {
        while calendar.component(.hour, from: tick) % 6 != 0 { tick = tick.addingTimeInterval(3600) }
    }
    var result: [Date] = []
    while tick < now {
        if tick.timeIntervalSince(from) > margin && now.timeIntervalSince(tick) > margin { result.append(tick) }
        tick = calendar.date(byAdding: step.0, value: step.1, to: tick) ?? now
    }
    return result
}

private func timeAxis(_ range: StatsRange) -> some AxisContent {
    AxisMarks(values: ticks(range, now: Date())) { value in
        AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
        AxisValueLabel {
            if let date = value.as(Date.self) {
                Text(range == .day ? Format.clock(date) : date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "ru_RU"))))
                    .font(.caption2)
            }
        }
    }
}

/// Two or three numbers above a chart, each with what it means.
private struct Figures: View {
    let items: [(value: String, label: String)]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.value).font(Theme.number(20)).monospacedDigit()
                    Text(item.label).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.well))
            }
        }
    }
}

private struct LimitsHistory: View {
    @ObservedObject var store: ProviderStore
    let range: StatsRange

    var body: some View {
        let now = Date()
        let points = Stats.limitSeries(store.samples, range, now: now)
        let exhausted = Stats.exhaustedWindows(store.samples, range, now: now)
        let peak = store.samples.filter { $0.kind == .weekly && $0.t >= now.addingTimeInterval(-range.interval) }.map(\.used).max()

        VStack(alignment: .leading, spacing: 12) {
            Figures(items: [
                ("\(exhausted)", "\(Format.plural(exhausted, "раз", "раза", "раз")) лимит на 5 часов закончился"),
                (peak.map { Format.percent($0) } ?? "—", "пик расхода недельного лимита"),
            ])
            let times = Pace.exhaustions(store.samples, since: now.addingTimeInterval(-range.interval))
            if !times.isEmpty {
                Label("Упирались в лимит: " + times.suffix(8).map { $0.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(Locale(identifier: "ru_RU"))) }.joined(separator: ", "),
                      systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            Well {
                if points.isEmpty {
                    EmptyChart(text: store.id == .claude
                               ? "Истории лимитов Claude пока нет: она копится, пока лимиты подключены."
                               : "За этот период данных о лимитах нет.")
                } else {
                    Chart(points) { point in
                        LineMark(x: .value("Время", point.t), y: .value("Потрачено", point.used), series: .value("Окно", point.series))
                            .foregroundStyle(by: .value("Окно", point.series))
                            .lineStyle(StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                    }
                    .chartForegroundStyleScale([WindowKind.session.title: store.tint, WindowKind.weekly.title: Theme.mint])
                    .chartYScale(domain: 0...100)
                    .chartXScale(domain: now.addingTimeInterval(-range.interval)...now)
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                            AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                            AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(.caption2) }
                        }
                    }
                    .chartXAxis { timeAxis(range) }
                    .chartLegend(position: .top, alignment: .leading, spacing: 6)
                    .frame(height: 170)
                }
            }
        }
    }
}

private struct TokensHistory: View {
    @ObservedObject var store: ProviderStore
    let range: StatsRange

    var body: some View {
        let now = Date()
        let points = Stats.tokenSeries(store.buckets, range, now: now)
        let totals = Stats.totals(store.buckets, range, now: now)
        let cachedShare = totals.input > 0 ? Double(totals.cached) / Double(totals.input) * 100 : 0

        VStack(alignment: .leading, spacing: 12) {
            if store.id == .claude {
                Note(symbol: "info.circle", text: "Токены считаются по Claude Code на этом Mac. Чаты и Cowork в Claude Desktop расход токенов локально не хранят, их активность на вкладке «Диалоги».")
                    .font(.caption)
                    .padding(.horizontal, 4)
            }
            if totals.total == 0 {
                Well { EmptyChart(text: "\(range.phrase.capitalizedFirst) \(store.id == .claude ? "Claude Code" : store.id.displayName) не расходовал токены.") }
            } else {
                let cost = Pricing.cost(store.buckets, range, now: now)
                Figures(items: [
                    (Format.tokens(totals.total), "токенов \(range.phrase)"),
                    (Format.percent(cachedShare), "входа прочитано из кеша"),
                    ("≈" + Pricing.format(cost.dollars), "стоило бы по API"),
                ])
                Text("Оценка по ценам API на октябрь 2026" + (cost.partial ? ", без моделей с неизвестной ценой" : "") + ". По подписке вы платите только её цену.")
                    .font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 4)
                Well {
                    Chart(points) { point in
                        BarMark(x: .value("Время", point.date, unit: range.unit), y: .value("Токены", point.value))
                            .foregroundStyle(by: .value("Тип", point.kind))
                            .cornerRadius(2)
                    }
                    .chartForegroundStyleScale([Stats.cachedKind: store.tint.opacity(0.32),
                                                Stats.freshKind: store.tint,
                                                Stats.outputKind: Theme.mint])
                    .chartXScale(domain: now.addingTimeInterval(-range.interval)...now)
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                            AxisValueLabel {
                                if let number = value.as(Double.self) { Text(Format.tokensAxis(Int(number))).font(.caption2) }
                            }
                        }
                    }
                    .chartXAxis { timeAxis(range) }
                    .chartLegend(position: .top, alignment: .leading, spacing: 6)
                    .frame(height: 170)
                }
            }
        }
    }
}

/// Claude Desktop and claude.ai activity: conversations by day, model and project.
private struct ChatsHistory: View {
    @ObservedObject var web: ClaudeWeb
    let range: StatsRange

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let activity = web.activity {
                let now = Date()
                let items = activity.inRange(range, now: now)
                let days = activity.days(range, now: now)
                let activeDays = Set(items.map { Calendar.current.startOfDay(for: $0.date) }).count
                Figures(items: [
                    ("\(items.count)", "\(Format.plural(items.count, "диалог", "диалога", "диалогов")) \(range.phrase)"),
                    ("\(activeDays)", "\(Format.plural(activeDays, "день", "дня", "дней")) с работой в Claude"),
                ])
                Well {
                    if days.isEmpty {
                        EmptyChart(text: "\(range.phrase.capitalizedFirst) диалогов не было.")
                    } else {
                        Chart(days) { day in
                            BarMark(x: .value("Время", day.date, unit: range.unit), y: .value("Диалоги", day.conversations))
                                .foregroundStyle(Theme.coral.gradient)
                                .cornerRadius(3)
                        }
                        .chartXScale(domain: now.addingTimeInterval(-range.interval)...now)
                        .chartYAxis {
                            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)").font(.caption2) }
                            }
                        }
                        .chartXAxis { timeAxis(range) }
                        .frame(height: 150)
                    }
                }
                let models = activity.shares(range) { $0.model }
                if !models.isEmpty {
                    SectionTitle(text: "Модели")
                    Well { ForEach(models) { row in ShareBar(row: row, color: Theme.coral, unit: "диал.") } }
                }
                let projects = activity.shares(range) { $0.project }
                if projects.count > 1 || projects.first?.name != "Без проекта" {
                    SectionTitle(text: "Проекты claude.ai")
                    Well { ForEach(projects) { row in ShareBar(row: row, color: Theme.coral, unit: "диал.") } }
                }
                Text("Обновлено \(Format.relative(activity.updated)). Считаются диалоги, которые менялись в этот период; сообщения не читаются.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            } else if web.isConnected {
                Well {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Загружаю активность claude.ai…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, minHeight: 90)
                }
                .task { await web.refreshActivity() }
            } else {
                Well {
                    Text("Войдите в claude.ai на вкладке «Лимиты», и здесь появится активность Claude Desktop: диалоги по дням, модели и проекты.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ProjectsBreakdown: View {
    @ObservedObject var store: ProviderStore
    let range: StatsRange

    var body: some View {
        let now = Date()
        let projects = Stats.projects(store.buckets, range, now: now)
        let models = Stats.models(store.buckets, range, now: now)

        VStack(alignment: .leading, spacing: 12) {
            if projects.isEmpty {
                Well { EmptyChart(text: "\(range.phrase.capitalizedFirst) работы в \(store.id.displayName) не было.") }
            } else {
                SectionTitle(text: "Проекты")
                Well {
                    ForEach(projects) { row in ShareBar(row: row, color: store.tint) }
                }
                let costly = TurnLog.shared.costliest(store.id, since: now.addingTimeInterval(-range.interval))
                if !costly.isEmpty {
                    SectionTitle(text: "Самые дорогие задачи")
                    Well(padding: 12) {
                        ForEach(Array(costly.enumerated()), id: \.element.id) { index, turn in
                            if index > 0 { Divider().opacity(0.5) }
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(turn.title).lineLimit(1)
                                    Text(turnDetail(turn)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                if let share = turn.limitShare, share >= 1 {
                                    Text(Format.percent(share)).monospacedDigit().foregroundStyle(store.tint)
                                }
                            }
                            .font(.callout)
                        }
                    }
                }
                if !models.isEmpty {
                    SectionTitle(text: "Модели")
                    Well {
                        ForEach(models) { row in
                            HStack {
                                Text(row.name).lineLimit(1)
                                Spacer()
                                if let dollars = modelDollars[row.name], dollars >= 0.01 {
                                    Text("≈\(Pricing.format(dollars))").monospacedDigit().foregroundStyle(.secondary)
                                }
                                Text(Format.percent(row.percent)).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(minWidth: 38, alignment: .trailing)
                            }
                            .font(.callout)
                        }
                    }
                    Text("Доля работы каждой модели и сколько та же работа стоила бы по API.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
            }
        }
    }
}

extension ProjectsBreakdown {
    private func turnDetail(_ turn: TurnLog.Turn) -> String {
        var parts = [turn.ended.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "ru_RU")))]
        if let seconds = turn.seconds, seconds >= 60 { parts.append(Format.duration(seconds)) }
        if let tokens = turn.tokens, tokens > 0 { parts.append("\(Format.tokens(tokens)) токенов") }
        return parts.joined(separator: " · ")
    }

    /// API-price estimate per model over the range.
    var modelDollars: [String: Double] {
        var result: [String: Double] = [:]
        for bucket in Stats.inRange(store.buckets, range, now: Date()) {
            guard let rate = Pricing.rate(for: bucket.key.model) else { continue }
            let c = bucket.counts
            result[bucket.key.model, default: 0] += (Double(c.freshInput) * rate.input + Double(c.cached) * rate.cached + Double(c.output) * rate.output) / 1_000_000
        }
        return result
    }
}

private struct ShareBar: View {
    let row: ShareRow
    let color: Color
    var unit: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.name).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(unit.map { "\(row.total) \($0)" } ?? Format.tokens(row.total)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            GeometryReader { geometry in
                Capsule()
                    .fill(row.id == "_rest" ? Color.secondary.opacity(0.35) : color.opacity(0.85))
                    .frame(width: max(4, geometry.size.width * row.share))
            }
            .frame(height: 5)
        }
    }
}

private struct EmptyChart: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 110)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
