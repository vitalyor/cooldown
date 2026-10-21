import AppKit
import ApplicationServices

/// A Claude Desktop conversation, as its window reports it.
struct ClaudeChat: Codable, Equatable {
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
    static let defaultText = "Продолжай с того места, где остановился."

    enum SendError: LocalizedError {
        case noPermission, notRunning, notFront, noInput, chatNotOpened(String)

        var errorDescription: String? {
            switch self {
            case .noPermission:
                return "Нужно разрешение «Универсальный доступ» для Cooldown. Откроются Системные настройки: включите Cooldown и нажмите «Продолжить» ещё раз."
            case .notRunning: return "Claude не открылся."
            case .notFront: return "Окно Claude не вышло на передний план, сообщение не отправлено."
            case .noInput: return "Не нашлось поле ввода в окне Claude. Сообщение не отправлено."
            case .chatNotOpened(let title): return "Не получилось открыть чат «\(title)». Сообщение не отправлено — откройте его и нажмите ещё раз."
            }
        }
    }

    static var hasPermission: Bool { AXIsProcessTrusted() }

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
            guard let data = UserDefaults.standard.data(forKey: "claudePendingChat") else { return nil }
            return try? JSONDecoder().decode(ClaudeChat.self, from: data)
        }
        set {
            UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "claudePendingChat")
        }
    }

    /// The chat that was open the last time Claude was looked at.
    private(set) static var lastChat: ClaudeChat?

    /// The window watcher saw this chat open.
    static func note(_ chat: ClaudeChat) { lastChat = chat }

    /// Reads the open chat from Claude's window, if Claude runs and Accessibility is allowed.
    @discardableResult
    static func observe() -> ClaudeChat? {
        guard hasPermission, let app = claudeApp, let window = window(of: app) else { return nil }
        guard let chat = currentChat(in: window) else { return nil }
        lastChat = chat
        ClaudeChatList.shared.learn(chat)
        return chat
    }

    /// Called when the Claude limit runs out: the chat in use is the one to continue later.
    static func rememberChatForReset() {
        if let chat = observe() ?? lastChat, Date().timeIntervalSince(chat.seen) < 3 * 3600 {
            pendingChat = chat
            ClaudeChatList.shared.add(chat, automatic: true)
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
    static func continueChat(_ chat: ClaudeChat? = nil) async throws {
        guard hasPermission else {
            requestPermission()
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

        if let chat, !chat.matches(currentChat(in: window)) {
            try await open(chat, app: app)
            window = Self.window(of: app) ?? window
            guard chat.matches(currentChat(in: window)) else { throw SendError.chatNotOpened(chat.title) }
        }

        var input: AXUIElement?
        for _ in 0..<20 {
            input = findInput(in: Self.window(of: app) ?? window)
            if input != nil { break }
            try await Task.sleep(for: .milliseconds(150))
        }
        guard let input else { throw SendError.noInput }
        AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try await Task.sleep(for: .milliseconds(200))

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { throw SendError.notFront }
        if let chat, !chat.matches(currentChat(in: Self.window(of: app) ?? window)) { throw SendError.chatNotOpened(chat.title) }
        type(text, to: app.processIdentifier)
        try await Task.sleep(for: .milliseconds(300))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { throw SendError.notFront }
        press(keyCode: 36, to: app.processIdentifier) // Return sends in Claude
        if let chat {
            if pendingChat?.matches(chat) == true { pendingChat = nil }
            // Learn the chat's id now that it is open, so next time it is found even if renamed.
            if let open = currentChat(in: Self.window(of: app) ?? window) { ClaudeChatList.shared.sent(to: chat, now: open) }
        }
    }

    /// Opens a chat: its button in Claude's sidebar if it is listed, otherwise Claude's own link.
    /// Opens a chat the way a person would: its button in the sidebar; if it is not listed there,
    /// the full list of chats ("Показать все" under Недавние); and by its link when the id is known.
    private static func open(_ chat: ClaudeChat, app: NSRunningApplication) async throws {
        func waitOpen() async -> Bool {
            for _ in 0..<25 {
                try? await Task.sleep(for: .milliseconds(150))
                if let window = window(of: app), chat.matches(currentChat(in: window)) { return true }
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
        if let window = window(of: app), let all = button(described: "Показать все", in: window, last: true) {
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
        let navigation: Set<String> = ["Поиск", "Новое", "Проекты", "Артефакты", "Запланированные задачи", "Персонализация",
                                       "Закрепленные", "Недавние", "Показать все", "Еще", "Ещё", "Search", "New chat", "Projects",
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

    static var claudeApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeApp.bundleID).first
    }

    static func window(of app: NSRunningApplication) -> AXUIElement? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // Electron builds its page tree only when an assistive app asks for it.
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let focused = value(root, kAXFocusedWindowAttribute) { return (focused as! AXUIElement) }
        if let windows = value(root, kAXWindowsAttribute) as? [AXUIElement] { return windows.first }
        return nil
    }

    nonisolated static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    /// Sidebar chat rows carry their title as text a level or two down (Claude wraps it in a group).
    private static func labelled(_ element: AXUIElement, _ title: String, depth: Int = 3) -> Bool {
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

    /// The page area carries the chat's address (claude.ai/chat/<id>) and "<title> - Claude".
    static func currentChat(in window: AXUIElement) -> ClaudeChat? {
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
        return ClaudeChat(id: id, title: title.isEmpty ? "Чат Claude" : title)
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
    private static func findInput(in window: AXUIElement) -> AXUIElement? {
        var stack = [window]
        var visited = 0
        var last: AXUIElement?
        while let element = stack.popLast(), visited < 4000 {
            visited += 1
            if value(element, kAXRoleAttribute) as? String == (kAXTextAreaRole as String) {
                let label = ((value(element, kAXDescriptionAttribute) as? String) ?? "").lowercased()
                if label.contains("запрос") || label.contains("prompt") || label.contains("claude") { return element }
                last = element
            }
            stack.append(contentsOf: children(element).reversed())
        }
        return last
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
