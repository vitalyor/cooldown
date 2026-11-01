import AppKit
import ApplicationServices

/// Watches Claude Desktop's windows the way a screen reader does: which chat each window shows,
/// whether Claude is writing an answer there (the composer then offers "Остановить ответ"), and
/// the first words of the latest answer. Nothing is sent and nothing goes over the network, so a
/// finished answer in Claude Desktop is announced like a finished Codex task.
///
/// Limits: only chats open in a window are seen. If the person switches to another chat while
/// one is still being written, that one is let go quietly rather than guessed about.
@MainActor
final class ClaudeDesktopWatcher {
    static let shared = ClaudeDesktopWatcher()

    private struct Writing {
        var chat: ClaudeChat
        var since: Date
        var sawStart: Bool
        var missed = 0
        /// When the stop button went away. Between tool calls and while a long command runs it
        /// disappears for a few seconds; only a quiet that lasts is the end of the answer.
        var quiet: Date?
    }

    /// How long the stop button must stay away before the answer counts as finished.
    private static let quietToFinish: TimeInterval = 25

    private var timer: Timer?
    private var writing: [String: Writing] = [:]
    /// Answers already on the page before the current turn began. The new answer's buttons
    /// appear only a moment after it ends, and a long chat shows only part of its messages, so
    /// a word-for-word match with one of these means the new answer was not found yet.
    private var earlier: [String: Set<String>] = [:]
    private var tick = 0
    /// The first look after Cooldown starts: answers already being written then started earlier.
    private var firstLook = true

    /// The composer's stop button while an answer is being written (the app's own words).
    nonisolated private static let stopLabels: Set<String> = ["Остановить ответ", "Stop response", "Stop generating", "Остановить генерацию"] // l10n:skip
    nonisolated private static let answerMarkers = ["Ответ Claude:", "Claude responded:", "Claude said:", "Claude’s response:"] // l10n:skip

    /// Buttons of a permission prompt in a chat (a connector or tool asking to run), in the
    /// app's own words. A group of two or more of them is a prompt.
    nonisolated static func permissionRole(_ label: String) -> RequestChoice.Role? {
        let text = label.lowercased().trimmingCharacters(in: .whitespaces)
        guard text.count < 40 else { return nil }
        if text.hasPrefix("разрешить") || text.hasPrefix("всегда разрешать") || text.hasPrefix("allow") || text.hasPrefix("always allow") // l10n:skip
            || text == "одобрить" || text == "approve" { return .allow } // l10n:skip
        if text == "запретить" || text == "отклонить" || text == "не разрешать" || text == "deny" || text == "don't allow" // l10n:skip
            || text == "decline" || text == "reject" { return .decline }
        return nil
    }

    /// A permission prompt seen in a chat: its words and its buttons.
    struct Prompt: Sendable, Equatable {
        var text: String
        var buttons: [String]
    }

    private var prompts: [String: Prompt] = [:]

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in ClaudeDesktopWatcher.shared.poll() }
        }
    }

    private func poll() {
        tick += 1
        guard Settings.watchClaudeWindow, ClaudeSender.hasPermission, !AppModel.shared.demoActive,
              let app = ClaudeSender.claudeApp else {
            if !writing.isEmpty { writing = [:]; AgentActivity.shared.replace(.claude, source: .window, with: []) }
            for (chat, prompt) in prompts { RequestCenter.shared.resolved(Self.promptKey(chat, prompt)) }
            prompts = [:]
            return
        }
        // Every 3 s while Claude is in front or writing; otherwise every 9 s is enough to notice.
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        guard front || !writing.isEmpty || tick % 3 == 0 else { return }

        // Reading the window is done off the main thread. Most looks are cheap: only the chat's
        // address and the message box are read; the whole window is walked when something
        // changed (a new chat, an answer just finished) or once a minute.
        guard !reading else { return }
        reading = true
        let pid = app.processIdentifier
        let writingKeys = Set(writing.keys)
        // While Claude writes, a fuller look every 9 s catches a permission prompt (it pauses
        // the answer); while one waits, every look, so an answer given in the app clears it.
        let full = tick % 20 == 0 || !prompts.isEmpty || (!writing.isEmpty && tick % 3 == 0)
        let cache = self.cache
        Task.detached(priority: .utility) {
            let looks = Self.read(pid: pid, cache: cache, writing: writingKeys, full: full)
            await MainActor.run {
                ClaudeDesktopWatcher.shared.reading = false
                ClaudeDesktopWatcher.shared.apply(looks)
            }
        }
    }

    private var reading = false
    private let cache = WindowCache()

    /// Elements found in the last full walk of each window: its page and its message box.
    final class WindowCache: @unchecked Sendable {
        let lock = NSLock()
        var entries: [CFHashCode: (page: AXUIElement, composer: AXUIElement)] = [:]
    }

    nonisolated private static func read(pid: pid_t, cache: WindowCache, writing: Set<String>, full: Bool) -> [Look] {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 2)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let windows = (ClaudeSender.value(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var looks: [Look] = []
        var seen = Set<CFHashCode>()
        for window in windows {
            let id = CFHash(window)
            seen.insert(id)
            cache.lock.lock()
            let known = cache.entries[id]
            cache.lock.unlock()
            if !full, let known, let chat = ClaudeSender.chat(of: known.page) {
                let busy = containsStop(known.composer)
                // An answer that just ended: read the whole window once for its first words.
                if busy || !writing.contains(key(chat)) {
                    looks.append(Look(chat: chat, busy: busy, answer: nil))
                    continue
                }
            }
            guard let walked = look(at: window) else { continue }
            if let page = walked.page, let composer = walked.composer {
                cache.lock.lock()
                cache.entries[id] = (page, composer)
                cache.lock.unlock()
            }
            looks.append(walked.look)
        }
        cache.lock.lock()
        cache.entries = cache.entries.filter { seen.contains($0.key) }
        cache.lock.unlock()
        return looks
    }

    /// The stop button lives in the message box: a few dozen elements instead of the window.
    nonisolated private static func containsStop(_ composer: AXUIElement) -> Bool {
        var stack = [composer]
        var visited = 0
        while let element = stack.popLast(), visited < 400 {
            visited += 1
            let values = ClaudeSender.values(element, [kAXRoleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute])
            if values[0] as? String == "AXButton", let label = values[1] as? String, stopLabels.contains(label) { return true }
            stack.append(contentsOf: (values[2] as? [AXUIElement]) ?? [])
        }
        return false
    }

    private func apply(_ looks: [Look]) {
        var seen: [String: Look] = [:]
        for look in looks {
            seen[Self.key(look.chat)] = look
            ClaudeChatList.shared.remember(look.chat)
            ClaudeSender.note(look.chat)
        }

        let now = Date()
        let activity = AgentActivity.shared
        for (key, look) in seen {
            if let answer = look.answer {
                if writing[key] == nil { earlier[key, default: []].insert(answer) }
            }
            writing[key]?.missed = 0
            if look.busy {
                if writing[key] == nil {
                    writing[key] = Writing(chat: look.chat, since: now, sawStart: !firstLook)
                    activity.started(.claude, key: key, title: look.chat.title, source: .window, at: now)
                } else {
                    if writing[key]?.quiet != nil { AgentActivity.trace("busy again \(key)") }
                    writing[key]?.quiet = nil
                    activity.touch(.claude, key: key)
                }
            } else if let was = writing[key] {
                if let quiet = was.quiet {
                    if now.timeIntervalSince(quiet) >= Self.quietToFinish {
                        writing.removeValue(forKey: key)
                        announceFinished(key: key, was: was, chat: look.chat, seenNow: look.answer, at: quiet)
                    }
                } else {
                    writing[key]?.quiet = now
                    AgentActivity.trace("quiet \(key)")
                }
            }
        }
        // A chat missing from one look is usually the window redrawing (as it does when an answer
        // completes); only after several looks in a row is it let go, without a card.
        for key in writing.keys where seen[key] == nil {
            writing[key]?.missed += 1
            AgentActivity.trace("miss \(key) \(writing[key]?.missed ?? 0)")
            if (writing[key]?.missed ?? 0) >= 5 {
                // Out of sight: the chat is let go quietly. The window is the only source for an
                // ordinary chat, so no completion card is invented for it.
                writing.removeValue(forKey: key)
            }
        }
        activity.replace(.claude, source: .window, with: Set(writing.keys))
        firstLook = false
        updatePrompts(seen)
    }

    /// The answer has ended. Its words are read again a moment later, once the app has drawn
    /// the message's buttons; words that were already on the page before the turn are an older
    /// answer, and the card then goes without a quote rather than with the wrong one.
    private func announceFinished(key: String, was: Writing, chat: ClaudeChat, seenNow: String?, at end: Date) {
        let cache = self.cache
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            var answer = seenNow
            if let pid = ClaudeSender.claudeApp?.processIdentifier {
                let looks = await Task.detached(priority: .utility) {
                    Self.read(pid: pid, cache: cache, writing: [], full: true)
                }.value
                if let fresh = looks.first(where: { Self.key($0.chat) == key })?.answer { answer = fresh }
            }
            var message = ""
            if let answer, !(earlier[key]?.contains(answer) ?? false) {
                message = answer
            } else {
                AgentActivity.trace("  \(key): latest answer not on screen yet, card without a quote")
            }
            if let answer { earlier[key, default: []].insert(answer) }
            AgentActivity.shared.finished(.claude, key: key, title: chat.title, message: message,
                                          duration: was.sawStart ? end.timeIntervalSince(was.since) : nil, source: .window,
                                          opener: .claudeChat(chat), at: end, startUnknown: !was.sawStart)
        }
    }

    private func updatePrompts(_ seen: [String: Look]) {
        for (key, look) in seen {
            let old = prompts[key]
            guard old != look.prompt else { continue }
            if let old { RequestCenter.shared.resolved(Self.promptKey(key, old)) }
            prompts[key] = look.prompt
            guard let prompt = look.prompt else { continue }
            let chat = look.chat
            let choices = prompt.buttons.map { label in
                RequestChoice(id: "press:" + label, title: label, role: Self.permissionRole(label) ?? .normal)
            } + [RequestChoice(id: "open", title: L("Открыть чат"), role: .open)]
            let lines = prompt.text.split(separator: "\n").map(String.init)
            let request = AgentRequest(key: Self.promptKey(key, prompt), provider: .claude, chat: "«\(chat.title)»",
                                       headline: lines.first ?? L("Claude просит разрешение"),
                                       detail: lines.dropFirst().joined(separator: "\n"), choices: choices,
                                       appBundleIDs: Presence.shared.away(after: 120).away ? [] : ["com.anthropic.claudefordesktop"],
                                       threadId: nil)
            RequestCenter.shared.post(request, open: { Task { await ClaudeSender.reveal(chat) } }) { choice in
                guard choice.id.hasPrefix("press:"), let pid = ClaudeSender.claudeApp?.processIdentifier else {
                    throw ResumeError.refused(L("Claude не открыт."))
                }
                let label = String(choice.id.dropFirst("press:".count))
                let result = await Task.detached(priority: .userInitiated) { await Self.press(label, prompt: prompt, chat: chat, pid: pid) }.value
                switch result {
                case .gone: throw ResumeError.refused(L("Запрос в чате уже закрыт или выглядит иначе."))
                case .ignored:
                    AgentActivity.trace("claude desktop prompt in \(chat.id): «\(label)» not taken")
                    throw ResumeError.refused(L("Claude не принял нажатие. Ответьте на запрос в чате."))
                case .done:
                    AgentActivity.trace("claude desktop prompt in \(chat.id): pressed «\(label)», prompt gone")
                }
            }
        }
        // Chats out of sight keep their prompt (they may still wait); none are guessed away.
    }

    nonisolated private static func promptKey(_ chat: String, _ prompt: Prompt) -> String {
        "claude-desktop|\(chat)|\(prompt.text.hashValue)|\(prompt.buttons.joined(separator: "/"))"
    }

    nonisolated private static func key(_ chat: ClaudeChat) -> String { "chat:" + (chat.id.isEmpty ? chat.title : chat.id) }

    struct Look: Sendable {
        var chat: ClaudeChat
        var busy: Bool
        var answer: String?
        var prompt: Prompt? = nil
    }

    /// One window, walked whole: its chat, whether an answer is being written, the latest
    /// answer's first words, and the page and message box for the cheap looks that follow.
    nonisolated private static func look(at window: AXUIElement) -> (look: Look, page: AXUIElement?, composer: AXUIElement?)? {
        var stack = [window]
        var visited = 0
        var chat: ClaudeChat?
        var page: AXUIElement?
        var input: AXUIElement?
        var busy = false
        var answer: String?
        var promptButtons: [(label: String, parent: AXUIElement?)] = []
        // Diagnostics (defaults write <bundle id> debugClaudeAX -bool YES): every button seen.
        let debug = UserDefaults.standard.bool(forKey: "debugClaudeAX")
        var allButtons: [String] = []
        while let element = stack.popLast(), visited < 8000 {
            visited += 1
            // One request for the three things needed from each element.
            let values = ClaudeSender.values(element, [kAXRoleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute, kAXTitleAttribute, kAXValueAttribute])
            let role = values[0] as? String
            if role == "AXWebArea", chat == nil, let found = ClaudeSender.chat(of: element) {
                chat = found
                page = element
            } else if role == "AXTextArea", input == nil {
                input = element
            } else if role == "AXButton", debug {
                allButtons.append("[\(values[1] as? String ?? "")] [\(values[3] as? String ?? "")]")
            }
            if role == "AXButton", let label = values[1] as? String, !label.isEmpty {
                if stopLabels.contains(label) { busy = true }
                // Message action buttons are labelled with the message's first words; the last
                // Claude one in reading order is the latest answer.
                for marker in answerMarkers {
                    if let range = label.range(of: marker) {
                        answer = String(label[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                        break
                    }
                }
            }
            // Newer versions of the app put the same words in a hidden heading of each message
            // instead of on its buttons.
            if role == "AXStaticText", let text = values[4] as? String {
                for marker in answerMarkers where text.hasPrefix(marker) {
                    answer = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            // Web buttons carry their words as a description or as a title.
            if role == "AXButton", let label = [values[1] as? String, values[3] as? String].compactMap({ $0 }).first(where: { !$0.isEmpty }),
               permissionRole(label) != nil {
                promptButtons.append((label, ClaudeSender.element(ClaudeSender.value(element, kAXParentAttribute))))
            }
            stack.append(contentsOf: ((values[2] as? [AXUIElement]) ?? []).reversed())
        }
        guard let chat else { return nil }
        // The message box: a few levels above the text field, holding the send/stop buttons.
        var composer = input
        for _ in 0..<4 {
            guard let current = composer, let parent = ClaudeSender.element(ClaudeSender.value(current, kAXParentAttribute)) else { break }
            composer = parent
        }
        let prompt = Self.prompt(from: promptButtons)
        if debug {
            let logs = Settings.appSupport.appendingPathComponent("logs", isDirectory: true)
            try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            try? (["chat \(chat.id) busy=\(busy) prompt=\(String(describing: prompt))"] + allButtons).joined(separator: "\n")
                .write(to: logs.appendingPathComponent("claude-window-buttons.txt"), atomically: true, encoding: .utf8)
        }
        // A prompt pauses the answer: the turn is not over while it waits.
        return (Look(chat: chat, busy: busy || prompt != nil, answer: answer, prompt: prompt), page, composer)
    }

    /// Two or more permission buttons side by side make a prompt; its words are the texts
    /// around them (a couple of levels up).
    nonisolated private static func prompt(from buttons: [(label: String, parent: AXUIElement?)]) -> Prompt? {
        var groups: [CFHashCode: (parent: AXUIElement, labels: [String])] = [:]
        for button in buttons {
            guard let parent = button.parent else { continue }
            groups[CFHash(parent), default: (parent, [])].labels.append(button.label)
        }
        guard let group = groups.values.first(where: { $0.labels.count >= 2 }) else { return nil }
        var container = group.parent
        for _ in 0..<2 {
            if let up = ClaudeSender.element(ClaudeSender.value(container, kAXParentAttribute)) { container = up }
        }
        var texts: [String] = []
        var stack = [container]
        var visited = 0
        while let element = stack.popLast(), visited < 300 {
            visited += 1
            let values = ClaudeSender.values(element, [kAXRoleAttribute, kAXValueAttribute, kAXChildrenAttribute])
            if values[0] as? String == "AXStaticText", let text = (values[1] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty, !group.labels.contains(text), texts.count < 6 {
                texts.append(text)
            }
            stack.append(contentsOf: ((values[2] as? [AXUIElement]) ?? []).reversed())
        }
        // The prompt's own title ("Claude хочет использовать … из …") sits a few levels higher
        // than its buttons, as a heading or a button that unfolds the details: it goes first,
        // so the card says what is asked rather than a side note.
        var top = container
        for _ in 0..<3 {
            if let up = ClaudeSender.element(ClaudeSender.value(top, kAXParentAttribute)) { top = up }
        }
        stack = [top]
        visited = 0
        while let element = stack.popLast(), visited < 600 {
            visited += 1
            let values = ClaudeSender.values(element, [kAXValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXChildrenAttribute])
            let words = [values[0] as? String, values[1] as? String, values[2] as? String].compactMap { $0 }
            if let title = words.first(where: { isPromptTitle($0) }) {
                let line = title.trimmingCharacters(in: .whitespacesAndNewlines)
                texts.removeAll { $0 == line }
                texts.insert(line, at: 0)
                break
            }
            stack.append(contentsOf: ((values[3] as? [AXUIElement]) ?? []).reversed())
        }
        // The tool's input can be long (a whole prompt): a card needs its start only.
        texts = texts.map { $0.count > 240 ? String($0.prefix(240)) + "…" : $0 }
        return Prompt(text: texts.joined(separator: "\n"), buttons: group.labels)
    }

    /// "Claude хочет использовать X из Y" / "Claude wants to use X from Y" and the like.
    nonisolated static func isPromptTitle(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard text.count < 200 else { return false }
        return ["хочет использовать", "хочет выполнить", "хочет открыть", "wants to use", "wants to run", "wants to access", "wants to open"] // l10n:skip
            .contains { lower.contains($0) }
    }

    /// Finds the chosen button of the very same prompt in that chat, or nil if it is gone.
    nonisolated private static func find(_ label: String, prompt: Prompt, chat: ClaudeChat, pid: pid_t) -> AXUIElement? {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 2)
        for window in (ClaudeSender.value(root, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            var stack = [window]
            var visited = 0
            var page: ClaudeChat?
            var buttons: [(label: String, element: AXUIElement, parent: AXUIElement?)] = []
            while let element = stack.popLast(), visited < 8000 {
                visited += 1
                let values = ClaudeSender.values(element, [kAXRoleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute, kAXTitleAttribute])
                if values[0] as? String == "AXWebArea", page == nil { page = ClaudeSender.chat(of: element) }
                if values[0] as? String == "AXButton",
                   let text = [values[1] as? String, values[3] as? String].compactMap({ $0 }).first(where: { !$0.isEmpty }),
                   permissionRole(text) != nil {
                    buttons.append((text, element, ClaudeSender.element(ClaudeSender.value(element, kAXParentAttribute))))
                }
                stack.append(contentsOf: ((values[2] as? [AXUIElement]) ?? []).reversed())
            }
            guard page?.id == chat.id, Self.prompt(from: buttons.map { ($0.label, $0.parent) }) == prompt,
                  let target = buttons.first(where: { $0.label == label }) else { continue }
            return target.element
        }
        return nil
    }

    enum PressResult { case done, gone, ignored }

    /// Presses the chosen button of a prompt in that chat and checks that Claude took it: the
    /// prompt must be gone afterwards. Claude's page sometimes reports an accessibility press as
    /// done and ignores it; then the button is clicked for real — Claude's window is brought up
    /// for a moment, and the pointer and the app you were in are put back. Called only from a
    /// button you pressed on a card.
    nonisolated static func press(_ label: String, prompt: Prompt, chat: ClaudeChat, pid: pid_t) async -> PressResult {
        guard let target = find(label, prompt: prompt, chat: chat, pid: pid) else { return .gone }
        AXUIElementPerformAction(target, kAXPressAction as CFString)
        if await gone(label, prompt: prompt, chat: chat, pid: pid) { return .done }
        AgentActivity.trace("claude desktop prompt in \(chat.id): press not taken, clicking «\(label)»")
        guard let again = find(label, prompt: prompt, chat: chat, pid: pid) else { return .done }
        await click(again, pid: pid)
        return await gone(label, prompt: prompt, chat: chat, pid: pid) ? .done : .ignored
    }

    /// Whether the prompt has left the chat within a couple of seconds.
    nonisolated private static func gone(_ label: String, prompt: Prompt, chat: ClaudeChat, pid: pid_t) async -> Bool {
        for _ in 0..<4 {
            try? await Task.sleep(for: .milliseconds(600))
            if find(label, prompt: prompt, chat: chat, pid: pid) == nil { return true }
        }
        return false
    }

    /// A real click in the middle of `element`, with Claude in front for that moment.
    nonisolated private static func click(_ element: AXUIElement, pid: pid_t) async {
        guard let position = ClaudeSender.value(element, kAXPositionAttribute), let size = ClaudeSender.value(element, kAXSizeAttribute) else { return }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        guard extent.width > 0, extent.height > 0 else { return }
        let point = CGPoint(x: origin.x + extent.width / 2, y: origin.y + extent.height / 2)
        let before = await MainActor.run { NSWorkspace.shared.frontmostApplication }
        let pointer = CGEvent(source: nil)?.location
        await MainActor.run { _ = NSRunningApplication(processIdentifier: pid)?.activate() }
        // The button's own window comes forward, so the click lands on it and not on something above.
        var window: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window) == .success, let window {
            AXUIElementPerformAction(window as! AXUIElement, kAXRaiseAction as CFString)
        }
        try? await Task.sleep(for: .milliseconds(350))
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(40))
        }
        try? await Task.sleep(for: .milliseconds(150))
        if let pointer { CGWarpMouseCursorPosition(pointer) }
        if let before, before.processIdentifier != pid {
            await MainActor.run { _ = before.activate() }
        }
    }
}
