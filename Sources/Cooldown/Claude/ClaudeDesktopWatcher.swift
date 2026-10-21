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
    nonisolated private static let stopLabels: Set<String> = ["Остановить ответ", "Stop response", "Stop generating", "Остановить генерацию"]
    nonisolated private static let answerMarkers = ["Ответ Claude:", "Claude responded:", "Claude said:", "Claude’s response:"]

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
        let full = tick % 20 == 0
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
    }

    nonisolated private static func key(_ chat: ClaudeChat) -> String { "chat:" + (chat.id.isEmpty ? chat.title : chat.id) }

    struct Look: Sendable {
        var chat: ClaudeChat
        var busy: Bool
        var answer: String?
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
        while let element = stack.popLast(), visited < 8000 {
            visited += 1
            // One request for the three things needed from each element.
            let values = ClaudeSender.values(element, [kAXRoleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute])
            let role = values[0] as? String
            if role == "AXWebArea", chat == nil, let found = ClaudeSender.chat(of: element) {
                chat = found
                page = element
            } else if role == "AXTextArea", input == nil {
                input = element
            } else if role == "AXButton", let label = values[1] as? String, !label.isEmpty {
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
            stack.append(contentsOf: ((values[2] as? [AXUIElement]) ?? []).reversed())
        }
        guard let chat else { return nil }
        // The message box: a few levels above the text field, holding the send/stop buttons.
        var composer = input
        for _ in 0..<4 {
            guard let current = composer, let parent = ClaudeSender.value(current, kAXParentAttribute) else { break }
            composer = (parent as! AXUIElement)
        }
        return (Look(chat: chat, busy: busy, answer: answer), page, composer)
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
