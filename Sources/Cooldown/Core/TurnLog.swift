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
        /// The working folder and the model, when the agent says (for per-project and per-model views).
        var project: String?
        var model: String?
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

    /// Turns of one project (by its display name) in the range, newest first.
    func turns(_ provider: ProviderID, project name: String, since: Date) -> [Turn] {
        turns.filter { $0.provider == provider && $0.ended >= since && $0.project.map(Stats.projectName) == name }
    }

    /// Per model: how many turns, and what an average one took.
    struct ModelRow: Identifiable {
        var model: String
        var count: Int
        var share: Double?
        var tokens: Int?
        var seconds: Double?
        var id: String { model }
    }

    func models(_ provider: ProviderID, since: Date) -> [ModelRow] {
        let recent = turns.filter { $0.provider == provider && $0.ended >= since && !($0.model ?? "").isEmpty }
        return Dictionary(grouping: recent, by: { $0.model! }).map { model, list in
            func average(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
            return ModelRow(model: model, count: list.count,
                            share: average(list.compactMap(\.limitShare)),
                            tokens: average(list.compactMap { $0.tokens.map(Double.init) }).map { Int($0) },
                            seconds: average(list.compactMap(\.seconds)))
        }
        .sorted { $0.count > $1.count }
    }

    /// The costliest turns of one agent in the range: by share of the limit, else by tokens.
    func costliest(_ provider: ProviderID, since: Date, count: Int = 5) -> [Turn] {
        turns.filter { $0.provider == provider && $0.ended >= since && (($0.limitShare ?? 0) >= 1 || ($0.tokens ?? 0) > 0) }
            .sorted { ($0.limitShare ?? 0, $0.tokens ?? 0) > ($1.limitShare ?? 0, $1.tokens ?? 0) }
            .prefix(count).map { $0 }
    }
}
