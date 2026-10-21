import Foundation

/// Notices when any Codex conversation finishes a turn ("task_complete" in its session file)
/// and says so with the agent's last message, like a notch app would. Only conversations the
/// person started (not Codex's own reviewers) and only turns that ran long enough to matter.
@MainActor
final class CodexFinishWatcher {
    static let shared = CodexFinishWatcher()

    private var offsets: [String: UInt64] = [:]
    private var userThreads: [String: Bool] = [:]
    private var threadIds: [String: String] = [:]
    private var titles: [String: String] = [:]
    /// Running token totals per conversation, and the total when the current turn began.
    private var lastTotal: [String: Int] = [:]
    private var turnStart: [String: Int] = [:]
    private let isoDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private var timer: Timer?
    private var watch: FolderWatch?
    private var primed = false

    func start() {
        // Codex's session folders tell when they change; the timer is only a safety net.
        watch = FolderWatch([CodexPaths.sessions.path, CodexPaths.home.appendingPathComponent("archived_sessions").path], latency: 1.5) {
            MainActor.assumeIsolated { CodexFinishWatcher.shared.poll() }
        }
        timer?.invalidate()
        timer = Timer.every(watch == nil ? 10 : 60) { _ in
            Task { @MainActor in CodexFinishWatcher.shared.poll() }
        }
        poll()
    }

    private func poll() {
        guard !AppModel.shared.demoActive else { return }
        for file in recentFiles() {
            let path = file.path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
            guard let start = offsets[path] else {
                // First sight (a new conversation, or Codex moved/continued one into a new file):
                // read it all; turns older than a few minutes are skipped by their timestamps.
                offsets[path] = primed ? 0 : size
                if primed { read(file, from: 0, to: size) }
                continue
            }
            if size > start { read(file, from: start, to: size) }
            offsets[path] = size
        }
        primed = true
    }

    /// Session files of conversations active in the last 15 minutes. Codex's own index says
    /// where each file is; if it cannot be read, both session folders are scanned instead.
    private func recentFiles() -> [URL] {
        let cutoff = Date().addingTimeInterval(-15 * 60)
        if let threads = CodexThreadIndex.updated(since: cutoff) {
            var files: [URL] = []
            for thread in threads where !thread.rolloutPath.isEmpty && thread.rolloutPath.hasSuffix(".jsonl") {
                let url = URL(fileURLWithPath: thread.rolloutPath)
                userThreads[url.path] = thread.isUser
                threadIds[url.path] = thread.id
                if !thread.title.isEmpty { titles[thread.id] = thread.title }
                files.append(url)
            }
            return files
        }
        return scannedFiles(cutoff: cutoff)
    }

    private func scannedFiles(cutoff: Date) -> [URL] {
        let fm = FileManager.default
        let calendar = Calendar.current
        var folders: [URL] = [CodexPaths.home.appendingPathComponent("archived_sessions")]
        for day in [Date(), Date().addingTimeInterval(-86400)] {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            folders.append(CodexPaths.sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!)))
        }
        var result: [URL] = []
        for folder in folders {
            guard let names = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for url in names where url.pathExtension == "jsonl" {
                if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, date > cutoff {
                    result.append(url)
                }
            }
        }
        return result
    }

    private func read(_ file: URL, from start: UInt64, to end: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: Int(min(end - start, 8 << 20))) else { return }
        if userThreads[file.path] == nil {
            let meta = Self.meta(file)
            userThreads[file.path] = meta.user
            if let id = meta.id { threadIds[file.path] = id }
        }
        // The conversation's own id is in the first line; the file name can carry a second id
        // (a continued segment), which Codex cannot open.
        let threadId = threadIds[file.path] ?? Self.threadId(from: file)
        guard userThreads[file.path] == true else { return }
        let key = threadId ?? file.lastPathComponent
        let title = threadId.flatMap { titles[$0] ?? AppModel.shared.knownTitle($0) ?? Self.indexTitle($0) } ?? ""
        let opener: AgentActivity.Opener = threadId.map { .codexThread($0) } ?? .none
        let activity = AgentActivity.shared
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // Only short event lines matter; skip the big ones (tool output, messages) unparsed.
            guard line.count < 1 << 20 else { continue }
            let head = line.prefix(160)
            guard head.contains(UInt8(ascii: "e")),
                  let text = String(bytes: head, encoding: .utf8) ?? String(bytes: head.dropLast(4), encoding: .utf8),
                  text.contains("\"event_msg\"") else { continue }
            let kind: String
            if text.contains("\"task_complete\"") { kind = "complete" }
            else if text.contains("\"task_started\"") { kind = "started" }
            else if text.contains("\"turn_aborted\"") || text.contains("\"task_aborted\"") { kind = "aborted" }
            else if text.contains("\"token_count\"") {
                activity.touch(.codex, key: key)
                // One parse for both: the running token total and the account limits.
                if let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                   let payload = object["payload"] as? [String: Any] {
                    if let total = (payload["info"] as? [String: Any])?["total_token_usage"] as? [String: Any] {
                        let sum = (Num.int(total["input_tokens"]) ?? 0) + (Num.int(total["output_tokens"]) ?? 0)
                        if sum > 0 { lastTotal[key] = sum }
                    }
                    if let limits = payload["rate_limits"] as? [String: Any],
                       let date = (object["timestamp"] as? String).flatMap({ isoDate.date(from: $0) }),
                       Date().timeIntervalSince(date) < 5 * 60, let snapshot = Self.limits(limits, at: date) {
                        AppModel.shared.codex.apply(snapshot)
                    }
                }
                continue
            }
            else { continue }
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { continue }
            let date = (object["timestamp"] as? String).flatMap { isoDate.date(from: $0) } ?? Date()
            // Codex rewrites whole conversations into new files (continuations, archiving):
            // only what happened in the last few minutes is news.
            guard Date().timeIntervalSince(date) < 5 * 60 else { continue }
            switch kind {
            case "started":
                turnStart[key] = lastTotal[key]
                activity.started(.codex, key: key, title: title, source: .files, at: date)
            case "aborted":
                activity.ended(.codex, key: key)
            default:
                let duration = (payload["duration_ms"] as? Double).map { $0 / 1000 }
                let message = payload["last_agent_message"] as? String ?? ""
                var tokens: Int?
                if let begin = turnStart.removeValue(forKey: key), let end = lastTotal[key], end > begin { tokens = end - begin }
                activity.finished(.codex, key: key, title: title, message: message, duration: duration,
                                  source: .files, opener: opener, at: date, tokens: tokens)
            }
        }
    }

    /// The account limits Codex writes into the session file with each token count.
    static func limits(_ raw: [String: Any], at date: Date) -> LimitSnapshot? {
        if let id = raw["limit_id"] as? String, id != "codex" { return nil }
        var snapshot = LimitSnapshot(provider: .codex, plan: raw["plan_type"] as? String, session: nil, weekly: nil,
                                     fetchedAt: date, source: "Codex")
        for key in ["primary", "secondary"] {
            guard let window = raw[key] as? [String: Any], let used = Num.double(window["used_percent"]),
                  let resets = Num.double(window["resets_at"]) else { continue }
            let minutes = Num.int(window["window_minutes"]) ?? (key == "primary" ? 300 : 10080)
            let limit = LimitWindow(kind: .from(minutes: minutes), usedPercent: min(100, max(0, used)), durationMinutes: minutes,
                                    resetsAt: Date(timeIntervalSince1970: resets))
            if limit.kind == .session { snapshot.session = limit } else { snapshot.weekly = limit }
        }
        return snapshot.session != nil || snapshot.weekly != nil ? snapshot : nil
    }

    /// Codex keeps conversation names in session_index.jsonl (one line per rename).
    static func indexTitle(_ id: String) -> String? {
        let url = CodexPaths.home.appendingPathComponent("session_index.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var name: String?
        for line in text.split(separator: "\n") where line.contains(id) {
            if let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
               (object["id"] as? String)?.lowercased() == id.lowercased(),
               let value = object["thread_name"] as? String, !value.isEmpty {
                name = value
            }
        }
        return name
    }

    static func threadId(from file: URL) -> String? {
        // rollout-2026-10-20T10-42-45-<uuid>.jsonl
        let name = file.deletingPathExtension().lastPathComponent
        guard name.count >= 36 else { return nil }
        let candidate = String(name.suffix(36))
        return UUID(uuidString: candidate) != nil ? candidate.lowercased() : nil
    }

    /// The first line says who started the session (Codex's reviewers and helpers are skipped)
    /// and which conversation it belongs to.
    static func meta(_ file: URL) -> (user: Bool, id: String?) {
        guard let handle = try? FileHandle(forReadingFrom: file), let data = try? handle.read(upToCount: 256 << 10) else { return (false, nil) }
        try? handle.close()
        guard let first = data.split(separator: UInt8(ascii: "\n")).first,
              let object = (try? JSONSerialization.jsonObject(with: Data(first))) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return (false, nil) }
        let id = (payload["id"] as? String).flatMap { UUID(uuidString: $0) != nil ? $0.lowercased() : nil }
        if let source = payload["thread_source"] as? String { return (source == "user", id) }
        return (true, id)
    }
}
