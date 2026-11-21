import AppKit
import SwiftUI

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
        @Published var busy = false
        @Published var problem: String?
        @Published var showExtra = false
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
        // The phone decides for itself whether you are here: it gets every card at once, even one
        // the Mac holds back below because the agent's app is in front.
        PhoneLink.shared.forward(content)
        // Working in Codex or Claude right now? Wait a moment: if the person stays there, they have
        // seen it for themselves and the card is dropped; if they leave, it shows then.
        if Self.isFront(content.appBundleIDs) && !Settings.cardsWhenFront {
            // The newest content of the card waits; one timer per key shows it.
            let first = graceKeys[content.key] == nil
            graceKeys[content.key] = content
            guard first else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace) {
                let controller = ToastController.shared
                // Answered or closed meanwhile (in the agent's own window, say): nothing to show.
                guard let latest = controller.graceKeys.removeValue(forKey: content.key) else { return }
                if Self.isFront(latest.appBundleIDs) && latest.life != .sticky { return }
                if Self.isFront(latest.appBundleIDs) && Self.idleSeconds < Self.grace { return }
                controller.reveal(latest)
            }
            return
        }
        reveal(content)
    }

    static func isFront(_ ids: [String]) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return ids.contains(front)
    }

    /// Seconds since the last key press, click or mouse move by a person (not by an app).
    static var idleSeconds: Double { Presence.shared.idle }

    func isShowing(_ key: String) -> Bool {
        cards.contains { $0.content.key == key } || waiting.contains { $0.key == key }
    }

    /// Cards held back for a moment because their app is in front (see `show`).
    private var graceKeys: [String: ToastContent] = [:]

    func dismiss(key: String) {
        PhoneLink.shared.resolve(key)
        graceKeys[key] = nil
        waiting.removeAll { $0.key == key }
        if let card = cards.first(where: { $0.content.key == key }) { remove(card) }
        Notifier.withdraw(prefix: key)
    }

    func setBusy(key: String, _ busy: Bool) {
        cards.first { $0.content.key == key }?.model.busy = busy
    }

    func setProblem(key: String, _ text: String) {
        guard let card = cards.first(where: { $0.content.key == key }) else { return }
        card.model.problem = text
        DispatchQueue.main.async { self.resize(card) }
    }

    /// A card's content grew (more buttons, a problem line): fit the panel to it.
    func resize(_ card: Card) {
        guard let hosting = (card.panel.contentView?.subviews.first as? NSGlassEffectView)?.contentView else { return }
        let height = max(96, hosting.fittingSize.height)
        guard abs(card.panel.frame.height - height) > 1 else { return }
        var frame = card.panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        card.panel.setFrame(frame, display: true)
        relayout(animated: true)
    }

    func reveal(_ content: ToastContent) {
        PhoneLink.shared.forward(content)
        // Cards turned off, the screen locked or quiet hours: a system notification instead (none
        // in quiet hours; the feed and the morning summary have it).
        // Sample cards are asked for by hand: shown whatever the settings say.
        let sample = content.key.hasPrefix("demo-") || content.key == "req-example"
        guard sample || (canShow && !QuietHours.active) else {
            if !QuietHours.active { Notifier.shared.system(id: content.key, title: content.title, body: content.body) }
            return
        }
        if let card = cards.first(where: { $0.content.key == content.key }) {
            card.content = content
            card.model.content = content
            card.model.busy = false
            card.model.problem = nil
            DispatchQueue.main.async { ToastController.shared.resize(card) }
            startTimer(card)
            relayout(animated: true)
            return
        }
        if cards.count >= Self.maxVisible {
            // Make room by retiring the oldest card that leaves by itself; answers stay.
            if let oldest = cards.last(where: { if case .auto = $0.content.life { return true } else { return false } }) {
                remove(oldest)
            } else {
                // The same card again (a guard card rewrites its text often) replaces its place in line.
                if let index = waiting.firstIndex(where: { $0.key == content.key }) { waiting[index] = content } else { waiting.append(content) }
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
                             choose: { [weak card] choice in
                                 guard let card, let key = card.content.requestKey else { return }
                                 if choice.id == "__more" {
                                     card.model.showExtra = true
                                     DispatchQueue.main.async { ToastController.shared.resize(card) }
                                     return
                                 }
                                 RequestCenter.shared.answer(key, choice)
                             },
                             close: { [weak self, weak card] in
                                 guard let card else { return }
                                 PhoneLink.shared.resolve(card.content.key)
                                 self?.remove(card)
                             },
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
        // Only the Space the person is on, and not in a screen recording or share unless the person
        // allows it in Settings. A card may carry a prompt, a command or an agent's answer; it must
        // not appear on another Space. Over a full-screen Codex or Claude too: that is their Space.
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.sharingType = Self.sharing
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
                // Four redraws a second are enough for a countdown bar and much cheaper than ten.
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let card else { return }
                // Nobody at the Mac: keep the card until they are back, so it is not missed.
                if !card.model.paused && Self.idleSeconds < 60 { left -= 0.25 }
                card.model.remaining = max(0, left / seconds)
            }
            if let card {
                // Gone from the Mac by itself: gone from the phone too (its buttons, the badge).
                PhoneLink.shared.resolve(card.content.key)
                self?.remove(card)
            }
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

    private func perform(_ action: ToastAction, from card: Card) {
        PhoneLink.shared.resolve(card.content.key)
        remove(card)
        switch action {
        case .openPanel:
            StatusController.shared?.open(PanelPlace(tab: .limits), for: card.content.provider)
        case .open(let place):
            StatusController.shared?.open(place, for: card.content.provider)
        case .openSettings(let pane):
            SettingsWindow.shared.show(pane)
        case .openFeed:
            StatusController.shared?.open(to: .feed)
        case .remindBeforeReset(let provider, let reset):
            ResetReminder.set(provider, reset: reset)
        case .continueAfterReset(let opener):
            Task { await AgentActivity.continueAfterReset(opener) }
        case .openFile(let url):
            NSWorkspace.shared.open(url)
        case .guardExit(let choice, let key):
            RouteGuard.shared.answerExit(choice, key: key)
        case .guardPause:
            RouteGuard.shared.pause(3600)
        case .guardCheck:
            Task { await RouteGuard.shared.checkNow() }
        case .guardResume:
            RouteGuard.shared.pause(nil)
        case .restartAgent(let provider):
            Task {
                let text = await AgentRestart.shared.restart(provider, whenFree: true, from: "Mac")
                ToastController.shared.show(ToastContent(key: "restart-\(provider.rawValue)", kind: .info, provider: provider,
                                                         title: L("Перезапуск %@", provider.displayName), body: text, life: .auto(15)))
            }
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
                    ToastController.shared.show(ToastCatalog.failure(L("Не отправлено в «%@»", "\(chat.title)"), error.localizedDescription, provider: .claude))
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
                show(ToastContent(key: "demo-sent", kind: .info, provider: .claude, title: L("Пример · ничего не отправлено"),
                                  body: L("Сейчас Cooldown вывел бы Claude вперёд и отправил в открытый чат: «%@»", "\(ClaudeSender.text)")))
                return
            }
            Task {
                do { try await ClaudeSender.continueChat(ClaudeSender.pendingChat) } catch {
                    ToastController.shared.show(ToastCatalog.failure(L("Не отправлено"), error.localizedDescription, provider: .claude))
                }
            }
        }
    }

    static var screenLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    private static var sharing: NSWindow.SharingType { Settings.cardsInCapture ? .readOnly : .none }

    /// The setting changed: apply it to the cards already on screen too.
    func applySharing() {
        for card in cards { card.panel.sharingType = Self.sharing }
    }

    /// The sample tour is running (Settings shows "stop" then).
    @Published private(set) var showingExamples = false
    private var exampleSteps: [DispatchWorkItem] = []

    /// Stops the tour: the samples still to come are dropped, the ones on screen close.
    func stopExamples() {
        exampleSteps.forEach { $0.cancel() }
        exampleSteps = []
        showingExamples = false
        for card in cards where card.content.key.hasPrefix("demo-") || card.content.key == "req-example" { remove(card) }
        waiting.removeAll { $0.key.hasPrefix("demo-") || $0.key == "req-example" }
    }

    /// A short tour of the card types, one after another.
    func showExamples() {
        stopExamples()
        showingExamples = true
        let examples: [ToastContent] = [
            ToastCatalog.taskWaiting(.codex, title: L("Рефакторинг парсера"), until: Date().addingTimeInterval(7200)),
            ToastCatalog.taskResumed(.codex, title: L("Рефакторинг парсера")),
            ToastCatalog.taskFinished(.codex, title: L("Продумать структуру таблицы учёта"),
                                      detail: L("Готово: структура собрана, файл лежит в папке проекта.")),
            ToastCatalog.taskAttention(.codex, title: L("Рефакторинг парсера"), reason: L("Codex спрашивает разрешение выполнить команду.")),
            ToastCatalog.limitReset(.claude, demo: true),
        ]
        // Keys of their own ("demo-…"): samples never replace a real card, here or on the phone.
        func later(_ delay: Double, _ block: @escaping () -> Void) {
            let step = DispatchWorkItem(block: block)
            exampleSteps.append(step)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: step)
        }
        for (index, example) in examples.enumerated() {
            var sample = example
            sample.key = "demo-" + example.key
            let shown = sample
            later(Double(index) * 2.2) { ToastController.shared.show(shown) }
        }
        later(Double(examples.count) * 2.2) {
            ToastController.shared.reveal(RequestCenter.exampleContent())
            ToastController.shared.showingExamples = false
        }
    }
}

// MARK: The card

private struct ToastView: View {
    @ObservedObject var model: ToastController.CardModel
    let act: (ToastAction) -> Void
    let choose: (RequestChoice) -> Void
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
                            Text(L("ждёт вас"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(content.tint)
                        }
                        Spacer()
                        Button(action: close) {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                                .frame(width: 18, height: 18).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L("Закрыть"))
                        .accessibilityLabel(L("Закрыть"))
                    }
                    Text(content.title).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if !content.body.isEmpty {
                        Text(content.body).font(.callout).foregroundStyle(.secondary)
                            // A card that waits for an answer may list several things (a guard card does): room for them.
                            .lineLimit(content.life == .sticky ? 6 : 3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if content.requestKey != nil {
                        RequestBlock(model: model, choose: choose)
                    } else {
                    // Every label on one line; what does not fit goes to the next row.
                    FlowRow(spacing: 6) {
                        ForEach(Array(content.actions.enumerated()), id: \.offset) { index, action in
                            Button(action.title) { act(action) }
                                .buttonStyle(ToastButton(fill: index == 0 ? content.tint : .primary, prominent: index == 0))
                        }
                    }
                    .padding(.top, content.actions.isEmpty ? 0 : 6)
                    }
                }
            }
            .padding(16)
        }
        // On top of the bottom margin, so every card keeps the same one; its ends stay clear of the corners.
        .overlay(alignment: .bottom) {
            if case .auto = content.life {
                GeometryReader { geometry in
                    Capsule().fill(content.tint.opacity(0.55))
                        .frame(width: geometry.size.width * model.remaining, height: 2)
                        .animation(.linear(duration: 0.25), value: model.remaining)
                }
                .frame(height: 2)
                .padding(.horizontal, 26)
                .padding(.bottom, 6)
                .opacity(model.paused ? 0.3 : 1)
            }
        }
        .frame(width: ToastController.width, alignment: .leading)
        .background(alignment: .trailing) {
            RadialGradient(colors: [content.tint.opacity(0.28), .clear], center: .trailing, startRadius: 0, endRadius: 220)
        }
        .background(GlassVeil())
        .onHover(perform: hover)
    }
}

/// Pictures of sample cards, for checking the layout (`--render --card <name>`).
@MainActor
enum CardSamples {
    static func content(_ name: String) -> ToastContent? {
        let reset = Date().addingTimeInterval(2 * 3600 + 33 * 60)
        switch name {
        case "stopped": return ToastCatalog.limitStopped(.codex, name: "Проверить установку OpenWRT", reset: reset, opener: .codexThread("x")) // l10n:skip
        case "out": return ToastCatalog.limitOut(.codex, reset: reset)
        case "request": return RequestCenter.exampleContent()
        case "question":
            var c = RequestCenter.exampleContent()
            c.title = L("Codex спрашивает")
            c.detail = "Что должно открываться на ssh.example.com: SSH в терминале или веб-терминал в браузере?" // l10n:skip
            c.choices = [RequestChoice(id: "option:0", title: "SSH в обычном терминале"), RequestChoice(id: "option:1", title: "Терминал в браузере"), // l10n:skip
                         RequestChoice(id: "open", title: L("Ответить в чате"), role: .open)]
            return c
        case "text":
            var c = RequestCenter.exampleContent()
            c.title = L("Codex спрашивает")
            c.body += L(" · вопрос %@ из %@", "2", "2")
            c.detail = "Какой email разрешить для входа?" // l10n:skip
            c.choices = [RequestChoice(id: "input", title: L("Ваш ответ"), role: .input), RequestChoice(id: "open", title: L("Ответить в чате"), role: .open)]
            return c
        case "guard":
            // The VPN dropped for Antigravity's route (made-up, as in the pictures of the README).
            let country = Locale.current.localizedString(forRegionCode: "RU") ?? "RU"
            return ToastContent(key: "route-guard", kind: .warning, provider: .antigravity,
                                title: L("Маршрут к %@ идёт мимо VPN", "Antigravity"),
                                body: [L("%@ видит страну «%@».", "Antigravity", country), L("На паузе: %@.", "Antigravity"),
                                       L("%@ не отправит сообщения, пока маршрут не придёт в норму.", "Antigravity"),
                                       L("Продолжу сам, когда всё наладится.")].joined(separator: "\n"),
                                actions: [.guardPause, .guardCheck, .openSettings(.vpn)], life: .sticky)
        case "exit":
            let country = Locale.current.localizedString(forRegionCode: "NL") ?? "NL"
            return ToastContent(key: "route-exit", kind: .info, provider: nil,
                                title: L("Маршрут к %@ сменился", "Claude" + L(" и ") + "Codex"),
                                body: L("%@: %@ → %@, %@", "Claude", L("США-1"), "198.51.100.7", country) + "\n"
                                    + L("%@: %@ → %@, %@", "Codex", L("США-1"), "198.51.100.7", country) + "\n"
                                    + L("Работа не остановлена. Разрешить этот адрес?"),
                                actions: [.guardExit(.remember, "x"), .guardExit(.once, "x"), .guardExit(.refuse, "x")], life: .sticky)
        case "paused":
            return ToastContent(key: "route-paused", kind: .info, provider: nil, title: L("Защита VPN выключена"),
                                body: L("До %@. Пока она выключена, агенты работают без проверки маршрута.", Format.clock(Date().addingTimeInterval(3600))),
                                actions: [.guardResume], life: .sticky)
        default: return nil
        }
    }

    static func view(_ content: ToastContent) -> some View {
        ToastView(model: ToastController.CardModel(content), act: { _ in }, choose: { _ in }, close: {}, hover: { _ in })
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
    }
}

/// The asked-about thing and the answers. No answer is the default: only a click sends one.
private struct RequestBlock: View {
    @ObservedObject var model: ToastController.CardModel
    let choose: (RequestChoice) -> Void
    @State private var draft = ""
    @FocusState private var typing: Bool

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        choose(RequestChoice(id: "text:" + text, title: text))
    }

    var body: some View {
        let content = model.content
        let main = content.choices.filter { !$0.extra }
        let extra = content.choices.filter(\.extra)
        let options = main.filter { $0.role == .normal }
        VStack(alignment: .leading, spacing: 8) {
            if let detail = content.detail, !detail.isEmpty {
                // A command or files in code type; a question in ordinary words.
                let question = content.choices.contains { $0.role == .normal || $0.role == .input }
                Text(detail)
                    .font(question ? .system(size: 12.5) : .system(size: 11.5, design: .monospaced))
                    // Room for what RequestCenter.fullyVisible lets through with an "Allow".
                    .lineLimit(14)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
            }
            if let problem = model.problem {
                Text(problem).font(.caption).foregroundStyle(Theme.signal).fixedSize(horizontal: false, vertical: true)
            }
            if model.busy {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L("Отправляю…")).font(.caption).foregroundStyle(.secondary) }
            } else {
                // Answer options of a question: one per line, the whole text visible.
                ForEach(options) { choice in
                    Button { choose(choice) } label: {
                        Text(choice.title).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(ToastButton(fill: content.tint, prominent: false, wide: true))
                }
                // A question answered in words: the field right on the card.
                ForEach(main.filter { $0.role == .input }) { choice in
                    HStack(alignment: .bottom, spacing: 6) {
                        TextField(choice.title, text: $draft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .lineLimit(1...5)
                            .focused($typing)
                            .onSubmit(sendDraft)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
                        Button(L("Отправить"), action: sendDraft)
                            .buttonStyle(ToastButton(fill: content.tint, prominent: true))
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                    }
                }
                let buttons = main.filter { $0.role != .normal && $0.role != .input } + (model.showExtra ? extra : [])
                FlowRow(spacing: 6) {
                    ForEach(buttons) { choice in
                        Button(choice.title) { choose(choice) }
                            .buttonStyle(ToastButton(fill: choice.role == .decline ? Theme.signal : content.tint,
                                                     prominent: choice.role == .allow))
                    }
                    if !extra.isEmpty && !model.showExtra {
                        Button(L("Ещё…")) { choose(RequestChoice(id: "__more", title: "")) }
                            .buttonStyle(ToastButton(fill: .primary, prominent: false))
                    }
                }
            }
        }
        .padding(.top, 4)
        .onChange(of: content.detail) { draft = "" }
    }
}

/// Lays buttons out left to right, wrapping to the next line when the card is full.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for view in subviews {
            var size = view.sizeThatFits(.unspecified)
            if size.width > width { size = view.sizeThatFits(ProposedViewSize(width: width, height: nil)); size.width = width }
            if x > 0 && x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            var size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            // A label longer than the whole row keeps its line and is shortened with "…".
            if size.width > bounds.width { size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)); size.width = bounds.width }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// Buttons drawn by hand: the card never becomes the active window, and system buttons
/// would look disabled there.
private struct ToastButton: ButtonStyle {
    let fill: Color
    let prominent: Bool
    var wide = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            // Never broken inside a word: one line (wide answer buttons may wrap between words).
            .lineLimit(wide ? 3 : 1)
            .truncationMode(.tail)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, wide ? 7 : 5)
            .background(RoundedRectangle(cornerRadius: wide ? 10 : 20, style: .continuous)
                .fill(prominent ? fill.opacity(configuration.isPressed ? 0.7 : 0.9)
                                : fill.opacity(configuration.isPressed ? 0.2 : 0.12)))
            .contentShape(Rectangle())
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
