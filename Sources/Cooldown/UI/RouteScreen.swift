import Combine
import SwiftUI

/// The VPN guard in the main window: where the agents go out now, what is held and why, and the
/// few things to do about it. Opened from the shield in the header or a banner on the limits.
struct RouteScreen: View {
    @Binding var screen: Screen
    var render = false
    @ObservedObject private var route = RouteGuard.shared
    @State private var now = Date()
    @State private var copied: String?
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BackBar(title: L("Защита VPN")) { screen = .home }
            if render { content } else { ScrollView(.vertical, showsIndicators: false) { content } }
        }
        .padding(14)
        .frame(maxHeight: render ? nil : .infinity, alignment: .top)
        .onReceive(tick) { now = $0 }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            hero
            if !newExits.isEmpty { newExitWell }
            SectionTitle(text: L("Агенты"))
            Well(padding: 12) {
                ForEach(Array(services.enumerated()), id: \.element) { index, service in
                    if index > 0 { Divider().opacity(0.5) }
                    agentRow(service)
                }
            }
            if !Freezer.shared.frozenNames.isEmpty {
                SectionTitle(text: L("Сейчас на паузе"))
                Well(padding: 12) {
                    ForEach(Freezer.shared.frozenNames, id: \.self) { name in
                        Label(name, systemImage: "pause.circle.fill").font(.callout).foregroundStyle(Theme.signal)
                    }
                    Footnote(text: L("Ничего не закрыто и не потеряно: приложения продолжат с того же места, когда маршрут придёт в норму."))
                }
            }
            if let note = route.timeZoneNote {
                SectionTitle(text: L("Часовой пояс"))
                Well(padding: 12) {
                    Note(symbol: "clock.badge.exclamationmark", text: note, color: Theme.amber)
                    TimeZoneButtons(target: route.timeZoneTarget)
                }
            }
            Button(L("Настройки защиты")) { SettingsWindow.shared.show(.vpn) }
                .buttonStyle(.link).font(.callout)
                .padding(.leading, 4)
        }
        .padding(.bottom, 16)
    }

    private var services: [GuardService] { GuardService.allCases.filter { ProviderID.shown.contains($0.provider) } }
    private var paused: Date? { Settings.guardPausedUntil.flatMap { $0 > now ? $0 : nil } }

    // MARK: The state at a glance

    private var hero: some View {
        let look = route.overall
        let state = heroState(look)
        let exits = route.exits
        return Well {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(state.color.opacity(0.16))
                    Image(systemName: state.symbol)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(state.color)
                        .symbolEffect(.pulse, options: .repeating, isActive: look == .held && paused == nil && !render)
                }
                .frame(width: 56, height: 56)
                .shadow(color: state.color.opacity(0.35), radius: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.title).font(.system(size: 17, weight: .semibold))
                    Text(state.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if paused == nil, look != .off, let at = route.checkedAt {
                        Text(L("Проверено %@ назад", Format.duration(max(1, now.timeIntervalSince(at)))))
                            .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
            }
            if paused == nil, look != .off {
                if look == .held, let exit = services.first(where: { route.look($0) == .held }).flatMap({ route.readings[$0]?.appExit ?? route.readings[$0]?.exit }) {
                    exitPlate(exit, held: true)
                } else if exits.count == 1, let exit = exits.first {
                    exitPlate(exit, held: false)
                } else if exits.count > 1 {
                    Note(symbol: "arrow.triangle.branch", text: L("Агенты выходят через разные адреса — по каждому ниже."))
                }
            }
            HStack(spacing: 8) {
                if paused != nil {
                    Button(L("Включить снова")) { route.pause(nil) }.buttonStyle(.glassProminent).tint(Theme.mint)
                } else {
                    Button(route.checking ? L("Проверяю…") : L("Проверить сейчас")) { Task { await route.round() } }
                        .buttonStyle(.glass).disabled(route.checking)
                    Button(L("Выключить на час")) { route.pause(3600) }.buttonStyle(.glass)
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
        }
    }

    private struct HeroState { let symbol: String; let color: Color; let title: String; let detail: String }

    private func heroState(_ look: RouteLook) -> HeroState {
        if let paused {
            return HeroState(symbol: "shield.slash.fill", color: Theme.amber, title: L("Защита выключена до %@", Format.clock(paused)),
                             detail: L("Агенты работают без проверки маршрута."))
        }
        let held = services.filter { route.look($0) == .held }.map(\.name)
        switch look {
        case .off:
            return HeroState(symbol: "shield.slash", color: .secondary, title: L("Агенты не защищены"),
                             detail: L("Защита выключена для каждого агента. Включить можно в настройках."))
        case .waiting:
            return HeroState(symbol: "shield", color: .secondary, title: L("Проверяю маршрут…"),
                             detail: L("Обычно это меньше секунды."))
        case .ok:
            return HeroState(symbol: "checkmark.shield.fill", color: Theme.mint, title: L("Маршрут в порядке"),
                             detail: L("Агенты выходят в сеть через VPN."))
        case .unsure:
            return HeroState(symbol: "questionmark.diamond.fill", color: Theme.amber, title: L("Маршрут не проверен"),
                             detail: L("Сервис не ответил. Cooldown проверит ещё раз через несколько секунд."))
        case .terminalOnly:
            return HeroState(symbol: "exclamationmark.shield.fill", color: Theme.amber, title: L("Терминал на паузе"),
                             detail: L("Приложения ходят через прокси и работают, а агенты в Терминале идут мимо VPN."))
        case .held:
            return HeroState(symbol: "exclamationmark.shield.fill", color: Theme.signal, title: L("Работа на паузе"),
                             detail: L("%@: маршрут идёт мимо VPN. Всё продолжится само, когда VPN вернётся.", held.joined(separator: ", ")))
        }
    }

    /// The country and address everything goes out through, big enough to read at a glance.
    private func exitPlate(_ exit: RouteExit, held: Bool) -> some View {
        let name = GuardService.allCases.lazy.compactMap { RouteGuard.exitName($0, exit.ip) }.first
        return HStack(spacing: 12) {
            Text(exit.flag).font(.system(size: 30))
            VStack(alignment: .leading, spacing: 2) {
                Text(exit.countryName).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(held ? Theme.signal : .primary)
                HStack(spacing: 6) {
                    Text(exit.ip).font(.callout.monospacedDigit()).textSelection(.enabled)
                    if let name { Text("· " + name).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            copyButton(exit.ip)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func copyButton(_ ip: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ip, forType: .string)
            copied = ip
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == ip { copied = nil } }
        } label: {
            Image(systemName: copied == ip ? "checkmark" : "doc.on.doc").frame(width: 22, height: 22)
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .help(L("Скопировать адрес"))
    }

    // MARK: Each agent

    private func agentRow(_ service: GuardService) -> some View {
        let look = route.look(service)
        let reading = route.readings[service]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(Theme.tint(for: service.provider)).frame(width: 8, height: 8)
                Text(service.name).font(.system(size: 13.5, weight: .semibold))
                Spacer(minLength: 0)
                chip(look)
            }
            if look != .off, let exit = reading?.exit {
                exitLine(exit, prefix: reading?.proxied == true ? L("Терминал:") : nil)
            }
            if look != .off, let reading, reading.proxied, let app = reading.appExit {
                exitLine(app, prefix: L("Приложение (прокси):"))
            }
        }
        .padding(.vertical, 2)
    }

    private func exitLine(_ exit: RouteExit, prefix: String?) -> some View {
        let name = RouteGuard.exitName(.anthropic, exit.ip)
        return HStack(spacing: 5) {
            if let prefix { Text(prefix).foregroundStyle(.secondary) }
            Text(exit.flag)
            Text(exit.countryName)
            Text("·").foregroundStyle(.tertiary)
            Text(name ?? exit.ip).monospacedDigit().lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 16)
    }

    private func chip(_ look: RouteLook) -> some View {
        let (text, color): (String, Color) = {
            if paused != nil, look != .off { return (L("без проверки"), Theme.amber) }
            switch look {
            case .off: return (L("не защищён"), .secondary)
            case .waiting: return (L("проверяю…"), .secondary)
            case .ok: return (L("в порядке"), Theme.mint)
            case .unsure: return (L("не проверен"), Theme.amber)
            case .terminalOnly: return (L("Терминал на паузе"), Theme.amber)
            case .held: return (L("на паузе"), Theme.signal)
            }
        }()
        return Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    // MARK: A new address

    private var newExits: [(service: GuardService, exit: RouteExit)] {
        route.pending.values.filter { GuardService.watched.contains($0.service) }
            .sorted { ($0.service.rawValue, $0.exit.ip) < ($1.service.rawValue, $1.exit.ip) }
    }

    private var newExitWell: some View {
        let key = route.pendingKey
        return Well(padding: 12) {
            Label(L("Новый адрес выхода"), systemImage: "arrow.triangle.swap").font(.system(size: 14, weight: .semibold))
            ForEach(newExits, id: \.exit.ip) { item in
                HStack(spacing: 5) {
                    Text(item.service.name).fontWeight(.medium)
                    Text(item.exit.flag)
                    Text(item.exit.countryName)
                    Text("·").foregroundStyle(.tertiary)
                    Text(item.exit.ip).monospacedDigit()
                }
                .font(.callout)
            }
            Footnote(text: L("Работа не остановлена: страна разрешена. Запомните адрес, если это ваш VPN."))
            HStack(spacing: 8) {
                Button(L("Разрешить и запомнить")) { route.answerExit(.remember, key: key) }.buttonStyle(.glassProminent).tint(Theme.mint)
                Button(L("Только сейчас")) { route.answerExit(.once, key: key) }.buttonStyle(.glass)
                Button(L("Запретить")) { route.answerExit(.refuse, key: key) }.buttonStyle(.glass)
            }
            .font(.callout)
        }
    }
}

/// The shield in the header: the VPN country's flag while all is well, a red shield while work is
/// held. Shown only with the guard switched on.
struct GuardButton: View {
    @ObservedObject private var route = RouteGuard.shared
    @AppStorage(SettingsKey.guardEnabled) private var enabled = false
    @Binding var screen: Screen

    var body: some View {
        if enabled || RouteGuard.sample {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                let paused = Settings.guardPaused(context.date)
                let look = route.overall
                let exits = route.exits
                Button { screen = .route } label: {
                    ZStack {
                        if !paused, look == .ok, exits.count == 1, let exit = exits.first {
                            Text(exit.flag).font(.system(size: 17))
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "checkmark.shield.fill")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(Theme.mint)
                                        .background(Circle().fill(.background).padding(-1))
                                        .offset(x: 5, y: 4)
                                }
                        } else {
                            Image(systemName: symbol(look, paused: paused))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(color(look, paused: paused))
                                .symbolEffect(.pulse, options: .repeating, isActive: look == .held && !paused)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help(help(look, paused: paused, exits: exits))
                .accessibilityLabel(L("Защита VPN"))
            }
        }
    }

    private func symbol(_ look: RouteLook, paused: Bool) -> String {
        if paused { return "shield.slash" }
        switch look {
        case .off: return "shield.slash"
        case .waiting: return "shield"
        case .ok: return "checkmark.shield.fill"
        case .unsure: return "questionmark.diamond"
        case .terminalOnly, .held: return "exclamationmark.shield.fill"
        }
    }

    private func color(_ look: RouteLook, paused: Bool) -> Color {
        if paused { return Theme.amber }
        switch look {
        case .off, .waiting: return .secondary
        case .ok: return Theme.mint
        case .unsure, .terminalOnly: return Theme.amber
        case .held: return Theme.signal
        }
    }

    private func help(_ look: RouteLook, paused: Bool, exits: [RouteExit]) -> String {
        if paused { return L("Защита VPN выключена на время") }
        let place = exits.map { "\($0.countryName), \($0.ip)" }.joined(separator: "; ")
        switch look {
        case .held: return L("Защита VPN: работа на паузе")
        case .ok: return place.isEmpty ? L("Защита VPN: маршрут в порядке") : L("Защита VPN: %@", place)
        default: return L("Защита VPN")
        }
    }
}

/// On the limits of an agent whose work is held: why, in one line, and the way to the details.
struct RouteBanner: View {
    let provider: ProviderID
    @Binding var screen: Screen
    @ObservedObject private var route = RouteGuard.shared

    var body: some View {
        let service = GuardService.of(provider)
        let look = route.look(service)
        if (Settings.guardEnabled || RouteGuard.sample), !Settings.guardPaused(Date()), look == .held || look == .terminalOnly {
            let exit = route.readings[service]?.exit
            let held = look == .held
            Button { screen = .route } label: {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(held ? Theme.signal : Theme.amber)
                        .symbolEffect(.pulse, options: .repeating, isActive: held)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(held ? L("%@ на паузе", provider.displayName) : L("%@ в Терминале на паузе", provider.displayName))
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(exit.map { L("Маршрут идёт через %@ %@ — мимо VPN.", $0.flag, $0.countryName) } ?? L("Маршрут не удалось проверить."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill((held ? Theme.signal : Theme.amber).opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder((held ? Theme.signal : Theme.amber).opacity(0.3), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
