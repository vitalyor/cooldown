import Foundation

/// A small permanent record per calendar day — tokens and their API-price estimate per agent,
/// finished tasks, Claude chats — for the year view. The detailed history keeps only 45 days;
/// days that leave it stay here (a few dozen bytes each). The past is filled in once from
/// whatever session files are still on disk.
@MainActor
final class DailyLog: ObservableObject {
    static let shared = DailyLog()

    struct Day: Codable, Equatable {
        var codexTokens = 0
        var claudeTokens = 0
        var codexDollars = 0.0
        var claudeDollars = 0.0
        var codexDone = 0
        var claudeDone = 0
        var chats = 0
        /// How much of the weekly limit was spent that day, in percent of the week.
        var codexWeek = 0.0
        var claudeWeek = 0.0

        init() {}

        // Older files lack newer fields: each is read if present, so no saved day is lost.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            codexTokens = try c.decodeIfPresent(Int.self, forKey: .codexTokens) ?? 0
            claudeTokens = try c.decodeIfPresent(Int.self, forKey: .claudeTokens) ?? 0
            codexDollars = try c.decodeIfPresent(Double.self, forKey: .codexDollars) ?? 0
            claudeDollars = try c.decodeIfPresent(Double.self, forKey: .claudeDollars) ?? 0
            codexDone = try c.decodeIfPresent(Int.self, forKey: .codexDone) ?? 0
            claudeDone = try c.decodeIfPresent(Int.self, forKey: .claudeDone) ?? 0
            chats = try c.decodeIfPresent(Int.self, forKey: .chats) ?? 0
            codexWeek = try c.decodeIfPresent(Double.self, forKey: .codexWeek) ?? 0
            claudeWeek = try c.decodeIfPresent(Double.self, forKey: .claudeWeek) ?? 0
        }
    }

    /// Weekly-limit spending per day from a series of readings (time, share used): rises add up;
    /// a large drop is a new week starting from zero.
    nonisolated static func weekUse(_ readings: [(t: Date, used: Double)]) -> [String: Double] {
        var result: [String: Double] = [:]
        var previous: Double?
        for reading in readings.sorted(by: { $0.t < $1.t }) {
            var delta = 0.0
            if let previous {
                let change = reading.used - previous
                delta = change < -3 ? reading.used : max(0, change)
            }
            previous = reading.used
            if delta > 0 { result[key(reading.t), default: 0] += delta }
        }
        return result
    }

    @Published private(set) var days: [String: Day] = [:]
    @Published private(set) var backfilling = false

    private let url = Settings.appSupport.appendingPathComponent("daily.json")
    private static let backfillKey = "dailyBackfillVersion"
    private static let backfillVersion = 2
    private var started = false

    nonisolated static let keyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    nonisolated static func key(_ date: Date) -> String { keyFormatter.string(from: date) }

    /// Only reads what is saved (for drawing the window into a picture).
    func load() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: Day].self, from: data) { days = saved }
    }

    func start() {
        guard !started else { return }
        started = true
        load()
        refresh()
        if UserDefaults.standard.integer(forKey: Self.backfillKey) < Self.backfillVersion { backfill() }
    }

    func day(_ date: Date) -> Day { days[Self.key(date)] ?? Day() }

    /// Recomputes the days the detailed history covers from it; older days are kept as they are.
    func refresh() {
        let model = AppModel.shared
        guard !model.demoActive else { return }
        var fresh: [String: Day] = [:]
        add(model.codex.buckets, provider: .codex, into: &fresh)
        add(model.claude.buckets, provider: .claude, into: &fresh)
        if let activity = ClaudeWeb.shared.activity {
            for item in activity.items { fresh[Self.key(item.date), default: Day()].chats += 1 }
        }
        let codexWeek = Self.weekUse(model.codex.samples.filter { $0.kind == .weekly }.map { ($0.t, $0.used) })
        // Claude: Cooldown's readings plus Claude Desktop's own record, which reaches further back.
        let claudeReadings = model.claude.samples.filter { $0.kind == .weekly }.map { ($0.t, $0.used) }
            + ClaudeDesktopUsage.all().compactMap { reading in reading.weekly.map { (reading.at, $0) } }
        let claudeWeek = Self.weekUse(claudeReadings)
        var merged = days
        for (key, value) in fresh {
            var day = merged[key] ?? Day()
            day.codexTokens = value.codexTokens
            day.claudeTokens = value.claudeTokens
            day.codexDollars = value.codexDollars
            day.claudeDollars = value.claudeDollars
            if value.chats > 0 { day.chats = value.chats }
            merged[key] = day
        }
        for (key, value) in codexWeek { merged[key, default: Day()].codexWeek = value }
        for (key, value) in claudeWeek { merged[key, default: Day()].claudeWeek = value }
        if merged != days {
            days = merged
            save()
        }
    }

    func countFinished(_ provider: ProviderID, at date: Date) {
        var day = days[Self.key(date)] ?? Day()
        if provider == .codex { day.codexDone += 1 } else { day.claudeDone += 1 }
        days[Self.key(date)] = day
        save()
    }

    private func add(_ buckets: [TokenBucket], provider: ProviderID, into result: inout [String: Day]) {
        for bucket in buckets {
            let key = Self.key(bucket.key.hour)
            let counts = bucket.counts
            var dollars = 0.0
            if let rate = Pricing.rate(for: bucket.key.model) {
                dollars = (Double(counts.freshInput) * rate.input + Double(counts.cached) * rate.cached + Double(counts.output) * rate.output) / 1_000_000
            }
            var day = result[key] ?? Day()
            if provider == .codex {
                day.codexTokens += counts.total
                day.codexDollars += dollars
            } else {
                day.claudeTokens += counts.total
                day.claudeDollars += dollars
            }
            result[key] = day
        }
    }

    private func save() {
        try? JSONEncoder().encode(days).write(to: url, options: .atomic)
    }

    // MARK: The past

    /// One pass over every session file still on disk (up to a year back), at low priority.
    /// Codex compresses old conversations (.jsonl.zst); they are read when the zstd tool is
    /// installed (Homebrew), otherwise skipped. Only days older than the detailed history are
    /// filled, so nothing is counted twice.
    private func backfill() {
        backfilling = true
        let horizon: TimeInterval = 400 * 86400
        let codexRoots = [CodexPaths.sessions, CodexPaths.home.appendingPathComponent("archived_sessions")]
        let claudeRoot = ClaudePaths.projects
        Task.detached(priority: .background) {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("cooldown-backfill-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            Self.unpackCompressed(codexRoots, into: temporary, horizon: horizon)
            let codex = CodexHistoryScanner(roots: codexRoots + [temporary], horizon: horizon).scan(cursors: [:]) { _ in }
            let claude = ClaudeHistoryScanner(root: claudeRoot, horizon: horizon).scan(cursors: [:]) { _ in }
            let codexBuckets = codex.tokens.map { TokenBucket(key: $0.key, counts: $0.value) }
            let claudeBuckets = claude.tokens.map { TokenBucket(key: $0.key, counts: $0.value) }
            let codexWeek = Self.weekUse(codex.samples.filter { $0.kind == .weekly }.map { ($0.t, $0.used) })
            await MainActor.run { DailyLog.shared.finishBackfill(codex: codexBuckets, claude: claudeBuckets, codexWeek: codexWeek) }
        }
    }

    private func finishBackfill(codex: [TokenBucket], claude: [TokenBucket], codexWeek: [String: Double]) {
        var past: [String: Day] = [:]
        add(codex, provider: .codex, into: &past)
        add(claude, provider: .claude, into: &past)
        // The days the detailed history covers are already right; only older ones are filled.
        let model = AppModel.shared
        let covered = (model.codex.buckets + model.claude.buckets).map(\.key.hour).min() ?? Date()
        let firstCovered = Self.key(covered)
        for (key, value) in past where key < firstCovered && days[key] == nil {
            days[key] = value
        }
        for (key, value) in codexWeek where key < firstCovered && (days[key]?.codexWeek ?? 0) == 0 {
            days[key, default: Day()].codexWeek = value
        }
        save()
        backfilling = false
        UserDefaults.standard.set(Self.backfillVersion, forKey: Self.backfillKey)
    }

    nonisolated private static func unpackCompressed(_ roots: [URL], into folder: URL, horizon: TimeInterval) {
        let tool = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let tool else { return }
        let cutoff = Date().addingTimeInterval(-horizon)
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let url as URL in walker where url.lastPathComponent.hasSuffix(".jsonl.zst") {
                guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modified >= cutoff else { continue }
                let out = folder.appendingPathComponent(String(url.lastPathComponent.dropLast(4)))
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = ["-d", "-q", "-f", url.path, "-o", out.path]
                try? process.run()
                process.waitUntilExit()
                // Keep the original's date so the reader's year limit treats it the same way.
                try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: out.path)
            }
        }
    }
}
