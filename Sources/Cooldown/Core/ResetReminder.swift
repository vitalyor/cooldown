import AppKit
import Foundation

/// "Remind me 10 minutes before the limit is back": one timer per agent on the wall clock,
/// kept across restarts. When it fires, a card says the limit returns soon.
@MainActor
enum ResetReminder {
    static let lead: TimeInterval = 10 * 60
    private static var timers: [ProviderID: Timer] = [:]

    private static func key(_ provider: ProviderID) -> String { "resetReminder.\(provider.rawValue)" }

    /// When the reminder for this agent fires, if one is set.
    static func when(_ provider: ProviderID) -> Date? {
        let value = UserDefaults.standard.double(forKey: key(provider))
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    /// Whether there is enough time left before `reset` for a reminder to make sense.
    static func possible(before reset: Date) -> Bool { reset.timeIntervalSinceNow > lead + 60 }

    static func set(_ provider: ProviderID, reset: Date) {
        let fire = reset.addingTimeInterval(-lead)
        UserDefaults.standard.set(fire.timeIntervalSince1970, forKey: key(provider))
        schedule()
        ToastController.shared.show(ToastContent(key: "remind-set-\(provider.rawValue)", kind: .info, provider: provider,
                                                 title: L("Напомню в %@", "\(Format.clock(fire))"),
                                                 body: L("За 10 минут до сброса лимита %@.", "\(provider.displayName)"), life: .auto(5)))
    }

    static func cancel(_ provider: ProviderID) {
        UserDefaults.standard.removeObject(forKey: key(provider))
        timers.removeValue(forKey: provider)?.invalidate()
    }

    /// (Re)creates the timers; a reminder whose time passed while Cooldown was closed fires now
    /// if the reset is still ahead, and is dropped otherwise.
    static func schedule() {
        for provider in ProviderID.allCases {
            timers.removeValue(forKey: provider)?.invalidate()
            guard let fire = when(provider) else { continue }
            if fire.timeIntervalSinceNow < -lead { cancel(provider); continue }
            let timer = Timer(fire: max(fire, Date().addingTimeInterval(1)), interval: 0, repeats: false) { _ in
                MainActor.assumeIsolated { ResetReminder.fire(provider) }
            }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            timers[provider] = timer
        }
    }

    private static func fire(_ provider: ProviderID) {
        let reset = when(provider)?.addingTimeInterval(lead)
        cancel(provider)
        guard let reset, reset > Date() else { return }
        var actions: [ToastAction] = [.openPanel]
        if provider == .codex { actions.insert(.openSchedule, at: 0) }
        Notifier.shared.post(id: "remind-\(provider.rawValue)-\(Int(reset.timeIntervalSince1970))",
                             title: L("Скоро лимит %@ восстановится", "\(provider.displayName)"),
                             body: L("Сброс в %@ — через 10 минут.", "\(Format.clock(reset))"),
                             toast: ToastContent(key: "remind-\(provider.rawValue)", kind: .reset, provider: provider,
                                                 title: L("Через 10 минут лимит %@ восстановится", "\(provider.displayName)"),
                                                 body: L("Сброс в %@. Самое время приготовить следующую задачу.", "\(Format.clock(reset))"),
                                                 actions: actions, life: .sticky))
    }
}
