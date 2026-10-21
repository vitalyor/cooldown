import SwiftUI

/// What happened while you were away: limits back, tasks continued, finished or waiting.
struct FeedScreen: View {
    @Binding var screen: Screen
    @ObservedObject private var log = EventLog.shared
    @State private var seenBefore = EventLog.shared.lastSeen
    @State private var query = ""
    @State private var filter: ProviderID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                BackBar(title: "События") { screen = .home }
                if !log.events.isEmpty {
                    Button("Очистить") { log.clear() }.buttonStyle(.link).font(.caption)
                }
            }
            if !log.events.isEmpty {
                HStack(spacing: 8) {
                    TextField("Поиск по событиям", text: $query)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .glassEffect(.regular, in: .capsule)
                    Picker("", selection: $filter) {
                        Text("Все").tag(ProviderID?.none)
                        Text("Codex").tag(ProviderID?.some(.codex))
                        Text("Claude").tag(ProviderID?.some(.claude))
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if log.events.isEmpty {
                Well {
                    VStack(spacing: 6) {
                        Image(systemName: "tray").font(.system(size: 22, weight: .light)).foregroundStyle(.secondary)
                        Text("Пока ничего не произошло. Здесь появятся сбросы лимитов, продолженные и законченные задачи.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(groups, id: \.title) { group in
                            SectionTitle(text: group.title)
                            Well(padding: 12) {
                                ForEach(Array(group.events.enumerated()), id: \.element.id) { index, event in
                                    if index > 0 { Divider().opacity(0.5) }
                                    row(event)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { log.markSeen() }
    }

    private var groups: [(title: String, events: [CooldownEvent])] {
        let calendar = Calendar.current
        var result: [(String, [CooldownEvent])] = []
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = log.events.filter { event in
            (filter == nil || event.provider == filter)
                && (term.isEmpty || event.title.lowercased().contains(term) || event.body.lowercased().contains(term))
        }
        for event in shown {
            let title = calendar.isDateInToday(event.date) ? "Сегодня"
                : calendar.isDateInYesterday(event.date) ? "Вчера" : Format.day(event.date)
            if let last = result.indices.last, result[last].0 == title { result[last].1.append(event) }
            else { result.append((title, [event])) }
        }
        return result
    }

    private func row(_ event: CooldownEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(event.kind)).foregroundStyle(color(event.kind)).frame(width: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.title).font(.system(size: 13, weight: event.date > seenBefore ? .semibold : .regular)).lineLimit(2)
                    if event.date > seenBefore { Circle().fill(Theme.cobalt).frame(width: 6, height: 6) }
                }
                if !event.body.isEmpty {
                    Text(event.body).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                Text(Format.clock(event.date)).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if let thread = event.threadId {
                Button { CodexApp.open(thread: thread) } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Открыть в Codex")
            }
        }
    }

    private func symbol(_ kind: CooldownEvent.Kind) -> String {
        switch kind {
        case .reset: return "arrow.counterclockwise.circle.fill"
        case .finished: return "checkmark.circle.fill"
        case .resumed: return "play.circle.fill"
        case .waiting: return "hourglass.circle.fill"
        case .attention: return "hand.raised.circle.fill"
        case .budget, .failure: return "exclamationmark.circle.fill"
        case .scheduled: return "clock.arrow.circlepath"
        case .info: return "info.circle.fill"
        }
    }

    private func color(_ kind: CooldownEvent.Kind) -> Color {
        switch kind {
        case .reset, .finished: return Theme.mint
        case .resumed, .scheduled, .info: return Theme.cobalt
        case .waiting: return .secondary
        case .attention: return Theme.amber
        case .budget, .failure: return Theme.signal
        }
    }
}
