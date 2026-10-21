import Foundation

/// Every finished turn Cooldown announced or counted, with what it cost — for "the most
/// expensive tasks" in the statistics. The last few hundred are kept.
@MainActor
final class TurnLog: ObservableObject {
    static let shared = TurnLog()

    struct Turn: Codable, Identifiable, Equatable {
        var id = UUID()
        var provider: ProviderID
        var title: String
        var ended: Date
        var seconds: Double?
        var tokens: Int?
        var limitShare: Double?
        var thread: String?
    }

    @Published private(set) var turns: [Turn] = []
    private let url = Settings.appSupport.appendingPathComponent("turns.json")

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let data = try? Data(contentsOf: url), let saved = try? decoder.decode([Turn].self, from: data) { turns = saved }
    }

    func add(_ turn: Turn) {
        turns.insert(turn, at: 0)
        if turns.count > 400 { turns.removeLast(turns.count - 400) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try? encoder.encode(turns).write(to: url, options: .atomic)
    }

    /// The costliest turns of one agent in the range: by share of the limit, else by tokens.
    func costliest(_ provider: ProviderID, since: Date, count: Int = 5) -> [Turn] {
        turns.filter { $0.provider == provider && $0.ended >= since && (($0.limitShare ?? 0) >= 1 || ($0.tokens ?? 0) > 0) }
            .sorted { ($0.limitShare ?? 0, $0.tokens ?? 0) > ($1.limitShare ?? 0, $1.tokens ?? 0) }
            .prefix(count).map { $0 }
    }
}
