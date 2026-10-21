import AppKit
import SwiftUI

/// Write a Codex task now; Cooldown starts it as soon as Codex has limit again.
struct ScheduleScreen: View {
    @EnvironmentObject private var model: AppModel
    @Binding var screen: Screen
    @State private var prompt = ""
    @State private var folder = UserDefaults.standard.string(forKey: "scheduleFolder") ?? ""
    @State private var canEdit = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BackBar(title: "Запуск после сброса") { screen = .home }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(waitingText)
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 6) {
                        SectionTitle(text: "Что сделать")
                        TextEditor(text: $prompt)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(height: 140)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.well))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        SectionTitle(text: "Папка проекта")
                        Well {
                            HStack {
                                Text(folder.isEmpty ? "Не выбрана" : folder)
                                    .font(.caption).foregroundStyle(folder.isEmpty ? Theme.amber : .secondary)
                                    .lineLimit(2).truncationMode(.middle)
                                Spacer()
                                Button("Выбрать…") { choose() }.buttonStyle(.link)
                            }
                            Toggle("Может менять файлы в этой папке", isOn: $canEdit).toggleStyle(.switch)
                            Text(canEdit ? "Codex работает в песочнице этой папки и сам решает простые подтверждения. За её пределы он не выходит."
                                         : "Только чтение: Codex изучит файлы и ответит, но ничего не изменит.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button {
                        ScheduledRunner.shared.add(prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines), folder: folder, canEdit: canEdit)
                        UserDefaults.standard.set(folder, forKey: "scheduleFolder")
                        screen = .home
                    } label: {
                        Label("Запланировать", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.tint(for: .codex))
                    .controlSize(.large)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || folder.isEmpty)
                }
                .padding(.bottom, 16)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var waitingText: String {
        guard let session = model.codex.snapshot?.session else {
            return "Cooldown запустит задачу в Codex, как только у него будет лимит."
        }
        if session.remaining(at: Date()) < 5 {
            return "Лимит Codex сейчас исчерпан. Задача запустится сама после сброса в \(Format.time(session.resetsAt)) — даже если вас не будет рядом."
        }
        return "Лимит у Codex сейчас есть, поэтому задача запустится сразу. Ставьте задачи сюда, когда лимит кончился, — они пойдут в работу после сброса."
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}

/// The scheduled tasks on the Codex Tasks tab.
struct ScheduledSection: View {
    @ObservedObject var runner = ScheduledRunner.shared
    @Binding var screen: Screen

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(text: "Запуск после сброса")
                Spacer()
                Button { screen = .schedule } label: { Label("Запланировать", systemImage: "plus") }
                    .buttonStyle(.link).font(.caption)
            }
            if runner.waiting.isEmpty && runner.recent.isEmpty {
                Text("Лимит кончился, а задачи ещё есть? Запишите их сюда — Codex начнёт сразу после сброса.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            } else {
                Well(padding: 12) {
                    ForEach(Array((runner.waiting + runner.recent).enumerated()), id: \.element.id) { index, task in
                        if index > 0 { Divider().opacity(0.5) }
                        row(task)
                    }
                }
            }
        }
    }

    private func row(_ task: ScheduledTask) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(task.state)).foregroundStyle(color(task.state)).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).lineLimit(2)
                Text(subtitle(task)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 4)
            switch task.state {
            case .waiting, .running:
                Button(task.state == .running ? "Остановить" : "Отменить") { runner.cancel(task.id) }
                    .buttonStyle(.link).font(.caption)
            default:
                Menu {
                    Button("Открыть журнал") { NSWorkspace.shared.open(runner.logURL(task)) }
                    Button("Убрать из списка") { runner.remove(task.id) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).frame(width: 24)
            }
        }
    }

    private func subtitle(_ task: ScheduledTask) -> String {
        let place = Stats.projectName(task.folder)
        switch task.state {
        case .waiting: return "\(place) · ждёт лимита"
        case .running: return "\(place) · выполняется с \(task.started.map { Format.time($0) } ?? "")"
        case .done: return "\(place) · \(task.result ?? "готово")"
        case .failed: return "\(place) · \(task.result ?? "не удалось")"
        case .cancelled: return "\(place) · отменено"
        }
    }

    private func symbol(_ state: ScheduledTask.State) -> String {
        switch state {
        case .waiting: return "clock"
        case .running: return "play.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private func color(_ state: ScheduledTask.State) -> Color {
        switch state {
        case .waiting: return .secondary
        case .running: return Theme.cobalt
        case .done: return Theme.mint
        case .failed: return Theme.amber
        case .cancelled: return .secondary
        }
    }
}
