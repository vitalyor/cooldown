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

    private struct Writing { var chat: ClaudeChat; var since: Date; var sawStart: Bool; var missed = 0 }

    private var timer: Timer?
    private var writing: [String: Writing] = [:]
    private var lastAnswer: [String: String] = [:]
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
            if let answer = look.answer { lastAnswer[key] = answer }
            writing[key]?.missed = 0
            if look.busy {
                if writing[key] == nil {
                    writing[key] = Writing(chat: look.chat, since: now, sawStart: !firstLook)
                    activity.started(.claude, key: key, title: look.chat.title, source: .window, at: now)
                } else {
                    activity.touch(.claude, key: key)
                }
            } else if let was = writing.removeValue(forKey: key) {
                activity.finished(.claude, key: key, title: look.chat.title, message: lastAnswer[key] ?? "",
                                  duration: was.sawStart ? now.timeIntervalSince(was.since) : nil, source: .window,
                                  opener: .claudeChat(look.chat), at: now, startUnknown: !was.sawStart)
            }
        }
        // A chat missing from one look is usually the window redrawing (as it does when an answer
        // completes); only after several looks in a row is it let go, without a card.
        for key in writing.keys where seen[key] == nil {
            writing[key]?.missed += 1
            AgentActivity.trace("miss \(key) \(writing[key]?.missed ?? 0)")
            if (writing[key]?.missed ?? 0) >= 5, let was = writing.removeValue(forKey: key) {
                // Out of sight but maybe still writing: the account can tell when it ends.
                ClaudeBackgroundChats.shared.track(was.chat, key: key, since: was.since)
            }
        }
        activity.replace(.claude, source: .window, with: Set(writing.keys))
        firstLook = false
        updatePrompts(seen)
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
                                       appBundleIDs: ["com.anthropic.claudefordesktop"],
                                       threadId: nil)
            RequestCenter.shared.post(request, open: { Task { await ClaudeSender.reveal(chat) } }) { choice in
                guard choice.id.hasPrefix("press:"), let pid = ClaudeSender.claudeApp?.processIdentifier else {
                    throw ResumeError.refused(L("Claude не открыт."))
                }
                let label = String(choice.id.dropFirst("press:".count))
                let pressed = await Task.detached(priority: .userInitiated) { Self.press(label, prompt: prompt, chat: chat, pid: pid) }.value
                guard pressed else { throw ResumeError.refused(L("Запрос в чате уже закрыт или выглядит иначе.")) }
                AgentActivity.trace("claude desktop prompt in \(chat.id): pressed «\(label)»")
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
            let values = ClaudeSender.values(element, [kAXRoleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute, kAXTitleAttribute])
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
            // Web buttons carry their words as a description or as a title.
            if role == "AXButton", let label = [values[1] as? String, values[3] as? String].compactMap({ $0 }).first(where: { !$0.isEmpty }),
               permissionRole(label) != nil {
                promptButtons.append((label, ClaudeSender.value(element, kAXParentAttribute).map { $0 as! AXUIElement }))
            }
            stack.append(contentsOf: ((values[2] as? [AXUIElement]) ?? []).reversed())
        }
        guard let chat else { return nil }
        // The message box: a few levels above the text field, holding the send/stop buttons.
        var composer = input
        for _ in 0..<4 {
            guard let current = composer, let parent = ClaudeSender.value(current, kAXParentAttribute) else { break }
            composer = (parent as! AXUIElement)
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
            if let up = ClaudeSender.value(container, kAXParentAttribute) { container = (up as! AXUIElement) }
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
        return Prompt(text: texts.joined(separator: "\n"), buttons: group.labels)
    }

    /// Presses the chosen button of a prompt in that chat, after finding the very same prompt.
    nonisolated static func press(_ label: String, prompt: Prompt, chat: ClaudeChat, pid: pid_t) -> Bool {
        let root = AXUIElementCreateApplication(pid)
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
                    buttons.append((text, element, ClaudeSender.value(element, kAXParentAttribute).map { $0 as! AXUIElement }))
                }
                stack.append(contentsOf: ((values[2] as? [AXUIElement]) ?? []).reversed())
            }
            guard page?.id == chat.id, Self.prompt(from: buttons.map { ($0.label, $0.parent) }) == prompt,
                  let target = buttons.first(where: { $0.label == label }) else { continue }
            return AXUIElementPerformAction(target.element, kAXPressAction as CFString) == .success
        }
        return false
    }
}


/// Chats that were being answered when they left the window (the person opened another chat).
/// With claude.ai connected, Cooldown looks once a minute at when those chats last changed:
/// a change after the answer began that then holds still means the answer is complete.
@MainActor
final class ClaudeBackgroundChats {
    static let shared = ClaudeBackgroundChats()

    private struct Item { var chat: ClaudeChat; var key: String; var since: Date; var seen: Date?; var steady = 0 }
    private var items: [String: Item] = [:]
    private var timer: Timer?

    func track(_ chat: ClaudeChat, key: String, since: Date) {
        guard ClaudeWeb.shared.isConnected, !chat.id.isEmpty else { return }
        AgentActivity.trace("follow by account \(key)")
        items[chat.id] = Item(chat: chat, key: key, since: since)
        if timer == nil {
            timer = Timer.every(60) { _ in
                Task { @MainActor in await ClaudeBackgroundChats.shared.check() }
            }
        }
    }

    private func check() async {
        let now = Date()
        items = items.filter { now.timeIntervalSince($0.value.since) < 30 * 60 }
        guard !items.isEmpty, let updates = try? await ClaudeWeb.shared.recentUpdates() else {
            if items.isEmpty { timer?.invalidate(); timer = nil }
            return
        }
        for (id, var item) in items {
            guard let changed = updates[id], changed > item.since.addingTimeInterval(5) else { continue }
            if item.seen == changed { item.steady += 1 } else { item.seen = changed; item.steady = 0 }
            items[id] = item
            guard item.steady >= 1 else { continue }
            items.removeValue(forKey: id)
            AgentActivity.shared.finished(.claude, key: item.key, title: item.chat.title, message: "",
                                          duration: changed.timeIntervalSince(item.since), source: .web,
                                          opener: .claudeChat(item.chat), at: changed)
        }
    }
}
