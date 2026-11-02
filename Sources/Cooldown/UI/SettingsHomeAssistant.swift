import SwiftUI

struct HomeAssistantRow: View {
    @ObservedObject private var ha = HomeAssistant.shared
    @AppStorage(SettingsKey.haURL) private var url = ""
    @AppStorage(SettingsKey.haDevice) private var device = ""
    @AppStorage(SettingsKey.haLive) private var live = true
    @AppStorage(SettingsKey.haNotify) private var notify = true
    @State private var token = ""
    @State private var hasToken = !(HomeAssistant.token ?? "").isEmpty
    @State private var busy = false

    /// http to a host outside the home network: the token and card texts would travel in the clear.
    static func plainOverNetwork(_ address: String) -> Bool {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)), url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") { return false }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            if parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
                || (parts[0] == 100 && (64...127).contains(parts[1])) { return false }
        }
        return true
    }

    var body: some View {
        TextField(L("Адрес"), text: $url, prompt: Text("http://localhost:8123"))
        if Self.plainOverNetwork(url) {
            Text(L("Адрес без https и не в домашней сети: токен и тексты карточек пойдут открытым текстом. Лучше https."))
                .font(.caption).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            SecureField(L("Токен"), text: $token, prompt: Text(hasToken ? L("Сохранён в Связке ключей") : L("Долгосрочный токен")))
            Button(L("Сохранить")) {
                HomeAssistant.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
                token = ""
                hasToken = !(HomeAssistant.token ?? "").isEmpty
                run()
            }
            .disabled(token.isEmpty)
        }
        if !ha.devices.isEmpty {
            Picker("iPhone", selection: $device) {
                ForEach(ha.devices, id: \.self) { Text($0.replacingOccurrences(of: "mobile_app_", with: "")).tag($0) }
            }
        }
        OptionToggle(title: L("Live Activity с лимитами"), isOn: $live)
        OptionToggle(title: L("Уведомления, когда вы не за Mac"), isOn: $notify)
        HStack {
            Spacer()
            Button(busy ? L("Отправляю…") : L("Проверить на iPhone")) { run() }.disabled(busy || !hasToken)
            Button(L("Виджет в Scriptable")) {
                do {
                    let address = try HomeAssistant.shared.installWidget()
                    ha.status = L("Скрипт «Cooldown» добавлен в Scriptable через iCloud (адрес %@). Вставьте токен Home Assistant в строку TOKEN на iPhone.", "\(address)")
                } catch { ha.status = error.localizedDescription }
            }
            .disabled(!hasToken)
        }
        if let status = ha.status { Footnote(text: status) }
    }

    private func run() {
        busy = true
        Task {
            await HomeAssistant.shared.test()
            busy = false
        }
    }
}
