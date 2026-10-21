import AppKit
import SwiftUI

// MARK: What a card says

/// What a card can offer besides closing.
enum ToastAction: Equatable {
    case openPanel
    case openClaude
    case openCodex
    case openCodexThread(String)
    case continueClaude(demo: Bool)
    case continueClaudeChat(ClaudeChat)
    case openClaudeChat(ClaudeChat)
    case continueAllClaude([ClaudeChat])
    case openSchedule
    case installUpdate
    case installRelease
    case openReleasePage
    case openFeed

    var title: String {
        switch self {
        case .openFeed: return "Посмотреть"
        case .openSchedule: return "Отложить задачу"
        case .installUpdate: return "Перезапустить"
        case .installRelease: return "Обновить"
        case .openReleasePage: return "Что нового"
        case .continueClaudeChat: return "Продолжить"
        case .continueAllClaude(let chats): return "Продолжить все (\(chats.count))"
        case .openPanel: return "Открыть Cooldown"
        case .openClaude, .openClaudeChat: return "Открыть Claude"
        case .openCodex, .openCodexThread: return "Открыть Codex"
        case .continueClaude: return "Продолжить"
        }
    }
}

struct ToastContent: Equatable {
    enum Kind { case reset, finished, attention, warning, info, waiting }

    /// How long a card stays: by itself for a while, or until the person answers it.
    enum Life: Equatable {
        case auto(Double)
        case sticky
    }

    /// Cards with the same key replace each other instead of piling up.
    var key: String
    var kind: Kind
    var provider: ProviderID?
    var title: String
    var body: String
    var actions: [ToastAction] = []
    var life: Life = .auto(8)
    var threadId: String? = nil

    /// The app the news is about: while it is in front, the person already sees what happened.
    var appBundleIDs: [String] {
        switch provider {
        case .codex: return ["com.openai.codex"]
        case .claude: return ["com.anthropic.claudefordesktop"]
        case nil: return []
        }
    }

    var tint: Color {
        switch kind {
        case .reset: return Theme.mint
        case .finished: return provider.map { Theme.tint(for: $0) } ?? Theme.cobalt
        case .attention: return Theme.amber
        case .warning: return Theme.signal
        case .waiting: return Theme.cobalt
        case .info: return Theme.cobalt
        }
    }

    var symbol: String {
        switch kind {
        case .reset: return "arrow.counterclockwise.circle.fill"
        case .finished: return "checkmark.circle.fill"
        case .attention: return "hand.raised.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .waiting: return "hourglass.circle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

/// The catalogue of cards Cooldown shows, in one place so the wording and behaviour stay consistent.
@MainActor
enum ToastCatalog {
    static func limitLow(_ provider: ProviderID, remaining: Double, reset: Date) -> ToastContent {
        let critical = remaining <= 5
        return ToastContent(key: "low-\(provider.rawValue)", kind: critical ? .warning : .attention, provider: provider,
                            title: "\(provider.displayName): осталось \(Format.percent(remaining))",
                            body: critical ? "Лимит на 5 часов почти кончился. Сброс в \(Format.time(reset))."
                                           : "Лимит на 5 часов заканчивается. Сброс в \(Format.time(reset)).",
                            actions: [.openPanel], life: .auto(critical ? 14 : 9))
    }

    static func limitReset(_ provider: ProviderID, demo: Bool = false) -> ToastContent {
        if provider == .claude {
            // Needs the person: Cooldown never writes into a Claude chat on its own.
            let target = ClaudeSender.pendingChat.map { "в чат «\($0.title)»" } ?? "в открытый чат Claude"
            return ToastContent(key: "reset-claude", kind: .reset, provider: .claude, title: "Лимит Claude восстановился",
                                body: "Можно продолжать. «Продолжить» отправит «\(ClaudeSender.text)» \(target).",
                                actions: [.continueClaude(demo: demo), .openClaude], life: .sticky)
        }
        return ToastContent(key: "reset-codex", kind: .reset, provider: .codex, title: "Лимит Codex восстановился",
                            body: "Окно на 5 часов сбросилось, можно работать дальше.", actions: [.openPanel], life: .auto(9))
    }

    static func taskWaiting(_ provider: ProviderID, title: String, until: Date?) -> ToastContent {
        ToastContent(key: "task-\(title)", kind: .waiting, provider: provider, title: "«\(title)» ждёт сброса",
                     body: until.map { "Лимит кончился. Cooldown продолжит задачу сам в \(Format.time($0))." }
                        ?? "Лимит кончился. Cooldown продолжит задачу сам сразу после сброса.",
                     actions: [.openPanel], life: .auto(9))
    }

    static func taskResumed(_ provider: ProviderID, title: String) -> ToastContent {
        ToastContent(key: "task-\(title)", kind: .reset, provider: provider, title: "«\(title)» продолжена",
                     body: "Лимит восстановился, Cooldown отправил «продолжай». Задача снова работает.",
                     actions: [provider == .codex ? .openCodex : .openPanel], life: .auto(9))
    }

    static func taskFinished(_ provider: ProviderID, title: String, detail: String, threadId: String? = nil) -> ToastContent {
        ToastContent(key: "task-\(title)", kind: .finished, provider: provider, title: "\(provider.displayName) закончил «\(title)»",
                     body: detail.isEmpty ? "Задача завершена, можно посмотреть результат." : detail,
                     actions: [threadId.map { .openCodexThread($0) } ?? (provider == .codex ? .openCodex : .openPanel)],
                     life: .auto(12), threadId: threadId)
    }

    static func taskAttention(_ provider: ProviderID, title: String, reason: String) -> ToastContent {
        ToastContent(key: "task-\(title)", kind: .attention, provider: provider, title: "«\(title)» ждёт вашего решения",
                     body: reason.isEmpty ? "Автопродолжение остановилось, нужно ваше участие." : reason,
                     actions: [provider == .codex ? .openCodex : .openPanel], life: .sticky)
    }

    static func taskBudget(_ provider: ProviderID, title: String) -> ToastContent {
        ToastContent(key: "task-\(title)", kind: .warning, provider: provider, title: "«\(title)»: попытки закончились",
                     body: "Задача несколько раз упиралась в лимит. Автопродолжение остановлено, загляните в диалог.",
                     actions: [.openPanel], life: .sticky)
    }

    static func failure(_ title: String, _ body: String, provider: ProviderID? = nil) -> ToastContent {
        ToastContent(key: "fail-\(title)", kind: .warning, provider: provider, title: title, body: body, life: .sticky)
    }
}

// MARK: Showing cards

/// Glass cards that slide out from under the menu bar icon, like a notch toast. They never take
/// the keyboard. Up to three stack under the icon; ones that need an answer stay until answered,
/// the rest leave by themselves (a thin line shows how long they have left; the pointer pauses it).
@MainActor
final class ToastController: ObservableObject {
    static let shared = ToastController()
    static let width: CGFloat = 370
    static let maxVisible = 3

    final class Card: Identifiable {
        let id = UUID()
        var content: ToastContent
        let panel: GlassPanel
        let model: CardModel
        var hideTask: Task<Void, Never>?
        init(content: ToastContent, panel: GlassPanel, model: CardModel) {
            self.content = content; self.panel = panel; self.model = model
        }
    }

    @MainActor
    final class CardModel: ObservableObject {
        @Published var content: ToastContent
        @Published var remaining: Double = 1
        @Published var paused = false
        init(_ content: ToastContent) { self.content = content }
    }

    private var cards: [Card] = []
    private var waiting: [ToastContent] = []
    var anchor: () -> NSRect? = { nil }

    /// Cards are shown only while someone is at the Mac; otherwise the system notification does the job.
    var canShow: Bool { !Self.screenLocked && Settings.toasts }

    /// How long news waits while its app is in front before Cooldown decides it was seen.
    static let grace: Double = 15

    func show(_ content: ToastContent) {
        AgentActivity.trace("card \(content.key) front=\(Self.isFront(content.appBundleIDs))")
        // Working in Codex or Claude right now? Wait a moment: if the person stays there, they have
        // seen it for themselves and the card is dropped; if they leave, it shows then.
        if Self.isFront(content.appBundleIDs) && !Settings.cardsWhenFront {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace) {
                let controller = ToastController.shared
                if Self.isFront(content.appBundleIDs) && content.life != .sticky { return }
                if Self.isFront(content.appBundleIDs) && Self.idleSeconds < Self.grace { return }
                controller.reveal(content)
            }
            return
        }
        reveal(content)
    }

    static func isFront(_ ids: [String]) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return ids.contains(front)
    }

    /// Seconds since the last key press, click or mouse move.
    static var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func reveal(_ content: ToastContent) {
        if let card = cards.first(where: { $0.content.key == content.key }) {
            card.content = content
            card.model.content = content
            startTimer(card)
            relayout(animated: true)
            return
        }
        if cards.count >= Self.maxVisible {
            // Make room by retiring the oldest card that leaves by itself; answers stay.
            if let oldest = cards.last(where: { if case .auto = $0.content.life { return true } else { return false } }) {
                remove(oldest)
            } else {
                waiting.append(content)
                return
            }
        }
        present(content)
    }

    private func present(_ content: ToastContent) {
        CardSound.play(for: content.kind)
        let model = CardModel(content)
        let panel = GlassPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let card = Card(content: content, panel: panel, model: model)
        let view = ToastView(model: model,
                             act: { [weak self, weak card] action in if let card { self?.perform(action, from: card) } },
                             close: { [weak self, weak card] in if let card { self?.remove(card) } },
                             hover: { [weak card] inside in card?.model.paused = inside })
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]
        let size = NSSize(width: Self.width, height: max(96, hosting.fittingSize.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]

        let glass = NSGlassEffectView(frame: hosting.frame)
        glass.cornerRadius = 24
        glass.contentView = hosting
        glass.autoresizingMask = [.width, .height]
        let container = NSView(frame: hosting.frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = 24
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.addSubview(glass)

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = container
        panel.setContentSize(size)

        cards.insert(card, at: 0)
        let target = frames()[0]
        panel.setFrame(target.offsetBy(dx: 0, dy: 14), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        relayout(animated: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
            panel.animator().alphaValue = 1
        } completionHandler: {
            Task { @MainActor in panel.invalidateShadow() }
        }
        NSSound(named: content.life == .sticky ? "Glass" : "Pop")?.play()
        startTimer(card)
    }

    /// Newest card right under the icon, older ones below it.
    private func frames() -> [NSRect] {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let anchorRect = anchor() ?? NSRect(x: visible.maxX - 200, y: visible.maxY, width: 24, height: 22)
        var x = anchorRect.midX - Self.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - Self.width - 8)
        var top = anchorRect.minY - 6
        return cards.map { card in
            let height = card.panel.frame.height > 0 ? card.panel.frame.height : 96
            let frame = NSRect(x: x, y: top - height, width: Self.width, height: height)
            top -= height + 8
            return frame
        }
    }

    private func relayout(animated: Bool) {
        let targets = frames()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.3 : 0
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
            for (card, frame) in zip(cards, targets) { card.panel.animator().setFrame(frame, display: true) }
        }
    }

    private func startTimer(_ card: Card) {
        card.hideTask?.cancel()
        guard case .auto(let seconds) = card.content.life else { card.model.remaining = 1; return }
        card.model.remaining = 1
        card.hideTask = Task { [weak self, weak card] in
            var left = seconds
            while left > 0 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let card else { return }
                // Nobody at the Mac: keep the card until they are back, so it is not missed.
                if !card.model.paused && Self.idleSeconds < 60 { left -= 0.1 }
                card.model.remaining = max(0, left / seconds)
            }
            if let card { self?.remove(card) }
        }
    }

    func remove(_ card: Card) {
        card.hideTask?.cancel()
        guard let index = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cards.remove(at: index)
        let panel = card.panel
        let frame = panel.frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
            panel.animator().setFrame(frame.offsetBy(dx: 0, dy: 10), display: true)
        } completionHandler: {
            Task { @MainActor in panel.orderOut(nil) }
        }
        relayout(animated: true)
        if !waiting.isEmpty, cards.count < Self.maxVisible { present(waiting.removeFirst()) }
    }

    func dismissAll() { cards.forEach(remove) }

    private func perform(_ action: ToastAction, from card: Card) {
        remove(card)
        switch action {
        case .openPanel:
            StatusController.shared?.open()
        case .openFeed:
            StatusController.shared?.open(to: .feed)
        case .installUpdate:
            UpdateWatch.install()
        case .installRelease:
            Task { await GitHubUpdater.shared.install() }
        case .openReleasePage:
            GitHubUpdater.shared.openReleasePage()
        case .openSchedule:
            AppModel.shared.selected = .codex
            StatusController.shared?.open(to: .schedule)
        case .continueClaudeChat(let chat):
            Task {
                do { try await ClaudeSender.continueChat(chat) } catch {
                    ToastController.shared.show(ToastCatalog.failure("Не отправлено в «\(chat.title)»", error.localizedDescription, provider: .claude))
                }
            }
        case .openClaude:
            ClaudeApp.open()
        case .openClaudeChat(let chat):
            Task { await ClaudeSender.reveal(chat) }
        case .continueAllClaude(let chats):
            Task { await ClaudeChatList.shared.continueAll(chats) }
        case .openCodex:
            CodexApp.open()
        case .openCodexThread(let id):
            CodexApp.open(thread: id)
        case .continueClaude(let demo):
            if demo {
                show(ToastContent(key: "demo-sent", kind: .info, provider: .claude, title: "Пример · ничего не отправлено",
                                  body: "Сейчас Cooldown вывел бы Claude вперёд и отправил в открытый чат: «\(ClaudeSender.text)»"))
                return
            }
            Task {
                do { try await ClaudeSender.continueChat(ClaudeSender.pendingChat) } catch {
                    ToastController.shared.show(ToastCatalog.failure("Не отправлено", error.localizedDescription, provider: .claude))
                }
            }
        }
    }

    static var screenLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// A short tour of the card types, one after another.
    func showExamples() {
        let examples: [ToastContent] = [
            ToastCatalog.taskWaiting(.codex, title: "Рефакторинг парсера", until: Date().addingTimeInterval(7200)),
            ToastCatalog.taskResumed(.codex, title: "Рефакторинг парсера"),
            ToastCatalog.taskFinished(.codex, title: "Продумать структуру таблицы учёта",
                                      detail: "Готово: структура собрана, файл лежит в /Volumes/T7/AI_ПМР."),
            ToastCatalog.taskAttention(.codex, title: "Рефакторинг парсера", reason: "Codex спрашивает разрешение выполнить команду."),
            ToastCatalog.limitReset(.claude, demo: true),
        ]
        for (index, example) in examples.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 2.2) { ToastController.shared.show(example) }
        }
    }
}

// MARK: The card

private struct ToastView: View {
    @ObservedObject var model: ToastController.CardModel
    let act: (ToastAction) -> Void
    let close: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        let content = model.content
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(content.tint.opacity(0.18)).frame(width: 40, height: 40)
                    Image(systemName: content.symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(content.tint)
                        .symbolEffect(.bounce, options: .nonRepeating)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if let provider = content.provider {
                            Circle().fill(Theme.tint(for: provider)).frame(width: 6, height: 6)
                            Text(provider.displayName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        if content.life == .sticky {
                            Label("ждёт вас", systemImage: "pin.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(content.tint)
                        }
                        Spacer()
                        Button(action: close) {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                                .frame(width: 18, height: 18).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Text(content.title).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(content.body).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        ForEach(Array(content.actions.enumerated()), id: \.offset) { index, action in
                            Button(action.title) { act(action) }
                                .buttonStyle(ToastButton(fill: index == 0 ? content.tint : .primary, prominent: index == 0))
                        }
                        Button("OK", action: close).buttonStyle(ToastButton(fill: .primary, prominent: false))
                    }
                    .padding(.top, 4)
                }
            }
            .padding(14)
            if case .auto = content.life {
                GeometryReader { geometry in
                    Capsule().fill(content.tint.opacity(0.55))
                        .frame(width: geometry.size.width * model.remaining, height: 2)
                        .animation(.linear(duration: 0.1), value: model.remaining)
                }
                .frame(height: 2)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
                .opacity(model.paused ? 0.3 : 1)
            }
        }
        .frame(width: ToastController.width, alignment: .leading)
        .background(alignment: .trailing) {
            RadialGradient(colors: [content.tint.opacity(0.28), .clear], center: .trailing, startRadius: 0, endRadius: 220)
        }
        .onHover(perform: hover)
    }
}

/// Buttons drawn by hand: the card never becomes the active window, and system buttons
/// would look disabled there.
private struct ToastButton: ButtonStyle {
    let fill: Color
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(prominent ? fill.opacity(configuration.isPressed ? 0.7 : 0.9)
                                                 : fill.opacity(configuration.isPressed ? 0.2 : 0.12)))
            .contentShape(Capsule())
    }
}


/// A short system sound per kind of card, each one chosen in Settings (all off by default).
enum CardSound {
    static func play(for kind: ToastContent.Kind) {
        let name: String?
        switch kind {
        case .finished: name = Settings.soundFinished ? "Glass" : nil
        case .attention, .warning: name = Settings.soundAttention ? "Ping" : nil
        case .reset: name = Settings.soundReset ? "Hero" : nil
        default: name = nil
        }
        if let name { NSSound(named: NSSound.Name(name))?.play() }
    }
}
