import Foundation

/// What the same tokens would cost on the pay-as-you-go API. An estimate for orientation only:
/// list prices per million tokens as published in October 2026; cache writes are not counted.
enum Pricing {
    struct Rate { let input: Double; let cached: Double; let output: Double }

    /// Longest matching prefix wins.
    private static let rates: [(String, Rate)] = [
        ("gpt-6.1", Rate(input: 2.0, cached: 0.10, output: 10.0)),
        ("gpt-6", Rate(input: 2.0, cached: 0.20, output: 10.0)),
        ("gpt-5.6", Rate(input: 4.0, cached: 0.40, output: 20.0)),
        ("claude-opus-5-5", Rate(input: 4.0, cached: 0.20, output: 20.0)),
        ("claude-opus-5", Rate(input: 5.0, cached: 0.50, output: 25.0)),
        ("claude-sonnet-5", Rate(input: 2.0, cached: 0.20, output: 10.0)),
    ]

    static func rate(for model: String) -> Rate? {
        rates.filter { model.hasPrefix($0.0) }.max { $0.0.count < $1.0.count }?.1
    }

    /// Dollars for the buckets in range, and whether some models had no known price.
    static func cost(_ buckets: [TokenBucket], _ range: StatsRange, now: Date) -> (dollars: Double, partial: Bool) {
        var total = 0.0
        var partial = false
        for bucket in Stats.inRange(buckets, range, now: now) {
            guard let rate = rate(for: bucket.key.model) else {
                if !bucket.counts.isZero { partial = true }
                continue
            }
            let c = bucket.counts
            total += (Double(c.freshInput) * rate.input + Double(c.cached) * rate.cached + Double(c.output) * rate.output) / 1_000_000
        }
        return (total, partial)
    }

    static func format(_ dollars: Double) -> String {
        if dollars >= 1000 { return String(format: "$%.1fk", dollars / 1000) }
        if dollars >= 100 { return String(format: "$%.0f", dollars) }
        return String(format: "$%.2f", dollars)
    }
}
