import Foundation

/// One thing that happened, kept for the feed "while you were away".
struct CooldownEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case reset, finished, resumed, waiting, attention, budget, failure, scheduled, info }

    var id = UUID()
    var date = Date()
    var kind: Kind
    var provider: ProviderID?
    var title: String
    var body: String
    /// The Codex conversation it is about, so the feed can open it.
    var threadId: String?
    /// The agent's request this event is about, so the feed can bring its card back.
    var requestKey: String?
}

/// The last 60 events, saved between launches.
@MainActor
final class EventLog: ObservableObject {
    static let shared = EventLog()
    @Published private(set) var events: [CooldownEvent] = []
    @Published var lastSeen: Date

    private let url = Settings.appSupport.appendingPathComponent("events.json")

    init() {
        lastSeen = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "eventsLastSeen"))
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([CooldownEvent].self, from: data) {
            events = saved
        }
    }

    var unseen: Int { events.filter { $0.date > lastSeen }.count }

    func add(_ event: CooldownEvent) {
        events.insert(event, at: 0)
        if events.count > 60 { events.removeLast(events.count - 60) }
        try? JSONEncoder().encode(events).write(to: url, options: .atomic)
    }

    func markSeen() {
        lastSeen = Date()
        UserDefaults.standard.set(lastSeen.timeIntervalSince1970, forKey: "eventsLastSeen")
    }

    func clear() {
        events = []
        try? FileManager.default.removeItem(at: url)
    }
}

/// Night mode: no cards and no banners; everything still lands in the feed, and the
/// first time the person is back in the morning they get a short summary.
enum QuietHours {
    static var active: Bool { scheduled || (Settings.quietWithFocus && FocusWatch.isFocused) }

    private static var scheduled: Bool {
        guard Settings.quietHours else { return false }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let from = Settings.quietFrom, to = Settings.quietTo
        return from <= to ? (now >= from && now < to) : (now >= from || now < to)
    }
}

/// After quiet hours (or a long time away), one card sums up what happened meanwhile.
@MainActor
enum MorningSummary {
    private static var quietSince: Date?

    static func check() {
        if QuietHours.active {
            if quietSince == nil { quietSince = Date() }
            return
        }
        guard let since = quietSince else { return }
        // Wait until someone is actually at the Mac.
        guard ToastController.shared.canShow, ToastController.idleSeconds < 60 else { return }
        quietSince = nil
        let events = EventLog.shared.events.filter { $0.date >= since }
        guard !events.isEmpty else { return }
        let count: (CooldownEvent.Kind) -> Int = { kind in events.filter { $0.kind == kind }.count }
        var parts: [String] = []
        if count(.finished) > 0 { parts.append("закончено задач: \(count(.finished))") }
        if count(.resumed) > 0 { parts.append("продолжено: \(count(.resumed))") }
        if count(.reset) > 0 { parts.append("сбросов лимита: \(count(.reset))") }
        if count(.attention) > 0 { parts.append("ждут вашего решения: \(count(.attention))") }
        let codex = AppModel.shared.codex.snapshot?.session.map { Format.percent($0.remaining(at: Date())) } ?? "—"
        let claude = AppModel.shared.claude.snapshot?.session.map { Format.percent($0.remaining(at: Date())) } ?? "—"
        let body = (parts.isEmpty ? "\(events.count) событий" : parts.joined(separator: ", ")) + ". Сейчас: Codex \(codex), Claude \(claude)."
        ToastController.shared.show(ToastContent(key: "morning", kind: .info, provider: nil, title: "Пока вас не было",
                                                 body: body, actions: [.openFeed], life: .sticky))
    }
}
