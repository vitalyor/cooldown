import Combine
import SwiftUI

/// Settings → VPN guard: what it is for, what it does now, and the few choices it needs.
struct GuardPane: View {
    @ObservedObject private var route = RouteGuard.shared
    @AppStorage(SettingsKey.guardEnabled) private var enabled = false
    @AppStorage(SettingsKey.guardFreeze) private var freeze = true
    @AppStorage(SettingsKey.guardFreezeTerminal) private var freezeTerminal = false
    @AppStorage(SettingsKey.guardForbidden) private var forbidden = Settings.guardForbiddenDefault
    @State private var problem: String?
    @State private var claudeVersion: String?
    @State private var now = Date()
    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        Section {
            OptionToggle(title: L("Защита от работы без VPN"),
                         detail: L("Claude, Codex и другие сервисы блокируют аккаунты, которыми пользуются из неподдерживаемых стран. Если VPN отвалился, Cooldown не даст агентам отправить запрос с вашего настоящего адреса."),
                         isOn: Binding(get: { enabled }, set: { problem = RouteGuard.setEnabled($0) }))
            if let problem { Note(symbol: "exclamationmark.triangle.fill", text: problem, color: Theme.amber).font(.caption) }
        } footer: {
            Footnote(text: L("Как это работает: Cooldown спрашивает сами сервисы (Anthropic, OpenAI и Google), из какой страны к ним приходят запросы, — по тому же пути, что и запросы агентов, поэтому неважно, где включён VPN: на Mac или на роутере. Запрос анонимный, без вашего аккаунта; своего сервера у Cooldown нет. Пока маршрут неправильный, Claude Code и Codex не отправляют сообщения, Cooldown сам не обращается к этим сервисам, а приложения агентов встают на паузу. Когда VPN вернётся, всё продолжится само."))
        }
        if enabled {
            Section {
                ForEach(GuardService.allCases.filter { ProviderID.shown.contains($0.provider) }, id: \.self) { service in
                    LabeledContent(service.name) {
                        HStack(spacing: 10) {
                            status(service)
                            // The guard for this agent alone (on by default).
                            Toggle("", isOn: Binding(get: { !service.off }, set: { route.setOff(service, !$0) }))
                                .labelsHidden()
                                .settingsSwitch(bare: true)
                                .controlSize(.mini)
                                .help(L("Защита для %@", service.name))
                        }
                    }
                }
                if let note = route.timeZoneNote {
                    Note(symbol: "clock.badge.exclamationmark", text: note, color: Theme.amber).font(.caption)
                }
                if route.timeZoneTarget != nil || TimeZoneSwitch.saved != nil {
                    TimeZoneButtons(target: route.timeZoneTarget)
                }
                HStack {
                    if let until = Settings.guardPausedUntil, until > now {
                        Text(L("Защита выключена до %@", Format.clock(until))).font(.caption).foregroundStyle(Theme.amber)
                        Spacer()
                        Button(L("Включить снова")) { RouteGuard.shared.pause(nil) }
                    } else {
                        Button(L("Выключить на час")) { RouteGuard.shared.pause(3600) }
                        Spacer()
                        Button(route.checking ? L("Проверяю…") : L("Проверить сейчас")) { Task { await RouteGuard.shared.round() } }
                            .disabled(route.checking)
                    }
                }
            } header: { Text(L("Маршрут сейчас")) }

            Section {
                OptionToggle(title: L("Ставить приложения на паузу"),
                             detail: L("Claude, ChatGPT (Codex) и Antigravity замирают, пока маршрут неправильный: ничего не закрывается и не теряется, ответ продолжится с того же места. Выключено — останавливаются только Claude Code и Codex."),
                             isOn: $freeze)
                    .onChange(of: freeze) { _, _ in RouteGuard.shared.enforce() }
                if freeze {
                    OptionToggle(title: L("И агентов в Терминале"),
                                 detail: L("Claude Code, Codex и Antigravity CLI, запущенные в Терминале, тоже замирают, даже посреди ответа. Терминал не реагирует, пока VPN не вернётся, потом всё продолжится. Выключено — их сообщения держат хуки."),
                                 isOn: $freezeTerminal)
                        .onChange(of: freezeTerminal) { _, _ in RouteGuard.shared.enforce() }
                }
                LabeledContent(L("Запрещённые страны")) {
                    TextField("", text: $forbidden)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 220)
                        .onSubmit { RouteGuard.shared.writeHookFiles(); Task { await RouteGuard.shared.round() } }
                        .onDisappear { RouteGuard.shared.writeHookFiles() }
                }
            } footer: {
                Footnote(text: L("Коды стран через пробел (RU — Россия, BY — Беларусь, CN — Китай). Маршрут через одну из них останавливает работу."))
            }

            let exits = Settings.guardExits
            if !exits.isEmpty || !Settings.guardRefused.isEmpty {
                Section {
                    // One row per address: a VPN usually takes every service out through the same one.
                    ForEach(Set(exits.values.flatMap(\.keys)).sorted(), id: \.self) { ip in
                        let services = GuardService.allCases.filter { exits[$0.rawValue]?[ip] != nil }
                        ExitRow(services: services, ip: ip,
                                name: services.compactMap { exits[$0.rawValue]?[ip] }.first { !$0.isEmpty } ?? "", refused: false)
                            .id("exit-" + ip)
                    }
                    ForEach(Settings.guardRefused, id: \.self) { ip in
                        ExitRow(services: [], ip: ip, name: "", refused: true).id("refused-" + ip)
                    }
                } header: { Text(L("Адреса выхода")) } footer: {
                    Footnote(text: L("Через эти адреса агенты уже выходили в сеть. Новый адрес в разрешённой стране работу не останавливает, но Cooldown спросит, разрешить ли его. Имя помогает узнать сервер в карточке."))
                }
            }

            Section {
                hookRow("Claude Code", AgentHooks.guardStatus(.claude), extra: claudeVersionNote)
                hookRow("Codex", AgentHooks.guardStatus(.codex),
                        extra: AgentHooks.guardStatus(.codex) != .on ? L("Codex запускает новый хук только после одобрения: откройте Codex, введите /hooks и отметьте хук Cooldown как доверенный.") : nil)
                if AntigravityGuard.present {
                    hookRow("Antigravity", AntigravityGuard.status,
                            extra: L("Останавливает Antigravity перед обращением к модели, пока маршрут до Google неправильный."))
                }
            } header: { Text(L("Хуки")) } footer: {
                Footnote(text: L("Хук держит ваше сообщение, пока Cooldown проверяет маршрут (обычно меньше секунды), и останавливает агента между шагами, если VPN отвалился посреди работы. Если Cooldown закрыт, хук проверяет маршрут сам."))
            }
        }
    }

    @ViewBuilder private func status(_ service: GuardService) -> some View {
        if service.off {
            Text(L("не проверяется")).foregroundStyle(.secondary)
        } else if let reading = route.readings[service], reading.at != .distantPast {
            let age = Format.duration(max(1, now.timeIntervalSince(reading.at)))
            switch reading.verdict {
            case .ok:
                let exit = reading.exit
                let name = exit.flatMap { RouteGuard.exitName(service, $0.ip) }
                Text(L("%@ · %@ · %@ назад", exit?.countryName ?? "", name ?? exit?.ip ?? "", age)).foregroundStyle(Theme.mint)
            case .forbidden:
                Text(L("%@ — работа остановлена", reading.exit?.countryName ?? "")).foregroundStyle(Theme.signal)
            case .refused:
                Text(L("адрес %@ запрещён", reading.exit?.ip ?? "")).foregroundStyle(Theme.signal)
            case .unchecked:
                Text(L("не удалось проверить")).foregroundStyle(Theme.amber)
            }
        } else {
            Text(L("проверяю…")).foregroundStyle(.secondary)
        }
    }

    private var claudeVersionNote: String? {
        guard let claudeVersion else { return nil }
        // Before 2.1.295 a hook that runs out of time lets the prompt through.
        return GitHubUpdater.isNewer("2.1.295", than: claudeVersion)
            ? L("Claude Code %@ устарел: при сбое проверки сообщение может уйти. Обновите его (claude update).", claudeVersion) : nil
    }

    @ViewBuilder private func hookRow(_ name: String, _ status: AgentHooks.Status, extra: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(name) {
                switch status {
                case .on: Text(L("включён")).foregroundStyle(Theme.mint)
                case .needsTrust: Text(L("ждёт одобрения")).foregroundStyle(Theme.amber)
                case .off: Text(L("не установлен")).foregroundStyle(.secondary)
                }
            }
            if let extra { Footnote(text: extra) }
        }
        .task { if name == "Claude Code", claudeVersion == nil { claudeVersion = await RouteGuard.claudeVersion() } }
        .onReceive(tick) { now = $0 }
    }
}

private struct ExitRow: View {
    let services: [GuardService]
    let ip: String
    @State var name: String
    let refused: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(ip).font(.callout.monospacedDigit())
                Text(refused ? L("запрещён") : services.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(refused ? Theme.signal : .secondary)
            }
            Spacer()
            if !refused {
                TextField("", text: $name, prompt: Text(L("Имя, например США-1")))
                    .labelsHidden()
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 170)
                    .onSubmit { services.forEach { RouteGuard.shared.rename($0, ip: ip, to: name) } }
            }
            Button { (services.isEmpty ? [.anthropic] : services).forEach { RouteGuard.shared.forget($0, ip: ip) } } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(L("Забыть адрес"))
        }
    }
}

/// "Put the VPN country's time zone" and "my zone back".
private struct TimeZoneButtons: View {
    let target: String?
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let target {
                    Button(L("Поставить пояс %@", target)) { act { try await TimeZoneSwitch.set(target) } }
                }
                Spacer()
                if let saved = TimeZoneSwitch.saved, saved != TimeZone.current.identifier {
                    Button(L("Вернуть мой пояс (%@)", saved)) { act { try await TimeZoneSwitch.restore() } }
                }
            }
            .disabled(busy)
            Footnote(text: problem ?? L("macOS попросит пароль администратора. Пока стоит пояс страны VPN, автоматический выбор пояса выключен; «Вернуть» включает его обратно."))
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        busy = true
        problem = nil
        Task {
            do { try await work() } catch { problem = L("Не удалось сменить часовой пояс: %@", error.localizedDescription) }
            busy = false
        }
    }
}
