import SwiftUI

struct ClaudeDesktopCard: View {
    @AppStorage(SettingsKey.notifyReset) private var notifyReset = true
    @AppStorage(SettingsKey.claudeAutoContinue) private var autoContinue = true
    @AppStorage(SettingsKey.claudeContinueText) private var continueText = ""
    @ObservedObject private var auto = ClaudeAutoContinue.shared
    @State private var sending = false
    @State private var result: String?
    @State private var failed = false

    var body: some View {
        Well {
            Label(L("Чаты Claude — продолжение после сброса"), systemImage: "bubble.left.and.text.bubble.right")
                .font(.system(size: 13, weight: .semibold))
            Text(L("Когда лимит восстановится, Cooldown продолжит выбранные чаты сам. Если не получится — например, нет разрешения или в поле ввода уже есть текст — придёт карточка «Продолжить»."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L("Продолжать автоматически"), isOn: $autoContinue).toggleStyle(.switch)
            Toggle(L("Сообщать, когда лимит восстановился"), isOn: $notifyReset).toggleStyle(.switch)
            TextField(ClaudeSender.defaultText, text: $continueText, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button { send() } label: {
                    Label(sending ? L("Отправляю…") : L("Продолжить сейчас"), systemImage: "paperplane").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.coral)
                .disabled(sending)
                Button { ClaudeApp.open() } label: { Label(L("Открыть"), systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.glass)
            }
            if !ClaudeSender.hasPermission {
                Text(L("Для отправки macOS один раз попросит разрешение «Универсальный доступ»."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if auto.running {
                Text(L("Продолжаю чаты…")).font(.caption).foregroundStyle(.secondary)
            } else if let summary = auto.lastSummary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
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
                result = L("Отправлено в открытый чат Claude.")
            } catch {
                failed = true
                result = error.localizedDescription
            }
            sending = false
        }
    }
}
