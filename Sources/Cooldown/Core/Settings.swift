import Foundation
import ServiceManagement

enum SettingsKey {
    static let refreshInterval = "refreshInterval"
    static let codexPath = "codexPath"
    static let claudePath = "claudePath"
    static let showPercent = "showPercent"
    static let menuSource = "menuSource"
    static let menuWindow = "menuWindow"
    static let notifyThresholds = "notifyThresholds"
    static let notifyReset = "notifyReset"
    static let notifyTasks = "notifyTasks"
    static let claudeAccountUsage = "claudeAccountUsage"
    static let claudeUsageCLI = "claudeUsageCLI"
    static let claudeContinueText = "claudeContinueText"
    static let claudeAutoContinue = "claudeAutoContinue"
    static let claudeAutoCode = "claudeAutoCode"
    static let toasts = "toasts"
    static let notifyFinished = "notifyFinished"
    static let notifyAttention = "notifyAttention"
    static let watchClaudeWindow = "watchClaudeWindow"
    static let showActivity = "showActivity"
    static let quietWithFocus = "quietWithFocus"
    static let cardsWhenFront = "cardsWhenFront"
    static let cardsInCapture = "cardsInCapture"
    static let guardEnabled = "guardEnabled"
    static let guardFreeze = "guardFreeze"
    static let guardForbidden = "guardForbidden"
    static let guardExits = "guardExits"
    static let guardRefused = "guardRefused"
    static let guardPausedUntil = "guardPausedUntil"
    static let notifyPace = "notifyPace"
    static let notifyProjects = "notifyProjects"
    static let weeklySummary = "weeklySummary"
    static let soundFinished = "soundFinished"
    static let autoUpdate = "autoUpdate"
    static let updateMode = "updateMode"
    static let soundAttention = "soundAttention"
    static let soundReset = "soundReset"
    static let finishedMinSeconds = "finishedMinSeconds"
    static let quietHours = "quietHours"
    static let quietFrom = "quietFrom"
    static let quietTo = "quietTo"
    static let haURL = "haURL"
    static let phoneLink = "phoneLink"
    static let phoneAlways = "phoneAlways"
    static let phoneLive = "phoneLive"
    static let phoneKeepAlive = "phoneKeepAlive"
    static let autoRestartAgents = "autoRestartAgents"
    static let haDevice = "haDevice"
    static let haLive = "haLive"
    static let haNotify = "haNotify"
    static let selectedProvider = "selectedProvider"
    static let notifiedKeys = "notifiedKeys"
}

/// Reads the same keys the settings screen writes with @AppStorage, with the same defaults.
enum Settings {
    private static var defaults: UserDefaults { testDefaults ?? .standard }
    /// `--guard-test` only: settings and files of its own, never the real ones.
    nonisolated(unsafe) static var testDefaults: UserDefaults?
    nonisolated(unsafe) static var testRoot: URL?

    static var appSupport: URL {
        if let testRoot { return testRoot }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Cooldown", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The plan last seen for an agent and since when (for learning the usual pace anew).
    static func plan(_ provider: ProviderID) -> (name: String, since: Date)? {
        guard let name = defaults.string(forKey: "plan.\(provider.rawValue)") else { return nil }
        let since = defaults.double(forKey: "planSince.\(provider.rawValue)")
        return (name, Date(timeIntervalSince1970: since))
    }

    static func setPlan(_ provider: ProviderID, name: String, since: Date) {
        defaults.set(name, forKey: "plan.\(provider.rawValue)")
        defaults.set(since.timeIntervalSince1970, forKey: "planSince.\(provider.rawValue)")
    }

    static var refreshInterval: TimeInterval {
        let value = defaults.double(forKey: SettingsKey.refreshInterval)
        return value >= 15 ? value : 60
    }

    static var codexPath: String { defaults.string(forKey: SettingsKey.codexPath) ?? "" }
    static var claudePath: String { defaults.string(forKey: SettingsKey.claudePath) ?? "" }
    static var showPercent: Bool { bool(SettingsKey.showPercent, true) }
    /// Which agents have a line in the menu bar: their ids joined by commas ("codex,antigravity").
    /// "lowest", the old default, means Codex and Claude; a single id is one line as before.
    static var menuSource: String { defaults.string(forKey: SettingsKey.menuSource) ?? "lowest" }
    static var menuProviders: [ProviderID] { menuProviders(menuSource) }
    /// At most two, always in the same order (Codex, Claude, Antigravity): two lines is all the
    /// menu bar's height holds with readable numbers.
    static func menuProviders(_ raw: String) -> [ProviderID] {
        let ids = Set((raw == "lowest" ? "codex,claude" : raw).split(separator: ",").compactMap { ProviderID(rawValue: String($0)) })
        return Array(ProviderID.allCases.filter(ids.contains).prefix(2))
    }
    /// "session" (5 hours) or "weekly" for the line/number in the menu bar.
    static var menuWindow: String { defaults.string(forKey: SettingsKey.menuWindow) ?? "session" }
    static var notifyThresholds: Bool { bool(SettingsKey.notifyThresholds, true) }
    static var notifyReset: Bool { bool(SettingsKey.notifyReset, true) }
    static var notifyTasks: Bool { bool(SettingsKey.notifyTasks, true) }
    /// Off until the person allows reading Claude Code's sign-in from the keychain.
    static var claudeAccountUsage: Bool { bool(SettingsKey.claudeAccountUsage, false) }
    /// On by default: limits from Claude Code's own /usage screen (no tokens spent).
    /// Cards under the menu bar icon instead of system banners while someone is at the Mac.
    static var toasts: Bool { bool(SettingsKey.toasts, true) }
    /// Say when Codex finishes a turn that ran at least this long.
    static var notifyFinished: Bool { bool(SettingsKey.notifyFinished, true) }
    /// Say when an agent stops to ask for a decision (from hooks).
    static var notifyAttention: Bool { bool(SettingsKey.notifyAttention, true) }
    /// Watch Claude Desktop's window for answers being written (needs Accessibility).
    static var watchClaudeWindow: Bool { bool(SettingsKey.watchClaudeWindow, true) }
    /// Show in the menu bar when an agent is working or waiting.
    static var showActivity: Bool { bool(SettingsKey.showActivity, true) }
    /// Quiet while a macOS Focus (Do Not Disturb, Sleep…) is on.
    static var quietWithFocus: Bool { bool(SettingsKey.quietWithFocus, true) }
    /// Show cards even while the agent's own app is in front.
    static var cardsWhenFront: Bool { bool(SettingsKey.cardsWhenFront, false) }
    /// Let screenshots, recordings and screen sharing see the cards. Off by default: a card may carry a prompt.
    static var cardsInCapture: Bool { bool(SettingsKey.cardsInCapture, false) }

    // VPN guard (RouteGuard). Off until the person turns it on.
    static var guardEnabled: Bool { bool(SettingsKey.guardEnabled, false) }
    /// Freeze the agents' apps while their route is wrong.
    static var guardFreeze: Bool { bool(SettingsKey.guardFreeze, true) }
    /// Countries the services do not serve: a route through one of them stops the agents.
    static let guardForbiddenDefault = "RU BY CN HK MO IR KP CU SY"
    static var guardForbiddenText: String { defaults.string(forKey: SettingsKey.guardForbidden) ?? guardForbiddenDefault }
    static var guardForbidden: Set<String> {
        Set(guardForbiddenText.uppercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count == 2 })
    }
    /// Exits seen and allowed, per service: address → the person's name for it ("" for none).
    static var guardExits: [String: [String: String]] {
        get { defaults.dictionary(forKey: SettingsKey.guardExits) as? [String: [String: String]] ?? [:] }
        set { defaults.set(newValue, forKey: SettingsKey.guardExits) }
    }
    /// Addresses the person said no to.
    static var guardRefused: [String] {
        get { defaults.stringArray(forKey: SettingsKey.guardRefused) ?? [] }
        set { defaults.set(newValue, forKey: SettingsKey.guardRefused) }
    }
    static var guardPausedUntil: Date? {
        get { defaults.object(forKey: SettingsKey.guardPausedUntil) as? Date }
        set { defaults.set(newValue, forKey: SettingsKey.guardPausedUntil) }
    }
    static func guardPaused(_ now: Date) -> Bool { guardPausedUntil.map { $0 > now } ?? false }
    static func set(_ value: Any?, forKey key: String) { defaults.set(value, forKey: key) }
    /// Warn while an agent works if the 5-hour limit will run out before it resets.
    static var notifyPace: Bool { bool(SettingsKey.notifyPace, true) }
    /// Say when one project takes a large part of the weekly limit.
    static var notifyProjects: Bool { bool(SettingsKey.notifyProjects, true) }
    /// A short summary of the week on Sunday evening.
    static var weeklySummary: Bool { bool(SettingsKey.weeklySummary, true) }
    static var soundFinished: Bool { bool(SettingsKey.soundFinished, false) }
    /// Install new releases from GitHub by itself (when the Mac is idle a moment).
    /// How new versions arrive: "off" (only when checked by hand), "download" (fetched and
    /// verified in the background, installed with one press) or "auto" (installed when the Mac is idle).
    static var updateMode: String {
        if let mode = defaults.string(forKey: SettingsKey.updateMode), ["off", "download", "auto"].contains(mode) { return mode }
        // The earlier on/off switch: off meant "ask first", the nearest is "download only".
        return bool(SettingsKey.autoUpdate, true) ? "auto" : "download"
    }
    static var soundAttention: Bool { bool(SettingsKey.soundAttention, false) }
    static var soundReset: Bool { bool(SettingsKey.soundReset, false) }
    static var finishedMinSeconds: Double {
        let value = UserDefaults.standard.double(forKey: SettingsKey.finishedMinSeconds)
        return value > 0 ? value : 60
    }
    static var quietHours: Bool { bool(SettingsKey.quietHours, false) }
    /// Minutes after midnight.
    static var quietFrom: Int { UserDefaults.standard.object(forKey: SettingsKey.quietFrom) as? Int ?? 23 * 60 }
    static var quietTo: Int { UserDefaults.standard.object(forKey: SettingsKey.quietTo) as? Int ?? 8 * 60 }
    static var claudeUsageCLI: Bool { bool(SettingsKey.claudeUsageCLI, true) }
    /// Continue the chosen Claude Desktop chats after the plan window resets, without a press.
    static var claudeAutoContinue: Bool { bool(SettingsKey.claudeAutoContinue, true) }
    /// Pick up Claude Code sessions stopped by the plan limit and continue them in the background.
    static var claudeAutoCode: Bool { bool(SettingsKey.claudeAutoCode, true) }

    /// Reset time of a window seen nearly spent; a notification fires once it passes.
    static func pendingReset(_ provider: ProviderID) -> Date? {
        let value = defaults.double(forKey: "pendingReset.\(provider.rawValue)")
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    static func setPendingReset(_ provider: ProviderID, _ date: Date?) {
        defaults.set(date?.timeIntervalSince1970 ?? 0, forKey: "pendingReset.\(provider.rawValue)")
    }

    static var notifiedKeys: [String] {
        get { defaults.stringArray(forKey: SettingsKey.notifiedKeys) ?? [] }
        // Keys carry the reset time, so many of them are still current. 500 is far more than the
        // handful of windows alive at once and does not push one out while its card is still open.
        set { defaults.set(Array(newValue.suffix(500)), forKey: SettingsKey.notifiedKeys) }
    }

    /// Cooldown for iPhone: on, notifications even while someone is at the Mac, and the Live
    /// Activity with buttons and the countdown to a reset.
    static var phoneLink: Bool { bool(SettingsKey.phoneLink, false) }
    static var phoneAlways: Bool { bool(SettingsKey.phoneAlways, false) }
    static var phoneLive: Bool { bool(SettingsKey.phoneLive, true) }
    static var phoneKeepAlive: Bool { bool(SettingsKey.phoneKeepAlive, true) }
    /// Codex lost its connection to Cooldown while a task waits: restart it by itself once it is free.
    static var autoRestartAgents: Bool { bool(SettingsKey.autoRestartAgents, true) }

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
