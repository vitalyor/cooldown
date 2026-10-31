import SwiftUI

struct PickerList<Item: Identifiable, Row: View>: View {
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

struct PickerRow: View {
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

struct ClaudeChatPicker: View {
    @ObservedObject private var list = ClaudeChatList.shared
    @Binding var screen: Screen
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(L("Найти чат по названию или проекту"), text: $query)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
            if !ClaudeSender.hasPermission {
                Note(symbol: "exclamationmark.triangle.fill", text: L("Чтобы видеть чаты Claude, нужен «Универсальный доступ» для Cooldown (Настройки → Готовность)."), color: Theme.amber)
            } else if list.available.isEmpty && !list.loadingAvailable {
                Well {
                    Text(L("Откройте Claude Desktop — Cooldown возьмёт список чатов из его боковой панели."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(L("Обновить")) { list.refreshAvailable() }.buttonStyle(.glass)
                }
            }
            if list.availableSource == .window {
                Text(L("Здесь чаты из боковой панели Claude и те, что Cooldown уже видел открытыми."))
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
                            Text(L("Открыт сейчас в Claude"))
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
        else if !item.chat.id.isEmpty { parts.append(L("открывался %@", "\(Format.relative(item.chat.seen))")) }
        else { parts.append(L("из боковой панели")) }
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
struct AgentNowSection: View {
    @ObservedObject private var activity = AgentActivity.shared
    let provider: ProviderID

    var body: some View {
        let items = activity.waiting(provider) + activity.working(provider)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(text: L("Сейчас в %@", "\(provider.displayName)"))
                Well(padding: 12) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { Divider().opacity(0.5) }
                        HStack(spacing: 10) {
                            Circle().fill(session.state == .waiting ? Theme.amber : Theme.mint).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title.isEmpty ? L("Без названия") : session.title).lineLimit(1)
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
        if session.state == .waiting { return L("%@ · ждёт вашего решения", "\(place)") + (session.reason.map { ": \($0)" } ?? "") }
        let minutes = Int(Date().timeIntervalSince(session.started) / 60)
        return L("%@ · работает", "\(place)") + (minutes > 0 ? L(" %@ мин", "\(minutes)") : "")
    }
}
