import Combine
import CoreGraphics
import Darwin
import Foundation

/// What the limits screen needs to know about reading limits through Claude Code.
@MainActor
final class ClaudeUsageStatus: ObservableObject {
    static let shared = ClaudeUsageStatus()
    /// Claude Code waits for the person to allow it in Cooldown's empty folder.
    @Published var needsPermission = false
    @Published var allowing = false
    @Published var problem: String?
}

/// Reads Claude plan limits the way a person would: Claude Code's own `/usage` screen.
/// Claude Code asks the server with its own sign-in; no model request is made and no tokens are spent.
/// The limits are shared by the whole subscription, so this covers Claude Desktop chats and Cowork too.
actor ClaudeUsageCLI {
    static let shared = ClaudeUsageCLI()

    /// Starting Claude Code takes a second or two, so a fresh reading is reused for a while.
    static let minimumInterval: TimeInterval = 120

    private var last: LimitSnapshot?
    private var lastError: Error?
    private var lastAttempt = Date.distantPast
    /// Failed readings in a row: after a failure the next try comes soon (1, 2, 4… minutes),
    /// not after the full pause, so a hiccup does not leave old numbers on screen for long.
    private var failuresInRow = 0
    /// Set when Claude just finished an answer: the share used has moved, so a minute's pause is enough.
    private(set) var turnFinished = false

    func noteTurnFinished() { turnFinished = true }
    private var running: Task<LimitSnapshot, Error>?

    /// How often Claude Code is started for /usage. Starting it costs a second of CPU and a
    /// few helper processes, so it follows what Claude is doing:
    /// - while Claude works: every minute, so the window always shows the latest share;
    /// - after it stops: the pause grows step by step (1½, 2, 3… minutes) up to 5 minutes;
    /// - quiet for half an hour or more: every 15 minutes (5 while Cooldown's window is open),
    ///   every 30 while the screen is locked;
    /// - not at all while Claude Code's status line already brings fresh numbers.
    struct Pace: Sendable {
        var claudeWorking = false
        /// Seconds since Claude last worked (0 while it works); nil if not seen at work yet.
        var idleFor: TimeInterval? = nil
        var panelOpen = false
        var claudeRunning = false
        var statusLineFresh = false
        var resetNear = false
    }

    static let workingInterval: TimeInterval = 60
    static let settledInterval: TimeInterval = 5 * 60

    static func interval(_ pace: Pace) -> TimeInterval {
        if let info = CGSessionCopyCurrentDictionary() as? [String: Any], info["CGSSessionScreenIsLocked"] as? Bool == true {
            return pace.claudeWorking ? settledInterval : 30 * 60
        }
        // The five-hour window is about to come back (or just came back): read often, so chats
        // waiting for it go on within a minute or two, not at the next lazy read.
        if pace.resetNear { return minimumInterval }
        if pace.statusLineFresh { return 10 * 60 }
        if pace.claudeWorking { return workingInterval }
        if let idle = pace.idleFor, idle < 30 * 60 { return decay(after: idle) }
        if pace.panelOpen { return settledInterval }
        let away = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if pace.claudeRunning && away < 10 * 60 { return settledInterval }
        return 15 * 60
    }

    /// The pause after Claude stopped working: a minute at first, then half a minute longer for
    /// every minute of quiet, up to five minutes.
    static func decay(after idle: TimeInterval) -> TimeInterval {
        min(settledInterval, workingInterval + idle / 2)
    }

    func read(binary: URL, force: Bool = false, pace: Pace = Pace()) async throws -> LimitSnapshot {
        var pause = Self.interval(pace)
        // After a failure, soon again (1, 2, 4 minutes); a failure that keeps coming back is
        // not retried more often than the normal pace.
        if (1...3).contains(failuresInRow) { pause = min(pause, 60 * pow(2, Double(failuresInRow - 1))) }
        if turnFinished { pause = min(pause, 60) }
        // The usage server asked to wait: asking every minute would only keep it saying so.
        if (lastError as? UsageError) == .rateLimited { pause = max(pause, 5 * 60) }
        // A few seconds' slack: the caller's minute timer would otherwise miss a one-minute pause
        // by a hair and make it two.
        if !force, Date().timeIntervalSince(lastAttempt) < pause - 5 {
            // The last try failed: that is the news, not the reading before it.
            if let lastError { throw lastError }
            if let last { return last }
        }
        if let running { return try await running.value }
        let task = Task.detached(priority: .utility) {
            // Claude Code sometimes draws the screen late (updates, notices); one retry covers it.
            do { return try Self.run(binary: binary) }
            catch UsageError.unreadable { return try Self.run(binary: binary) }
            // Its own question about Cooldown's own empty folder: nothing there to protect.
            catch UsageError.trust {
                try Self.acceptFolder(binary: binary)
                return try Self.run(binary: binary)
            }
        }
        running = task
        defer { running = nil }
        lastAttempt = Date()
        do {
            var snapshot = try await task.value
            // A five-hour window that is still running does not vanish between two readings: if
            // this one missed it (the screen changed shape), the last reading's stays until it ends.
            if snapshot.session == nil, let known = last?.session, known.resetsAt > Date(),
               let lastAt = last?.fetchedAt, Date().timeIntervalSince(lastAt) < 30 * 60 {
                snapshot.session = known
                AgentActivity.trace("claude /usage: no five-hour line this time, keeping the last one")
            }
            last = snapshot
            lastError = nil
            failuresInRow = 0
            turnFinished = false
            await MainActor.run {
                ClaudeUsageStatus.shared.needsPermission = false
                ClaudeUsageStatus.shared.problem = nil
            }
            return snapshot
        } catch {
            lastError = error
            failuresInRow += 1
            let needsPermission = (error as? UsageError) == .trust
            await MainActor.run {
                ClaudeUsageStatus.shared.needsPermission = needsPermission
                ClaudeUsageStatus.shared.problem = needsPermission ? nil : error.localizedDescription
            }
            throw error
        }
    }

    /// Answers Claude Code's one-time folder question with "Yes, I trust this folder". It is only
    /// ever asked about Cooldown's own empty folder, where the program is started.
    private static func acceptFolder(binary: URL) throws {
        let session = try Terminal(binary: binary, arguments: [])
        defer { session.stop() }
        func flat(_ text: String) -> String { text.replacingOccurrences(of: " ", with: "").lowercased() }
        guard session.wait(until: { flat($0).contains("trustthisfolder") }, timeout: 20) else { return }
        // Let the question finish drawing before answering it, like a person would.
        _ = session.wait(until: { _ in false }, timeout: 1.2)
        session.send("\u{1B}[B")   // move to "Yes, I trust this folder"
        _ = session.wait(until: { flat($0).contains("❯yes,itrust") }, timeout: 2)
        session.send("\r")
        _ = session.wait(until: { flat($0).contains("shift+tab") || flat($0).contains("try\"") }, timeout: 8)
    }

    func allowFolder(binary: URL) async throws -> LimitSnapshot {
        try await Task.detached(priority: .userInitiated) { try Self.acceptFolder(binary: binary) }.value
        lastAttempt = .distantPast
        return try await read(binary: binary, force: true)
    }

    // MARK: Running Claude Code in a pseudo-terminal

    /// Where Claude Code keeps the (empty) sessions of those /usage runs. They are Cooldown's own
    /// leftovers, so they are cleared after every reading and never listed as sessions.
    static var transcriptFolder: URL {
        let encoded = workFolder.path.replacingOccurrences(of: "[^A-Za-z0-9-]", with: "-", options: .regularExpression)
        return ClaudePaths.projects.appendingPathComponent(encoded, isDirectory: true)
    }

    static func clearTranscripts() {
        let fm = FileManager.default
        let folder = transcriptFolder
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "jsonl" { try? fm.removeItem(at: file) }
    }

    /// A tall terminal: /usage now adds "What's contributing to your limits usage?" under the
    /// limits, and on a 60-row screen the session line scrolled off the top of the full redraw that
    /// is read — the week was there, the five hours were not.
    static let rows: UInt16 = 200

    static var workFolder: URL {
        let folder = Settings.appSupport.appendingPathComponent("claude-usage", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }


    private static func run(binary: URL) throws -> LimitSnapshot {
        var master: Int32 = 0
        var slave: Int32 = 0
        var size = winsize(ws_row: Self.rows, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw UsageError.terminal }
        defer { close(master) }

        let process = Process()
        process.executableURL = binary
        // Only the usage screen is wanted: no hooks (Cooldown's own or other tools'), no status
        // line, no update checks or other background traffic for this short run.
        process.arguments = ["/usage", "--settings", #"{"disableAllHooks":true,"statusLine":{"type":"command","command":"true"}}"#,
                             // None of the person's MCP servers: they would start (and may ask for
                             // sign-ins or permissions) on every run, only to be closed a second later.
                             "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
        // An empty folder of Cooldown's own: started in the home folder, Claude Code looks around it,
        // and macOS then asks on Cooldown's behalf for Photos, Documents and the like.
        process.currentDirectoryURL = workFolder
        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        environment["TERM"] = "xterm-256color"
        // Not CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: with it, /usage only shows its cached
        // numbers (marked "Refreshing…") and never fetches fresh ones.
        // Claude Code looks into Chrome's, Brave's and Edge's folders for its browser extension at start;
        // macOS 27 takes that for Cooldown reading other apps' data. Not wanted here: turned off.
        environment["CLAUDE_CODE_ENABLE_CFC"] = "false"
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["COLUMNS"] = "120"
        environment["LINES"] = String(Self.rows)
        // Its own folder first: an npm install under nvm/fnm starts with `#!/usr/bin/env node`.
        let own = [binary.deletingLastPathComponent().path, binary.resolvingSymlinksInPath().deletingLastPathComponent().path]
        environment["PATH"] = (own + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        process.environment = environment
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        try process.run()
        try? terminal.close()

        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        var bytes = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        var deadline = Date().addingTimeInterval(25)
        // "Failed to load usage data" is usually a passing server hiccup: press "r" like a person.
        var retries = 0
        var retryAt: Date?
        // /usage first draws the numbers it cached last time ("Refreshing…"), then fetches and
        // updates only what changed on screen. Once it is quiet again, a one-column resize makes
        // it draw the whole screen afresh, and only that drawing is read.
        var lastOutput = Date()
        var sawLimits: Date?
        var redrawFrom: Int?
        var width: UInt16 = 120
        let started = Date()
        while Date() < deadline {
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 100) > 0 {
                let count = Darwin.read(master, &chunk, chunk.count)
                if count > 0 { bytes.append(chunk, count: count); lastOutput = Date() } else if count == 0 { break }
            }
            if let from = redrawFrom {
                if !process.isRunning { break }
                guard Date().timeIntervalSince(lastOutput) > 0.5, bytes.count > from else { continue }
                // Claude Code 2.1.30x draws its last numbers with "Refreshing…" (or "Loading usage
                // data…" with none) until the server answers — a second, or many over a slow VPN —
                // and then may only erase that line. Each full redraw shows where it really is: still
                // waiting, look again a moment later (up to 40 s); otherwise this drawing is the one.
                let drawn = plain(bytes.suffix(from: bytes.startIndex + from))
                // A drawing that still has "Refreshing" anywhere got mixed with the answer arriving
                // at the same moment: not a clean picture either.
                if Self.pending(drawn) || drawn.contains("Refreshing"), let seen = sawLimits, Date().timeIntervalSince(seen) < 40 {
                    redrawFrom = nil
                    lastOutput = Date()
                    continue
                }
                break
            }
            if let seen = sawLimits {
                if Date().timeIntervalSince(lastOutput) > 0.9 || Date().timeIntervalSince(seen) > 40 {
                    redrawFrom = bytes.count
                    lastOutput = Date()
                    width = width == 120 ? 121 : 120
                    var size = winsize(ws_row: Self.rows, ws_col: width, ws_xpixel: 0, ws_ypixel: 0)
                    _ = ioctl(master, TIOCSWINSZ, &size)
                    kill(process.processIdentifier, SIGWINCH)
                    deadline = max(deadline, Date().addingTimeInterval(5))
                }
                continue
            }
            do {
                let text = plain(bytes)
                let flat = text.replacingOccurrences(of: " ", with: "")
                if flat.localizedCaseInsensitiveContains("trustthisfolder") { break }
                // The usage server says "not now": waiting longer only asks again.
                if flat.contains("Usageendpointisratelimited") { break }
                // No numbers of its own yet ("Loading usage data…"): give a slow connection time.
                if flat.contains("Loadingusagedata") { deadline = max(deadline, started.addingTimeInterval(50)) }
                let failures = flat.components(separatedBy: "Failedtoloadusagedata").count - 1
                if failures > retries {
                    if retries >= 3 { break }
                    if let at = retryAt {
                        if Date() >= at {
                            var key = UInt8(ascii: "r")
                            _ = Darwin.write(master, &key, 1)
                            retries += 1
                            retryAt = nil
                            deadline = max(deadline, Date().addingTimeInterval(12))
                        }
                    } else {
                        retryAt = Date().addingTimeInterval(Double(retries + 1) * 1.5)
                    }
                }
                // Claude Code sometimes draws spaces as cursor jumps, so words may arrive glued together.
                // /usage first draws its cached numbers with "Refreshing…", then the fresh ones.
                // A week with its numbers (Pro with an idle session has only one "Resets" line).
                if text.range(of: #"Current\s*week"#, options: .regularExpression) != nil,
                   text.range(of: #"%\s*(used|left)"#, options: .regularExpression) != nil, text.contains("Resets") {
                    sawLimits = Date()
                    deadline = max(deadline, Date().addingTimeInterval(45))
                }
            }
            if !process.isRunning { break }
        }

        // Close the screen the way a person would, then make sure Claude Code is gone.
        var escape: UInt8 = 0x1B
        _ = Darwin.write(master, &escape, 1)
        usleep(200_000)
        if process.isRunning { process.terminate() }
        let stop = Date().addingTimeInterval(2)
        while process.isRunning && Date() < stop { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }

        clearTranscripts()
        let text = plain(bytes)
        let redraw = redrawFrom.map { plain(bytes.suffix(from: bytes.startIndex + $0)) }
        // What the last drawing says about itself comes first: numbers it could not refresh are old.
        let latest = (redraw ?? text).replacingOccurrences(of: " ", with: "")
        if latest.contains("Usageendpointisratelimited") || text.replacingOccurrences(of: " ", with: "").contains("Usageendpointisratelimited") {
            throw UsageError.rateLimited
        }
        let stale = ["last-knownusage", "couldnotrefresh", "Couldnotrefreshusagedata"].contains { latest.localizedCaseInsensitiveContains($0) }
        if stale, latest.localizedCaseInsensitiveContains("ratelimited") { throw UsageError.rateLimited }
        if !stale, let snapshot = read(stream: text, redraw: redraw, now: Date()) { return snapshot }
        let logs = Settings.appSupport.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try? text.write(to: logs.appendingPathComponent("claude-usage-unread.txt"), atomically: true, encoding: .utf8)
        let flat = text.replacingOccurrences(of: " ", with: "")
        if stale || flat.contains("Failedtoloadusagedata") || pending(text) { throw UsageError.serverFailed }
        if ["Notloggedin", "Pleaserun/login", "Authenticationrequired", "Selectloginmethod", "InvalidAPIkey", "OAuthtokenhasexpired"]
            .contains(where: { flat.localizedCaseInsensitiveContains($0) }) {
            throw UsageError.signedOut
        }
        if flat.localizedCaseInsensitiveContains("trustthisfolder") || flat.localizedCaseInsensitiveContains("trustthefiles") { throw UsageError.trust }
        // Claude Code's own error line, word for word: more use than "could not read".
        if let line = text.components(separatedBy: "\n").last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Error:") }) {
            throw UsageError.claude(String(line.trimmingCharacters(in: .whitespaces).prefix(200)))
        }
        throw UsageError.unreadable
    }

    /// Claude Code is still fetching the limits: "Refreshing…" (or "Loading usage data…" before it
    /// has any numbers) is the last thing it drew, with only "Esc to cancel" after it.
    static func pending(_ text: String) -> Bool {
        let markers = ["Refreshing", "Loading usage data", "Loadingusagedata"].compactMap { text.range(of: $0, options: .backwards) }
        guard let marker = markers.max(by: { $0.lowerBound < $1.lowerBound }) else { return false }
        let after = String(text[marker.upperBound...].filter { !$0.isWhitespace })
        return after.replacingOccurrences(of: "Esctocancel", with: "", options: .caseInsensitive).count < 40
    }

    /// The last drawing of the limits (from the last "Current session" on).
    /// The numbers from everything /usage drew, not from one picture of the screen: Claude Code
    /// keeps adding sections (a usage breakdown, tips…), redraws only what changed, and a tall screen
    /// can scroll. So each window is taken on its own, from its latest drawing that came after the
    /// cached numbers ("Refreshing…") were replaced: first from the full redraw, and a window
    /// missing there from the rest of the fresh output. Cached numbers are never used.
    static func read(stream text: String, redraw: String?, now: Date) -> LimitSnapshot? {
        let primary = redraw.flatMap { pending($0) || $0.contains("Refreshing") ? nil : parse(latestScreen($0), now: now) }
        // After the last "Refreshing…" everything drawn is fresh; per window, its last drawing wins.
        var tail = text
        if let marker = text.range(of: "Refreshing", options: .backwards) { tail = String(text[marker.upperBound...]) }
        let fresh = latestPerWindow(tail, now: now)
        guard var result = primary ?? fresh else { return nil }
        if let fresh {
            if result.session == nil { result.session = fresh.session }
            if result.weekly == nil { result.weekly = fresh.weekly }
            for extra in fresh.extras where !result.extras.contains(where: { $0.label == extra.label }) { result.extras.append(extra) }
        }
        result.limitReached = (result.session?.usedPercent ?? 0) >= 100 || (result.weekly?.usedPercent ?? 0) >= 100
        return result
    }

    /// Each window's last complete drawing in `text` (session, week, per-model weeks).
    static func latestPerWindow(_ text: String, now: Date) -> LimitSnapshot? {
        guard let regex = try? NSRegularExpression(pattern: #"Current\s*"#) else { return nil }
        let starts = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text)?.lowerBound }
        var result: LimitSnapshot?
        // From the end: the first reading found for a window is its latest.
        for (index, start) in starts.enumerated().reversed() {
            let end = index + 1 < starts.count ? starts[index + 1] : text.endIndex
            guard let one = parse(String(text[start..<end]), now: now) else { continue }
            if result == nil { result = LimitSnapshot(provider: .claude, plan: nil, session: nil, weekly: nil, fetchedAt: now, source: one.source) }
            if result?.session == nil { result?.session = one.session }
            if result?.weekly == nil { result?.weekly = one.weekly }
            for extra in one.extras where !(result?.extras.contains(where: { $0.label == extra.label }) ?? false) { result?.extras.append(extra) }
        }
        return result
    }

    static func latestScreen(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"Current\s*session"#, options: .caseInsensitive),
              let last = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = Range(last.range, in: text) else { return text }
        return String(text[range.lowerBound...])
    }

    /// Terminal output without colours and cursor commands; cursor moves to the right become spaces.
    static func plain(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        if let move = try? NSRegularExpression(pattern: "\u{1B}\\[(\\d*)C") {
            let range = NSRange(text.startIndex..., in: text)
            for match in move.matches(in: text, range: range).reversed() {
                let count = Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) } ?? 1
                if let whole = Range(match.range, in: text) {
                    text.replaceSubrange(whole, with: String(repeating: " ", count: min(count, 200)))
                }
            }
        }
        let codes = "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|\u{1B}[@-_]"
        text = text.replacingOccurrences(of: codes, with: "", options: .regularExpression)
        return text.replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: Reading the screen

    /// Pulls every "Current …" block: its percentage and its reset time.
    static func parse(_ text: String, now: Date) -> LimitSnapshot? {
        var snapshot = LimitSnapshot(provider: .claude, plan: nil, session: nil, weekly: nil, fetchedAt: now,
                                     source: "Claude Code /usage")
        let blocks = text.replacingOccurrences(of: #"Current\s*"#, with: "\u{1}", options: .regularExpression)
            .components(separatedBy: "\u{1}").dropFirst()
        for block in blocks {
            let header = block.prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)
            // "% used" today; "% left" is read too, in case a later version turns it around.
            guard let used = firstMatch(#"(\d+(?:\.\d+)?)\s*%\s*used"#, in: block).flatMap(Double.init)
                    ?? firstMatch(#"(\d+(?:\.\d+)?)\s*%\s*left"#, in: block).flatMap(Double.init).map({ 100 - $0 }) else { continue }
            let resetText = firstMatch(#"Resets\s*([^\n(]+)"#, in: block)?.trimmingCharacters(in: .whitespaces)
            let zone = firstMatch(#"Resets[^\n(]*\(([A-Za-z_]+(?:/[A-Za-z0-9_+\-]+)+)"#, in: block).flatMap(TimeZone.init(identifier:))
            let lower = header.lowercased().replacingOccurrences(of: " ", with: "")
            let kind: WindowKind = lower.hasPrefix("session") || lower.contains("5-hour") || lower.contains("5hour") ? .session : .weekly
            // Never invent a reset time. A made-up five-hour or weekly reset would win the merge
            // against a real reading and send auto-continue at the wrong moment.
            guard let resetText, let resets = resetDate(resetText, zone: zone ?? .current, now: now) else { continue }
            // A reset outside its window's length is a misread (an old time pushed to tomorrow):
            // it would win the merge and send auto-continue at the wrong moment.
            guard resets > now.addingTimeInterval(-60),
                  resets < now.addingTimeInterval(Double(kind.defaultMinutes) * 60 + 3_600) else { continue }
            var window = LimitWindow(kind: kind, usedPercent: min(100, max(0, used)),
                                     durationMinutes: kind.defaultMinutes, resetsAt: resets)
            if kind == .session {
                if snapshot.session == nil { snapshot.session = window }
            } else if lower.contains("allmodels") || (snapshot.weekly == nil && !lower.contains("(")) {
                snapshot.weekly = window
            } else if let name = firstMatch(#"\(([^)]+)\)"#, in: header) {
                let clean = name.replacingOccurrences(of: #"\s*only$"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                window.label = L("Неделя, %@", "\(clean.capitalized)")
                snapshot.extras.append(window)
            }
        }
        snapshot.limitReached = (snapshot.session?.usedPercent ?? 0) >= 100 || (snapshot.weekly?.usedPercent ?? 0) >= 100
        return snapshot.session != nil || snapshot.weekly != nil ? snapshot : nil
    }

    /// "6:10pm", "Oct 23 at 7pm", "Oct 23, 7:30am" in the time zone the screen names; also a
    /// 24-hour "18:10" and "in 3h 20m", in case a later version writes it so.
    static func resetDate(_ text: String, zone: TimeZone, now: Date) -> Date? {
        if let relative = try? NSRegularExpression(pattern: #"^in\s*(?:(\d+)\s*d[a-z]*)?\s*(?:(\d+)\s*h[a-z]*)?\s*(?:(\d+)\s*m[a-z]*)?"#, options: .caseInsensitive),
           let match = relative.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.range.length > 3 {
            let parts = (1...3).map { Range(match.range(at: $0), in: text).flatMap { Double(text[$0]) } ?? 0 }
            let seconds = parts[0] * 86_400 + parts[1] * 3_600 + parts[2] * 60
            return seconds > 0 ? now.addingTimeInterval(seconds) : nil
        }
        // "Jan 2, 2027 at 7pm": a reset in the next year carries it.
        let pattern = #"^(?:([A-Za-z]{3})[a-z]*\s*(\d{1,2})(?:,?\s*(\d{4}))?(?:,)?\s*(?:at\s*)?)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? { Range(match.range(at: index), in: text).map { String(text[$0]) } }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard var hour = group(4).flatMap(Int.init) else { return nil }
        // A bare number is not a time: a 24-hour time always has its minutes.
        guard group(6) != nil || group(5) != nil, hour < 24 else { return nil }
        let minute = group(5).flatMap(Int.init) ?? 0
        let pm = group(6)?.lowercased() == "pm"
        if group(6) != nil { if hour == 12 { hour = pm ? 12 : 0 } else if pm { hour += 12 } }
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = hour
        parts.minute = minute
        if let month = group(1), let day = group(2).flatMap(Int.init) {
            let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            guard let index = months.firstIndex(of: month.lowercased()) else { return nil }
            parts.month = index + 1
            parts.day = day
            if let year = group(3).flatMap(Int.init) { parts.year = year }
            guard var date = calendar.date(from: parts) else { return nil }
            if group(3) == nil, date < now.addingTimeInterval(-86_400) { date = calendar.date(byAdding: .year, value: 1, to: date) ?? date }
            return date
        }
        guard var date = calendar.date(from: parts) else { return nil }
        if date < now.addingTimeInterval(-60) { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
        return date
    }

    private static func firstMatch(_ pattern: String, in text: some StringProtocol) -> String? {
        let string = String(text)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: string) else { return nil }
        return String(string[range])
    }

    enum UsageError: LocalizedError, Equatable {
        case terminal, signedOut, trust, unreadable, missing, serverFailed, rateLimited
        case claude(String)

        var errorDescription: String? {
            switch self {
            case .terminal: return L("Не удалось запустить Claude Code.")
            case .missing: return L("Claude Code не найден. Откройте настройку Cooldown: она установит его по одной кнопке.")
            case .signedOut: return L("Claude Code не вошёл в аккаунт. Откройте настройку Cooldown и нажмите «Войти».")
            case .trust: return L("Claude Code ждёт разрешения работать в пустой папке Cooldown.")
            case .unreadable: return L("Не удалось прочитать экран /usage в Claude Code.")
            case .serverFailed: return L("Claude Code не смог загрузить лимиты с сервера; Cooldown повторит через минуту.")
            case .rateLimited: return L("Сервер лимитов Claude просит подождать; Cooldown спросит позже.")
            case .claude(let line): return L("Claude Code ответил: %@", line)
            }
        }
    }
}

/// A small pseudo-terminal session with Claude Code, used for the one-time folder permission.
private final class Terminal {
    private let process = Process()
    private var master: Int32 = 0
    private var output = Data()

    init(binary: URL, arguments: [String]) throws {
        var slave: Int32 = 0
        var size = winsize(ws_row: ClaudeUsageCLI.rows, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw ClaudeUsageCLI.UsageError.terminal }
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = ClaudeUsageCLI.workFolder
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        environment["CLAUDE_CODE_ENABLE_CFC"] = "false" // no look into browsers' folders
        environment["DISABLE_AUTOUPDATER"] = "1"
        process.environment = environment
        let handle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        process.standardInput = handle
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        try? handle.close()
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
    }

    func wait(until done: (String) -> Bool, timeout: TimeInterval) -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && process.isRunning {
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 200) > 0 {
                let count = Darwin.read(master, &chunk, chunk.count)
                if count > 0 { output.append(chunk, count: count) }
            }
            if done(ClaudeUsageCLI.plain(output)) { return true }
        }
        return false
    }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { Darwin.write(master, $0.baseAddress, $0.count) }
    }

    func stop() {
        if process.isRunning { process.terminate() }
        let stop = Date().addingTimeInterval(2)
        while process.isRunning && Date() < stop { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        close(master)
    }
}
