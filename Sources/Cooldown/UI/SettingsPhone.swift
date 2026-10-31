import CooldownLink
import SwiftUI

// MARK: iPhone

struct PhonePane: View {
    @ObservedObject private var link = PhoneLink.shared
    @AppStorage(SettingsKey.phoneLink) private var enabled = false
    @AppStorage(SettingsKey.phoneAlways) private var always = false
    @AppStorage(SettingsKey.phoneLive) private var live = true
    @AppStorage(SettingsKey.phoneKeepAlive) private var keepAlive = true
    @AppStorage(SettingsKey.autoRestartAgents) private var autoRestart = true

    private var hasPhone: Bool { !link.devices.isEmpty || !(link.account?.peers.isEmpty ?? true) }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { enabled && link.account != nil || link.busy }, set: { on in
                Task { if on { await link.enable() } else { await link.disable() } }
            })) {
                Text(L("Cooldown для iPhone"))
                Text(L("Карточки с кнопками, лимиты, задачи и Live Activity на телефоне. Нажатое там выполняет этот Mac."))
            }
            .toggleStyle(.switch)
            .disabled(link.busy)
            if link.account != nil {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let message = link.message { Footnote(text: message) }
        } footer: {
            Footnote(text: L("Карточки, названия чатов и ответы шифруются на Mac и открываются только на вашем iPhone. Сервер Cooldown передаёт их, не читая; для Live Activity он видит только общие строки вроде «Claude работает» и время сброса."))
        }
        if link.account != nil {
            Section(L("Устройства")) {
                // The relay may be unreachable while the pairing in the vault is still valid:
                // show the known peers instead of claiming there is no iPhone.
                if link.devices.isEmpty, let peers = link.account?.peers, !peers.isEmpty {
                    ForEach(peers) { peer in
                        HStack {
                            Image(systemName: "iphone").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(peer.name)
                                Text(L("Связь с relay недоступна; пара сохранена"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(L("Отключить")) { Task { await link.unpair(peer.id) } }
                        }
                    }
                }
                ForEach(link.devices) { device in
                    HStack {
                        Image(systemName: "iphone").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name)
                            Text(device.online ? L("На связи") : L("Был на связи %@", "\(Format.relative(Date(timeIntervalSince1970: TimeInterval(device.seen))))"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Отключить")) { Task { await link.unpair(device.id) } }
                    }
                }
                if let invite = link.invite {
                    InviteView(invite: invite, expires: link.inviteExpires ?? Date())
                } else {
                    HStack {
                        Text(hasPhone ? L("Ещё один iPhone") : L("Пока ни одного iPhone"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Добавить iPhone")) { Task { await link.makeInvite() } }.disabled(link.busy)
                    }
                }
            }
            Section(L("Что приходит на iPhone")) {
                OptionToggle(title: L("Уведомлять, даже когда я за Mac"),
                             detail: L("Обычно телефон молчит, пока вы за Mac, и включается, когда Mac заблокирован или вас нет у него пару минут."),
                             isOn: $always)
                OptionToggle(title: L("Кнопки на экране блокировки"),
                             detail: L("Live Activity: пока агент работает — сколько он уже работает; ответы агентам и «Продолжить» — с кнопками; когда лимит кончился — отсчёт до сброса. Без лишних цифр."),
                             isOn: $live)
            }
            Section {
                OptionToggle(title: L("Держать связь с iPhone"),
                             detail: L("На мобильном интернете iPhone теряет связь с сервисом уведомлений Apple и получает уведомления пачкой раз в 10 минут. Пока агенты работают, Cooldown шлёт тихий сигнал: на мобильном интернете раз в 2,5 минуты — и уведомления приходят сразу, на Wi‑Fi раз в 10 минут, только чтобы заметить, что вы ушли. На телефоне его не видно."),
                             isOn: $keepAlive)
                OptionToggle(title: L("Перезапускать Codex, если он перестал отвечать"),
                             detail: L("Иногда Codex теряет связь с Cooldown: вопросы и автопродолжение перестают работать. Cooldown перезапустит его сам — только когда в нём ничего не идёт, как ⌘Q, — и скажет об этом. С iPhone перезапуск можно запустить кнопкой на карточке (с Face ID)."),
                             isOn: $autoRestart)
            }
            Section(L("Доставка")) {
                if let last = link.lastDelivery {
                    HStack(spacing: 6) {
                        Image(systemName: last.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(last.ok ? .green : .orange)
                        Text(last.ok
                             ? L("Последнее уведомление дошло за %@ с · %@", (last.seconds ?? 0).formatted(.number.precision(.fractionLength(1)).locale(AppLanguage.locale)), Format.relative(last.at))
                             : L("Последнее уведомление iPhone не подтвердил · %@", Format.relative(last.at)))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let summary = link.historySummary {
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
                if let hint = link.slowHint {
                    Label(hint, systemImage: "antenna.radiowaves.left.and.right.slash").font(.callout).foregroundStyle(.orange)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Проверить доставку"))
                        Text(L("Пришлёт на iPhone уведомление и покажет, за сколько оно дошло. Каждое уведомление iPhone подтверждает; неподтверждённое сервер отправит ещё раз."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if link.checking { ProgressView().controlSize(.small) }
                    Button(L("Проверить")) { link.checkDelivery() }.disabled(link.checking || !hasPhone)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Пробный прогон"))
                        Text(L("Как будто агент поработал, пока вас нет: на iPhone Live Activity «работает» с таймером, через 40 секунд — уведомление «готово», и Live Activity закрывается. На Mac ничего не запускается."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if link.rehearsing { ProgressView().controlSize(.small) }
                    Button(L("Запустить")) { link.rehearse() }.disabled(link.rehearsing || !hasPhone)
                }
                HStack {
                    Text(L("Журналы доставки: Mac и iPhone")).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Показать")) {
                        let folder = Settings.appSupport
                        let files = ["activity.log", "phone-delivery.log"].map { folder.appendingPathComponent($0) }
                            .filter { FileManager.default.fileExists(atPath: $0.path) }
                        if files.isEmpty { NSWorkspace.shared.open(folder) } else { NSWorkspace.shared.activateFileViewerSelecting(files) }
                    }
                }
                if let result = link.checkResult {
                    Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(result.ok ? .green : .orange)
                }
            }
        }
    }

    private var statusColor: Color {
        switch link.status {
        case .online: return .green
        case .connecting: return .orange
        default: return .secondary
        }
    }

    private var statusText: String {
        switch link.status {
        case .online: return L("Подключено к серверу Cooldown")
        case .connecting: return L("Подключаюсь…")
        case .offline: return L("Нет связи с сервером — повторю сам")
        case .off: return L("Выключено")
        }
    }
}

struct InviteView: View {
    let invite: PairingInvite
    let expires: Date
    @State private var qr: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if let qr {
                Image(nsImage: qr).interpolation(.none).resizable().frame(width: 168, height: 168)
                    .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Отсканируйте камерой iPhone")).font(.headline)
                Footnote(text: L("Откройте Cooldown на iPhone или просто наведите камеру на код. Код одноразовый и действует 5 минут."))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, expires.timeIntervalSince(context.date))
                    Text(left > 0 ? L("Осталось %@", "\(Int(left) / 60):\(String(format: "%02d", Int(left) % 60))") : L("Код истёк"))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack {
                    Button(L("Новый код")) { Task { await PhoneLink.shared.makeInvite() } }
                    Button(L("Отмена")) { PhoneLink.shared.cancelInvite() }
                }
            }
        }
        .padding(.vertical, 6)
        .task(id: invite.url.absoluteString) {
            // The code is redrawn only when the invite changes, not on every clock tick.
            qr = PhoneLink.qr(invite.url)
        }
    }
}
