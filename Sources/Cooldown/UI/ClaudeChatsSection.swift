import SwiftUI

struct ClaudeChatsSection: View {
    @ObservedObject private var list = ClaudeChatList.shared
    @Binding var screen: Screen
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(text: L("Чаты для продолжения"))
                Spacer()
                Button {
                    AddTaskScreen.wantsClaudeCode = false
                    screen = .addTask
                } label: { Label(L("Выбрать чат"), systemImage: "plus") }
                    .buttonStyle(.link).font(.caption)
            }
            if list.entries.isEmpty {
                Text(L("Выберите чаты Claude, которые нужно продолжить, когда лимит восстановится. Если не выбрать, Cooldown сам запомнит чат, в котором кончился лимит."))
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
                                Button(L("Продолжить сейчас")) { send(entry) }
                                Button(L("Убрать")) { list.remove(entry) }
                            } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 28, height: 22)
                        }
                    }
                }
                if list.entries.count >= 2 {
                    Button {
                        Task { await list.continueAll(list.entries.map(\.chat)) }
                    } label: {
                        Label(list.continuing ? L("Продолжаю…") : L("Продолжить все сейчас"), systemImage: "paperplane").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .disabled(list.continuing)
                }
            }
            if let error { Note(symbol: "exclamationmark.triangle.fill", text: error, color: Theme.amber) }
        }
    }

    private func subtitle(_ entry: ClaudeChatList.Entry) -> String {
        var parts: [String] = [entry.automatic ? L("запомнен при исчерпании лимита") : L("выбран вами")]
        if let sent = entry.lastSent { parts.append(L("продолжен %@", "\(Format.relative(sent))")) }
        if let attempt = entry.lastAttempt, Date().timeIntervalSince(attempt) < 3600 {
            switch entry.lastOutcome {
            case "trying": parts.append(L("пробую продолжить"))
            case "failed": parts.append(L("не удалось продолжить"))
            case "uncertain": parts.append(L("проверьте, дошло ли сообщение"))
            default: break
            }
        }
        return parts.joined(separator: " · ")
    }

    private func send(_ entry: ClaudeChatList.Entry) {
        error = nil
        Task {
            do { try await ClaudeSender.continueChat(entry.chat) } catch { self.error = error.localizedDescription }
        }
    }
}
