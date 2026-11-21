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
// Google has no such page. Its own geolocation is read from YouTube's service-worker data
// (`www.youtube.com/sw.js_data` names the country and address Google sees), sent with curl's
// --connect-to along Antigravity's own API address, so the route is Antigravity's. Google takes
// frequent anonymous requests for a robot, so it is asked more rarely (see `due`).
//
// Two routes may differ. Apps (Claude Desktop, ChatGPT) follow the system proxy; command-line
// agents (Claude Code, Codex in a terminal, and Cooldown's own calls) go direct unless their
// environment names a proxy. With a system proxy set, both are checked and judged apart.
//
// While a route is wrong: the hooks in Claude Code and Codex hold prompts and stop work between
// steps, Cooldown makes no request of its own to that service, the agents' apps can be frozen
// (paused by the system, nothing lost) and one card says what happened. Off by default.

enum GuardService: String, CaseIterable {
    case anthropic, openai, google

    /// The host the agent itself talks to: its route is the one that counts.
    var host: String {
        switch self {
        case .anthropic: return "api.anthropic.com"
        case .openai: return "chatgpt.com"
        case .google: return "cloudcode-pa.googleapis.com"
        }
    }

    var provider: ProviderID {
        switch self {
        case .anthropic: return .claude
        case .openai: return .codex
        case .google: return .antigravity
        }
    }

    var name: String { provider.displayName }

    /// Apps frozen while this route is wrong (ChatGPT for Mac carries the Codex bundle id).
    var apps: [String] {
        switch self {
        case .anthropic: return ["com.anthropic.claudefordesktop"]
        case .openai: return ["com.openai.codex", "com.openai.chat"]
        case .google: return ["com.google.antigravity", "com.google.antigravity-ide"]
        }
    }

    /// Every address the agents of this service talk to: under per-site VPN rules one may go
    /// through the tunnel and another past it, so each is checked and the worst one counts.
    var hosts: [String] {
        switch self {
        case .anthropic: return ["api.anthropic.com", "claude.ai"]
        case .openai: return ["chatgpt.com", "api.openai.com"]
        case .google: return [host]
        }
    }

    /// What curl asks for: where a request to `host` comes from, along that host's route.
    func probe(_ host: String) -> [String] {
        switch self {
        case .anthropic, .openai: return ["https://\(host)/cdn-cgi/trace"]
        case .google: return ["--connect-to", "www.youtube.com:443:\(host):443", Self.googleURL]
        }
    }

    /// Command-line agents of this service, for freezing in a terminal: program names, parts of
    /// the program's path, and, for scripts run by node and the like, parts of the command line.
    var terminalAgents: (names: [String], paths: [String], args: [String]) {
        switch self {
        case .anthropic: return (["claude"], ["/.local/share/claude/versions/"], ["@anthropic-ai/claude-code"])
        case .openai: return (["codex"], ["/@openai/codex/"], ["@openai/codex"])
        case .google: return (["agy", "gemini"], ["/.gemini/bin/"], ["@google/gemini-cli"])
        }
    }

    var terminalName: String {
        switch self {
        case .anthropic: return "Claude Code"
        case .openai: return "Codex"
        case .google: return "Antigravity CLI"
        }
    }

    static let googleURL = "https://www.youtube.com/sw.js_data"

    func parse(_ text: String) -> RouteExit? { self == .google ? RouteExit.parseGoogle(text) : RouteExit.parse(text) }

    static func of(_ provider: ProviderID) -> GuardService {
        switch provider {
        case .claude: return .anthropic
        case .codex: return .openai
        case .antigravity: return .google
        }
    }

    /// The services of the agents the person uses (hidden ones, or ones the guard is switched off
    /// for, are neither checked nor frozen).
    @MainActor static var watched: [GuardService] {
        let off = Settings.guardOff
        return allCases.filter { ProviderID.shown.contains($0.provider) && !off.contains($0.rawValue) }
    }

    /// The guard is switched off for this agent alone.
    var off: Bool { Settings.guardOff.contains(rawValue) }
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

    /// `[["yt.sw.adr",null,[[["ru","RU",null,"95.27.150.254",…`: the language, country and
    /// address Google sees.
    static func parseGoogle(_ text: String) -> RouteExit? {
        let pattern = #"\["yt\.sw\.adr",null,\[\[\["[^"]*","([A-Za-z]{2})",null,"([0-9A-Fa-f.:]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let country = Range(match.range(at: 1), in: text), let ip = Range(match.range(at: 2), in: text) else { return nil }
        return RouteExit(ip: String(text[ip]), country: text[country].uppercased(), colo: "")
    }

    var countryName: String { Locale.current.localizedString(forRegionCode: country) ?? country }
}

/// One check of a service: the direct route, and the system proxy's when one is set.
struct RouteTrace: Equatable {
    var direct: RouteExit?
    var viaProxy: RouteExit?
    var proxied = false
    /// The usual path's answer (the first host over IPv4, or IPv6 where there is no IPv4), the one
    /// asked about when new: a fallback answer while that one timed out is not a new exit.
    var primary: RouteExit?
    var primaryProxy: RouteExit?
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
    /// When the route went wrong (or could not be checked), for the pace of checks after it.
    private var problemSince: Date?
    /// The network as last seen (see NetWatch.fingerprint): a change freezes the apps until checked.
    private var lastFingerprint: String?
    /// After a network change or a wake, a check that could not answer keeps the apps paused
    /// this long without alarm: the VPN may still be connecting.
    private var settlingSince: Date?
    private var sleepObservers: [NSObjectProtocol] = []
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
    nonisolated(unsafe) static var tracer: (GuardService) async -> RouteTrace = { await RouteGuard.trace($0) }
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
        guard live(now), !GuardService.of(provider).off else { return true }
        guard let reading = state.get(GuardService.of(provider)), now.timeIntervalSince(reading.at) < freshFor else { return false }
        return reading.verdict == .ok && reading.appVerdict == .ok
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
        return holds(reading.appVerdict, reading)
    }

    /// What a verdict means: a forbidden or refused route holds at once; no answer holds once it
    /// repeats, and not in the first 15 s after a network change (the VPN may still be connecting:
    /// `settling` keeps the apps paused meanwhile, without a card).
    private func holds(_ verdict: RouteVerdict, _ reading: RouteReading) -> Bool {
        switch verdict {
        case .ok: return false
        case .forbidden, .refused: return true
        case .unchecked:
            if let since = settlingSince, Date().timeIntervalSince(since) < 15 { return false }
            return reading.misses >= 2
        }
    }

    /// Whether a card must say the agents of `service` are held.
    private func stopped(_ service: GuardService) -> Bool {
        guard Self.live(Date()), let reading = readings[service] else { return false }
        if appsStopped(service) { return true }
        // Through a proxy the apps are fine: a wrong direct route holds only command-line agents
        // without a proxy of their own, which a quiet note says (see cliOnly).
        if reading.proxied && reading.appVerdict == .ok { return false }
        return holds(reading.verdict, reading)
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
        let service = GuardService.of(provider)
        guard GuardService.watched.contains(service) else { return false }
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
        do {
            if on {
                if AntigravityGuard.present, AntigravityGuard.status == .off, installsHooks { try AntigravityGuard.install() }
            } else {
                try AntigravityGuard.uninstall()
            }
        } catch {
            problems.append(error.localizedDescription)
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
        if Self.installsHooks, AntigravityGuard.present, AntigravityGuard.status == .off { try? AntigravityGuard.install() }
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
        if !Self.quiet {
            NetWatch.start { RouteGuard.shared.netEvent() }
            lastFingerprint = NetWatch.fingerprint()
        }
        if sleepObservers.isEmpty, !Self.quiet {
            let center = NSWorkspace.shared.notificationCenter
            // Before sleep the apps are paused, so on waking nothing leaves before the route is checked
            // (the VPN usually reconnects a few seconds after the Mac does).
            sleepObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RouteGuard.shared.goingToSleep() }
            })
            sleepObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RouteGuard.shared.woke() }
            })
        }
        // Until the first check the apps wait, as after any network change.
        for service in GuardService.watched where readings[service] == nil {
            readings[service] = RouteReading(verdict: .unchecked, exit: nil, appVerdict: .unchecked, appExit: nil, at: .distantPast)
        }
        settlingSince = Date()
        problemSince = nil
        enforce()
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
        problemSince = nil
        settlingSince = nil
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
        guard Self.live(Date()) else { return }
        // Online or offline is a change by itself; anything else the system reports (roaming, a
        // new flag) counts only if the network's fingerprint moved.
        guard online != wasOnline else { netEvent(); return }
        lastFingerprint = NetWatch.fingerprint()
        networkChanged()
    }

    /// The routing table or the proxy settings moved (NetWatch): a real change if the network's
    /// fingerprint is new.
    func netEvent() {
        guard Self.live(Date()) else { return }
        let fingerprint = NetWatch.fingerprint()
        guard fingerprint != lastFingerprint else { return }
        lastFingerprint = fingerprint
        networkChanged()
    }

    /// A new network, a VPN up or down, a proxy switched, waking from sleep: until checked again
    /// the old readings let nothing through (requests and hooks wait), and the apps pause for the
    /// moment the check takes (if the route is the same, they hardly notice).
    func networkChanged(check: Bool = true) {
        guard Self.live(Date()), !sleeping else { return }
        generation += 1
        settlingSince = Date()
        age()
        enforce()
        guard check else { return }
        if checking {
            rerun = true
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Task { await RouteGuard.shared.round() } }
        }
    }

    /// Going to sleep: the readings no longer count, but nothing is frozen now (a stopped app could
    /// not answer the system and would hold the sleep up); the apps pause first thing on waking.
    func goingToSleep() {
        guard Self.live(Date()) else { return }
        sleeping = true
        generation += 1
        settlingSince = Date()
        age()
    }

    /// Awake: the apps pause at once and go on after the first check (the VPN usually
    /// reconnects a few seconds after the Mac does).
    func woke() {
        sleeping = false
        networkChanged(check: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Task { await RouteGuard.shared.round() } }
    }

    /// Between going to sleep and waking: nothing is frozen (a stopped app could not answer the
    /// system and would hold the sleep up), whatever the network does meanwhile.
    private var sleeping = false

    private func age() {
        // The hooks' own answers from before the change no longer count either.
        for service in GuardService.allCases { try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent("self-" + service.rawValue)) }
        for (service, var reading) in readings {
            reading.misses = 0
            reading.at = .distantPast
            readings[service] = reading
            Self.state.set(service, reading)
            writeState(service, reading)
        }
    }

    /// Paused for the moment a check after a network change takes, or (no answer yet) while the
    /// VPN may still be connecting; no card for this. `app`: the apps' route, else the direct one.
    private func settling(_ service: GuardService, app: Bool) -> Bool {
        guard Self.live(Date()), !sleeping, let reading = readings[service] else { return false }
        if reading.at == .distantPast { return true }
        guard let since = settlingSince, Date().timeIntervalSince(since) < 15 else { return false }
        return (app ? reading.appVerdict : reading.verdict) == .unchecked
    }

    /// Whether command-line agents of `service` (they go direct) must be frozen.
    private func cliStopped(_ service: GuardService) -> Bool {
        guard Self.live(Date()), let reading = readings[service] else { return false }
        return holds(reading.verdict, reading)
    }

    /// `--guard-test` only: as if the person had closed a card.
    func dismissForTest(_ key: String) { dismiss(key) }

    /// `--guard-test` only: as if Cooldown had just started.
    func forgetReadings() {
        readings = [:]
        for service in GuardService.allCases { Self.state.set(service, nil) }
    }

    /// "Check now" (a card, the phone): a fresh round, or the one already running, to its end.
    func checkNow() async {
        if checking { await nextReading() } else { await round() }
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
        if !Settings.guardPaused(Date()), shown["route-paused"] != nil { dismiss("route-paused") }
        if Settings.guardPaused(Date()) {
            // Paused: nothing is checked; the timer wakes when the pause ends.
            releaseWaiters()
            scheduleNext(allGood: true)
            return
        }
        checking = true
        timer?.invalidate()
        writeHookFiles()
        var started = generation
        repeat {
            rerun = false
            started = generation
            let services = GuardService.watched.filter(due)
            await withTaskGroup(of: (GuardService, RouteTrace).self) { group in
                for service in services {
                    group.addTask { (service, await Self.tracer(service)) }
                }
                for await (service, trace) in group where started == generation && Self.live(Date()) {
                    record(service, trace)
                }
            }
        } while (rerun || started != generation) && Self.live(Date())
        checking = false
        // Paced by what must be caught quickly: the apps' route, and the direct one unless a proxy
        // carries the apps (a terminal going direct through Clash is not a reason to slow down).
        let all = GuardService.watched.allSatisfy { service in
            guard let reading = readings[service], reading.appVerdict == .ok, reading.at != .distantPast else { return false }
            return reading.proxied || reading.verdict == .ok
        }
        if all { problemSince = nil; settlingSince = nil } else if problemSince == nil { problemSince = Date() }
        checkTimeZone()
        expirePending()
        announce()
        releaseWaiters()
        scheduleNext(allGood: all)
    }

    /// Google is asked at most every 15 s while Antigravity runs and every minute otherwise (often
    /// enough, frequent anonymous requests get an address a captcha); at once after a network
    /// change or a new exit for another service, which age its reading.
    private func due(_ service: GuardService) -> Bool {
        guard service == .google, let reading = readings[service] else { return true }
        let running = NSWorkspace.shared.runningApplications.contains { service.apps.contains($0.bundleIdentifier ?? "") }
        let every: TimeInterval
        if reading.verdict == .unchecked || reading.appVerdict == .unchecked {
            // One lost answer is asked again soon (a dropped VPN often looks just like that from
            // here); once it repeats, Google may be slowing us down: once a minute.
            every = reading.misses < 2 ? 5 : 60
        } else {
            every = running || reading.verdict != .ok ? 15 : 60
        }
        return Date().timeIntervalSince(reading.at) >= every * 0.9
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
        // While wrong: every 5 s the first minute (a VPN that comes back is noticed at once and the
        // apps go on), then every 15 s.
        let wrongFor = problemSince.map { Date().timeIntervalSince($0) } ?? 0
        let base: TimeInterval = allGood ? (Self.agentsBusy ? 5 : 15) : (wrongFor < 60 ? 5 : 15)
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
    nonisolated static func trace(_ service: GuardService) async -> RouteTrace {
        let proxied = systemProxy
        let forbidden = Settings.guardForbidden
        // Per host, in order: IPv4, IPv6, the system proxy. The order picks which exit is shown
        // and learned when all are fine: the first host's IPv4, the usual path.
        let answers = await withTaskGroup(of: (Int, RouteExit?).self) { group in
            for (index, host) in service.hosts.enumerated() {
                group.addTask { (index * 3, await traceOnce(service, host, family: "-4")) }
                group.addTask { (index * 3 + 1, await traceOnce(service, host, family: "-6")) }
                if proxied { group.addTask { (index * 3 + 2, await traceThroughSystem(service, host)) } }
            }
            var all: [Int: RouteExit] = [:]
            for await (slot, exit) in group { all[slot] = exit }
            return all
        }
        let ordered = answers.keys.sorted()
        let direct = ordered.filter { $0 % 3 != 2 }.map { answers[$0] }
        let viaProxy = ordered.filter { $0 % 3 == 2 }.map { answers[$0] }
        let refused = Set(Settings.guardRefused)
        let hasIPv4 = answers.keys.contains { $0 % 3 == 0 }
        return RouteTrace(direct: worst(direct, forbidden: forbidden, refused: refused),
                          viaProxy: proxied ? worst(viaProxy, forbidden: forbidden, refused: refused) : nil, proxied: proxied,
                          primary: hasIPv4 ? answers[0] : answers[1], primaryProxy: answers[2])
    }

    /// The exit to judge by: a forbidden one wins, then IPv4 (the usual path), then IPv6.
    /// A family with no connection at all does not count (many networks have no IPv6).
    nonisolated static func worst(_ v4: RouteExit?, _ v6: RouteExit?, forbidden: Set<String>) -> RouteExit? {
        worst([v4, v6], forbidden: forbidden)
    }

    /// The same over several answers (hosts, families): a forbidden country wins, then an address
    /// the person refused, otherwise the first that answered.
    nonisolated static func worst(_ exits: [RouteExit?], forbidden: Set<String>, refused: Set<String> = []) -> RouteExit? {
        let answered = exits.compactMap { $0 }
        return answered.first { forbidden.contains($0.country) } ?? answered.first { refused.contains($0.ip) } ?? answered.first
    }

    /// A proxy in System Settings (or a PAC file): what Clash, V2Ray and the like set up.
    nonisolated static var systemProxy: Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return false }
        return ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable"].contains { (settings[$0] as? Int) == 1 }
    }

    /// The system's HTTPS or SOCKS proxy as a curl `-x` (not a PAC file).
    nonisolated static var systemProxyForCurl: [String]? {
        guard let s = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return nil }
        if (s["HTTPSEnable"] as? Int) == 1, let host = s["HTTPSProxy"] as? String, let port = s["HTTPSPort"] as? Int {
            return ["-x", "http://\(host):\(port)"]
        }
        if (s["SOCKSEnable"] as? Int) == 1, let host = s["SOCKSProxy"] as? String, let port = s["SOCKSPort"] as? Int {
            return ["-x", "socks5h://\(host):\(port)"]
        }
        return nil
    }

    /// `curl`, the same as the hooks use: no cookies, no account, nothing but the request line
    /// and curl's own headers. It does not follow the system proxy: the direct route.
    nonisolated private static func traceOnce(_ service: GuardService, _ host: String, family: String) async -> RouteExit? {
        await curl([family] + service.probe(host)).flatMap(service.parse)
    }

    /// Waits for curl without holding a thread of Swift's shared pool: while routes time out a
    /// round runs up to a dozen of these at once.
    /// The answer goes to a file (a block page of any size can never stall curl on a full pipe),
    /// and a watchdog ends the wait in any case: a round must always finish.
    nonisolated private static func curl(_ arguments: [String]) async -> String? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cooldown-route-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        return await withCheckedContinuation { continuation in
            let once = OnceGate()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = ["-s", "-m", "3", "--connect-timeout", "2", "--max-filesize", "1048576", "--proto", "=https",
                                 "-o", file.path] + arguments
            process.environment = ["PATH": "/usr/bin:/bin"] // no proxy from Cooldown's own environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let text = finished.terminationStatus == 0 ? (try? String(contentsOf: file, encoding: .utf8)) : nil
                once.run { continuation.resume(returning: text) }
            }
            if (try? process.run()) == nil {
                once.run { continuation.resume(returning: nil) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
                once.run {
                    if process.isRunning { process.terminate() }
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// The apps' route: URLSession follows the system proxy and PAC as Chromium and WebKit do.
    /// A new session each time: no connection is reused across a network change, and the request
    /// names no app (the same headers as the curl checks). Google's check must go to its API
    /// address, which only curl can do: through the system's proxy given to curl by hand.
    nonisolated private static func traceThroughSystem(_ service: GuardService, _ host: String) async -> RouteExit? {
        if service == .google, let proxy = systemProxyForCurl {
            return await curl(proxy + service.probe(host)).flatMap(service.parse)
        }
        // ponytail: with only a PAC file Google is asked at youtube.com itself, whose route may
        // differ from googleapis.com under per-site rules; read the PAC with CFNetwork if that matters.
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
        guard let url = URL(string: service == .google ? GuardService.googleURL : "https://\(host)/cdn-cgi/trace"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return service.parse(String(decoding: data, as: UTF8.self))
    }

    private func record(_ service: GuardService, _ trace: RouteTrace) {
        let forbidden = Settings.guardForbidden
        let refused = Set(Settings.guardRefused)
        let verdict = RouteVerdict.judge(trace.direct, forbidden: forbidden, refused: refused)
        let appExit = trace.proxied ? trace.viaProxy : trace.direct
        let appVerdict = trace.proxied ? RouteVerdict.judge(trace.viaProxy, forbidden: forbidden, refused: refused) : verdict
        let lost = verdict == .unchecked || appVerdict == .unchecked
        let misses = lost ? (readings[service]?.misses ?? 0) + 1 : 0
        // Another service seen from a new country: the VPN switched, so Google is due again now
        // (its reading stays valid meanwhile; at most every 15 s).
        if service != .google, let before = readings[service]?.exit?.country, let now = trace.direct?.country, before != now,
           var google = readings[.google], google.at != .distantPast, Date().timeIntervalSince(google.at) > 15 {
            google.at = min(google.at, Date().addingTimeInterval(-60))
            readings[.google] = google
            Self.state.set(.google, google)
            rerun = true
        }
        let reading = RouteReading(verdict: verdict, exit: trace.direct, appVerdict: appVerdict, appExit: appExit, at: Date(),
                                   proxied: trace.proxied, misses: misses)
        readings[service] = reading
        Self.state.set(service, reading)
        writeState(service, reading)
        // Tests hand in traces without a primary: the chosen exit stands in.
        let primaries = trace.primary == nil && trace.primaryProxy == nil ? [trace.direct, appExit] : [trace.primary, trace.proxied ? trace.primaryProxy : nil]
        for exit in primaries.compactMap({ $0 }) where RouteVerdict.judge(exit, forbidden: forbidden, refused: refused) == .ok {
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
        pendingSeen[key] = Date()
        guard pending[key] == nil else { return }
        pending[key] = (service, exit)
        showExitCard(notify: notified.insert(key).inserted)
    }

    /// An address asked about but not seen for a while (one answer that came over IPv6 or the
    /// other host while IPv4 timed out) is not asked about any more.
    private var pendingSeen: [String: Date] = [:]
    /// Addresses already announced with a notification in this run: a card again, but no new alert.
    private var notified: Set<String> = []

    private func expirePending() {
        let stale = pending.keys.filter { (pendingSeen[$0] ?? .distantPast) < Date().addingTimeInterval(-90) }
        guard !stale.isEmpty else { return }
        stale.forEach { pending[$0] = nil; pendingSeen[$0] = nil }
        showExitCard(notify: false)
    }

    static func exitName(_ service: GuardService, _ ip: String) -> String? {
        // A name given to an address counts for every service that goes out through it.
        let names = [Settings.guardExits[service.rawValue]?[ip]] + Settings.guardExits.values.map { $0[ip] }
        return names.compactMap { $0 }.first { !$0.isEmpty }
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

    // MARK: Time zone

    /// A word in Settings when the Mac's time zone does not fit the VPN's country (services see both).
    @Published private(set) var timeZoneNote: String?
    /// The zone to switch the Mac to (the VPN country's main one), while it does not fit.
    @Published private(set) var timeZoneTarget: String?

    func checkTimeZone() {
        let exit = GuardService.watched.compactMap { readings[$0] }.first { $0.appVerdict == .ok && $0.at != .distantPast }?.appExit
        let zone = TimeZone.current
        guard let exit, TimeZoneCheck.mismatch(country: exit.country, zone: zone) == true else {
            timeZoneNote = nil
            timeZoneTarget = nil
            return
        }
        timeZoneTarget = TimeZoneCheck.zones[exit.country]?.first
        timeZoneNote = L("Часовой пояс Mac — %@, а VPN выходит в стране «%@». Приложения и сайты видят и то и другое, и несовпадение заметно.",
                         zone.identifier, exit.countryName)
        // Said once per country and zone; the note in Settings stays.
        let key = exit.country + "|" + zone.identifier
        guard Settings.guardTimeZoneWarned != key else { return }
        Settings.set(key, forKey: SettingsKey.guardTimeZoneWarned)
        present(ToastContent(key: "route-tz", kind: .info, provider: nil, title: L("Часовой пояс выдаёт VPN"),
                             body: timeZoneNote ?? "", actions: [.openSettings(.vpn)], life: .auto(15)), notify: false)
    }

    // MARK: What a wrong route does

    /// Something is held now: apps frozen or a route wrong (an update waits for it to pass).
    var holding: Bool { !Freezer.shared.frozen.isEmpty || !blocked.isEmpty }

    /// Services whose agents are held now, among the agents the person uses.
    var blocked: [GuardService] { GuardService.watched.filter(stopped) }

    func enforce() {
        guard Settings.guardEnabled else { return }
        if Settings.guardFreeze {
            let services = GuardService.watched.filter { appsStopped($0) || settling($0, app: true) }
            let terminal = Settings.guardFreezeTerminal ? GuardService.watched.filter { cliStopped($0) || settling($0, app: false) } : []
            // Cooldown's own `codex exec` tasks go direct and have no hook between steps: they pause
            // with the route (an exception to "never Cooldown's own").
            let own = cliStopped(.openai) || settling(.openai, app: false) ? ScheduledRunner.shared.runningPids : []
            // Offline nothing can leave: nothing new is frozen, but what no longer needs it goes on.
            Freezer.shared.set(Set(services.flatMap(\.apps)), terminal: terminal, own: own, onlyThaw: !online)
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
            let tools = quietOnes.map(\.terminalName).joined(separator: L(" и "))
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
            lines.append(services.count == 1 ? L("%@ видит страну «%@».", Self.names(services), country) : L("%@ видят страну «%@».", Self.names(services), country))
        }
        for service in refused {
            lines.append(L("%@: адрес %@ вы запретили.", service.name, verdict(service).1?.ip ?? "?"))
        }
        if !unchecked.isEmpty { lines.append(L("%@: не удалось проверить маршрут.", Self.names(unchecked))) }
        let frozen = Freezer.shared.frozenNames
        if !frozen.isEmpty { lines.append(L("На паузе: %@.", frozen.joined(separator: ", "))) }
        let tools = blocked.filter {
            $0 == .google ? AntigravityGuard.status == .on : AgentHooks.guardStatus($0 == .anthropic ? .claude : .codex) == .on
        }.map { $0 == .google ? "Antigravity" : $0.terminalName }
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
                            actions: [.guardPause, .guardCheck, .openSettings(.vpn)], life: .sticky)
    }

    static func names(_ services: [GuardService]) -> String {
        let names = services.map(\.name)
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + L(" и ") + names.last!
    }

    /// Pictures only (`--settings-snapshot`): made-up readings and exits, in a settings store of
    /// its own (the real addresses never appear), nothing checked or frozen.
    func showcase() {
        Self.quiet = true
        Self.installsHooks = false
        Settings.testDefaults = UserDefaults(suiteName: Self.pictureSuite)
        Settings.testDefaults?.removePersistentDomain(forName: Self.pictureSuite)
        Settings.set(true, forKey: SettingsKey.guardEnabled)
        let ip = "203.0.113.24" // an address for documentation (RFC 5737)
        Settings.guardExits = ["anthropic": [ip: L("США-1")], "openai": [ip: L("США-1")]]
        Settings.guardOff = ["google"]
        let exit = RouteExit(ip: ip, country: "US", colo: "ORD")
        for service in [GuardService.anthropic, .openai] {
            readings[service] = RouteReading(verdict: .ok, exit: exit, appVerdict: .ok, appExit: exit, at: Date().addingTimeInterval(-20))
        }
        checkTimeZone()
    }

    static let pictureSuite = "cooldown-pictures"

    /// The guard for one agent alone: off leaves its route unchecked, its apps and hooks alone.
    func setOff(_ service: GuardService, _ off: Bool) {
        var set = Settings.guardOff
        if off { set.insert(service.rawValue) } else { set.remove(service.rawValue) }
        Settings.guardOff = set
        writeHookFiles()
        objectWillChange.send()
        if off {
            // What waited for it goes: its card, its exit questions.
            pending = pending.filter { $0.value.service != service }
            showExitCard(notify: false)
            enforce()
        } else {
            // Back on: nothing old counts, it is checked at once.
            networkChanged()
        }
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
            // Said on a card (and on the phone), with the way back.
            present(ToastContent(key: "route-paused", kind: .info, provider: nil, title: L("Защита VPN выключена"),
                                 body: L("До %@. Пока она выключена, агенты работают без проверки маршрута.", Format.clock(Date().addingTimeInterval(seconds ?? 0))),
                                 actions: [.guardResume], life: .sticky), notify: false)
        } else {
            dismiss("route-paused")
            // Back on: whatever happened during the pause, nothing old counts; checked at once.
            writeHookFiles()
            networkChanged()
            return
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
            Self.write(Bundle.main.bundlePath + "\n", to: on)
        } else if Settings.guardEnabled, let until = Settings.guardPausedUntil, until > Date() {
            // Paused: the end of the pause on the second line, so the hooks come back on time by
            // themselves even if Cooldown is closed meanwhile.
            Self.write(Bundle.main.bundlePath + "\n" + "\(Int(until.timeIntervalSince1970))\n", to: on)
        } else {
            try? fm.removeItem(at: on)
        }
        Self.write(Settings.guardForbidden.sorted().joined(separator: " ") + "\n", to: dir.appendingPathComponent("forbidden"))
        Self.write(Settings.guardRefused.joined(separator: "\n") + "\n", to: dir.appendingPathComponent("refused"))
        func clean(_ text: String) -> String {
            text.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: "\n", with: " ")
        }
        for service in GuardService.allCases {
            // Switched off for this agent: its hook lets everything through.
            let skip = dir.appendingPathComponent("skip-" + service.rawValue)
            if service.off { Self.write("off\n", to: skip) } else { try? fm.removeItem(at: skip) }
            let block = L("Cooldown: %@ сейчас видит вас не через VPN. Запрос не отправлен — повторите, когда VPN заработает.", service.name)
            let unchecked = L("Cooldown: не удалось проверить маршрут к %@. Запрос не отправлен — проверьте VPN и повторите.", service.name)
            Self.write(clean(block), to: dir.appendingPathComponent("msg-\(service.rawValue)-block"))
            Self.write(clean(unchecked), to: dir.appendingPathComponent("msg-\(service.rawValue)-unchecked"))
        }
    }

    /// The direct route's verdict: the hooks run where the command-line agents do.
    private func writeState(_ service: GuardService, _ reading: RouteReading) {
        let word = reading.verdict == .ok ? "ok" : reading.verdict == .unchecked ? "unchecked" : "block"
        let at = reading.at == .distantPast ? 0 : Int(reading.at.timeIntervalSince1970)
        Self.write("\(word) \(at)\n", to: Self.dir.appendingPathComponent(service.rawValue))
    }

    /// Written only when it changed: these files are rewritten on every check otherwise.
    private static func write(_ text: String, to url: URL) {
        guard (try? String(contentsOf: url, encoding: .utf8)) != text else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
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
    /// Shells held so the agent they run in the foreground stays their job (see `terminal`).
    private(set) var shells: [pid_t] = []
    private(set) var frozenNames: [String] = []

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

    /// Exactly these apps frozen (with the command-line agents of `terminal` running in a
    /// terminal, and `own`: Cooldown's own processes that must pause too), every other one let go.
    /// `onlyThaw` (offline): nothing new is frozen, what no longer needs it goes on.
    func set(_ bundleIDs: Set<String>, terminal: [GuardService] = [], own: [pid_t] = [], onlyThaw: Bool = false) {
        let running = Self.resolve(bundleIDs)
        let table = running.isEmpty && terminal.isEmpty && own.isEmpty ? [:] : Self.table()
        var targets = Set(Self.processes(in: running.map(\.folders), table: table))
        // Cooldown's own processes with what they started (npm's codex runs the real one as a child).
        var queue = own
        while let pid = queue.popLast() {
            guard targets.insert(pid).inserted else { continue }
            queue.append(contentsOf: table.filter { $0.value.parent == pid }.map(\.key))
        }
        var names = Set(running.map(\.name))
        var held = Set<pid_t>()
        if !terminal.isEmpty {
            let agents = Self.terminal(terminal, table: table)
            targets.formUnion(agents.pids)
            held = agents.shells.subtracting(targets)
            names.formUnion(agents.names)
        }
        if onlyThaw {
            targets.formIntersection(frozen)
            held.formIntersection(shells)
        }
        let newTargets = targets.sorted(), newShells = held.sorted()
        // A shell that saw its job stop would take the terminal back and leave the agent in the
        // background: the shell is held first and let go last.
        for pid in newShells where !shells.contains(pid) { kill(pid, SIGSTOP) }
        for pid in frozen where !targets.contains(pid) { kill(pid, SIGCONT) }
        for pid in newTargets where !frozen.contains(pid) { kill(pid, SIGSTOP) }
        for pid in shells where !held.contains(pid) { kill(pid, SIGCONT) }
        let changed = newTargets != frozen || newShells != shells
        frozen = newTargets
        shells = newShells
        frozenNames = targets.isEmpty ? [] : names.sorted()
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

    /// The agents first, their shells last: the order they are let go in.
    private var all: [pid_t] { frozen + shells }

    private func persist() {
        if all.isEmpty {
            try? FileManager.default.removeItem(at: Self.file)
        } else {
            try? all.map(String.init).joined(separator: " ").write(to: Self.file, atomically: true, encoding: .utf8)
        }
    }

    /// A small shell outside Cooldown: once Cooldown is gone (crash, force quit) the frozen apps go
    /// on within two seconds. Started in a session of its own, so whatever ends Cooldown's process
    /// group does not take it along.
    private func restartWatcher() {
        if watcher > 0 {
            // At once (a TERM would wait out its `sleep`), and reaped: no zombie per freeze.
            kill(watcher, SIGKILL)
            waitpid(watcher, nil, 0)
            watcher = 0
        }
        guard !all.isEmpty else { return }
        let list = all.map(String.init).joined(separator: " ")
        let script = "while kill -0 \(getpid()) 2>/dev/null; do sleep 2; done; kill -CONT \(list) 2>/dev/null; rm -f \"$0\""
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own session, and none of Cooldown's open files (a pipe it held open would keep a
        // read elsewhere waiting).
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in 0...2 { posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }
        let arguments = ["/bin/sh", "-c", script, Self.file.path]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        if posix_spawn(&pid, "/bin/sh", &actions, &attributes, &argv, environ) == 0 { watcher = pid }
    }

    private var watcher: pid_t = 0

    struct Entry { var parent: pid_t; var group: pid_t; var foreground: pid_t; var tty: UInt32; var terminal: Bool; var program: String }

    /// Every process once: parent, process group, terminal and program.
    static func table() -> [pid_t: Entry] {
        var table: [pid_t: Entry] = [:]
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in allPids() {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { continue }
            let program = proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? String(cString: path) : ""
            table[pid] = Entry(parent: pid_t(info.pbi_ppid), group: pid_t(info.pbi_pgid), foreground: pid_t(info.e_tpgid),
                               tty: info.e_tdev, terminal: info.pbi_flags & 0xC0 != 0, // PROC_FLAG_CONTROLT | PROC_FLAG_CTTY
                               program: program)
        }
        return table
    }

    /// Whether a process is Cooldown or was started by it (never frozen, except `own`).
    private static func descendsFromMe(_ pid: pid_t, _ table: [pid_t: Entry]) -> Bool {
        let me = onlyUnderForTest != nil ? -1 : getpid()
        var current = pid
        for _ in 0..<64 {
            if current == me { return true }
            guard let parent = table[current]?.parent, parent > 1, parent != current else { return false }
            current = parent
        }
        return false
    }

    /// The processes of these apps. Each app is a list of folders: its bundle first, then what
    /// else belongs to it. Taken: processes running a program from the bundle, and their
    /// descendants running a program from any of the folders. Never taken: Cooldown and
    /// anything it started, processes attached to a terminal (stopping those hands the terminal
    /// back to the shell), and other programs an agent started (dev servers, tunnels, proxies).
    static func processes(in apps: [[String]], table given: [pid_t: Entry]? = nil) -> [pid_t] {
        let apps = apps.filter { !$0.isEmpty }
        guard !apps.isEmpty else { return [] }
        let table = given ?? Self.table()
        var children: [pid_t: [pid_t]] = [:]
        for (pid, info) in table { children[info.parent, default: []].append(pid) }
        var result = Set<pid_t>()
        for folders in apps {
            let bundle = folders[0]
            var queue = table.filter { $0.value.program.hasPrefix(bundle) }.map(\.key)
            while let pid = queue.popLast() {
                guard let info = table[pid], !info.terminal, !descendsFromMe(pid, table),
                      folders.contains(where: { info.program.hasPrefix($0) }), result.insert(pid).inserted else { continue }
                queue.append(contentsOf: children[pid] ?? [])
            }
        }
        return result.subtracting([getpid()]).sorted()
    }

    /// Command-line agents of these services running in a terminal (`claude`, `codex`, `agy`…,
    /// or node running their package), never Cooldown's own; and for an agent that is its
    /// terminal's foreground job, the shell it was started from. Only the agents themselves:
    /// what they started (dev servers, tunnels, proxies) runs on.
    static func terminal(_ services: [GuardService], table given: [pid_t: Entry]? = nil) -> (pids: Set<pid_t>, shells: Set<pid_t>, names: Set<String>) {
        let table = given ?? Self.table()
        func matches(_ pid: pid_t, _ entry: Entry, _ service: GuardService) -> Bool {
            let agent = service.terminalAgents
            let name = (entry.program as NSString).lastPathComponent
            if agent.names.contains(name) || agent.paths.contains(where: entry.program.contains) { return true }
            guard ["node", "bun", "deno", "python", "python3"].contains(name) else { return false }
            // `node /opt/homebrew/bin/claude`: the script named like the agent, or its real place
            // inside the package (the bin entry is a link into node_modules).
            let argv = arguments(pid)
            let scripts = argv.dropFirst().prefix(1).flatMap { [$0, URL(fileURLWithPath: $0).resolvingSymlinksInPath().path] }
            if scripts.contains(where: { agent.names.contains(($0 as NSString).lastPathComponent) }) { return true }
            let line = (argv + scripts).joined(separator: " ")
            return agent.args.contains(where: line.contains)
        }
        var pids = Set<pid_t>(), shells = Set<pid_t>(), names = Set<String>()
        for (pid, entry) in table where entry.terminal && pid != getpid() && !descendsFromMe(pid, table) {
            if let only = onlyUnderForTest, !entry.program.hasPrefix(only) { continue }
            guard let service = services.first(where: { matches(pid, entry, $0) }) else { continue }
            pids.insert(pid)
            names.insert(service.terminalName)
            if entry.group == entry.foreground, entry.parent > 1, let shell = table[entry.parent],
               shell.terminal, shell.tty == entry.tty, shell.group != entry.group {
                shells.insert(entry.parent)
            }
        }
        return (pids, shells, names)
    }

    /// `--guard-test-terminal` only: its agents run under a `script` the test itself started, and
    /// only programs in this folder are looked at (a real Claude Code in a terminal is never touched).
    nonisolated(unsafe) static var onlyUnderForTest: String?

    /// The command line of a process (its arguments only, not its environment).
    private static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        // argc, the program path, NUL padding, then argc arguments; the environment follows.
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var fields: [String] = []
        var current: [UInt8] = []
        var index = 4
        // Skip the program path and the padding after it.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        while index < size, fields.count < argc {
            if buffer[index] == 0 {
                fields.append(String(decoding: current, as: UTF8.self))
                current = []
            } else {
                current.append(buffer[index])
            }
            index += 1
        }
        return fields
    }

    private static func allPids() -> [pid_t] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        return Array(pids.prefix(max(0, count))).filter { $0 > 1 }
    }
}


/// Whether the Mac's time zone fits a country (the zones listed for it in the system's tz table).
enum TimeZoneCheck {
    static let zones: [String: [String]] = {
        var table: [String: [String]] = [:]
        let text = (try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t")
            if fields.count >= 3 { table[String(fields[0]), default: []].append(String(fields[2])) }
        }
        return table
    }()

    /// true: none of the country's zones has the Mac's offset now; nil: the country is unknown.
    static func mismatch(country: String, zone: TimeZone, now: Date = Date()) -> Bool? {
        guard let ids = zones[country.uppercased()], !ids.isEmpty else { return nil }
        let offsets = Set(ids.compactMap { TimeZone(identifier: $0)?.secondsFromGMT(for: now) })
        return !offsets.contains(zone.secondsFromGMT(for: now))
    }
}

/// Lets its block run the first time only (a continuation is resumed exactly once).
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ block: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        block()
    }
}

/// Switching the Mac's time zone to the VPN country's and back. macOS asks for an administrator
/// password each time (systemsetup needs it); the automatic time zone is turned off while the
/// chosen one is in use, or it would put the real one back, and turned on again on return.
enum TimeZoneSwitch {
    /// The zone (and whether it was automatic) from before the first switch: what "back" restores.
    static var saved: String? { Settings.strings("timeZoneSaved")?.first }
    private static var savedAuto: Bool { Settings.strings("timeZoneSaved")?.dropFirst().first == "auto" }

    static var automatic: Bool {
        (NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.timezone.auto.plist")?["Active"] as? Bool) ?? false
    }

    @MainActor static func set(_ zone: String) async throws {
        if saved == nil { Settings.set([TimeZone.current.identifier, automatic ? "auto" : "manual"], forKey: "timeZoneSaved") }
        try await run(zone, automatic: false)
    }

    @MainActor static func restore() async throws {
        guard let zone = saved else { return }
        try await run(zone, automatic: savedAuto)
        Settings.set(nil, forKey: "timeZoneSaved")
    }

    /// Zone names are letters, digits, "/", "_", "+" and "-": nothing that could break the command.
    static func valid(_ zone: String) -> Bool {
        zone.range(of: #"^[A-Za-z0-9/_+-]+$"#, options: .regularExpression) != nil && TimeZone(identifier: zone) != nil
    }

    @MainActor private static func run(_ zone: String, automatic: Bool) async throws {
        guard valid(zone) else { throw NSError(domain: "Cooldown", code: 1, userInfo: [NSLocalizedDescriptionKey: zone]) }
        let auto = "/usr/bin/defaults write /Library/Preferences/com.apple.timezone.auto Active -bool \(automatic ? "true" : "false")"
        // Automatic off before setting (else it puts the real zone back at once); on again after
        // setting the old one.
        let command = automatic ? "/usr/sbin/systemsetup -settimezone \(zone) && \(auto)" : "\(auto) && /usr/sbin/systemsetup -settimezone \(zone)"
        let script = "do shell script \"\(command)\" with administrator privileges"
        let status: Int32 = await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            if (try? process.run()) == nil { process.terminationHandler = nil; continuation.resume(returning: -1) }
        }
        guard status == 0 else {
            throw NSError(domain: "Cooldown", code: Int(status), userInfo: [NSLocalizedDescriptionKey: L("пояс не изменён (отменено или нет прав)")])
        }
        NSTimeZone.resetSystemTimeZone()
        RouteGuard.shared.checkTimeZone()
    }
}
