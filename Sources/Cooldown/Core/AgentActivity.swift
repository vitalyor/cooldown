import AppKit
import Foundation

/// One place that knows which agent sessions are working right now, which wait for the person,
/// and which just finished. Every source reports here — Codex's session files, Cooldown's hooks
/// in Codex and Claude Code, and Claude Desktop's window — so a finished turn is announced once,
/// however many sources noticed it, and the menu bar can show what is busy.
@MainActor
final class AgentActivity: ObservableObject {
    static let shared = AgentActivity()

    enum Source: String { case files, hook, window, web }
    enum State: Equatable { case working, waiting }

    struct Session: Identifiable, Equatable {
        let provider: ProviderID
        let key: String
        var title: String
        var state: State
        var started: Date
        var updated: Date
        var source: Source
        var reason: String? = nil
        /// The 5-hour window's share used when the turn began, to tell what the turn cost.
        var startUsed: Double? = nil
        var startReset: Date? = nil
        var silenceSaid = false
        var id: String { "\(provider.rawValue):\(key)" }
    }

    /// What a card offers to open for this session.
    enum Opener: Equatable {
        case codexThread(String)
        case claudeChat(ClaudeChat)
        case claudeApp
        case none
    }

    @Published private(set) var sessions: [String: Session] = [:]

    /// Finished turns already announced, by session, so a second source stays quiet.
    private var announced: [String: (at: Date, source: Source)] = [:]
    private var sweep: Timer?

    init() {
        sweep = Timer.every(60) { _ in
            Task { @MainActor in AgentActivity.shared.dropStale() }
        }
    }

    func working(_ provider: ProviderID) -> [Session] {
        sessions.values.filter { $0.provider == provider && $0.state == .working }.sorted { $0.started < $1.started }
    }

    func waiting(_ provider: ProviderID) -> [Session] {
        sessions.values.filter { $0.provider == provider && $0.state == .waiting }
    }

    // MARK: Reports

    /// A short trail of what the sources reported and what was decided (activity.log, kept small).
    static func trace(_ text: String) {
        let url = Settings.appSupport.appendingPathComponent("activity.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            let size = handle.offsetInFile
            try? handle.close()
            if size > 256 * 1024 { try? FileManager.default.removeItem(at: url) }
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    func started(_ provider: ProviderID, key: String, title: String, source: Source, at date: Date = Date()) {
        if sessions["\(provider.rawValue):\(key)"] == nil { Self.trace("start \(provider.rawValue) \(source.rawValue) \(key) «\(title)»") }
        let id = "\(provider.rawValue):\(key)"
        if var existing = sessions[id] {
            existing.state = .working
            existing.updated = date
            existing.reason = nil
            if !title.isEmpty { existing.title = title }
            sessions[id] = existing
        } else {
            let window = AppModel.shared.store(provider).snapshot?.session
            sessions[id] = Session(provider: provider, key: key, title: title, state: .working, started: date, updated: date, source: source,
                                   startUsed: window?.usedPercent, startReset: window?.resetsAt)
        }
        changed()
    }

    /// Still busy (a tool ran, a token count came in): keeps the session from looking stale.
    func touch(_ provider: ProviderID, key: String) {
        let id = "\(provider.rawValue):\(key)"
        guard let session = sessions[id] else { return }
        let now = Date()
        // Work goes on after a permission question: the person has answered it.
        if session.state == .waiting, now.timeIntervalSince(session.updated) > 5 {
            sessions[id]?.state = .working
            sessions[id]?.reason = nil
            sessions[id]?.updated = now
            changed()
            return
        }
        // Signs of life are kept aside: they come every few seconds and change nothing on screen,
        // so they must not make the views that show `sessions` redraw.
        pulse[id] = now
    }

    private var pulse: [String: Date] = [:]

    private func lastSign(_ id: String, _ session: Session) -> Date { max(session.updated, pulse[id] ?? .distantPast) }

    /// Codex asks for permission for every command that needs it — also when "approve for me"
    /// is on and its own reviewer answers in seconds. So the card waits: if within 20 seconds
    /// the reviewer worked or the turn moved on, nobody needed to be asked.
    func permissionAsked(_ provider: ProviderID, key: String, title: String, reason: String, opener: Opener, at date: Date) {
        let id = "\(provider.rawValue):\(key)"
        Self.trace("permission \(id) — checking in 20 s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            let activity = AgentActivity.shared
            if let moved = activity.pulse[id], moved > date { Self.trace("  \(id): moved on"); return }
            if let session = activity.sessions[id], session.updated > date { Self.trace("  \(id): changed"); return }
            if activity.sessions[id] == nil { Self.trace("  \(id): turn over"); return }
            if provider == .codex, CodexThreadIndex.reviewerActive(since: date.addingTimeInterval(-2)) {
                Self.trace("  \(id): Codex's reviewer decides"); return
            }
            activity.waiting(provider, key: key, title: title, reason: reason, opener: opener)
        }
    }

    /// The agent stopped to ask the person (permission, a question).
    func waiting(_ provider: ProviderID, key: String, title: String, reason: String, opener: Opener) {
        let id = "\(provider.rawValue):\(key)"
        let now = Date()
        var session = sessions[id] ?? Session(provider: provider, key: key, title: title, state: .waiting, started: now, updated: now, source: .hook)
        let wasWaiting = session.state == .waiting && sessions[id] != nil
        session.state = .waiting
        session.updated = now
        session.reason = reason
        if !title.isEmpty { session.title = title }
        sessions[id] = session
        changed()
        guard !wasWaiting, Settings.notifyAttention, !AppModel.shared.demoActive else { return }
        let name = session.title.isEmpty ? provider.displayName : session.title
        Notifier.shared.post(id: "wait-\(id)-\(Int(now.timeIntervalSince1970))",
                             title: "\(provider.displayName) ждёт вас: «\(name)»", body: reason,
                             toast: ToastContent(key: "wait-\(id)", kind: .attention, provider: provider,
                                                 title: "\(provider.displayName) ждёт вашего решения",
                                                 body: "«\(name)»: \(reason)", actions: [Self.action(opener, provider)],
                                                 life: .auto(20), threadId: Self.thread(opener)))
    }

    /// A turn ended. `duration` is known to sources that saw it start; otherwise the session's
    /// own start (if any source reported it) is used.
    /// `startUnknown`: the source only saw the turn midway (Cooldown started during it), so its
    /// own start time says nothing about how long the turn ran.
    func finished(_ provider: ProviderID, key: String, title: String, message: String, duration: TimeInterval?,
                  source: Source, opener: Opener, at date: Date = Date(), startUnknown: Bool = false, tokens: Int? = nil) {
        let id = "\(provider.rawValue):\(key)"
        let session = sessions.removeValue(forKey: id)
        changed()
        let length = startUnknown ? nil : (duration ?? session.map { date.timeIntervalSince($0.started) })
        Self.trace("finish \(provider.rawValue) \(source.rawValue) \(key) length=\(length.map { String(Int($0)) } ?? "?")")
        // The same turn told by a second source (hooks and files both saw it) is said once; a new
        // turn reported by the same source is news again.
        // (A file Codex rewrote can show the very same turn again: same moment, skipped too.)
        if let last = announced[id], (last.source != source && abs(date.timeIntervalSince(last.at)) < 120)
            || abs(date.timeIntervalSince(last.at)) < 2 {
            Self.trace("  skip: already announced by \(last.source.rawValue)"); return
        }
        // Short turns are not news; a turn of unknown length is announced.
        if let length, length < Settings.finishedMinSeconds { announced[id] = (date, source); Self.trace("  skip: short"); return }
        announced[id] = (date, source)
        guard Settings.notifyFinished, !AppModel.shared.demoActive else { Self.trace("  skip: off/demo"); return }
        Self.trace("  announce")
        let name = !title.isEmpty ? title : (session?.title.isEmpty == false ? session!.title : "\(provider.displayName): задача")
        if name == "Guardian review" { return }
        let text = message.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let minutes = length.map { Int(($0 / 60).rounded()) }
        // What the turn cost: its length, tokens and the share of the 5-hour limit it took.
        var limitShare: Double?
        if let session, let used = session.startUsed, let reset = session.startReset,
           let now = AppModel.shared.store(provider).snapshot?.session, abs(now.resetsAt.timeIntervalSince(reset)) < 600 {
            limitShare = max(0, now.usedPercent - used)
        }
        var cost: [String] = []
        if let minutes, minutes > 0 { cost.append("\(minutes) мин") }
        if let tokens, tokens > 0 { cost.append("\(Format.tokens(tokens)) токенов") }
        if let limitShare, limitShare >= 1 { cost.append("≈\(Format.percent(limitShare)) лимита") }
        let summary = cost.joined(separator: " · ")
        var detail = text.isEmpty ? (minutes.map { "Работал \($0) мин." } ?? "Готово.") : String(text.prefix(200))
        if !summary.isEmpty && !text.isEmpty { detail += "\n" + summary }
        TurnLog.shared.add(TurnLog.Turn(provider: provider, title: name, ended: date, seconds: length, tokens: tokens,
                                        limitShare: limitShare, thread: Self.thread(opener)))
        DailyLog.shared.countFinished(provider, at: date)
        EventLog.shared.add(CooldownEvent(kind: .finished, provider: provider, title: "\(provider.displayName) закончил «\(name)»",
                                          body: detail, threadId: Self.thread(opener)))
        guard !QuietHours.active else { return }
        Notifier.shared.post(id: "finished-\(id)-\(Int(date.timeIntervalSince1970))",
                             title: "\(provider.displayName) закончил «\(name)»", body: detail,
                             toast: ToastContent(key: "finished-\(id)", kind: .finished, provider: provider,
                                                 title: "\(provider.displayName) закончил «\(name)»", body: detail,
                                                 actions: [Self.action(opener, provider)], life: .auto(12),
                                                 threadId: Self.thread(opener)),
                             record: false)
    }

    /// A turn that ended with an error (Claude Code says so through its hook).
    func failed(_ provider: ProviderID, key: String, title: String, reason: String, opener: Opener) {
        let id = "\(provider.rawValue):\(key)"
        let session = sessions.removeValue(forKey: id)
        changed()
        Self.trace("failed \(provider.rawValue) \(key) \(reason)")
        guard Settings.notifyFinished, !AppModel.shared.demoActive else { return }
        let name = !title.isEmpty ? title : (session?.title ?? provider.displayName)
        let body = reason.isEmpty ? "Ход прервался ошибкой — загляните в сессию." : String(reason.prefix(200))
        EventLog.shared.add(CooldownEvent(kind: .failure, provider: provider, title: "\(provider.displayName) остановился с ошибкой: «\(name)»", body: body))
        Notifier.shared.post(id: "failed-\(id)-\(Int(Date().timeIntervalSince1970))",
                             title: "\(provider.displayName) остановился с ошибкой", body: "«\(name)»: \(body)",
                             toast: ToastContent(key: "failed-\(id)", kind: .warning, provider: provider,
                                                 title: "\(provider.displayName) остановился с ошибкой", body: "«\(name)»: \(body)",
                                                 actions: [Self.action(opener, provider)], life: .auto(20)),
                             record: false)
    }

    /// Interrupted, closed or gone: no card, just no longer busy.
    func ended(_ provider: ProviderID, key: String) {
        if sessions["\(provider.rawValue):\(key)"] != nil { Self.trace("end \(provider.rawValue) \(key)") }
        if sessions.removeValue(forKey: "\(provider.rawValue):\(key)") != nil { changed() }
    }

    /// Sessions a source can see directly (Claude's window) are replaced as a whole on each look.
    func replace(_ provider: ProviderID, source: Source, with keys: Set<String>) {
        let before = sessions.count
        for session in sessions.values where session.provider == provider && session.source == source && !keys.contains(session.key) {
            Self.trace("gone \(provider.rawValue) \(session.key)")
        }
        sessions = sessions.filter { $0.value.provider != provider || $0.value.source != source || keys.contains($0.value.key) }
        if sessions.count != before { changed() }
    }

    private func dropStale() {
        let now = Date()
        let before = sessions
        // Hooks and files tell when a turn ends; if that word never came (crash, closed app),
        // forget the session after a long silence instead of showing it busy forever.
        // Codex reports progress all the time; a long silence while it is said to be working is
        // worth a look (stuck, or waiting for something it did not say).
        for (id, session) in sessions where session.provider == .codex && session.state == .working && !session.silenceSaid
            && now.timeIntervalSince(lastSign(id, session)) > 15 * 60 && Settings.notifyAttention {
            sessions[id]?.silenceSaid = true
            let name = session.title.isEmpty ? "задача" : session.title
            Notifier.shared.post(id: "silence-\(id)-\(Int(now.timeIntervalSince1970))", title: "Codex молчит 15 минут: «\(name)»",
                                 body: "Работа не закончена, но новых шагов нет. Возможно, стоит заглянуть.",
                                 toast: ToastContent(key: "silence-\(id)", kind: .attention, provider: .codex,
                                                     title: "Codex молчит 15 минут",
                                                     body: "«\(name)»: работа не закончена, но новых шагов нет. Возможно, стоит заглянуть.",
                                                     actions: [.openCodexThread(session.key)], life: .auto(20), threadId: session.key))
        }
        sessions = sessions.filter { now.timeIntervalSince(lastSign($0.key, $0.value)) < ($0.value.provider == .codex ? 45 : 20) * 60 }
        pulse = pulse.filter { sessions[$0.key] != nil }
        // A question nobody reports as answered: after ten minutes it is shown as work again.
        for (id, session) in sessions where session.state == .waiting && now.timeIntervalSince(session.updated) > 600 {
            sessions[id]?.state = .working
            sessions[id]?.reason = nil
        }
        announced = announced.filter { now.timeIntervalSince($0.value.at) < 600 }
        if sessions != before { changed() }
    }

    private func changed() {
        AppModel.shared.activityChanged()
        // A plain record of what is busy now, for checking Cooldown from outside.
        let rows = sessions.values.map { ["agent": $0.provider.rawValue, "key": $0.key, "title": $0.title,
                                          "state": $0.state == .working ? "working" : "waiting", "source": $0.source.rawValue,
                                          "since": ISO8601DateFormatter().string(from: $0.started)] }
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]) {
            try? data.write(to: Settings.appSupport.appendingPathComponent("activity-now.json"), options: .atomic)
        }
    }

    private static func action(_ opener: Opener, _ provider: ProviderID) -> ToastAction {
        switch opener {
        case .codexThread(let id): return .openCodexThread(id)
        case .claudeChat(let chat): return .openClaudeChat(chat)
        case .claudeApp: return .openClaude
        case .none: return provider == .codex ? .openCodex : .openPanel
        }
    }

    private static func thread(_ opener: Opener) -> String? {
        if case .codexThread(let id) = opener { return id }
        return nil
    }
}
