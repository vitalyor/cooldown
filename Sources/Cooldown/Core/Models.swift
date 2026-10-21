import Foundation

/// Every agent the app watches. Each one brings its own limits, history and tasks.
enum ProviderID: String, Codable, CaseIterable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }
}

enum WindowKind: String, Codable, CaseIterable {
    case session
    case weekly

    static func from(minutes: Int) -> WindowKind { minutes <= 24 * 60 ? .session : .weekly }

    var title: String { self == .session ? "5 часов" : "Неделя" }
    var defaultMinutes: Int { self == .session ? 300 : 10080 }
}

struct LimitWindow: Codable, Equatable {
    var kind: WindowKind
    var usedPercent: Double
    var durationMinutes: Int
    var resetsAt: Date
    /// Set for extra windows, e.g. Claude's separate weekly limit for one model family.
    var label: String? = nil

    var start: Date { resetsAt.addingTimeInterval(-Double(durationMinutes) * 60) }
    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }

    /// Past the reset time the old numbers no longer apply: the window is full again.
    func isExpired(at now: Date) -> Bool { resetsAt <= now }

    func remaining(at now: Date) -> Double { isExpired(at: now) ? 100 : remainingPercent }
}

struct LimitSnapshot: Codable, Equatable {
    var provider: ProviderID
    var plan: String?
    var session: LimitWindow?
    var weekly: LimitWindow?
    var extras: [LimitWindow] = []
    var resetCredits: Int? = nil
    var limitReached: Bool = false
    /// When the numbers were read at their source (may be earlier than when the app polled).
    var fetchedAt: Date
    /// Where the numbers came from, shown in small print.
    var source: String? = nil

    /// The lowest remaining share across the main windows, the number the menu bar shows.
    func lowestRemaining(at now: Date) -> Double? {
        [session?.remaining(at: now), weekly?.remaining(at: now)].compactMap { $0 }.min()
    }
}

/// One reading of a limit window at a moment in time: from a live poll or from session history.
struct LimitSample: Codable, Hashable {
    var t: Date
    var kind: WindowKind
    var used: Double
    var resetsAt: Date
}

struct TokenCounts: Codable, Hashable {
    var input = 0      // all input, cached included
    var cached = 0     // input read from cache
    var output = 0
    var reasoning = 0

    var total: Int { input + output }
    var freshInput: Int { max(0, input - cached) }
    var isZero: Bool { input == 0 && output == 0 }

    static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input, cached: a.cached + b.cached,
                    output: a.output + b.output, reasoning: a.reasoning + b.reasoning)
    }

    static func - (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: max(0, a.input - b.input), cached: max(0, a.cached - b.cached),
                    output: max(0, a.output - b.output), reasoning: max(0, a.reasoning - b.reasoning))
    }
}

struct BucketKey: Hashable, Codable {
    var hour: Date
    var project: String   // working folder, as recorded by the agent
    var model: String
}

struct TokenBucket: Codable, Hashable {
    var key: BucketKey
    var counts: TokenCounts
}

enum Num {
    static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()

    /// Seconds since 1970 (or milliseconds, recognised by size) or an ISO 8601 string.
    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return epoch(number.doubleValue) }
        guard let text = value as? String else { return nil }
        if let seconds = Double(text) { return epoch(seconds) }
        return fractional.date(from: text) ?? plain.date(from: text)
    }

    private static func epoch(_ value: Double) -> Date {
        Date(timeIntervalSince1970: value > 1e12 ? value / 1000 : value)
    }
}
