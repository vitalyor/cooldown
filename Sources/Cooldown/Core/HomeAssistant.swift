import Darwin
import Foundation
import Security

/// Sends Cooldown's limits and events to the iPhone through the person's own Home Assistant:
/// one Live Activity per agent (lock screen and Dynamic Island) and notifications for events.
/// Home Assistant's companion app does the delivery; Cooldown only calls its REST API.
@MainActor
final class HomeAssistant: ObservableObject {
    static let shared = HomeAssistant()

    enum Failure: LocalizedError {
        case notConfigured, http(Int), unreachable(String), noDevice
        var errorDescription: String? {
            switch self {
            case .notConfigured: return L("Укажите адрес Home Assistant и токен.")
            case .http(401): return L("Home Assistant не принял токен. Создайте новый в профиле → Безопасность.")
            case .http(let code): return L("Home Assistant ответил кодом %@.", "\(code)")
            case .unreachable(let text): return L("Home Assistant недоступен: %@", "\(text)")
            case .noDevice: return L("В Home Assistant не найден iPhone. Войдите в приложение Home Assistant на телефоне.")
            }
        }
    }

    @Published var devices: [String] = []
    @Published var status: String?

    private var lastSent: [String: (value: Int, exhausted: Bool, at: Date)] = [:]

    // MARK: Settings

    static var url: String {
        let value = UserDefaults.standard.string(forKey: SettingsKey.haURL) ?? ""
        return value.isEmpty ? "http://localhost:8123" : value
    }
    static var device: String { UserDefaults.standard.string(forKey: SettingsKey.haDevice) ?? "" }
    /// The whole iPhone side is parked for now: off unless switched on again on purpose.
    static let featureEnabled = false
    static var liveEnabled: Bool { featureEnabled && (UserDefaults.standard.object(forKey: SettingsKey.haLive) as? Bool ?? true) }
    static var notifyEnabled: Bool { featureEnabled && (UserDefaults.standard.object(forKey: SettingsKey.haNotify) as? Bool ?? true) }
    var isReady: Bool { Self.featureEnabled && !(Self.token ?? "").isEmpty && !Self.device.isEmpty }

    /// The token lives in the Keychain, never in preferences.
    static var token: String? {
        get {
            var item: CFTypeRef?
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Cooldown.HomeAssistant",
                                        kSecReturnData as String: true]
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Cooldown.HomeAssistant"]
            SecItemDelete(base as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(newValue.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    // MARK: API

    private func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Any? {
        guard let token = Self.token, !token.isEmpty, let url = URL(string: Self.url + path) else { throw Failure.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw Failure.http(code) }
            return try? JSONSerialization.jsonObject(with: data)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
    }

    /// The phones signed in to Home Assistant's app: its notify.mobile_app_* services.
    func loadDevices() async throws {
        guard let domains = try await call("GET", "/api/services") as? [[String: Any]] else { throw Failure.noDevice }
        let notify = domains.first { $0["domain"] as? String == "notify" }?["services"] as? [String: Any] ?? [:]
        devices = notify.keys.filter { $0.hasPrefix("mobile_app_") }.sorted()
        if devices.isEmpty { throw Failure.noDevice }
        if !devices.contains(Self.device) { UserDefaults.standard.set(devices[0], forKey: SettingsKey.haDevice) }
    }

    private func notify(_ payload: [String: Any]) async throws {
        guard !Self.device.isEmpty else { throw Failure.noDevice }
        _ = try await call("POST", "/api/services/notify/\(Self.device)", body: payload)
    }

    // MARK: Live Activities

    /// Updates an agent's Live Activity when something worth the phone's attention changed:
    /// every few percent, the limit running out, or coming back. iOS throttles chatty activities.
    func updateLive(_ provider: ProviderID, snapshot: LimitSnapshot?, force: Bool = false) {
        guard Self.liveEnabled, isReady, let session = snapshot?.session else { return }
        let now = Date()
        let remaining = session.remaining(at: now)
        let exhausted = remaining <= 0.5 && !session.isExpired(at: now)
        let rounded = Int(remaining.rounded())
        if !force, let last = lastSent[provider.rawValue] {
            let changed = abs(last.value - rounded) >= 5 || last.exhausted != exhausted
            guard changed, now.timeIntervalSince(last.at) > 60 || last.exhausted != exhausted else { return }
        }
        lastSent[provider.rawValue] = (rounded, exhausted, now)

        let color = provider == .codex ? "#5C80FF" : "#D97757"
        var data: [String: Any] = [
            "tag": "cooldown-\(provider.rawValue)",
            "live_update": true,
            "notification_icon": provider == .codex ? "mdi:console" : "mdi:asterisk",
            "notification_icon_color": color,
            "progress_bar_color": exhausted ? "#FF5A5A" : Self.levelHex(remaining),
            "background_color": "#0E1122",
            "text_color": "#FFFFFF",
            "silent": true,
        ]
        var message: String
        if exhausted {
            message = L("Лимит кончился · сброс в %@", "\(Format.time(session.resetsAt))")
            data["chronometer"] = true
            data["when"] = Int(session.resetsAt.timeIntervalSince1970)
            data["progress_bar_direction"] = "decreasing"
        } else {
            message = L("Осталось %@%% · сброс в %@", "\(rounded)", "\(Format.time(session.resetsAt))")
            if let weekly = snapshot?.weekly { message += L(" · неделя %@%%", "\(Int(weekly.remaining(at: now).rounded()))") }
            data["progress"] = rounded
            data["progress_max"] = 100
            data["critical_text"] = "\(rounded)%"
        }
        Task {
            do {
                try await notify(["title": provider.displayName, "message": message, "data": data])
                status = nil
            } catch { status = error.localizedDescription }
        }
    }

    func endLive(_ provider: ProviderID) {
        guard isReady else { return }
        lastSent[provider.rawValue] = nil
        Task { try? await notify(["message": "clear_notification", "data": ["tag": "cooldown-\(provider.rawValue)"]]) }
    }

    // MARK: Sensors for widgets

    /// Mirrors the limits into Home Assistant as sensor.cooldown_codex / sensor.cooldown_claude,
    /// which the Scriptable widget on the iPhone reads.
    func publishSensors() {
        guard Self.featureEnabled, !(Self.token ?? "").isEmpty else { return }
        let now = Date()
        for provider in ProviderID.allCases {
            guard let snapshot = AppModel.shared.store(provider).snapshot, let session = snapshot.session else { continue }
            let remaining = session.remaining(at: now)
            let iso = ISO8601DateFormatter().string(from: session.resetsAt)
            let body: [String: Any] = [
                "state": String(format: "%.0f", remaining),
                "attributes": [
                    "friendly_name": "Cooldown \(provider.displayName)",
                    "unit_of_measurement": "%",
                    "resets_at": iso,
                    "weekly": snapshot.weekly.map { Int($0.remaining(at: now).rounded()) } ?? 0,
                    "exhausted": remaining <= 0.5 && !session.isExpired(at: now),
                    "icon": provider == .codex ? "mdi:console" : "mdi:asterisk",
                ] as [String: Any],
            ]
            Task { _ = try? await call("POST", "/api/states/sensor.cooldown_\(provider.rawValue)", body: body) }
        }
    }

    /// Puts the widget script into Scriptable's iCloud folder, with this Home Assistant's
    /// network address and token filled in. It shows up in Scriptable on the iPhone by itself.
    func installWidget() throws -> String {
        guard let template = Bundle.main.url(forResource: "Cooldown", withExtension: "js"),
              var script = try? String(contentsOf: template, encoding: .utf8) else { throw Failure.notConfigured }
        guard let token = Self.token, !token.isEmpty else { throw Failure.notConfigured }
        var address = Self.url
        if address.contains("localhost") || address.contains("127.0.0.1") {
            // The phone can't reach "localhost": use the Mac's address on the local network.
            let ip = Self.lanAddress() ?? "localhost"
            address = address.replacingOccurrences(of: "localhost", with: ip).replacingOccurrences(of: "127.0.0.1", with: ip)
        }
        script = script.replacingOccurrences(of: "__HA_URL__", with: address).replacingOccurrences(of: "__HA_TOKEN__", with: token)
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~dk~simonbs~Scriptable/Documents", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw Failure.unreachable(L("не найдена папка Scriptable в iCloud. Откройте Scriptable на iPhone с включённым iCloud."))
        }
        try script.write(to: folder.appendingPathComponent("Cooldown.js"), atomically: true, encoding: .utf8)
        publishSensors()
        return address
    }

    static func lanAddress() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var candidate: String?
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(item.pointee.ifa_flags)
            guard let addr = item.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: item.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.") { return ip }
            candidate = candidate ?? ip
        }
        return candidate
    }

    // MARK: Notifications

    /// Events go to the phone when nobody is at the Mac (locked, or idle for a few minutes).
    func forward(title: String, body: String, force: Bool = false) {
        guard Self.notifyEnabled, isReady else { return }
        guard force || ToastController.screenLocked || ToastController.idleSeconds > 300 else { return }
        Task { try? await notify(["title": title, "message": body, "data": ["push": ["sound": "default"]]]) }
    }

    func test() async {
        do {
            try await loadDevices()
            lastSent = [:]
            updateLive(.codex, snapshot: AppModel.shared.codex.snapshot, force: true)
            updateLive(.claude, snapshot: AppModel.shared.claude.snapshot, force: true)
            try await notify(["title": L("Cooldown на связи"), "message": L("Уведомления и Live Activity с лимитами будут приходить сюда.")])
            status = L("Отправлено на %@.", "\(Self.device.replacingOccurrences(of: "mobile_app_", with: ""))")
        } catch {
            status = error.localizedDescription
        }
    }

    static func levelHex(_ remaining: Double) -> String {
        guard let color = GaugeIcon.levelColor(remaining).usingColorSpace(.sRGB) else { return "#4CCB6B" }
        return String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }
}
