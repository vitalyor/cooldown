import AppKit
import Foundation

/// One button of a request card.
struct RequestChoice: Equatable, Identifiable {
    enum Role: Equatable { case allow, normal, decline, open }
    var id: String
    var title: String
    var role: Role = .normal
    /// Shown only after "Ещё" (rarely needed, stronger choices).
    var extra = false
}

/// Something an agent is waiting for: a permission or a question, from any chat.
struct AgentRequest: Equatable {
    /// Stable for this very request (provider, conversation, request id).
    var key: String
    var provider: ProviderID
    /// The conversation's name, when known.
    var chat: String
    var headline: String
    /// The exact thing asked about: the command, the files, the question.
    var detail: String?
    var choices: [RequestChoice]
    /// Apps where the person answers this themselves; while one is in front, no card.
    var appBundleIDs: [String]
    var threadId: String?
}

/// Agents' requests as cards with the answers right on them, so nothing waits unnoticed while
/// the person is in another app. A card only ever sends the answer whose button was pressed;
/// closing it or ignoring it answers nothing. Before anything is sent, the source checks that
/// the very same request is still waiting.
@MainActor
final class RequestCenter {
    static let shared = RequestCenter()

    typealias Responder = (RequestChoice) async throws -> Void

    private var pending: [String: (request: AgentRequest, respond: Responder, open: () -> Void)] = [:]
    private var shown = Set<String>()
    private var observer: NSObjectProtocol?

    private init() {
        // Leaving the agent's app with a request still open: now is the moment for its card.
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                     object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { RequestCenter.shared.revealWaiting() }
        }
    }

    func isPending(_ key: String) -> Bool { pending[key] != nil }

    /// A request appeared (or changed). Shown at once unless its app is in front.
    func post(_ request: AgentRequest, open: @escaping () -> Void, respond: @escaping Responder) {
        let isNew = pending[request.key] == nil
        pending[request.key] = (request, respond, open)
        if isNew {
            AgentActivity.trace("request \(request.key): \(request.headline)")
            EventLog.shared.add(CooldownEvent(kind: .attention, provider: request.provider,
                                              title: "\(request.provider.displayName) ждёт вас: \(request.headline)",
                                              body: request.chat, threadId: request.threadId))
        }
        reveal(request.key)
    }

    /// The request is gone (answered here or in the app, or the turn ended).
    func resolved(_ key: String) {
        guard pending.removeValue(forKey: key) != nil else { return }
        shown.remove(key)
        ToastController.shared.dismiss(key: "req-" + key)
    }

    /// All requests of one conversation that are no longer in `keep`.
    func resolveAll(prefix: String, except keep: Set<String>) {
        for key in pending.keys where key.hasPrefix(prefix) && !keep.contains(key) { resolved(key) }
    }

    private func revealWaiting() {
        for key in pending.keys where !shown.contains(key) { reveal(key) }
    }

    private func reveal(_ key: String) {
        guard let entry = pending[key], Settings.notifyAttention else { return }
        let request = entry.request
        if ToastController.isFront(request.appBundleIDs) { return }
        shown.insert(key)
        let content = ToastContent(key: "req-" + key, kind: .attention, provider: request.provider,
                                   title: request.headline, body: request.chat, life: .sticky,
                                   threadId: request.threadId, detail: request.detail, choices: request.choices, requestKey: key)
        if ToastController.shared.canShow && !QuietHours.active {
            ToastController.shared.reveal(content, force: true)
        } else {
            Notifier.shared.post(id: "req-\(key)", title: "\(request.provider.displayName) ждёт вас", body: request.headline,
                                 toast: content, record: false)
        }
    }

    /// The person pressed a button on the card.
    func answer(_ key: String, _ choice: RequestChoice) {
        guard let entry = pending[key] else { ToastController.shared.dismiss(key: "req-" + key); return }
        if choice.role == .open {
            entry.open()
            return
        }
        ToastController.shared.setBusy(key: "req-" + key, true)
        AgentActivity.trace("request \(key): answering «\(choice.title)»")
        Task {
            do {
                try await entry.respond(choice)
                self.resolved(key)
            } catch {
                ToastController.shared.setBusy(key: "req-" + key, false)
                ToastController.shared.setProblem(key: "req-" + key, "Не отправлено: \(error.localizedDescription) Откройте чат и ответьте там.")
            }
        }
    }
}
