import Foundation

enum ClaudePaths {
    static var home: URL {
        if let value = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !value.isEmpty {
            return URL(fileURLWithPath: value)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    static var projects: URL { home.appendingPathComponent("projects") }
    static var settings: URL { home.appendingPathComponent("settings.json") }

    /// What Cooldown's status line command saves on every Claude Code update.
    static var bridgeFile: URL { Settings.appSupport.appendingPathComponent("claude-status.json") }
    /// The status line command that was set before Cooldown's, run after it so nothing is lost.
    static var previousStatusLine: URL { Settings.appSupport.appendingPathComponent("claude-statusline-previous.json") }

    static func binary(override: String) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        let custom = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { candidates.append((custom as NSString).expandingTildeInPath) }
        candidates += [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return URL(fileURLWithPath: found) }
        return desktopBundled()
    }

    /// Claude Desktop carries its own copy of Claude Code (for the Code tab), so people who only
    /// use the app still have one. The newest version wins.
    static func desktopBundled() -> URL? {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let versions = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for version in sorted {
            let builds = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(version).path)) ?? []
            for build in builds {
                let binary = root.appendingPathComponent("\(version)/\(build)/claude.app/Contents/MacOS/claude")
                if fm.isExecutableFile(atPath: binary.path) { return binary }
            }
        }
        return nil
    }
}

enum ClaudeError: LocalizedError {
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return L("Лимиты Claude ещё не подключены.")
        }
    }
}

/// Claude's plan limits come from several places, each with its strengths:
/// - Claude Code's /usage screen (official client, the whole subscription, refreshed every few minutes);
/// - Claude Code's status line, which receives `rate_limits` with every reply (official, freshest
///   while Claude Code is in use);
/// - the claude.ai account, only when the person signed in to it in Cooldown (adds model limits);
/// - Claude Desktop's own record of plan usage on disk (no reset times, so it only adds a fresher
///   figure to a window another source already knows).
/// They are merged by one rule (see `merge`), so they never contradict each other on screen.
/// Claude Code's sign-in token is not used: Anthropic allows it only inside its own apps.
enum ClaudeLimits {
    /// Set by the refresh button: the next read skips the pause between /usage runs.
    nonisolated(unsafe) static var forceNext = false

    static func fetch(force: Bool = false) async throws -> LimitSnapshot {
        let force = force || forceNext
        forceNext = false
        var candidates: [LimitSnapshot] = []
        var firstError: Error?
        let bridged = fromBridge()
        if Settings.claudeUsageCLI, let binary = ClaudePaths.binary(override: Settings.claudePath) {
            let pace = await MainActor.run {
                ClaudeUsageCLI.Pace(claudeWorking: !AgentActivity.shared.working(.claude).isEmpty,
                                    panelOpen: AppModel.shared.panelVisible,
                                    claudeRunning: ClaudeSender.claudeApp != nil,
                                    statusLineFresh: bridged.map { Date().timeIntervalSince($0.fetchedAt) < 180 } ?? false)
            }
            do { candidates.append(try await ClaudeUsageCLI.shared.read(binary: binary, force: force, pace: pace)) } catch { firstError = error }
        }
        if await ClaudeWeb.shared.isConnected {
            do { candidates.append(try await ClaudeWeb.shared.usage()) } catch { firstError = firstError ?? error }
        }
        if let bridged { candidates.append(bridged) }
        guard let merged = merge(candidates, desktop: ClaudeDesktopUsage.latest()) else {
            throw firstError ?? ClaudeError.notConnected
        }
        return merged
    }

    /// One picture from several readings. Per window: the current window is the one with the
    /// latest reset time; readings of that same window (resets within 10 minutes of each other)
    /// are compared, and the highest share used wins — within one window usage only grows, so the
    /// highest figure is the newest. Readings much older than the newest are left out, so a limit
    /// change by Anthropic is not masked for long.
    static func merge(_ candidates: [LimitSnapshot], desktop: ClaudeDesktopUsage.Reading? = nil, now: Date = Date()) -> LimitSnapshot? {
        guard let newest = candidates.map(\.fetchedAt).max() else { return nil }
        let recent = candidates.filter { newest.timeIntervalSince($0.fetchedAt) < 20 * 60 }
        func pick(_ kind: WindowKind) -> (LimitWindow, [String])? {
            let windows = recent.compactMap { snapshot in (kind == .session ? snapshot.session : snapshot.weekly).map { ($0, snapshot.source ?? "", snapshot.fetchedAt) } }
            guard let current = windows.max(by: { $0.0.resetsAt < $1.0.resetsAt }) else { return nil }
            var same = windows.filter { abs($0.0.resetsAt.timeIntervalSince(current.0.resetsAt)) < 10 * 60 }
            // Usage only grows within a window — except when a reset is used: then the newest
            // reading is right. So the highest figure wins only among readings taken together.
            if let newestRead = same.map({ $0.2 }).max() {
                same = same.filter { newestRead.timeIntervalSince($0.2) < 5 * 60 }
            }
            var best = same.max(by: { $0.0.usedPercent < $1.0.usedPercent })!.0
            var sources = same.filter { $0.0.usedPercent == best.usedPercent }.map(\.1)
            let lastRead = same.map { $0.2 }.max() ?? .distantPast
            if let desktop, now.timeIntervalSince(desktop.at) < 20 * 60, desktop.at > best.start, desktop.at > lastRead,
               desktop.at < best.resetsAt,
               let used = kind == .session ? desktop.session : desktop.weekly, used > best.usedPercent {
                best.usedPercent = min(100, used)
                sources = ["Claude Desktop"]
            }
            return (best, sources)
        }
        guard var result = recent.max(by: { $0.fetchedAt < $1.fetchedAt }) else { return nil }
        let session = pick(.session), weekly = pick(.weekly)
        result.session = session?.0
        result.weekly = weekly?.0
        result.plan = recent.compactMap(\.plan).first
        if let richest = recent.filter({ !$0.extras.isEmpty }).max(by: { $0.fetchedAt < $1.fetchedAt }) { result.extras = richest.extras }
        result.fetchedAt = newest
        let names = Array(Set((session?.1 ?? []) + (weekly?.1 ?? []))).filter { !$0.isEmpty }.sorted()
        result.source = names.isEmpty ? result.source : names.joined(separator: L(" и "))
        return result
    }

    /// The usage object shared by claude.ai and Claude Code's /usage.
    static func parseUsage(_ object: [String: Any], source: String) -> LimitSnapshot? {
        var snapshot = LimitSnapshot(provider: .claude, plan: nil, session: nil, weekly: nil, fetchedAt: Date(), source: source)
        snapshot.session = window(object["five_hour"], kind: .session)
        snapshot.weekly = window(object["seven_day"], kind: .weekly)
        for (key, value) in object where key.hasPrefix("seven_day_") && !key.contains("oauth") && !key.contains("cowork") {
            if var extra = window(value, kind: .weekly) {
                extra.label = extraTitle(key)
                snapshot.extras.append(extra)
            }
        }
        snapshot.extras.sort { ($0.label ?? "") < ($1.label ?? "") }
        return snapshot.session != nil || snapshot.weekly != nil ? snapshot : nil
    }

    // MARK: Status line

    static var bridgeConnected: Bool { ClaudeStatusLine.isInstalled }

    static func fromBridge() -> LimitSnapshot? {
        guard let data = try? Data(contentsOf: ClaudePaths.bridgeFile),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let limits = object["rate_limits"] as? [String: Any] else { return nil }
        let saved = Num.date(object["savedAt"]) ?? Date.distantPast
        var snapshot = LimitSnapshot(provider: .claude, plan: nil, session: nil, weekly: nil, fetchedAt: saved,
                                     source: L("строка статуса Claude Code"))
        snapshot.session = window(limits["five_hour"], kind: .session)
        snapshot.weekly = window(limits["seven_day"], kind: .weekly)
        for (key, value) in limits where key.hasPrefix("seven_day_") {
            if var extra = window(value, kind: .weekly) {
                extra.label = extraTitle(key)
                snapshot.extras.append(extra)
            }
        }
        snapshot.extras.sort { ($0.label ?? "") < ($1.label ?? "") }
        guard snapshot.session != nil || snapshot.weekly != nil else { return nil }
        return snapshot
    }

    // MARK: Parsing

    private static func window(_ raw: Any?, kind: WindowKind) -> LimitWindow? {
        guard let raw = raw as? [String: Any] else { return nil }
        let used = Num.double(raw["used_percentage"]) ?? Num.double(raw["utilization"]) ?? Num.double(raw["used_percent"])
        guard let used, let resets = Num.date(raw["resets_at"]) else { return nil }
        return LimitWindow(kind: kind, usedPercent: min(100, max(0, used)), durationMinutes: kind.defaultMinutes, resetsAt: resets)
    }

    private static func extraTitle(_ key: String) -> String {
        let name = key.replacingOccurrences(of: "seven_day_", with: "")
        switch name {
        case "opus": return L("Неделя, Opus")
        case "sonnet": return L("Неделя, Sonnet")
        case "fable": return L("Неделя, Fable")
        default: return L("Неделя, %@", "\(name.capitalized)")
        }
    }
}
