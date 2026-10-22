import Foundation

enum StatsTab: String, CaseIterable, Identifiable {
    case limits
    case chats
    case tokens
    case projects

    static func options(for provider: ProviderID) -> [StatsTab] {
        provider == .claude ? [.limits, .chats, .tokens, .projects] : [.limits, .tokens, .projects]
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .limits: return L("Расход")
        case .chats: return L("Диалоги")
        case .tokens: return L("Токены")
        case .projects: return L("Проекты")
        }
    }
}

enum StatsRange: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return L("24 часа")
        case .week: return L("7 дней")
        case .month: return L("30 дней")
        }
    }

    var phrase: String {
        switch self {
        case .day: return L("за сутки")
        case .week: return L("за 7 дней")
        case .month: return L("за 30 дней")
        }
    }

    var interval: TimeInterval {
        switch self {
        case .day: return 86400
        case .week: return 7 * 86400
        case .month: return 30 * 86400
        }
    }

    var unit: Calendar.Component { self == .day ? .hour : .day }
}

struct TokenPoint: Identifiable {
    let id: String
    let date: Date
    let kind: String
    let value: Int
}

struct LimitPoint: Identifiable {
    let id: Int
    let t: Date
    let used: Double
    let series: String
}

struct ShareRow: Identifiable {
    let id: String
    let name: String
    let total: Int
    let share: Double     // of the largest row, for bar length
    let percent: Double   // of everything
}

enum Stats {
    static let freshKind = L("Новые входные")
    static let cachedKind = L("Из кеша")
    static let outputKind = L("Ответ")

    static func inRange(_ buckets: [TokenBucket], _ range: StatsRange, now: Date) -> [TokenBucket] {
        let from = now.addingTimeInterval(-range.interval)
        return buckets.filter { $0.key.hour >= from && $0.key.hour <= now }
    }

    static func totals(_ buckets: [TokenBucket], _ range: StatsRange, now: Date) -> TokenCounts {
        inRange(buckets, range, now: now).reduce(TokenCounts()) { $0 + $1.counts }
    }

    static func tokenSeries(_ buckets: [TokenBucket], _ range: StatsRange, now: Date) -> [TokenPoint] {
        let calendar = Calendar.current
        var sums: [Date: TokenCounts] = [:]
        for bucket in inRange(buckets, range, now: now) {
            let slot = range == .day ? bucket.key.hour : calendar.startOfDay(for: bucket.key.hour)
            sums[slot, default: TokenCounts()] = sums[slot, default: TokenCounts()] + bucket.counts
        }
        return sums.keys.sorted().flatMap { slot -> [TokenPoint] in
            let counts = sums[slot] ?? TokenCounts()
            let key = String(Int(slot.timeIntervalSince1970))
            return [
                TokenPoint(id: key + "c", date: slot, kind: cachedKind, value: counts.cached),
                TokenPoint(id: key + "f", date: slot, kind: freshKind, value: counts.freshInput),
                TokenPoint(id: key + "o", date: slot, kind: outputKind, value: counts.output),
            ]
        }
    }

    static func projects(_ buckets: [TokenBucket], _ range: StatsRange, now: Date) -> [ShareRow] {
        shares(inRange(buckets, range, now: now), limit: 5) { projectName($0.key.project) }
    }

    static func models(_ buckets: [TokenBucket], _ range: StatsRange, now: Date) -> [ShareRow] {
        shares(inRange(buckets, range, now: now), limit: 3) { $0.key.model.isEmpty ? L("Модель не указана") : $0.key.model }
    }

    private static func shares(_ buckets: [TokenBucket], limit: Int, name: (TokenBucket) -> String) -> [ShareRow] {
        var sums: [String: Int] = [:]
        for bucket in buckets { sums[name(bucket), default: 0] += bucket.counts.total }
        let sorted = sums.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        guard let largest = sorted.first?.value else { return [] }
        let everything = Double(max(1, sorted.reduce(0) { $0 + $1.value }))
        var rows = sorted.prefix(limit).map {
            ShareRow(id: $0.key, name: $0.key, total: $0.value, share: Double($0.value) / Double(largest),
                     percent: Double($0.value) / everything * 100)
        }
        let rest = sorted.dropFirst(limit).reduce(0) { $0 + $1.value }
        if rest > 0 {
            rows.append(ShareRow(id: "_rest", name: L("Остальные"), total: rest, share: Double(rest) / Double(largest),
                                 percent: Double(rest) / everything * 100))
        }
        return rows
    }

    static func projectName(_ cwd: String) -> String {
        if cwd.isEmpty { return L("Папка не указана") }
        if cwd.contains("/Documents/Codex/") { return L("Чаты без проекта") }
        if cwd == NSHomeDirectory() { return L("Домашняя папка") }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Usage of each window over the range, drawn as the saw it really is: a window keeps its level
    /// until its reset time and then drops to zero, even if nothing was recorded at that moment.
    static func limitSeries(_ samples: [LimitSample], _ range: StatsRange, now: Date) -> [LimitPoint] {
        let from = now.addingTimeInterval(-range.interval)
        let step = range.interval / 300
        var latest: [String: LimitSample] = [:]
        for sample in samples where sample.t >= from && sample.t <= now {
            let key = "\(sample.kind.rawValue)-\(Int(sample.t.timeIntervalSince1970 / step))"
            if let existing = latest[key], existing.t >= sample.t { continue }
            latest[key] = sample
        }

        var raw: [(t: Date, used: Double, kind: WindowKind)] = []
        for kind in WindowKind.allCases {
            let ofKind = latest.values.filter { $0.kind == kind }.sorted { $0.t < $1.t }
            let windows = Dictionary(grouping: ofKind) { Int($0.resetsAt.timeIntervalSince1970 / 600) }
            for (_, group) in windows {
                guard let first = group.first, let last = group.last else { continue }
                let start = first.resetsAt.addingTimeInterval(-Double(kind.defaultMinutes) * 60)
                if start >= from && start < first.t { raw.append((start, 0, kind)) }
                for sample in group { raw.append((sample.t, sample.used, kind)) }
                if last.resetsAt <= now && last.resetsAt > last.t {
                    raw.append((last.resetsAt, last.used, kind))
                    raw.append((last.resetsAt.addingTimeInterval(1), 0, kind))
                }
            }
        }
        return raw.sorted { $0.t < $1.t }.enumerated().map {
            LimitPoint(id: $0.offset, t: $0.element.t, used: $0.element.used, series: $0.element.kind.title)
        }
    }

    /// How many 5-hour windows in the range were spent to the end.
    static func exhaustedWindows(_ samples: [LimitSample], _ range: StatsRange, now: Date) -> Int {
        let from = now.addingTimeInterval(-range.interval)
        let session = samples.filter { $0.kind == .session && $0.t >= from && $0.t <= now }
        let windows = Dictionary(grouping: session) { Int($0.resetsAt.timeIntervalSince1970 / 600) }
        return windows.values.filter { group in (group.map(\.used).max() ?? 0) >= 99 }.count
    }
}
