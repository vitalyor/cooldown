import SwiftUI

// MARK: Обновления

struct UpdatesPane: View {
    @AppStorage(SettingsKey.updateMode) private var updateMode = Settings.updateMode
    @ObservedObject private var updater = GitHubUpdater.shared

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cooldown \(GitHubUpdater.current)").font(.headline)
                    if let available = updater.available {
                        Text(updater.readyVersion == available.version ? L("Версия %@ загружена и готова", "\(available.version)") : L("Доступна версия %@", "\(available.version)"))
                            .font(.callout).foregroundStyle(Theme.mint)
                    } else {
                        Text(updater.state ?? L("Установлена эта версия")).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if updater.available != nil {
                    Button(updater.installing ? L("Устанавливаю…") : L("Обновить")) { Task { await updater.install() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(updater.installing)
                } else {
                    Button(updater.checking ? L("Проверяю…") : L("Проверить")) { Task { await updater.check(manual: true) } }
                        .disabled(updater.checking || updater.installing)
                }
            }
            .padding(.vertical, 2)
        }
        Section {
            Picker(L("Новые версии"), selection: $updateMode) {
                Text(L("Не проверять")).tag("off")
                Text(L("Только скачивать")).tag("download")
                Text(L("Скачивать и ставить")).tag("auto")
            }
            .pickerStyle(.radioGroup)
            .onChange(of: updateMode) { _, _ in updater.modeChanged() }
        } footer: {
            Footnote(text: updateMode == "off"
                     ? L("Cooldown сам не проверяет новые версии; кнопка «Проверить» работает всегда.")
                     : updateMode == "download"
                     ? L("Новая версия загружается и проверяется заранее, а ставится одним нажатием — на карточке или здесь.")
                     : L("Новая версия ставится сама, когда Mac пару минут без дела. Перед установкой проверяются контрольная сумма и подпись тем же сертификатом."))
        }
        if let release = updater.available, !release.notes.isEmpty {
            Section(L("Что нового в %@", "\(release.version)")) {
                Text(release.notes.components(separatedBy: "\n---").first ?? release.notes)
                    .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button(L("Открыть на GitHub")) { updater.openReleasePage() }.buttonStyle(.link)
            }
        }
    }
}

// MARK: Статистика

struct DataPane: View {
    @EnvironmentObject private var model: AppModel
    @State private var message: String?
    @State private var rebuilding = false

    var body: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Таблица по дням"))
                    Footnote(text: L("Токены, деньги и доля недели для Codex и Claude — CSV для Numbers или Excel."))
                }
                Spacer()
                Button(L("Сохранить…")) { exportCSV() }
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Пересобрать статистику"))
                    Footnote(text: L("Заново прочитать историю сессий, если цифры кажутся неверными."))
                }
                Spacer()
                Button(rebuilding ? L("Читаю…") : L("Пересобрать")) {
                    rebuilding = true
                    Task {
                        await model.codex.scan(fullRebuild: true)
                        await model.claude.scan(fullRebuild: true)
                        rebuilding = false
                        message = L("Статистика пересобрана.")
                    }
                }
                .disabled(rebuilding)
            }
            if let message { Footnote(text: message) }
        } header: { Text(L("История")) } footer: {
            Footnote(text: L("Подробности — из сессий Codex и Claude Code за 45 дней; итоги по дням для «Года работы» хранятся дольше. Всё только на этом Mac."))
        }
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Демо"))
                    Footnote(text: L("За минуту по шагам на выдуманных данных: лимит кончается, задача ждёт и продолжается. Ваши данные потом вернутся."))
                }
                Spacer()
                Button(L("Показать")) {
                    StatusController.shared?.open()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { DemoController.shared.start() }
                }
            }
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "cooldown-\(DailyLog.key(Date())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var rows = ["date,codex_tokens,codex_usd,codex_week_percent,codex_done,claude_tokens,claude_usd,claude_week_percent,claude_done,claude_chats"]
        for (key, day) in DailyLog.shared.days.sorted(by: { $0.key < $1.key }) {
            rows.append([key, "\(day.codexTokens)", String(format: "%.2f", day.codexDollars), String(format: "%.1f", day.codexWeek), "\(day.codexDone)",
                         "\(day.claudeTokens)", String(format: "%.2f", day.claudeDollars), String(format: "%.1f", day.claudeWeek), "\(day.claudeDone)",
                         "\(day.chats)"].joined(separator: ","))
        }
        do {
            try (rows.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            message = L("Сохранено: %@", "\(url.lastPathComponent)")
        } catch {
            message = L("Не сохранилось: %@", "\(error.localizedDescription)")
        }
    }
}
