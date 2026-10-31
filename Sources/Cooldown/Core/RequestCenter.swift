import AppKit
import Foundation

/// One button of a request card.
struct RequestChoice: Equatable, Identifiable {
    /// `input`: a text field and "Отправить"; the answer arrives as "text:<what was typed>".
    enum Role: Equatable { case allow, normal, decline, open, input }
    var id: String
    var title: String
    var role: Role = .normal
    /// Shown only after "Ещё" (rarely needed, stronger choices).
    var extra = false
}

/// An answer to one question: a ready option (its index) or typed text.
enum RequestAnswer: Equatable, Sendable {
    case option(Int)
    case text(String)

    /// "option:2" or "text:…", as a pressed button or a sent field gives it.
    init?(choice id: String) {
        if id.hasPrefix("option:"), let index = Int(id.dropFirst("option:".count)) { self = .option(index) }
        else if id.hasPrefix("text:") { self = .text(String(id.dropFirst("text:".count))) }
        else { return nil }
    }

    var token: String {
        switch self {
        case .option(let index): return "o:\(index)"
        case .text(let text): return "t:" + text
        }
    }

    /// All answers of a card with several questions: "answers:" and a JSON list of tokens.
    static func encode(_ answers: [RequestAnswer]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: answers.map(\.token))) ?? Data("[]".utf8)
        return "answers:" + String(decoding: data, as: UTF8.self)
    }

    static func decode(_ id: String) -> [RequestAnswer]? {
        guard id.hasPrefix("answers:"),
              let list = (try? JSONSerialization.jsonObject(with: Data(id.dropFirst("answers:".count).utf8))) as? [String] else { return nil }
        let answers = list.compactMap { token -> RequestAnswer? in
            if token.hasPrefix("o:"), let index = Int(token.dropFirst(2)) { return .option(index) }
            if token.hasPrefix("t:") { return .text(String(token.dropFirst(2))) }
            return nil
        }
        return answers.count == list.count ? answers : nil
    }
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
    private var answering = Set<String>()
    /// Multi-question cards: which question is shown and the options picked so far.
    private var steps: [String: [RequestAnswer]] = [:]
    private var observer: NSObjectProtocol?

    init() {
        // Leaving the agent's app with a request still open: now is the moment for its card.
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.revealWaiting() }
        }
    }

    deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }

    func isPending(_ key: String) -> Bool { pending[key] != nil }
    func hasPending(prefix: String) -> Bool { pending.keys.contains { $0.hasPrefix(prefix) } }

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

    /// A made-up Codex permission request for the sample cards. It is not pending anywhere,
    /// so any of its buttons only closes it.
    static func exampleContent() -> ToastContent {
        ToastContent(key: "req-example", kind: .attention, provider: .codex,
                     title: L("Codex хочет выполнить команду"), body: L("Рефакторинг парсера"), life: .sticky,
                     threadId: nil, detail: "swift test --filter ParserTests", // l10n:skip
                     choices: [RequestChoice(id: "allow", title: L("Разрешить"), role: .allow),
                               RequestChoice(id: "session", title: L("На всю сессию"), role: .allow),
                               RequestChoice(id: "decline", title: L("Отклонить"), role: .decline),
                               RequestChoice(id: "open", title: L("Открыть чат"), role: .open)],
                     requestKey: "example")
    }

    /// The person pressed a button on the card.
    func answer(_ key: String, _ choice: RequestChoice) {
        guard !answering.contains(key) else { return }
        guard let entry = pending[key] else { ToastController.shared.dismiss(key: "req-" + key); return }
        if choice.role == .open {
            // The question is in front of you in the chat now: the card steps aside and stays
            // away (the feed still has it; it closes for good once the answer is seen).
            entry.open()
            shown.insert(key)
            steps[key] = nil
            ToastController.shared.dismiss(key: "req-" + key)
            return
        }
        // Several questions: note this answer and show the next question on the same card; all
        // answers go together after the last one, as the agent's own app sends them.
        if !entry.request.steps.isEmpty, let answer = RequestAnswer(choice: choice.id) {
            var picked = steps[key] ?? []
            picked.append(answer)
            steps[key] = picked
            if picked.count < entry.request.steps.count {
                ToastController.shared.reveal(content(entry.request))
                return
            }
            let all = RequestChoice(id: RequestAnswer.encode(picked), title: "")
            return send(key, entry: entry, choice: all)
        }
        send(key, entry: entry, choice: choice)
    }

    private func send(_ key: String, entry: (request: AgentRequest, respond: Responder, open: () -> Void), choice: RequestChoice) {
        guard answering.insert(key).inserted else { return }
        ToastController.shared.setBusy(key: "req-" + key, true)
        AgentActivity.trace("request \(key): answering")
        Task {
            defer { self.answering.remove(key) }
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
