import Foundation
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var available = false
    static let claudeCategory = "claude-reset"
    static let continueAction = "continue"
    static let openAction = "open"

    func setup() {
        guard Bundle.main.bundleIdentifier != nil, !CommandLine.arguments.contains("--snapshot") else { return }
        available = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let proceed = UNNotificationAction(identifier: Self.continueAction, title: L("Продолжить"), options: [.foreground])
        let open = UNNotificationAction(identifier: Self.openAction, title: L("Открыть Claude"), options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.claudeCategory, actions: [proceed, open],
                                                                 intentIdentifiers: [])])
    }

    func post(id: String, title: String, body: String, opensClaude: Bool = false, demo: Bool = false,
              toast: ToastContent? = nil, record: Bool = true) {
        guard available else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                if record && !demo {
                    EventLog.shared.add(CooldownEvent(kind: Self.eventKind(toast?.kind, opensClaude: opensClaude),
                                                      provider: toast?.provider, title: title, body: body,
                                                      threadId: toast?.threadId))
                }
                if !demo { HomeAssistant.shared.forward(title: title, body: body) }
            }
            // Quiet hours: it is in the feed; the morning summary will mention it.
            if !demo, MainActor.assumeIsolated({ QuietHours.active }) { return }
        }
        // At the Mac: a card under the menu bar icon. Away (screen locked): a normal notification.
        if Thread.isMainThread, MainActor.assumeIsolated({ ToastController.shared.canShow }) {
            let card = toast ?? ToastContent(key: id, kind: opensClaude ? .reset : .info, provider: nil, title: title, body: body,
                                             actions: opensClaude ? [.continueClaude(demo: demo), .openClaude] : [.openPanel],
                                             life: opensClaude ? .sticky : .auto(8))
            MainActor.assumeIsolated { ToastController.shared.show(card) }
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if opensClaude {
            content.userInfo = ["open": "claude", "demo": demo]
            content.categoryIdentifier = Self.claudeCategory
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    @MainActor
    private static func eventKind(_ kind: ToastContent.Kind?, opensClaude: Bool) -> CooldownEvent.Kind {
        switch kind {
        case .reset?: return .reset
        case .finished?: return .finished
        case .attention?: return .attention
        case .warning?: return .failure
        case .waiting?: return .waiting
        default: return opensClaude ? .reset : .info
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.userInfo["open"] as? String == "claude" {
            if response.actionIdentifier == Self.continueAction,
               response.notification.request.content.userInfo["demo"] as? Bool == true {
                Task { @MainActor in
                    Notifier.shared.post(id: "demo-sent-\(Date().timeIntervalSince1970)", title: L("Демо · Ничего не отправлено"),
                                         body: L("В обычном режиме Cooldown сейчас вывел бы Claude вперёд и отправил в открытый чат: «%@»", "\(ClaudeSender.text)"))
                }
            } else if response.actionIdentifier == Self.continueAction {
                // The person pressed "Продолжить": one message, sent because they asked for it.
                Task { @MainActor in
                    do { try await ClaudeSender.continueChat(ClaudeSender.pendingChat) } catch {
                        Notifier.shared.post(id: "send-\(Date().timeIntervalSince1970)", title: L("Не отправлено"),
                                             body: error.localizedDescription)
                    }
                }
            } else {
                DispatchQueue.main.async { ClaudeApp.open() }
            }
        }
        completionHandler()
    }
}
