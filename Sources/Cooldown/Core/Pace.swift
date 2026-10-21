import Foundation

/// The person's own pace, learned from the limit history: how fast a 5-hour window goes while
/// they actually work, and how far into the week they usually are by now.
enum Pace {
    /// Share of the 5-hour window spent per hour of active work (idle stretches left out).
    static func typicalSessionRate(_ samples: [LimitSample]) -> Double? {
        let session = samples.filter { $0.kind == .session }.sorted { $0.t < $1.t }
        var spent = 0.0, active: TimeInterval = 0
        for (a, b) in zip(session, session.dropFirst()) {
            let gap = b.t.timeIntervalSince(a.t)
            guard gap > 0, gap <= 30 * 60, abs(a.resetsAt.timeIntervalSince(b.resetsAt)) < 600 else { continue }
            let delta = b.used - a.used
            if delta > 0.3 { spent += delta; active += gap }
        }
        guard active >= 3600, spent > 0 else { return nil }
        return spent / active * 3600
    }

    /// Hours of work at the usual pace that the rest of this 5-hour window allows.
    static func hoursLeft(_ window: LimitWindow, samples: [LimitSample], now: Date) -> Double? {
        guard !window.isExpired(at: now), let rate = typicalSessionRate(samples), rate > 0 else { return nil }
        return window.remainingPercent / rate
    }

    /// How much of the weekly limit was used at this same point of the last few weeks.
    static func usualWeekShare(_ window: LimitWindow, samples: [LimitSample], now: Date) -> Double? {
        let length = TimeInterval(window.durationMinutes * 60)
        let fraction = now.timeIntervalSince(window.start) / length
        guard fraction > 0.05, fraction < 0.98 else { return nil }
        let past = Dictionary(grouping: samples.filter { $0.kind == .weekly && $0.resetsAt < window.start.addingTimeInterval(3600) }) {
            Int($0.resetsAt.timeIntervalSince1970 / 1800)
        }
        var values: [Double] = []
        for (_, group) in past.sorted(by: { $0.key > $1.key }).prefix(4) {
            guard let reset = group.first?.resetsAt else { continue }
            let target = reset.addingTimeInterval(-length + fraction * length)
            let near = group.min { abs($0.t.timeIntervalSince(target)) < abs($1.t.timeIntervalSince(target)) }
            if let near, abs(near.t.timeIntervalSince(target)) < 6 * 3600 { values.append(near.used) }
        }
        guard values.count >= 2 else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// When the 5-hour limit ran out in the range: the first moment each window reached 99%.
    static func exhaustions(_ samples: [LimitSample], since: Date) -> [Date] {
        let session = samples.filter { $0.kind == .session && $0.t >= since }.sorted { $0.t < $1.t }
        var result: [Date] = []
        var windows = Set<Int>()
        for sample in session where sample.used >= 99 {
            let key = Int(sample.resetsAt.timeIntervalSince1970 / 600)
            if windows.insert(key).inserted { result.append(sample.t) }
        }
        return result
    }
}
