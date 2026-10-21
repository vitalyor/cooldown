import Foundation
import ServiceManagement

enum SettingsKey {
    static let refreshInterval = "refreshInterval"
    static let relayPath = "relayPath"
    static let codexPath = "codexPath"
    static let claudePath = "claudePath"
    static let showPercent = "showPercent"
    static let menuSource = "menuSource"
    static let notifyThresholds = "notifyThresholds"
    static let notifyReset = "notifyReset"
    static let notifyTasks = "notifyTasks"
    static let claudeAccountUsage = "claudeAccountUsage"
    static let claudeUsageCLI = "claudeUsageCLI"
    static let claudeContinueText = "claudeContinueText"
    static let toasts = "toasts"
    static let notifyFinished = "notifyFinished"
    static let notifyAttention = "notifyAttention"
    static let watchClaudeWindow = "watchClaudeWindow"
    static let showActivity = "showActivity"
    static let quietWithFocus = "quietWithFocus"
    static let cardsWhenFront = "cardsWhenFront"
    static let notifyPace = "notifyPace"
    static let notifyProjects = "notifyProjects"
    static let weeklySummary = "weeklySummary"
    static let soundFinished = "soundFinished"
    static let autoUpdate = "autoUpdate"
    static let soundAttention = "soundAttention"
    static let soundReset = "soundReset"
    static let finishedMinSeconds = "finishedMinSeconds"
    static let quietHours = "quietHours"
    static let quietFrom = "quietFrom"
    static let quietTo = "quietTo"
    static let haURL = "haURL"
    static let haDevice = "haDevice"
    static let haLive = "haLive"
    static let haNotify = "haNotify"
    static let selectedProvider = "selectedProvider"
    static let notifiedKeys = "notifiedKeys"
}

/// Reads the same keys the settings screen writes with @AppStorage, with the same defaults.
enum Settings {
    private static var defaults: UserDefaults { .standard }

    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Cooldown", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Relay ships inside Cooldown.app when it was there at build time; otherwise its folder is
    /// chosen in Settings.
    static var defaultRelayPath: String {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("relay"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("resume").path) {
            return bundled.path
        }
        return ""
    }

    static var refreshInterval: TimeInterval {
        let value = defaults.double(forKey: SettingsKey.refreshInterval)
        return value >= 15 ? value : 60
    }

    static var relayPath: String {
        let value = defaults.string(forKey: SettingsKey.relayPath) ?? ""
        return value.isEmpty ? defaultRelayPath : value
    }

    static var codexPath: String { defaults.string(forKey: SettingsKey.codexPath) ?? "" }
    static var claudePath: String { defaults.string(forKey: SettingsKey.claudePath) ?? "" }
    static var showPercent: Bool { bool(SettingsKey.showPercent, true) }
    /// "lowest" across all agents, or one agent's id.
    static var menuSource: String { defaults.string(forKey: SettingsKey.menuSource) ?? "lowest" }
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
    /// Warn while an agent works if the 5-hour limit will run out before it resets.
    static var notifyPace: Bool { bool(SettingsKey.notifyPace, true) }
    /// Say when one project takes a large part of the weekly limit.
    static var notifyProjects: Bool { bool(SettingsKey.notifyProjects, true) }
    /// A short summary of the week on Sunday evening.
    static var weeklySummary: Bool { bool(SettingsKey.weeklySummary, true) }
    static var soundFinished: Bool { bool(SettingsKey.soundFinished, false) }
    /// Install new releases from GitHub by itself (when the Mac is idle a moment).
    static var autoUpdate: Bool { bool(SettingsKey.autoUpdate, true) }
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
        set { defaults.set(Array(newValue.suffix(80)), forKey: SettingsKey.notifiedKeys) }
    }

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
