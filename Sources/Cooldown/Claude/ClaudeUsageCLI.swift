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
    private var running: Task<LimitSnapshot, Error>?

    /// How often Claude Code is started for /usage. Starting it costs a second of CPU and a
    /// few helper processes, so it runs only as often as the numbers can have changed:
    /// every 2 minutes while Claude is working or Cooldown's window is open, every 5 while
    /// Claude Desktop is open and someone is at the Mac, every 15 otherwise, every 30 while
    /// the screen is locked — and not at all while Claude Code's status line already brings
    /// fresh numbers.
    struct Pace: Sendable {
        var claudeWorking = false
        var panelOpen = false
        var claudeRunning = false
        var statusLineFresh = false
    }

    static func interval(_ pace: Pace) -> TimeInterval {
        if let info = CGSessionCopyCurrentDictionary() as? [String: Any], info["CGSSessionScreenIsLocked"] as? Bool == true {
            return 30 * 60
        }
        if pace.statusLineFresh { return 10 * 60 }
        if pace.claudeWorking || pace.panelOpen { return minimumInterval }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if pace.claudeRunning && idle < 10 * 60 { return 5 * 60 }
        return 15 * 60
    }

    func read(binary: URL, force: Bool = false, pace: Pace = Pace()) async throws -> LimitSnapshot {
        if !force, Date().timeIntervalSince(lastAttempt) < Self.interval(pace) {
            if let last { return last }
            if let lastError { throw lastError }
        }
        if let running { return try await running.value }
        let task = Task.detached(priority: .utility) {
            // Claude Code sometimes draws the screen late (updates, notices); one retry covers it.
            do { return try Self.run(binary: binary) } catch UsageError.unreadable { return try Self.run(binary: binary) }
        }
        running = task
        defer { running = nil }
        lastAttempt = Date()
        do {
            let snapshot = try await task.value
            last = snapshot
            lastError = nil
            await MainActor.run {
                ClaudeUsageStatus.shared.needsPermission = false
                ClaudeUsageStatus.shared.problem = nil
            }
            return snapshot
        } catch {
            lastError = error
            let needsPermission = (error as? UsageError) == .trust
            await MainActor.run {
                ClaudeUsageStatus.shared.needsPermission = needsPermission
                ClaudeUsageStatus.shared.problem = needsPermission ? nil : error.localizedDescription
            }
            throw error
        }
    }

    /// Answers Claude Code's one-time folder question with "Yes, I trust this folder" for Cooldown's
    /// own empty folder. Only ever called from the button the person presses in Cooldown.
    func allowFolder(binary: URL) async throws -> LimitSnapshot {
        try await Task.detached(priority: .userInitiated) {
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
        }.value
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

    static var workFolder: URL {
        let folder = Settings.appSupport.appendingPathComponent("claude-usage", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }


    private static func run(binary: URL) throws -> LimitSnapshot {
        var master: Int32 = 0
        var slave: Int32 = 0
        var size = winsize(ws_row: 60, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw UsageError.terminal }
        defer { close(master) }

        let process = Process()
        process.executableURL = binary
        // Only the usage screen is wanted: no hooks (Cooldown's own or other tools'), no status
        // line, no update checks or other background traffic for this short run.
        process.arguments = ["/usage", "--settings", #"{"disableAllHooks":true,"statusLine":{"type":"command","command":"true"}}"#]
        // An empty folder of Cooldown's own: started in the home folder, Claude Code looks around it,
        // and macOS then asks on Cooldown's behalf for Photos, Documents and the like.
        process.currentDirectoryURL = workFolder
        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        environment["TERM"] = "xterm-256color"
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["COLUMNS"] = "120"
        environment["LINES"] = "60"
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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
        let deadline = Date().addingTimeInterval(25)
        var settleUntil: Date?
        while Date() < deadline {
            if let settleUntil, Date() > settleUntil { break }
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 200) > 0 {
                let count = Darwin.read(master, &chunk, chunk.count)
                if count > 0 { bytes.append(chunk, count: count) } else if count == 0 { break }
            }
            if settleUntil == nil {
                let text = plain(bytes)
                if text.replacingOccurrences(of: " ", with: "").localizedCaseInsensitiveContains("trustthisfolder") { break }
                // Claude Code sometimes draws spaces as cursor jumps, so words may arrive glued together.
                if text.range(of: #"Current\s*week"#, options: .regularExpression) != nil,
                   text.components(separatedBy: "Resets").count > 2 {
                    settleUntil = Date().addingTimeInterval(0.6)
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
        if let snapshot = parse(text, now: Date()) { return snapshot }
        let logs = Settings.appSupport.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try? text.write(to: logs.appendingPathComponent("claude-usage-unread.txt"), atomically: true, encoding: .utf8)
        if text.localizedCaseInsensitiveContains("login") || text.localizedCaseInsensitiveContains("sign in") {
            throw UsageError.signedOut
        }
        if text.localizedCaseInsensitiveContains("trust") { throw UsageError.trust }
        throw UsageError.unreadable
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
            guard let used = firstMatch(#"(\d+(?:\.\d+)?)\s*%\s*used"#, in: block).flatMap(Double.init) else { continue }
            let resetText = firstMatch(#"Resets\s*([^\n(]+)"#, in: block)?.trimmingCharacters(in: .whitespaces)
            let zone = firstMatch(#"Resets[^\n(]*\(([A-Za-z_]+/[A-Za-z_]+)"#, in: block).flatMap(TimeZone.init(identifier:))
            let lower = header.lowercased().replacingOccurrences(of: " ", with: "")
            let kind: WindowKind = lower.hasPrefix("session") ? .session : .weekly
            let fallback = now.addingTimeInterval(Double(kind.defaultMinutes) * 60)
            let resets = resetText.flatMap { resetDate($0, zone: zone ?? .current, now: now) } ?? fallback
            var window = LimitWindow(kind: kind, usedPercent: min(100, max(0, used)),
                                     durationMinutes: kind.defaultMinutes, resetsAt: resets)
            if kind == .session {
                if snapshot.session == nil { snapshot.session = window }
            } else if lower.contains("allmodels") || (snapshot.weekly == nil && !lower.contains("(")) {
                snapshot.weekly = window
            } else if let name = firstMatch(#"\(([^)]+)\)"#, in: header) {
                let clean = name.replacingOccurrences(of: #"\s*only$"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                window.label = "Неделя, \(clean.capitalized)"
                snapshot.extras.append(window)
            }
        }
        snapshot.limitReached = (snapshot.session?.usedPercent ?? 0) >= 100 || (snapshot.weekly?.usedPercent ?? 0) >= 100
        return snapshot.session != nil || snapshot.weekly != nil ? snapshot : nil
    }

    /// "6:10pm", "Oct 23 at 7pm", "Oct 23, 7:30am" in the time zone the screen names.
    static func resetDate(_ text: String, zone: TimeZone, now: Date) -> Date? {
        let pattern = #"^(?:([A-Za-z]{3})[a-z]*\s*(\d{1,2})(?:,)?\s*(?:at\s*)?)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? { Range(match.range(at: index), in: text).map { String(text[$0]) } }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard var hour = group(3).flatMap(Int.init) else { return nil }
        let minute = group(4).flatMap(Int.init) ?? 0
        let pm = group(5)?.lowercased() == "pm"
        if hour == 12 { hour = pm ? 12 : 0 } else if pm { hour += 12 }
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = hour
        parts.minute = minute
        if let month = group(1), let day = group(2).flatMap(Int.init) {
            let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            guard let index = months.firstIndex(of: month.lowercased()) else { return nil }
            parts.month = index + 1
            parts.day = day
            guard var date = calendar.date(from: parts) else { return nil }
            if date < now.addingTimeInterval(-86_400) { date = calendar.date(byAdding: .year, value: 1, to: date) ?? date }
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

    enum UsageError: LocalizedError {
        case terminal, signedOut, trust, unreadable, missing

        var errorDescription: String? {
            switch self {
            case .terminal: return "Не удалось запустить Claude Code."
            case .missing: return "Claude Code не найден. Откройте вкладку Code в Claude Desktop один раз или установите Claude Code."
            case .signedOut: return "Claude Code не вошёл в аккаунт. Запустите claude в Терминале и войдите."
            case .trust: return "Claude Code ждёт разрешения работать в пустой папке Cooldown."
            case .unreadable: return "Не удалось прочитать экран /usage в Claude Code."
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
        var size = winsize(ws_row: 60, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw ClaudeUsageCLI.UsageError.terminal }
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = ClaudeUsageCLI.workFolder
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
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
