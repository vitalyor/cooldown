import Foundation

/// Claude Desktop keeps a record of plan usage on disk (plan-usage-history.json): every so often
/// the share used of the 5-hour and the weekly window. No reset times are recorded, so a reading
/// can only be placed into a window that another source already knows. Read-only, local.
enum ClaudeDesktopUsage {
    struct Reading {
        var at: Date
        var session: Double?
        var weekly: Double?
    }

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }

    static func all() -> [Reading] {
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let samples = object["samples"] as? [[String: Any]] else { return [] }
        return samples.compactMap { sample in
            guard let at = Num.date(sample["t"]), let usage = sample["u"] as? [String: Any] else { return nil }
            let reading = Reading(at: at, session: Num.double(usage["fh"]), weekly: Num.double(usage["sd"]))
            return reading.session == nil && reading.weekly == nil ? nil : reading
        }
        .sorted { $0.at < $1.at }
    }

    static func latest() -> Reading? { all().last }

    /// Readings placed into windows the history already knows: each gets the reset time of a
    /// known reading of the same kind whose window covers it. The rest are left out.
    static func samples(fitting known: [LimitSample]) -> [LimitSample] {
        var result: [LimitSample] = []
        let readings = all()
        for kind in WindowKind.allCases {
            let windows = Set(known.filter { $0.kind == kind }.map(\.resetsAt)).sorted()
            guard !windows.isEmpty else { continue }
            let length = TimeInterval(kind.defaultMinutes * 60)
            for reading in readings {
                guard let used = kind == .session ? reading.session : reading.weekly,
                      let reset = windows.first(where: { reading.at < $0 && reading.at >= $0.addingTimeInterval(-length) }) else { continue }
                result.append(LimitSample(t: reading.at, kind: kind, used: min(100, max(0, used)), resetsAt: reset))
            }
        }
        return result
    }
}
