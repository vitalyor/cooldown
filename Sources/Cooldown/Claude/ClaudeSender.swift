import AppKit
import ApplicationServices

/// A Claude Desktop conversation, as its window reports it.
struct ClaudeChat: Codable, Equatable, Sendable {
    var id: String          // the uuid in claude.ai/chat/<id>; empty when only the title is known yet
    var title: String
    var seen: Date = Date()

    /// The same chat: by id when both have one, otherwise by title.
    func matches(_ other: ClaudeChat?) -> Bool {
        guard let other else { return false }
        if !id.isEmpty && !other.id.isEmpty { return id == other.id }
        return title == other.title
    }
}

/// Sends one message into a Claude Desktop chat, and only when the person presses "Продолжить"
/// (in a card, a notification or in Cooldown). It reads Claude's window through Accessibility —
/// the same structured view VoiceOver uses — so it knows which chat is open, can open the chat
/// the limit ran out in, and checks it is really there before typing.
@MainActor
enum ClaudeSender {
    static let defaultText = L("Продолжай с того места, где остановился.")

    enum SendError: LocalizedError {
        case noPermission, notRunning, notFront, noInput, chatNotOpened(String)
        case inputNotEmpty, notConfirmed, busy, notStopped(String)

        var errorDescription: String? {
            switch self {
            case .noPermission:
                return L("Нужно разрешение «Универсальный доступ» для Cooldown. Откроются Системные настройки: включите Cooldown и нажмите «Продолжить» ещё раз.")
            case .notRunning: return L("Claude не открылся.")
            case .notFront: return L("Окно Claude не вышло на передний план, сообщение не отправлено.")
            case .noInput: return L("Не нашлось поле ввода в окне Claude. Сообщение не отправлено.")
            case .chatNotOpened(let title): return L("Не получилось открыть чат «%@». Сообщение не отправлено — откройте его и нажмите ещё раз.", "\(title)")
            case .inputNotEmpty: return L("В поле ввода Claude уже есть текст. Сообщение не отправлено, чтобы его не потерять.")
            case .notConfirmed: return L("Не удалось подтвердить, что Claude принял сообщение. Проверьте чат — повторно оно не отправится.")
            case .busy: return L("Cooldown уже отправляет сообщение в Claude. Дождитесь конца и повторите.")
            case .notStopped(let title): return L("«%@» не был остановлен лимитом — ответ закончился сам. Продолжать не стал.", "\(title)")
            }
        }
    }

    static var hasPermission: Bool { AXIsProcessTrusted() }
    /// One message at a time: two callers must never type into the same composer.
    private static var sending = false

    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static var text: String {
        let saved = UserDefaults.standard.string(forKey: SettingsKey.claudeContinueText) ?? ""
        return saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultText : saved
    }

    // MARK: Which chat

    /// The chat the Claude limit ran out in: the one to continue.
    static var pendingChat: ClaudeChat? {
        get {
            guard let data = UserDefaults.standard.data(forKey: "claudePendingChat"),
                  let chat = try? JSONDecoder().decode(ClaudeChat.self, from: data) else { return nil }
            // Remembered until the reset it waits for and half a day after (a sticky card may be
            // pressed in the morning), never for days beyond it.
            let until = max(chat.seen.addingTimeInterval(8 * 3600), (Settings.pendingReset(.claude) ?? .distantPast).addingTimeInterval(12 * 3600))
            return Date() < until ? chat : nil
        }
        set {
            UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "claudePendingChat")
        }
    }

    /// The chat that was open the last time Claude was looked at.
    private(set) static var lastChat: ClaudeChat?

    /// The window watcher saw this chat open.
    static func note(_ chat: ClaudeChat) { lastChat = chat }

    /// The same observation, with the window walk off the main thread.
    static func observeOffMain() async -> ClaudeChat? {
        guard hasPermission, let app = claudeApp, let window = window(of: app) else { return nil }
        let handle = AXHandle(window)
        let looked = await Task.detached(priority: .userInitiated) { currentChat(in: handle.value) }.value
        guard let chat = looked else { return nil }
        lastChat = chat
        ClaudeChatList.shared.learn(chat)
        return chat
    }

    /// Called when the Claude limit runs out: the chat it ran out in (`known`, when the stop names
    /// it), else the chat in use in Claude Desktop. The window walk is asynchronous, so the caller
    /// never blocks the main thread on AX.
    static func rememberChatForReset(_ known: ClaudeChat? = nil) {
        if var known {
            known.seen = Date()
            pendingChat = known
            ClaudeChatList.shared.add(known, automatic: true)
            return
        }
        // The chat seen lately is an immediate fallback ("lately": in use, not one from hours ago);
        // the fresh AX look may update it a moment later.
        if let chat = lastChat, Date().timeIntervalSince(chat.seen) < 15 * 60 {
            pendingChat = chat
            ClaudeChatList.shared.add(chat, automatic: true)
        }
        Task { @MainActor in
            if let chat = await observeOffMain(), Date().timeIntervalSince(chat.seen) < 3 * 3600 {
                pendingChat = chat
                ClaudeChatList.shared.add(chat, automatic: true)
            }
        }
    }

    /// Shows a chat without sending anything: by its address when known, otherwise through
    /// the sidebar; falls back to just bringing Claude forward.
    static func reveal(_ chat: ClaudeChat) async {
        if !chat.id.isEmpty, let url = URL(string: "claude://claude.ai/chat/\(chat.id)") {
            NSWorkspace.shared.open(url)
            return
        }
        ClaudeApp.open()
        guard hasPermission else { return }
        for _ in 0..<20 {
            if let app = claudeApp, app.isFinishedLaunching, window(of: app) != nil {
                try? await open(chat, app: app)
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    // MARK: Sending

    /// Brings Claude forward, opens `chat` (if given and not open yet), checks it is open,
    /// puts the text into its input and presses Return.
    /// `onlyIfStopped` (the automatic path): continue only a chat that the limit really stopped —
    /// Claude shows its own notice and "Повторить попытку" there. Claude's own button is pressed
    /// when it is there (exactly what the person would do); otherwise the message is typed.
    static func continueChat(_ chat: ClaudeChat? = nil, promptForPermission: Bool = true, onlyIfStopped: Bool = false) async throws {
        try await send(text, to: chat, promptForPermission: promptForPermission, retryIfStopped: true, onlyIfStopped: onlyIfStopped)
    }

    /// Claude's own words under an answer the limit cut off, and its button to try again.
    /// Claude's own sentence under a cut-off answer (not words a chat may contain about limits).
    nonisolated static let limitNotices = ["Остановлено из-за лимита", "Stopped due to usage limit", "Stopped because of usage limit"] // l10n:skip
    /// Its button right below that sentence. Not "Повторить"/"Retry": those regenerate an answer.
    nonisolated static let retryLabels: Set<String> = ["Повторить попытку", "Try again"] // l10n:skip

    /// Looks at the end of the open chat: was it stopped by the limit, and Claude's retry button.
    nonisolated static func limitStop(in window: AXUIElement) -> (stopped: Bool, retry: AXUIElement?) {
        var stack = [window]
        var visited = 0
        var notice = false
        var noticeAt = -1
        var textsAfter = 0
        var retry: AXUIElement?
        while let element = stack.popLast(), visited < 8000 {
            visited += 1
            let values = Self.values(element, [kAXRoleAttribute, kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute])
            let role = values[0] as? String
            let words = [values[1], values[2], values[3]].compactMap { $0 as? String }
            if role == "AXStaticText", words.contains(where: { w in w.count < 200 && limitNotices.contains { w.hasPrefix($0) } }) {
                notice = true
                noticeAt = visited
                textsAfter = 0
                retry = nil   // a later notice is the one that counts
            } else if role == "AXStaticText", noticeAt >= 0 {
                textsAfter += 1
            }
            // The button that belongs to the notice: right after it, in page order.
            if role == "AXButton", noticeAt >= 0, visited - noticeAt < 40,
               words.contains(where: { retryLabels.contains($0.trimmingCharacters(in: .whitespaces)) }) {
                retry = element
            }
            stack.append(contentsOf: ((values[4] as? [AXUIElement]) ?? []).reversed())
        }
        // Only a notice at the end of the chat: an old one above a later answer says nothing now.
        let last = notice && textsAfter < 15
        return (last, last ? retry : nil)
    }

    /// The same for any message ("Ответить" from the phone).
    /// With `promptForPermission` false (the automatic path) a missing permission simply fails;
    /// nothing pops up while the person is away.
    static func send(_ message: String, to chat: ClaudeChat?, promptForPermission: Bool = true,
                     retryIfStopped: Bool = false, onlyIfStopped: Bool = false) async throws {
        guard !sending else { throw SendError.busy }
        try RouteGuard.check(.claude)
        sending = true
        defer { sending = false }
        guard hasPermission else {
            if promptForPermission { requestPermission() }
            throw SendError.noPermission
        }
        ClaudeApp.open()
        var app: NSRunningApplication?
        for _ in 0..<40 {
            app = claudeApp
            if let app, app.isFinishedLaunching, app.isActive { break }
            app?.activate()
            try await Task.sleep(for: .milliseconds(150))
        }
        guard let app else { throw SendError.notRunning }
        guard app.isActive else { throw SendError.notFront }

        var window: AXUIElement?
        for _ in 0..<20 {
            window = Self.window(of: app)
            if window != nil { break }
            try await Task.sleep(for: .milliseconds(150))
        }
        guard var window else { throw SendError.noInput }

        if let chat, !chat.matches(await currentChatOffMain(window)) {
            try await open(chat, app: app)
            window = Self.window(of: app) ?? window
            guard chat.matches(await currentChatOffMain(window)) else { throw SendError.chatNotOpened(chat.title) }
        }

        if retryIfStopped {
            // Give the chat a moment to draw its last answer, then look at how it ended.
            try await Task.sleep(for: .milliseconds(600))
            let current = Self.window(of: app) ?? window
            let stop = await Task.detached { Self.limitStop(in: current) }.value
            if onlyIfStopped && !stop.stopped {
                throw SendError.notStopped(chat?.title ?? L("Чат Claude"))
            }
            if let retry = stop.retry {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { throw SendError.notFront }
                guard AXUIElementPerformAction(retry, kAXPressAction as CFString) == .success else { throw SendError.notConfirmed }
                // Claude starts answering again: the notice goes and the stop button appears.
                for _ in 0..<30 {
                    try await Task.sleep(for: .milliseconds(200))
                    let now = Self.window(of: app) ?? current
                    let after = await Task.detached { Self.limitStop(in: now) }.value
                    if !after.stopped {
                        if let chat {
                            if pendingChat?.matches(chat) == true { pendingChat = nil }
                            if let open = await currentChatOffMain(Self.window(of: app) ?? current) { ClaudeChatList.shared.sent(to: chat, now: open) }
                        }
                        return
                    }
                }
                throw SendError.notConfirmed
            }
        }

        var input: AXUIElement?
        for _ in 0..<20 {
            // The composer walk is a few thousand AX elements; keep it off the main thread.
            input = await findInputOffMain(Self.window(of: app) ?? window)
            if input != nil { break }
            try await Task.sleep(for: .milliseconds(150))
        }
        guard let input else { throw SendError.noInput }
        try requireEmptyInput(inputText(input))
        guard AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
            throw SendError.noInput
        }
        try await Task.sleep(for: .milliseconds(200))

        if let chat, !chat.matches(await currentChatOffMain(Self.window(of: app) ?? window)) { throw SendError.chatNotOpened(chat.title) }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { throw SendError.notFront }
        try requireEmptyInput(inputText(input))
        type(message, to: app.processIdentifier)
        try await Task.sleep(for: .milliseconds(300))
        if let chat, !chat.matches(await currentChatOffMain(Self.window(of: app) ?? window)) { throw SendError.chatNotOpened(chat.title) }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { throw SendError.notFront }
        try requireTypedInput(inputText(input), message: message)
        press(keyCode: 36, to: app.processIdentifier) // Return sends in Claude
        try await confirmSent(readInput: { inputText(input) }, isFront: {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        })
        if let chat {
            if pendingChat?.matches(chat) == true { pendingChat = nil }
            // Learn the chat's id now that it is open, so next time it is found even if renamed.
            if let open = await currentChatOffMain(Self.window(of: app) ?? window) { ClaudeChatList.shared.sent(to: chat, now: open) }
        }
    }

    static func requireEmptyInput(_ text: String?) throws {
        guard let text else { throw SendError.noInput }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SendError.inputNotEmpty }
    }

    static func requireTypedInput(_ text: String?, message: String) throws {
        guard text == message else { throw SendError.notConfirmed }
    }

    /// Reads what is in the message box, if Accessibility exposes it. An Electron contenteditable
    /// may report nothing; then the caller cannot check for a draft, and neither can it confirm.
    private static func inputText(_ input: AXUIElement) -> String? {
        guard let raw = value(input, kAXValueAttribute) else { return nil }
        if let text = raw as? String { return text }
        if let text = raw as? NSAttributedString { return text.string }
        return nil
    }

    /// Claude clears the message box after accepting a message. Wait a few seconds for that; if
    /// the text is still there, do not claim success and do not clear the pending chat.
    static func confirmSent(readInput: () -> String?, isFront: () -> Bool) async throws {
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(150))
            guard isFront() else { throw SendError.notConfirmed }
            guard let current = readInput() else {
                // The element disappeared (the page redrew) or this Claude build does not expose
                // its value. We cannot tell whether Return sent the message; do not claim it did.
                throw SendError.notConfirmed
            }
            let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return }
        }
        throw SendError.notConfirmed
    }

    /// Opens a chat: its button in Claude's sidebar if it is listed, otherwise Claude's own link.
    /// Opens a chat the way a person would: its button in the sidebar; if it is not listed there,
    /// the full list of chats ("Показать все" under Недавние); and by its link when the id is known.
    private static func open(_ chat: ClaudeChat, app: NSRunningApplication) async throws {
        func waitOpen() async -> Bool {
            for _ in 0..<25 {
                try? await Task.sleep(for: .milliseconds(150))
                if let window = window(of: app), chat.matches(await currentChatOffMain(window)) { return true }
            }
            return false
        }
        // The chat's own address works wherever it sits: in a project, or far down the list.
        if !chat.id.isEmpty, let url = URL(string: "claude://claude.ai/chat/\(chat.id)") {
            NSWorkspace.shared.open(url)
            if await waitOpen() { return }
        }
        if let window = window(of: app), let button = sidebarButton(titled: chat.title, in: window) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            if await waitOpen() { return }
        }
        if let window = window(of: app), let all = button(described: "Показать все", in: window, last: true) { // l10n:skip
            AXUIElementPerformAction(all, kAXPressAction as CFString)
            for _ in 0..<15 {
                try await Task.sleep(for: .milliseconds(200))
                if let window = Self.window(of: app), let button = sidebarButton(titled: chat.title, in: window, anyRole: true) {
                    AXUIElementPerformAction(button, kAXPressAction as CFString)
                    if await waitOpen() { return }
                    break
                }
            }
        }
    }

    /// Chat titles listed in Claude's sidebar (pinned, projects and recent), in order.
    static func sidebarTitles() -> [String] {
        guard hasPermission, let app = claudeApp, let window = window(of: app) else { return [] }
        return sidebarTitles(in: window)
    }

    /// The same walk, off the main thread; used by the picker.
    static func sidebarTitlesOffMain() async -> [String] {
        guard hasPermission, let app = claudeApp, let window = window(of: app) else { return [] }
        let handle = AXHandle(window)
        return await Task.detached(priority: .userInitiated) { sidebarTitles(in: handle.value) }.value
    }

    nonisolated private static func sidebarTitles(in window: AXUIElement) -> [String] {
        let navigation: Set<String> = ["Поиск", "Новое", "Проекты", "Артефакты", "Запланированные задачи", "Персонализация", // l10n:skip
                                       "Закрепленные", "Недавние", "Показать все", "Еще", "Ещё", "Search", "New chat", "Projects", // l10n:skip
                                       "Artifacts", "Recents", "Starred", "Show all", "More"]
        var titles: [String] = []
        var stack = [window]
        var visited = 0
        while let element = stack.popLast(), visited < 5000 {
            visited += 1
            if value(element, kAXRoleAttribute) as? String == "AXButton",
               let title = value(element, kAXTitleAttribute) as? String, !title.isEmpty, !navigation.contains(title),
               labelled(element, title),
               !titles.contains(title) {
                titles.append(title)
            }
            stack.append(contentsOf: children(element).reversed())
        }
        return titles
    }

    // MARK: Reading Claude's window

    /// Is there unsent text in the open chat's message box? nil when it cannot be read.
    static func draftInOpenChat() async -> Bool? {
        guard hasPermission, let app = claudeApp, let window = window(of: app) else { return nil }
        guard let input = await findInputOffMain(window), let text = inputText(input) else { return nil }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static var claudeApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeApp.bundleID).first
    }

    static func window(of app: NSRunningApplication) -> AXUIElement? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 2)
        // Electron builds its page tree only when an assistive app asks for it.
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let focused = element(value(root, kAXFocusedWindowAttribute)) { return focused }
        if let windows = value(root, kAXWindowsAttribute) as? [AXUIElement] { return windows.first }
        return nil
    }

    /// An Accessibility element from a loosely typed attribute. `as?` is not allowed for Core
    /// Foundation types (the compiler calls it always-true), so the type is checked explicitly.
    nonisolated static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    nonisolated static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    /// Sidebar chat rows carry their title as text a level or two down (Claude wraps it in a group).
    nonisolated private static func labelled(_ element: AXUIElement, _ title: String, depth: Int = 3) -> Bool {
        guard depth > 0 else { return false }
        return children(element).contains { child in
            value(child, kAXValueAttribute) as? String == title || labelled(child, title, depth: depth - 1)
        }
    }

    /// Several attributes in one request (one round trip to the app instead of one each).
    nonisolated static func values(_ element: AXUIElement, _ attributes: [String]) -> [Any?] {
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &result) == .success,
              let array = result as? [Any] else { return Array(repeating: nil, count: attributes.count) }
        return attributes.indices.map { index -> Any? in
            guard index < array.count else { return nil }
            let value = array[index] as AnyObject
            // Missing attributes come back as an AXValue holding an error.
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
            return array[index]
        }
    }

    nonisolated static func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private nonisolated static func currentChatOffMain(_ window: AXUIElement) async -> ClaudeChat? {
        let handle = AXHandle(window)
        return await Task.detached(priority: .userInitiated) { currentChat(in: handle.value) }.value
    }

    /// The page area carries the chat's address (claude.ai/chat/<id>) and "<title> - Claude".
    nonisolated static func currentChat(in window: AXUIElement) -> ClaudeChat? {
        var stack = [window]
        var visited = 0
        while let element = stack.popLast(), visited < 3000 {
            visited += 1
            if let chat = chat(of: element) { return chat }
            stack.append(contentsOf: children(element))
        }
        return nil
    }

    /// The chat a page area shows, if this element is that page area.
    nonisolated static func chat(of element: AXUIElement) -> ClaudeChat? {
        guard value(element, kAXRoleAttribute) as? String == "AXWebArea",
              let url = value(element, kAXURLAttribute) as? URL ?? (value(element, kAXURLAttribute) as? String).flatMap(URL.init(string:)),
              url.path.hasPrefix("/chat/") else { return nil }
        let id = url.lastPathComponent
        var title = (value(element, kAXTitleAttribute) as? String) ?? ""
        if title.hasSuffix(" - Claude") { title = String(title.dropLast(9)) }
        return ClaudeChat(id: id, title: title.isEmpty ? L("Чат Claude") : title)
    }

    private static func sidebarButton(titled title: String, in window: AXUIElement, anyRole: Bool = false) -> AXUIElement? {
        var stack = [window]
        var visited = 0
        while let element = stack.popLast(), visited < 6000 {
            visited += 1
            let role = value(element, kAXRoleAttribute) as? String
            if (role == "AXButton" || (anyRole && role == "AXLink")), value(element, kAXTitleAttribute) as? String == title {
                return element
            }
            stack.append(contentsOf: children(element))
        }
        return nil
    }

    private static func button(described description: String, in window: AXUIElement, last: Bool) -> AXUIElement? {
        var stack = [window]
        var visited = 0
        var found: AXUIElement?
        while let element = stack.popLast(), visited < 5000 {
            visited += 1
            if value(element, kAXRoleAttribute) as? String == "AXButton",
               value(element, kAXDescriptionAttribute) as? String == description
                || value(element, kAXTitleAttribute) as? String == description {
                if !last { return element }
                found = element
            }
            stack.append(contentsOf: children(element).reversed())
        }
        return found
    }

    /// The message box: the text area Claude labels "Напишите запрос…" / "Write your prompt…",
    /// or the last text area in the window.
    nonisolated private static func findInput(in window: AXUIElement) -> AXUIElement? {
        var stack = [window]
        var visited = 0
        var last: AXUIElement?
        while let element = stack.popLast(), visited < 4000 {
            visited += 1
            if value(element, kAXRoleAttribute) as? String == (kAXTextAreaRole as String) {
                let label = ((value(element, kAXDescriptionAttribute) as? String) ?? "").lowercased()
                if label.contains("запрос") || label.contains("prompt") || label.contains("claude") { return element } // l10n:skip
                last = element
            }
            stack.append(contentsOf: children(element).reversed())
        }
        return last
    }

    private nonisolated static func findInputOffMain(_ window: AXUIElement) async -> AXUIElement? {
        let handle = AXHandle(window)
        return await Task.detached(priority: .userInitiated) { findInput(in: handle.value).map { AXHandle($0) } }.value?.value
    }

    private static func type(_ text: String, to pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + 16, units.count)])
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                chunk.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                event?.postToPid(pid)
            }
            index += 16
            usleep(20_000)
        }
    }

    private static func press(keyCode: CGKeyCode, to pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)?.postToPid(pid)
        }
    }
}

/// AXUIElement is a Core Foundation object, not marked Sendable; the helper is only moved to one
/// serial detached task and read there, so this unchecked box is the narrow boundary.
private final class AXHandle: @unchecked Sendable {
    let value: AXUIElement
    init(_ value: AXUIElement) { self.value = value }
}
