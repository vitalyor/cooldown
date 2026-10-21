import AppKit
import WebKit

/// Claude Desktop keeps chats and Cowork on the server, so its plan limits and activity live in the
/// claude.ai account. Cooldown signs in to claude.ai in its own web view (the person types their
/// credentials into claude.ai itself) and then only reads: the same usage the Settings → Usage page
/// shows, and the list of conversations for activity statistics. It never writes to chats.
@MainActor
final class ClaudeWeb: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = ClaudeWeb()

    enum State: Equatable {
        case disconnected
        case connecting
        case connected(plan: String?)
        case signedOut
    }

    @Published private(set) var state: State
    @Published private(set) var activity: ClaudeActivity?
    @Published private(set) var loginMessage: String?

    private static let connectedKey = "claudeWebConnected"
    private static let orgKey = "claudeWebOrganization"
    private static let planKey = "claudeWebPlan"

    private var worker: WKWebView?
    private var workerReady = false
    private var readyWaiters: [CheckedContinuation<Bool, Never>] = []
    private var loginWindow: NSWindow?
    private var loginTimer: Timer?
    private var lastActivityLoad: Date?

    override init() {
        let defaults = UserDefaults.standard
        state = defaults.bool(forKey: Self.connectedKey) ? .connected(plan: defaults.string(forKey: Self.planKey)) : .disconnected
        super.init()
        activity = ClaudeActivity.load()
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    private var organization: String? { UserDefaults.standard.string(forKey: Self.orgKey) }

    // MARK: Reading

    private var cached: LimitSnapshot?

    /// claude.ai is asked at most every two minutes, whatever the refresh interval.
    func usage() async throws -> LimitSnapshot {
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < 110 { return cached }
        guard let organization else { throw ClaudeWebError.notConnected }
        let object = try await json("/api/organizations/\(organization)/usage")
        guard let usage = object as? [String: Any] else { throw ClaudeWebError.unexpected(Self.describe(object)) }
        guard var snapshot = ClaudeLimits.parseUsage(usage, source: "аккаунт claude.ai") else {
            throw ClaudeWebError.unexpected(Self.describe(usage))
        }
        snapshot.plan = UserDefaults.standard.string(forKey: Self.planKey)
        cached = snapshot
        if case .signedOut = state { state = .connected(plan: snapshot.plan) }
        if lastActivityLoad.map({ Date().timeIntervalSince($0) > 15 * 60 }) ?? true {
            Task { await refreshActivity() }
        }
        return snapshot
    }

    func refreshActivity() async {
        lastActivityLoad = Date()
        do {
            let (conversations, names) = try await conversationList()
            let fresh = ClaudeActivity(conversations: conversations, projectNames: names)
            activity = fresh
            fresh.save()
        } catch {
            // Activity is a nice-to-have; limits keep working without it.
        }
    }

    private var listCache: (at: Date, conversations: [[String: Any]], projects: [String: String])?

    /// The account's conversations and project names; read at most every five minutes.
    private func conversationList() async throws -> ([[String: Any]], [String: String]) {
        if let listCache, Date().timeIntervalSince(listCache.at) < 300 { return (listCache.conversations, listCache.projects) }
        guard let organization else { throw ClaudeWebError.notConnected }
        let conversations = try await json("/api/organizations/\(organization)/chat_conversations") as? [[String: Any]] ?? []
        let projects = (try? await json("/api/organizations/\(organization)/projects")) as? [[String: Any]] ?? []
        let names = Dictionary(projects.compactMap { project -> (String, String)? in
            guard let id = project["uuid"] as? String, let name = project["name"] as? String else { return nil }
            return (id, name)
        }, uniquingKeysWith: { first, _ in first })
        listCache = (Date(), conversations, names)
        return (conversations, names)
    }

    /// When the account's most recent chats last changed, read fresh (no cache), for telling
    /// that an answer written in a chat nobody has open has come to an end.
    func recentUpdates() async throws -> [String: Date] {
        guard let organization else { throw ClaudeWebError.notConnected }
        let list = try await json("/api/organizations/\(organization)/chat_conversations?limit=30") as? [[String: Any]] ?? []
        var result: [String: Date] = [:]
        for item in list {
            if let id = (item["uuid"] as? String)?.lowercased(), let date = Num.date(item["updated_at"]) { result[id] = date }
        }
        return result
    }

    /// Every chat of the account, newest first, for the "continue after reset" picker.
    func conversations() async throws -> [ClaudeChatList.Known] {
        let (conversations, names) = try await conversationList()
        return conversations.compactMap { item -> ClaudeChatList.Known? in
            guard let id = item["uuid"] as? String, !id.isEmpty else { return nil }
            let name = (item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Без названия"
            let updated = Num.date(item["updated_at"])
            let project = (item["project_uuid"] as? String).flatMap { names[$0] }
            return ClaudeChatList.Known(chat: ClaudeChat(id: id.lowercased(), title: name, seen: updated ?? Date()),
                                        project: project, updated: updated)
        }
        .sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
    }

    /// GET a claude.ai API path from inside a claude.ai page, so the request is an ordinary
    /// same-origin request of a signed-in browser.
    private func json(_ path: String) async throws -> Any {
        guard await ensureWorker() else { throw ClaudeWebError.offline }
        guard let worker else { throw ClaudeWebError.offline }
        let script = """
        const response = await fetch(path, { credentials: 'include', headers: { 'Accept': 'application/json' } });
        return [response.status, await response.text()];
        """
        let result = try await worker.callAsyncJavaScript(script, arguments: ["path": path], in: nil, contentWorld: .defaultClient)
        guard let pair = result as? [Any], pair.count == 2, let status = Num.int(pair[0]), let body = pair[1] as? String else {
            throw ClaudeWebError.unexpected("нет ответа")
        }
        if status == 401 || status == 403 {
            if body.contains("challenge") || body.contains("cf-") {
                workerReady = false
                throw ClaudeWebError.offline
            }
            state = .signedOut
            throw ClaudeWebError.signedOut
        }
        guard status == 200 else { throw ClaudeWebError.http(status) }
        guard let data = body.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else {
            throw ClaudeWebError.unexpected("ответ не JSON")
        }
        return object
    }

    private func ensureWorker() async -> Bool {
        if workerReady, worker != nil { return true }
        if worker == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            view.navigationDelegate = self
            view.customUserAgent = Self.userAgent
            worker = view
        }
        workerReady = false
        worker?.load(URLRequest(url: URL(string: "https://claude.ai/robots.txt")!))
        return await withCheckedContinuation { continuation in
            readyWaiters.append(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.finishWaiting(false) }
        }
    }

    private func finishWaiting(_ ready: Bool) {
        workerReady = ready
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0.resume(returning: ready) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            if webView === self.worker { self.finishWaiting(true) }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            if webView === self.worker { self.finishWaiting(false) }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            if webView === self.worker { self.finishWaiting(false) }
        }
    }

    // MARK: Signing in

    /// Opens claude.ai's own sign-in page in a window. Cooldown watches for the moment the account
    /// answers, then closes the window. Nothing the person types passes through Cooldown's code.
    func showLogin() {
        if let loginWindow {
            loginWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        state = .connecting
        loginMessage = nil
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 700), configuration: configuration)
        view.customUserAgent = Self.userAgent
        view.load(URLRequest(url: URL(string: "https://claude.ai/login")!))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Вход в claude.ai для Cooldown"
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = LoginWindowDelegate.shared
        loginWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)

        loginTimer?.invalidate()
        loginTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in await ClaudeWeb.shared.checkLogin() }
        }
    }

    fileprivate func loginWindowClosed() {
        loginTimer?.invalidate()
        loginTimer = nil
        loginWindow = nil
        if case .connecting = state {
            state = UserDefaults.standard.bool(forKey: Self.connectedKey) ? .connected(plan: UserDefaults.standard.string(forKey: Self.planKey)) : .disconnected
        }
    }

    private func checkLogin() async {
        guard loginWindow != nil else { return }
        guard let organizations = try? await json("/api/organizations") as? [[String: Any]], !organizations.isEmpty else { return }
        let chosen = organizations.first { organization in
            let capabilities = organization["capabilities"] as? [String] ?? []
            return capabilities.contains("chat") && capabilities.contains { $0.hasPrefix("claude_") }
        } ?? organizations.first { ($0["capabilities"] as? [String] ?? []).contains("chat") } ?? organizations[0]
        guard let id = chosen["uuid"] as? String else { return }
        let plan = Self.planName(chosen)
        let defaults = UserDefaults.standard
        defaults.set(id, forKey: Self.orgKey)
        defaults.set(plan, forKey: Self.planKey)
        defaults.set(true, forKey: Self.connectedKey)
        state = .connected(plan: plan)
        loginTimer?.invalidate()
        loginTimer = nil
        loginWindow?.close()
        loginWindow = nil
        await AppModel.shared.refreshLimits()
        await refreshActivity()
    }

    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                               for: records.filter { $0.displayName.contains("claude.ai") || $0.displayName.contains("anthropic") })
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.orgKey)
        defaults.removeObject(forKey: Self.planKey)
        defaults.set(false, forKey: Self.connectedKey)
        worker = nil
        workerReady = false
        cached = nil
        activity = nil
        ClaudeActivity.remove()
        state = .disconnected
    }

    private static func planName(_ organization: [String: Any]) -> String? {
        let tier = (organization["rate_limit_tier"] as? String ?? "").lowercased()
        let capabilities = organization["capabilities"] as? [String] ?? []
        if tier.contains("max") || capabilities.contains("claude_max") {
            if tier.contains("20x") { return "Max 20x" }
            if tier.contains("5x") { return "Max 5x" }
            return "Max"
        }
        if capabilities.contains("claude_pro") || tier.contains("pro") { return "Pro" }
        if tier.contains("team") || capabilities.contains("raven") { return "Team" }
        return nil
    }

    static func describe(_ object: Any) -> String {
        if let dict = object as? [String: Any] { return "поля: " + dict.keys.sorted().joined(separator: ", ") }
        return "тип \(type(of: object))"
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
}

private final class LoginWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = LoginWindowDelegate()

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in ClaudeWeb.shared.loginWindowClosed() }
    }
}

enum ClaudeWebError: LocalizedError {
    case notConnected
    case signedOut
    case offline
    case http(Int)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Аккаунт claude.ai не подключён."
        case .signedOut: return "Вход в claude.ai истёк. Войдите снова в настройках Cooldown."
        case .offline: return "claude.ai сейчас не отвечает. Проверю позже."
        case .http(let code): return "claude.ai ответил с кодом \(code)."
        case .unexpected(let detail): return "claude.ai прислал лимиты в незнакомом виде (\(detail))."
        }
    }
}

/// What the person did in Claude Desktop and claude.ai: when each conversation was last active, its
/// model and project. Built from the conversation list, without reading any message.
struct ClaudeActivity: Codable, Equatable {
    struct Item: Codable, Equatable {
        var date: Date
        var model: String
        var project: String
    }

    struct Day: Identifiable, Equatable {
        var date: Date
        var conversations: Int
        var id: Date { date }
    }

    var updated: Date
    var items: [Item]

    init(conversations: [[String: Any]], projectNames: [String: String]) {
        let since = Date().addingTimeInterval(-45 * 86400)
        items = conversations.compactMap { conversation in
            guard let date = Num.date(conversation["updated_at"]) ?? Num.date(conversation["created_at"]), date >= since else { return nil }
            let model = (conversation["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Модель не указана"
            let project = (conversation["project_uuid"] as? String).flatMap { projectNames[$0] }
                ?? ((conversation["project"] as? [String: Any])?["name"] as? String)
                ?? "Без проекта"
            return Item(date: date, model: model, project: project)
        }
        updated = Date()
    }

    func inRange(_ range: StatsRange, now: Date = Date()) -> [Item] {
        let from = now.addingTimeInterval(-range.interval)
        return items.filter { $0.date >= from && $0.date <= now }
    }

    func days(_ range: StatsRange, now: Date = Date()) -> [Day] {
        let calendar = Calendar.current
        var perSlot: [Date: Int] = [:]
        for item in inRange(range, now: now) {
            let slot = range == .day ? hourStart(item.date) : calendar.startOfDay(for: item.date)
            perSlot[slot, default: 0] += 1
        }
        return perSlot.map { Day(date: $0.key, conversations: $0.value) }.sorted { $0.date < $1.date }
    }

    func shares(_ range: StatsRange, by key: (Item) -> String) -> [ShareRow] {
        var counts: [String: Int] = [:]
        for item in inRange(range) { counts[key(item), default: 0] += 1 }
        let sorted = counts.sorted { $0.value > $1.value }
        guard let largest = sorted.first?.value else { return [] }
        let total = Double(max(1, sorted.reduce(0) { $0 + $1.value }))
        return sorted.prefix(6).map {
            ShareRow(id: $0.key, name: $0.key, total: $0.value, share: Double($0.value) / Double(largest), percent: Double($0.value) / total * 100)
        }
    }

    private static var url: URL { Settings.appSupport.appendingPathComponent("claude-activity.json") }

    static func load() -> ClaudeActivity? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(ClaudeActivity.self, from: data)
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }

    static func remove() { try? FileManager.default.removeItem(at: url) }
}
