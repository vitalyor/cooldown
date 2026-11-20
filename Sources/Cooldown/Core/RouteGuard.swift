import AppKit
import Darwin
import Network

// MARK: VPN guard
//
// AI services ban accounts used from countries they do not serve, and a VPN drops now and then
// (sleep, a new Wi-Fi, a router switching servers). The guard asks each service itself which
// country a request reaches it from: `https://<host>/cdn-cgi/trace` is answered by Cloudflare in
// front of Anthropic and OpenAI, along the very route the agent's own requests take, whether the
// VPN runs on this Mac, on the router, or only for some sites. No server of Cooldown's own is
// involved, and the request carries no account (no cookies, no token).
//
// Two routes may differ. Apps (Claude Desktop, ChatGPT) follow the system proxy; command-line
// agents (Claude Code, Codex in a terminal, and Cooldown's own calls) go direct unless their
// environment names a proxy. With a system proxy set, both are checked and judged apart.
//
// While a route is wrong: the hooks in Claude Code and Codex hold prompts and stop work between
// steps, Cooldown makes no request of its own to that service, the agents' apps can be frozen
// (paused by the system, nothing lost) and one card says what happened. Off by default.

enum GuardService: String, CaseIterable {
    case anthropic, openai

    /// The host the agent itself talks to: its route is the one that counts.
    var host: String { self == .anthropic ? "api.anthropic.com" : "chatgpt.com" }
    var provider: ProviderID { self == .anthropic ? .claude : .codex }
    var name: String { provider.displayName }
    /// Apps frozen while this route is wrong (ChatGPT for Mac carries the Codex bundle id).
    var apps: [String] { self == .anthropic ? ["com.anthropic.claudefordesktop"] : ["com.openai.codex", "com.openai.chat"] }

    static func of(_ provider: ProviderID) -> GuardService? {
        switch provider {
        case .claude: return .anthropic
        case .codex: return .openai
        case .antigravity: return nil
        }
    }

    /// The services of the agents the person uses (hidden ones are neither checked nor frozen).
    @MainActor static var watched: [GuardService] { allCases.filter { ProviderID.shown.contains($0.provider) } }
}

/// Where requests leave for a service, as the service sees them.
struct RouteExit: Codable, Equatable {
    var ip: String
    var country: String
    var colo: String

    /// `ip=…`, `loc=…`, `colo=…` lines of a Cloudflare trace.
    static func parse(_ text: String) -> RouteExit? {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0]] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        guard let ip = fields["ip"], !ip.isEmpty, let country = fields["loc"], country.count == 2 else { return nil }
        return RouteExit(ip: ip, country: country.uppercased(), colo: fields["colo"] ?? "")
    }

    var countryName: String { Locale.current.localizedString(forRegionCode: country) ?? country }
}

/// One check of a service: the direct route, and the system proxy's when one is set.
struct RouteTrace: Equatable {
    var direct: RouteExit?
    var viaProxy: RouteExit?
    var proxied = false
}

enum RouteVerdict: String {
    case ok
    /// The service sees a country it does not serve.
    case forbidden
    /// An address the person said no to.
    case refused
    /// No answer: the route could not be checked.
    case unchecked

    static func judge(_ exit: RouteExit?, forbidden: Set<String>, refused: Set<String>) -> RouteVerdict {
        guard let exit else { return .unchecked }
        if forbidden.contains(exit.country) { return .forbidden }
        if refused.contains(exit.ip) { return .refused }
        return .ok
    }
}

struct RouteReading {
    /// Command-line agents and Cooldown's own calls (the direct route).
    var verdict: RouteVerdict
    var exit: RouteExit?
    /// The apps (through the system proxy, if one is set; otherwise the same as above).
    var appVerdict: RouteVerdict
    var appExit: RouteExit?
    var at: Date
    /// A system proxy carries the apps: a wrong direct route alone then stops only command-line agents.
    var proxied = false
    /// Unchecked this many times in a row: one lost answer holds requests but does not yet
    /// freeze apps or raise a card.
    var misses = 0
}

/// The last readings, for code that runs off the main thread (Cooldown's own senders).
final class RouteState: @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [GuardService: RouteReading] = [:]

    func set(_ service: GuardService, _ reading: RouteReading?) {
        lock.lock(); readings[service] = reading; lock.unlock()
    }

    func get(_ service: GuardService) -> RouteReading? {
        lock.lock(); defer { lock.unlock() }
        return readings[service]
    }
}

@MainActor
final class RouteGuard: ObservableObject {
    static let shared = RouteGuard()
    nonisolated static let state = RouteState()
    /// A reading older than this no longer lets anything through.
    nonisolated static let freshFor: TimeInterval = 120

    @Published private(set) var readings: [GuardService: RouteReading] = [:]
    @Published private(set) var checking = false
    /// New exits waiting for "allow" or "block", one per service and address.
    @Published private(set) var pending: [String: (service: GuardService, exit: RouteExit)] = [:]
    /// Command-line agents held while the apps work through a proxy: said once, quietly.
    private var cliNoted = false

    private var monitor: NWPathMonitor?
    private var launchObserver: NSObjectProtocol?
    private var quitObserver: NSObjectProtocol?
    private var activity: NSObjectProtocol?
    private var online = true
    private var timer: Timer?
    private var failures = 0
    /// Bumped by every network change and by turning the guard off: a round that started before
    /// is out of date, its results are dropped, and a new round follows.
    private var generation = 0
    private var rerun = false
    private var episode: Date?
    private var announced = false
    private var lastCard = ""
    private var allowedNow: Set<String> = []
    private var lastGood: [GuardService: RouteExit] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    static var dir: URL { Settings.appSupport.appendingPathComponent("guard", isDirectory: true) }

    // `--guard-test` swaps these: made-up answers, no cards or phone, no hooks in the real agents.
    nonisolated(unsafe) static var tracer: (GuardService) async -> RouteTrace = { await RouteGuard.trace($0.host) }
    nonisolated(unsafe) static var quiet = false
    nonisolated(unsafe) static var installsHooks = true
    private(set) var shown: [String: ToastContent] = [:]

    private func present(_ content: ToastContent, notify: Bool) {
        shown[content.key] = content
        guard !Self.quiet else { return }
        if notify {
            Notifier.shared.post(id: "\(content.key)-\(Int(Date().timeIntervalSince1970))", title: content.title, body: content.body, toast: content)
        } else {
            ToastController.shared.show(content)
        }
    }

    private func dismiss(_ key: String) {
        shown.removeValue(forKey: key)
        guard !Self.quiet else { return }
        ToastController.shared.dismiss(key: key)
    }

    private func redrawMenu() {
        guard !Self.quiet else { return }
        AppModel.shared.updateMenuImage(animated: false)
    }

    // MARK: Asking (any thread)

    private nonisolated static func live(_ now: Date) -> Bool { Settings.guardEnabled && !Settings.guardPaused(now) }

    /// Whether Cooldown and the agents may reach `provider` now: both routes right and fresh.
    nonisolated static func allows(_ provider: ProviderID, now: Date = Date()) -> Bool {
        guard live(now) else { return true }
        guard let service = GuardService.of(provider) else { return antigravityAllowed(now) }
        guard let reading = state.get(service), now.timeIntervalSince(reading.at) < freshFor else { return false }
        return reading.verdict == .ok && reading.appVerdict == .ok
    }

    /// Antigravity's servers tell nothing of the route: it waits while every checked route is
    /// wrong, which means the VPN as a whole is down.
    private nonisolated static func antigravityAllowed(_ now: Date) -> Bool {
        let all = GuardService.allCases.compactMap { state.get($0) }.filter { now.timeIntervalSince($0.at) < freshFor }
        return all.isEmpty || all.contains { $0.verdict == .ok || $0.appVerdict == .ok }
    }

    /// Apps fine through a proxy, the direct route wrong.
    private func cliOnly(_ service: GuardService) -> Bool {
        guard Self.live(Date()), let reading = readings[service], reading.proxied, reading.appVerdict == .ok else { return false }
        return reading.verdict == .forbidden || reading.verdict == .refused
    }

    /// Whether the apps of `service` must be frozen: a finished check said so (not a guess
    /// after a network change, and not one lost answer).
    private func appsStopped(_ service: GuardService) -> Bool {
        guard Self.live(Date()), let reading = readings[service] else { return false }
        switch reading.appVerdict {
        case .ok: return false
        case .forbidden, .refused: return true
        case .unchecked: return reading.misses >= 2
        }
    }

    /// Whether a card must say the agents of `service` are held.
    private func stopped(_ service: GuardService) -> Bool {
        guard Self.live(Date()), let reading = readings[service] else { return false }
        if appsStopped(service) { return true }
        // Through a proxy the apps are fine: a wrong direct route holds only command-line agents
        // without a proxy of their own, which a quiet note says (see cliOnly).
        if reading.proxied && reading.appVerdict == .ok { return false }
        switch reading.verdict {
        case .ok: return false
        case .forbidden, .refused: return true
        case .unchecked: return reading.misses >= 2
        }
    }

    struct Blocked: LocalizedError {
        let provider: ProviderID
        var errorDescription: String? {
            L("Пауза: маршрут к %@ сейчас идёт мимо VPN или не проверен. Cooldown не обращается к нему, пока всё не придёт в норму.", provider.displayName)
        }
    }

    nonisolated static func check(_ provider: ProviderID) throws {
        if !allows(provider) { throw Blocked(provider: provider) }
    }

    /// Before Cooldown's own request: right after launch (or a network change) the check may
    /// still be running; it is waited for, up to a few seconds.
    nonisolated static func gate(_ provider: ProviderID) async throws {
        if live(Date()), !allows(provider), await shared.awaitingCheck(provider) { await shared.nextReading() }
        try check(provider)
    }

    /// No answer yet for a watched service (just launched, or the network just changed): worth
    /// waiting for. A fresh "wrong route" is not: no new check is started for it.
    private func awaitingCheck(_ provider: ProviderID) -> Bool {
        guard let service = GuardService.of(provider), GuardService.watched.contains(service) else { return false }
        guard let reading = readings[service] else { return true }
        return reading.at == .distantPast
    }

    // MARK: Running

    func start() {
        Freezer.recover()
        if quitObserver == nil {
            quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Freezer.shared.thawAll() }
            }
        }
        apply()
    }

    /// The switch in Settings: hooks in the agents that are installed, then the checks.
    /// Returns what went wrong, if anything.
    static func setEnabled(_ on: Bool) -> String? {
        Settings.set(on, forKey: SettingsKey.guardEnabled)
        var problems: [String] = []
        for agent in AgentHooks.Agent.allCases {
            do {
                if on {
                    if present(agent), AgentHooks.guardStatus(agent) == .off { try AgentHooks.installGuard(agent) }
                } else {
                    try AgentHooks.uninstallGuard(agent)
                }
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        shared.apply()
        return problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    private static func present(_ agent: AgentHooks.Agent) -> Bool {
        agent == .claude ? ClaudePaths.binary(override: Settings.claudePath) != nil : CodexPaths.binary(override: Settings.codexPath) != nil
    }

    /// `claude --version`: "2.1.303 (Claude Code)" → "2.1.303". Local, no request.
    nonisolated static func claudeVersion() async -> String? {
        guard let binary = ClaudePaths.binary(override: Settings.claudePath) else { return nil }
        return await Task.detached {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["--version"]
            process.environment = ProcessInfo.processInfo.environment.merging(["CLAUDE_CODE_ENABLE_CFC": "false"]) { $1 }
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            process.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return text.split(separator: " ").first.map(String.init)
        }.value
    }

    /// Turned on or off in Settings, paused or resumed.
    func apply() {
        if Settings.guardEnabled { begin() } else { end() }
    }

    private func begin() {
        // An agent installed after the guard was turned on gets its hook too.
        for agent in AgentHooks.Agent.allCases where Self.installsHooks && Self.present(agent) && AgentHooks.guardStatus(agent) == .off {
            try? AgentHooks.installGuard(agent)
        }
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        writeHookFiles()
        try? AgentHooks.writeGuardScript()
        if monitor == nil, !Self.quiet {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                let online = path.status == .satisfied
                Task { @MainActor in RouteGuard.shared.pathChanged(online) }
            }
            monitor.start(queue: .global(qos: .utility))
            self.monitor = monitor
        }
        if launchObserver == nil {
            // An agent's app opened while its route is wrong: frozen before it gets going.
            launchObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RouteGuard.shared.enforce() }
            }
        }
        // A menu bar app is napped by macOS when nothing of it is on screen; its timers would
        // drift and the readings would age. Not while the guard works.
        if activity == nil, !Self.quiet {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "VPN guard")
        }
        Task { await round() }
    }

    private func end() {
        generation += 1
        monitor?.cancel()
        monitor = nil
        timer?.invalidate()
        timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        Freezer.shared.thawAll()
        try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent("on"))
        dismiss("route-guard")
        dismiss("route-exit")
        episode = nil
        announced = false
        lastCard = ""
        failures = 0
        rerun = false
        pending = [:]
        cliNoted = false
        forgetReadings()
        releaseWaiters()
        redrawMenu()
    }

    func pathChanged(_ online: Bool) {
        let wasOnline = self.online
        self.online = online
        guard Self.live(Date()), online || wasOnline else { return }
        // A new network, a VPN up or down, waking from sleep: until checked again, the old
        // readings let nothing through (requests and hooks wait), but freeze nothing either.
        generation += 1
        for (service, var reading) in readings {
            reading.at = .distantPast
            readings[service] = reading
            Self.state.set(service, reading)
            writeState(service, reading)
        }
        if checking {
            rerun = true
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Task { await RouteGuard.shared.round() } }
        }
    }

    /// `--guard-test` only: as if the person had closed a card.
    func dismissForTest(_ key: String) { dismiss(key) }

    /// `--guard-test` only: as if Cooldown had just started.
    func forgetReadings() {
        readings = [:]
        for service in GuardService.allCases { Self.state.set(service, nil) }
    }

    /// Waits for the next round to finish (at most a few seconds).
    private func nextReading() async {
        if !checking { Task { await round() } }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// One check of every watched service at once; each result counts as soon as it comes.
    func round() async {
        guard Settings.guardEnabled, !checking else {
            if !checking { releaseWaiters() }
            return
        }
        if Settings.guardPaused(Date()) {
            // Paused: nothing is checked; the timer wakes when the pause ends.
            releaseWaiters()
            scheduleNext(allGood: true)
            return
        }
        checking = true
        timer?.invalidate()
        writeHookFiles()
        repeat {
            rerun = false
            let started = generation
            let services = GuardService.watched
            await withTaskGroup(of: (GuardService, RouteTrace).self) { group in
                for service in services {
                    group.addTask { (service, await Self.tracer(service)) }
                }
                for await (service, trace) in group where started == generation && Self.live(Date()) {
                    record(service, trace)
                }
            }
        } while rerun && Self.live(Date())
        checking = false
        // Paced by what must be caught quickly: the apps' route, and the direct one unless a proxy
        // carries the apps (a terminal going direct through Clash is not a reason to slow down).
        let all = GuardService.watched.allSatisfy { service in
            guard let reading = readings[service], reading.appVerdict == .ok else { return false }
            return reading.proxied || reading.verdict == .ok
        }
        failures = all ? 0 : failures + 1
        announce()
        releaseWaiters()
        scheduleNext(allGood: all)
    }

    private func releaseWaiters() {
        waiters.forEach { $0.resume() }
        waiters = []
    }

    private func scheduleNext(allGood: Bool) {
        timer?.invalidate()
        guard Settings.guardEnabled else { return }
        // Every 5 s while an agent works or its app is in front (a VPN on the router drops without
        // the Mac noticing), 15 s otherwise; with a growing pause while something is wrong, so a
        // broken route does not keep knocking on the service from the real address.
        let base: TimeInterval = allGood ? (Self.agentsBusy ? 5 : 15) : [5, 15, 30, 60][min(max(failures, 1) - 1, 3)]
        var wait = base * Double.random(in: 0.8...1.2)
        if let until = Settings.guardPausedUntil, until > Date() { wait = max(wait, until.timeIntervalSinceNow + 1) }
        timer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { _ in
            Task { @MainActor in await RouteGuard.shared.round() }
        }
    }

    private static var agentsBusy: Bool {
        if quiet { return false }
        if ProviderID.agents.contains(where: { !AgentActivity.shared.working($0).isEmpty }) { return true }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        return GuardService.allCases.contains { $0.apps.contains(front) }
    }

    // MARK: Checking a route

    /// The direct route over IPv4 and IPv6 (a VPN that carries only one lets the other out), and,
    /// with a system proxy set, the route the apps take through it.
    nonisolated static func trace(_ host: String) async -> RouteTrace {
        async let v4 = traceOnce(host, family: "-4")
        async let v6 = traceOnce(host, family: "-6")
        let proxied = systemProxy
        async let viaProxy: RouteExit? = proxied ? traceThroughSystem(host) : nil
        let direct = worst(await v4, await v6, forbidden: Settings.guardForbidden)
        return RouteTrace(direct: direct, viaProxy: await viaProxy, proxied: proxied)
    }

    /// The exit to judge by: a forbidden one wins, then IPv4 (the usual path), then IPv6.
    /// A family with no connection at all does not count (many networks have no IPv6).
    nonisolated static func worst(_ v4: RouteExit?, _ v6: RouteExit?, forbidden: Set<String>) -> RouteExit? {
        if let v6, forbidden.contains(v6.country) { return v6 }
        if let v4, forbidden.contains(v4.country) { return v4 }
        return v4 ?? v6
    }

    /// A proxy in System Settings (or a PAC file): what Clash, V2Ray and the like set up.
    nonisolated static var systemProxy: Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return false }
        return ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable"].contains { (settings[$0] as? Int) == 1 }
    }

    /// `curl`, the same as the hooks use: no cookies, no account, nothing but the request line
    /// and curl's own headers. It does not follow the system proxy: the direct route.
    nonisolated private static func traceOnce(_ host: String, family: String) async -> RouteExit? {
        await Task.detached(priority: .utility) { () -> RouteExit? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = ["-s", family, "-m", "3", "--proto", "=https", "https://\(host)/cdn-cgi/trace"]
            process.environment = ["PATH": "/usr/bin:/bin"] // no proxy from Cooldown's own environment
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return RouteExit.parse(String(decoding: data, as: UTF8.self))
        }.value
    }

    /// The apps' route: URLSession follows the system proxy and PAC as Chromium and WebKit do.
    /// A new session each time: no connection is reused across a network change, and the request
    /// names no app (the same headers as the curl checks).
    nonisolated private static func traceThroughSystem(_ host: String) async -> RouteExit? {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 4
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": "curl/8.7.1", "Accept": "*/*"]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "https://\(host)/cdn-cgi/trace"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return RouteExit.parse(String(decoding: data, as: UTF8.self))
    }

    private func record(_ service: GuardService, _ trace: RouteTrace) {
        let forbidden = Settings.guardForbidden
        let refused = Set(Settings.guardRefused)
        let verdict = RouteVerdict.judge(trace.direct, forbidden: forbidden, refused: refused)
        let appExit = trace.proxied ? trace.viaProxy : trace.direct
        let appVerdict = trace.proxied ? RouteVerdict.judge(trace.viaProxy, forbidden: forbidden, refused: refused) : verdict
        let lost = verdict == .unchecked || appVerdict == .unchecked
        let misses = lost ? (readings[service]?.misses ?? 0) + 1 : 0
        let reading = RouteReading(verdict: verdict, exit: trace.direct, appVerdict: appVerdict, appExit: appExit, at: Date(),
                                   proxied: trace.proxied, misses: misses)
        readings[service] = reading
        Self.state.set(service, reading)
        writeState(service, reading)
        for exit in [trace.direct, appExit].compactMap({ $0 }) where RouteVerdict.judge(exit, forbidden: forbidden, refused: refused) == .ok {
            noteExit(service, exit)
        }
        enforce()
    }

    // MARK: Exits

    /// A known exit passes quietly; the first one ever is learned; a new one in an allowed
    /// country keeps working and asks on a card.
    private func noteExit(_ service: GuardService, _ exit: RouteExit) {
        var known = Settings.guardExits
        var mine = known[service.rawValue] ?? [:]
        if mine.isEmpty {
            mine[exit.ip] = ""
            known[service.rawValue] = mine
            Settings.guardExits = known
        }
        let key = "\(service.rawValue)|\(exit.ip)"
        if mine[exit.ip] != nil || allowedNow.contains(key) {
            lastGood[service] = exit
            if pending.removeValue(forKey: key) != nil { showExitCard(notify: false) }
            return
        }
        // Asked once per address: the same one seen again changes nothing.
        guard pending[key] == nil else { return }
        pending[key] = (service, exit)
        showExitCard(notify: true)
    }

    static func exitName(_ service: GuardService, _ ip: String) -> String? {
        guard let name = Settings.guardExits[service.rawValue]?[ip], !name.isEmpty else { return nil }
        return name
    }

    /// What a card asking about exits is about: an answer applies only to exactly these.
    var pendingKey: String { pending.keys.sorted().joined(separator: ",") }

    private func showExitCard(notify: Bool) {
        let items = pending.values.filter { GuardService.watched.contains($0.service) }
            .sorted { ($0.service.rawValue, $0.exit.ip) < ($1.service.rawValue, $1.exit.ip) }
        guard !items.isEmpty else { dismiss("route-exit"); return }
        let services = GuardService.watched.filter { service in items.contains { $0.service == service } }
        let lines = items.map { item -> String in
            let before = lastGood[item.service].map { Self.exitName(item.service, $0.ip) ?? $0.ip } ?? L("прежний адрес")
            return L("%@: %@ → %@, %@", item.service.name, before, item.exit.ip, item.exit.countryName)
        }
        let key = pendingKey
        let question = Set(items.map(\.exit.ip)).count == 1
            ? L("Работа не остановлена. Разрешить этот адрес?") : L("Работа не остановлена. Разрешить эти адреса?")
        let content = ToastContent(key: "route-exit", kind: .info, provider: services.count == 1 ? services[0].provider : nil,
                                   title: L("Маршрут к %@ сменился", Self.names(services)),
                                   body: lines.joined(separator: "\n") + "\n" + question,
                                   actions: [.guardExit(.remember, key), .guardExit(.once, key), .guardExit(.refuse, key)], life: .sticky)
        present(content, notify: notify)
    }

    /// The answer on an exit card. False when the card is out of date (another address is
    /// waiting now, or none): nothing is changed then.
    @discardableResult
    func answerExit(_ choice: GuardExitChoice, key: String) -> Bool {
        guard !pending.isEmpty, key == pendingKey else {
            // An old card: the one about what waits now comes back (pressing closed it).
            showExitCard(notify: false)
            return false
        }
        var known = Settings.guardExits
        var refused = Settings.guardRefused
        for (service, exit) in pending.values {
            switch choice {
            case .remember:
                known[service.rawValue, default: [:]][exit.ip] = ""
                lastGood[service] = exit
            case .once:
                allowedNow.insert("\(service.rawValue)|\(exit.ip)")
                lastGood[service] = exit
            case .refuse:
                if !refused.contains(exit.ip) { refused.append(exit.ip) }
            }
        }
        Settings.guardExits = known
        Settings.guardRefused = refused
        pending = [:]
        dismiss("route-exit")
        writeHookFiles()
        Task { await round() }
        return true
    }

    func rename(_ service: GuardService, ip: String, to name: String) {
        var known = Settings.guardExits
        known[service.rawValue, default: [:]][ip] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.guardExits = known
        objectWillChange.send()
    }

    func forget(_ service: GuardService, ip: String) {
        var known = Settings.guardExits
        known[service.rawValue]?.removeValue(forKey: ip)
        Settings.guardExits = known
        Settings.guardRefused = Settings.guardRefused.filter { $0 != ip }
        writeHookFiles()
        objectWillChange.send()
    }

    // MARK: What a wrong route does

    /// Services whose agents are held now, among the agents the person uses.
    var blocked: [GuardService] { GuardService.watched.filter(stopped) }

    func enforce() {
        guard Settings.guardEnabled else { return }
        // Offline altogether: nothing can leave anyway, so apps are not frozen for it.
        if Settings.guardFreeze {
            if online {
                let services = GuardService.watched.filter(appsStopped)
                var apps = Set(services.flatMap(\.apps))
                if !GuardService.watched.isEmpty, GuardService.watched.allSatisfy(appsStopped) {
                    apps.formUnion(["com.google.antigravity", "com.google.antigravity-ide"])
                }
                Freezer.shared.set(apps)
            }
        } else {
            Freezer.shared.thawAll()
        }
        updateCard()
        redrawMenu()
    }

    private func updateCard() {
        let quietOnes = GuardService.watched.filter(cliOnly)
        if quietOnes.isEmpty {
            cliNoted = false
        } else if !cliNoted {
            cliNoted = true
            let tools = quietOnes.map { $0.provider == .claude ? "Claude Code" : "Codex" }.joined(separator: L(" и "))
            present(ToastContent(key: "route-cli", kind: .info, provider: quietOnes.count == 1 ? quietOnes[0].provider : nil,
                                 title: L("Приложения работают через прокси"),
                                 body: L("%@ в Терминале без прокси пошёл бы напрямую — его сообщения задерживаются. Задайте HTTPS_PROXY в Терминале, и хук пропустит их.", tools),
                                 actions: [.openSettings(.vpn)], life: .auto(12)), notify: false)
        }
        let blocked = self.blocked
        guard !blocked.isEmpty, online else {
            if episode != nil, online {
                episode = nil
                lastCard = ""
                dismiss("route-guard")
                if announced {
                    present(ToastContent(key: "route-ok", kind: .reset, provider: nil, title: L("VPN снова работает"),
                                         body: L("Маршрут в норме, всё продолжено."), actions: [], life: .auto(8)), notify: true)
                }
                announced = false
            }
            return
        }
        if episode == nil { episode = Date() }
        let content = card(blocked)
        guard content.title + content.body != lastCard else { return }
        lastCard = content.title + content.body
        present(content, notify: false)
    }

    /// Once per episode, when the round is over: the feed and the phone get the whole picture.
    private func announce() {
        guard episode != nil, !announced, online, !blocked.isEmpty else { return }
        announced = true
        present(card(blocked), notify: true)
    }

    private func card(_ blocked: [GuardService]) -> ToastContent {
        let everything = blocked.count == GuardService.watched.count
        func verdict(_ service: GuardService) -> (RouteVerdict, RouteExit?) {
            let reading = readings[service]
            if let reading, reading.appVerdict != .ok, appsStopped(service) { return (reading.appVerdict, reading.appExit) }
            return (reading?.verdict ?? .unchecked, reading?.exit)
        }
        let forbidden = blocked.filter { verdict($0).0 == .forbidden }
        let refused = blocked.filter { verdict($0).0 == .refused }
        let unchecked = blocked.filter { verdict($0).0 == .unchecked }
        var lines: [String] = []
        // Grouped by country: "Claude and Codex see Russia".
        let byCountry = Dictionary(grouping: forbidden) { verdict($0).1?.countryName ?? "?" }
        for (country, services) in byCountry.sorted(by: { $0.key < $1.key }) {
            lines.append(services.count == 1 ? L("%@ видит %@.", Self.names(services), country) : L("%@ видят %@.", Self.names(services), country))
        }
        for service in refused {
            lines.append(L("%@: адрес %@ вы запретили.", service.name, verdict(service).1?.ip ?? "?"))
        }
        if !unchecked.isEmpty { lines.append(L("%@: не удалось проверить маршрут.", Self.names(unchecked))) }
        let frozen = Freezer.shared.frozenNames
        if !frozen.isEmpty { lines.append(L("На паузе: %@.", frozen.joined(separator: ", "))) }
        let tools = blocked.filter { AgentHooks.guardStatus($0.provider == .claude ? .claude : .codex) == .on }
            .map { $0.provider == .claude ? "Claude Code" : "Codex" }
        if tools.count == 1 { lines.append(L("%@ не отправит сообщения, пока маршрут не придёт в норму.", tools[0])) }
        if tools.count > 1 { lines.append(L("%@ не отправят сообщения, пока маршрут не придёт в норму.", tools.joined(separator: L(" и ")))) }
        lines.append(L("Продолжу сам, когда всё наладится."))
        let title: String
        if !forbidden.isEmpty || !refused.isEmpty {
            title = everything ? L("VPN не работает — работа остановлена") : L("Маршрут к %@ идёт мимо VPN", Self.names(forbidden + refused))
        } else {
            title = L("Не удалось проверить маршрут к %@", Self.names(unchecked))
        }
        return ToastContent(key: "route-guard", kind: .warning, provider: blocked.count == 1 ? blocked[0].provider : nil,
                            title: title, body: lines.joined(separator: "\n"),
                            actions: [.guardPause, .openSettings(.vpn)], life: .sticky)
    }

    static func names(_ services: [GuardService]) -> String {
        let names = services.map(\.name)
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + L(" и ") + names.last!
    }

    /// "Turn the guard off for an hour", from the card or Settings; nil turns it back on.
    func pause(_ seconds: TimeInterval?) {
        Settings.guardPausedUntil = seconds.map { Date().addingTimeInterval($0) }
        if seconds != nil {
            // Paused by hand: no "VPN is back" card, nothing came back.
            generation += 1
            announced = false
            episode = nil
            lastCard = ""
            dismiss("route-guard")
        }
        writeHookFiles()
        enforce()
        Task { await round() }
    }

    // MARK: Files the hooks read

    /// `on` (holding this app's path: a deleted Cooldown leaves the hooks inert) while the guard
    /// works, the countries and addresses refused, and the words a hook shows, in the person's language.
    func writeHookFiles() {
        let dir = Self.dir
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let on = dir.appendingPathComponent("on")
        if Self.live(Date()) {
            try? (Bundle.main.bundlePath + "\n").write(to: on, atomically: true, encoding: .utf8)
        } else {
            try? fm.removeItem(at: on)
        }
        try? (Settings.guardForbidden.sorted().joined(separator: " ") + "\n").write(to: dir.appendingPathComponent("forbidden"), atomically: true, encoding: .utf8)
        try? (Settings.guardRefused.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("refused"), atomically: true, encoding: .utf8)
        func clean(_ text: String) -> String {
            text.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: "\n", with: " ")
        }
        for service in GuardService.allCases {
            let block = L("Cooldown: %@ сейчас видит вас не через VPN. Запрос не отправлен — повторите, когда VPN заработает.", service.name)
            let unchecked = L("Cooldown: не удалось проверить маршрут к %@. Запрос не отправлен — проверьте VPN и повторите.", service.name)
            try? clean(block).write(to: dir.appendingPathComponent("msg-\(service.rawValue)-block"), atomically: true, encoding: .utf8)
            try? clean(unchecked).write(to: dir.appendingPathComponent("msg-\(service.rawValue)-unchecked"), atomically: true, encoding: .utf8)
        }
    }

    /// The direct route's verdict: the hooks run where the command-line agents do.
    private func writeState(_ service: GuardService, _ reading: RouteReading) {
        let word = reading.verdict == .ok ? "ok" : reading.verdict == .unchecked ? "unchecked" : "block"
        let at = reading.at == .distantPast ? 0 : Int(reading.at.timeIntervalSince1970)
        try? "\(word) \(at)\n".write(to: Self.dir.appendingPathComponent(service.rawValue), atomically: true, encoding: .utf8)
    }
}

enum GuardExitChoice: String, Equatable {
    case remember, once, refuse
}

// MARK: Freezing apps

/// Pauses an app's processes the way the system does (SIGSTOP) and lets them go on (SIGCONT):
/// nothing is closed or lost, an answer half-received goes on where it stopped. A small watcher
/// outside Cooldown lets them go if Cooldown itself stops, so nothing stays frozen by mistake.
@MainActor
final class Freezer {
    static let shared = Freezer()

    private(set) var frozen: [pid_t] = []
    private(set) var frozenNames: [String] = []
    private var watcher: Process?

    static var file: URL { RouteGuard.dir.appendingPathComponent("frozen") }

    /// What else belongs to an app though it lives elsewhere: Claude Desktop runs its own Claude
    /// Code from its support folder.
    static func extraFolders(_ bundleID: String) -> [String] {
        guard bundleID == "com.anthropic.claudefordesktop" else { return [] }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/Library/Application Support/Claude/claude-code/"]
    }

    /// Running apps with these bundle ids: their folders (the app and what belongs to it) and
    /// names (`--guard-test` swaps it).
    static var resolve: (Set<String>) -> [(folders: [String], name: String)] = { ids in
        NSWorkspace.shared.runningApplications.filter { ids.contains($0.bundleIdentifier ?? "") }.compactMap { app in
            guard let path = app.bundleURL?.path else { return nil }
            return ([path + "/"] + extraFolders(app.bundleIdentifier ?? ""), app.localizedName ?? (path as NSString).lastPathComponent)
        }
    }

    /// Exactly these apps frozen, every other one let go.
    func set(_ bundleIDs: Set<String>) {
        let running = Self.resolve(bundleIDs)
        let targets = Self.processes(in: running.map(\.folders))
        for pid in frozen where !targets.contains(pid) { kill(pid, SIGCONT) }
        for pid in targets where !frozen.contains(pid) { kill(pid, SIGSTOP) }
        let changed = targets != frozen
        frozen = targets
        frozenNames = targets.isEmpty ? [] : Array(Set(running.map(\.name))).sorted()
        guard changed else { return }
        persist()
        restartWatcher()
    }

    func thawAll() { set([]) }

    /// After a crash: whatever the last run froze goes on.
    static func recover() {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        for pid in text.split(whereSeparator: \.isWhitespace).compactMap({ pid_t($0) }) where pid > 1 { kill(pid, SIGCONT) }
        try? FileManager.default.removeItem(at: file)
    }

    private func persist() {
        if frozen.isEmpty {
            try? FileManager.default.removeItem(at: Self.file)
        } else {
            try? frozen.map(String.init).joined(separator: " ").write(to: Self.file, atomically: true, encoding: .utf8)
        }
    }

    private func restartWatcher() {
        watcher?.terminate()
        watcher = nil
        guard !frozen.isEmpty else { return }
        let list = frozen.map(String.init).joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Cooldown gone (crash, force quit): the frozen apps go on within two seconds.
        process.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 2; done; kill -CONT \(list) 2>/dev/null; rm -f \"$0\"", Self.file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        watcher = process
    }

    private struct Info { var parent: pid_t; var terminal: Bool; var program: String }

    /// The processes of these apps. Each app is a list of folders: its bundle first, then what
    /// else belongs to it. Taken: processes running a program from the bundle, and their
    /// descendants running a program from any of the folders. Never taken: Cooldown and
    /// anything it started, processes attached to a terminal (stopping those hands the terminal
    /// back to the shell), and other programs an agent started (dev servers, tunnels, proxies).
    static func processes(in apps: [[String]]) -> [pid_t] {
        let apps = apps.filter { !$0.isEmpty }
        guard !apps.isEmpty else { return [] }
        let me = getpid()
        var table: [pid_t: Info] = [:]
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in allPids() {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { continue }
            let program = proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? String(cString: path) : ""
            table[pid] = Info(parent: pid_t(info.pbi_ppid), terminal: info.pbi_flags & 0xC0 != 0, program: program) // PROC_FLAG_CONTROLT | PROC_FLAG_CTTY
        }
        func descendsFromMe(_ pid: pid_t) -> Bool {
            var current = pid
            for _ in 0..<64 {
                if current == me { return true }
                guard let parent = table[current]?.parent, parent > 1, parent != current else { return false }
                current = parent
            }
            return false
        }
        var children: [pid_t: [pid_t]] = [:]
        for (pid, info) in table { children[info.parent, default: []].append(pid) }
        var result = Set<pid_t>()
        for folders in apps {
            let bundle = folders[0]
            let roots = table.filter { $0.value.program.hasPrefix(bundle) }.map(\.key)
            var queue = roots
            while let pid = queue.popLast() {
                guard let info = table[pid], !info.terminal, !descendsFromMe(pid),
                      folders.contains(where: { info.program.hasPrefix($0) }), result.insert(pid).inserted else { continue }
                queue.append(contentsOf: children[pid] ?? [])
            }
        }
        return result.subtracting([me]).sorted()
    }

    private static func allPids() -> [pid_t] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        return Array(pids.prefix(max(0, count))).filter { $0 > 1 }
    }
}
