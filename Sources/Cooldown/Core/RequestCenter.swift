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

/// One of several questions asked at once: answered one after another on the same card.
struct RequestStep: Equatable {
    var headline: String
    var detail: String?
    var choices: [RequestChoice]
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
    /// Several questions: the card walks through them, and the answer goes out after the last
    /// one as a single choice "answers:<option index per question>".
    var steps: [RequestStep] = []
}

/// Agents' requests as cards with the answers right on them, so nothing waits unnoticed while
/// the person is in another app. A card only ever sends the answer whose button was pressed;
/// closing it or ignoring it answers nothing. Before anything is sent, the source checks that
/// the very same request is still waiting.
@MainActor
final class RequestCenter: ObservableObject {
    static let shared = RequestCenter()
    /// Requests still waiting (the feed offers their cards again).
    @Published private(set) var waitingKeys = Set<String>()

    typealias Responder = (RequestChoice) async throws -> Void

    private var pending: [String: (request: AgentRequest, respond: Responder, open: () -> Void)] = [:]
    private var shown = Set<String>()
    /// Multi-question cards: which question is shown and the options picked so far.
    private var steps: [String: [Int]] = [:]
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
        let same = pending[request.key]?.request == request
        pending[request.key] = (request, respond, open)
        waitingKeys.insert(request.key)
        if isNew {
            AgentActivity.trace("request \(request.key): \(request.headline)")
            EventLog.shared.add(CooldownEvent(kind: .attention, provider: request.provider,
                                              title: L("%@ ждёт вас: %@", "\(request.provider.displayName)", "\(request.headline)"),
                                              body: request.chat, threadId: request.threadId, requestKey: request.key))
        }
        // Seen again unchanged (the source re-reads often): the card stays as it is.
        if same { return }
        reveal(request.key)
    }

    /// The request is gone (answered here or in the app, or the turn ended).
    func resolved(_ key: String) {
        guard pending.removeValue(forKey: key) != nil else { return }
        shown.remove(key)
        waitingKeys.remove(key)
        steps[key] = nil
        ToastController.shared.dismiss(key: "req-" + key)
    }

    /// All requests of one conversation that are no longer in `keep`.
    func resolveAll(prefix: String, except keep: Set<String>) {
        for key in pending.keys where key.hasPrefix(prefix) && !keep.contains(key) { resolved(key) }
    }

    private func revealWaiting() {
        for key in pending.keys where !shown.contains(key) { reveal(key) }
    }

    /// From the feed: the card again, wherever the person is.
    func showAgain(_ key: String) {
        shown.remove(key)
        reveal(key, force: true)
    }

    private func reveal(_ key: String, force: Bool = false) {
        guard let entry = pending[key], force || Settings.notifyAttention else { return }
        let request = entry.request
        if !force && ToastController.isFront(request.appBundleIDs) { return }
        shown.insert(key)
        let content = self.content(request)
        if ToastController.shared.canShow && !QuietHours.active {
            ToastController.shared.reveal(content, force: true)
        } else {
            Notifier.shared.post(id: "req-\(key)", title: L("%@ ждёт вас", "\(request.provider.displayName)"), body: request.headline,
                                 toast: content, record: false)
        }
    }

    private func content(_ request: AgentRequest) -> ToastContent {
        var headline = request.headline, detail = request.detail, choices = request.choices, body = request.chat
        if !request.steps.isEmpty {
            let index = min(steps[request.key]?.count ?? 0, request.steps.count - 1)
            let step = request.steps[index]
            headline = step.headline
            detail = step.detail
            choices = step.choices
            body += L(" · вопрос %@ из %@", "\(index + 1)", "\(request.steps.count)")
        }
        return ToastContent(key: "req-" + request.key, kind: .attention, provider: request.provider,
                            title: headline, body: body, life: .sticky,
                            threadId: request.threadId, detail: detail, choices: choices, requestKey: request.key)
    }

    /// The person pressed a button on the card.
    func answer(_ key: String, _ choice: RequestChoice) {
        guard let entry = pending[key] else { ToastController.shared.dismiss(key: "req-" + key); return }
        if choice.role == .open {
            entry.open()
            return
        }
        // Several questions: note this answer and show the next question on the same card.
        if !entry.request.steps.isEmpty, choice.id.hasPrefix("option:"), let option = Int(choice.id.dropFirst("option:".count)) {
            var picked = steps[key] ?? []
            picked.append(option)
            steps[key] = picked
            if picked.count < entry.request.steps.count {
                ToastController.shared.reveal(content(entry.request))
                return
            }
            let all = RequestChoice(id: "answers:" + picked.map(String.init).joined(separator: ","), title: "")
            return send(key, entry: entry, choice: all)
        }
        send(key, entry: entry, choice: choice)
    }

    private func send(_ key: String, entry: (request: AgentRequest, respond: Responder, open: () -> Void), choice: RequestChoice) {
        ToastController.shared.setBusy(key: "req-" + key, true)
        AgentActivity.trace("request \(key): answering «\(choice.title)»")
        Task {
            do {
                try await entry.respond(choice)
                self.resolved(key)
            } catch {
                if self.steps[key] != nil {
                    self.steps[key] = nil
                    ToastController.shared.reveal(self.content(entry.request))
                }
                ToastController.shared.setBusy(key: "req-" + key, false)
                ToastController.shared.setProblem(key: "req-" + key, L("Не отправлено: %@ Откройте чат и ответьте там.", "\(error.localizedDescription)"))
            }
        }
    }
}
