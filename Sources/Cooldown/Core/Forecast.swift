import Foundation

struct ProjectionPoint: Equatable {
    var t: Date
    var used: Double
}

struct Forecast: Equatable {
    enum Outcome: Equatable {
        case exhausted
        case idle
        case lasts(usedAtReset: Double)
        case runsOut(at: Date)
    }

    var outcome: Outcome
    var ratePerHour: Double
    var projectionEnd: ProjectionPoint?
}

/// Straight-line projection of the current window: recent pace if there is enough of it,
/// otherwise the average pace since the window began.
enum Forecaster {
    static func make(window: LimitWindow, samples: [LimitSample], now: Date) -> Forecast {
        let used = window.usedPercent
        if used >= 99.5 { return Forecast(outcome: .exhausted, ratePerHour: 0, projectionEnd: nil) }

        let points = Self.points(for: window, samples: samples, now: now)
        let idleSpan: TimeInterval = window.kind == .session ? 30 * 60 : 6 * 3600
        let lookback: TimeInterval = window.kind == .session ? 45 * 60 : 24 * 3600

        let recentValues = points.filter { $0.t >= now.addingTimeInterval(-idleSpan) }.map(\.used)
        let growth = (recentValues.max() ?? used) - (recentValues.min() ?? used)
        let idle = Forecast(outcome: .idle, ratePerHour: 0, projectionEnd: ProjectionPoint(t: window.resetsAt, used: used))
        guard growth >= 0.5 else { return idle }

        // A week holds nights and days off, so a burst of work says little about it: the weekly
        // window uses the average pace since it opened. The 5-hour window follows the recent pace.
        let elapsed = now.timeIntervalSince(window.start)
        let average: Double? = elapsed > 600 ? used / elapsed : nil
        var slope = window.kind == .weekly ? average : regressionSlope(points.filter { $0.t >= now.addingTimeInterval(-lookback) })
        if (slope ?? 0) <= 0 { slope = average }
        guard let perSecond = slope, perSecond > 0 else { return idle }

        let fullAt = now.addingTimeInterval((100 - used) / perSecond)
        if fullAt < window.resetsAt {
            return Forecast(outcome: .runsOut(at: fullAt), ratePerHour: perSecond * 3600,
                            projectionEnd: ProjectionPoint(t: fullAt, used: 100))
        }
        let atReset = min(100, used + perSecond * window.resetsAt.timeIntervalSince(now))
        return Forecast(outcome: .lasts(usedAtReset: atReset), ratePerHour: perSecond * 3600,
                        projectionEnd: ProjectionPoint(t: window.resetsAt, used: atReset))
    }

    /// Readings of this exact window, anchored at zero when it opened and at the current value now.
    static func points(for window: LimitWindow, samples: [LimitSample], now: Date) -> [ProjectionPoint] {
        var points = samples
            .filter { $0.kind == window.kind && abs($0.resetsAt.timeIntervalSince(window.resetsAt)) < 600
                && $0.t >= window.start && $0.t < now }
            .map { ProjectionPoint(t: $0.t, used: $0.used) }
            .sorted { $0.t < $1.t }
        points.insert(ProjectionPoint(t: window.start, used: 0), at: 0)
        points.append(ProjectionPoint(t: now, used: window.usedPercent))
        return points
    }

    static func regressionSlope(_ points: [ProjectionPoint]) -> Double? {
        guard points.count >= 2, let first = points.first?.t, let last = points.last?.t,
              last.timeIntervalSince(first) >= 300 else { return nil }
        let xs = points.map { $0.t.timeIntervalSince(first) }
        let ys = points.map(\.used)
        let n = Double(points.count)
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        var numerator = 0.0
        var denominator = 0.0
        for i in points.indices {
            numerator += (xs[i] - mx) * (ys[i] - my)
            denominator += (xs[i] - mx) * (xs[i] - mx)
        }
        return denominator > 0 ? numerator / denominator : nil
    }
}
