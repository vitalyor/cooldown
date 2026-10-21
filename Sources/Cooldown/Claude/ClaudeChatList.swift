import Foundation

/// Claude Desktop chats chosen to be continued after a limit reset — the Desktop counterpart of
/// Codex auto-continue. When the limit comes back, each one gets a card; one press on
/// "Продолжить" and Cooldown finds the chat (wherever Claude is), checks it and sends the message.
@MainActor
final class ClaudeChatList: ObservableObject {
    static let shared = ClaudeChatList()

    struct Entry: Codable, Identifiable, Equatable {
        var chat: ClaudeChat
        var added = Date()
        var automatic = false     // remembered by Cooldown when the limit ran out
        var lastSent: Date?
        var id: String { chat.id.isEmpty ? chat.title : chat.id }
    }

    /// A chat Cooldown can offer in the picker.
    struct Known: Codable, Identifiable, Equatable {
        var chat: ClaudeChat
        var project: String?
        var updated: Date?
        var id: String { chat.id.isEmpty ? "title:" + chat.title : chat.id }
    }

    enum ListSource { case none, window, web }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var available: [Known] = []
    @Published private(set) var availableSource: ListSource = .none
    @Published private(set) var loadingAvailable = false
    /// Chats seen open in Claude's window, by id: grows by itself, no network needed.
    private var known: [String: Known] = [:]
    private var knownDirty = false
    private let knownURL = Settings.appSupport.appendingPathComponent("claude-known-chats.json")
    var cardsWaiting: Bool {
        get { UserDefaults.standard.bool(forKey: "claudeCardsWaiting") }
        set { UserDefaults.standard.set(newValue, forKey: "claudeCardsWaiting") }
    }
    private let url = Settings.appSupport.appendingPathComponent("claude-chats.json")

    init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Entry].self, from: data) { entries = saved }
        if let data = try? Data(contentsOf: knownURL), let saved = try? JSONDecoder().decode([Known].self, from: data) {
            known = Dictionary(saved.map { ($0.chat.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// A chat seen open in Claude: its address is now known, whatever list it sits in.
    func remember(_ chat: ClaudeChat) {
        guard !chat.id.isEmpty else { return }
        learn(chat)
        if let old = known[chat.id], old.chat.title == chat.title, Date().timeIntervalSince(old.chat.seen) < 600 { return }
        var entry = known[chat.id] ?? Known(chat: chat)
        entry.chat = chat
        known[chat.id] = entry
        knownDirty = true
        saveKnownSoon()
    }

    /// Builds the picker list. With claude.ai connected: every chat, with its project and date.
    /// Without: the chats in Claude's sidebar, plus every chat Cooldown has seen open before.
    func refreshAvailable() {
        current = ClaudeSender.observe()
        loadingAvailable = true
        Task { @MainActor in
            defer { loadingAvailable = false }
            if ClaudeWeb.shared.isConnected, let list = try? await ClaudeWeb.shared.conversations(), !list.isEmpty {
                for item in list where !item.chat.id.isEmpty { known[item.chat.id] = item }
                knownDirty = true
                saveKnownSoon()
                available = list
                availableSource = .web
                return
            }
            var titles = ClaudeSender.sidebarTitles()
            // Electron builds its accessibility tree on first request; ask again shortly.
            for _ in 0..<4 where titles.isEmpty && ClaudeSender.claudeApp != nil {
                try? await Task.sleep(for: .milliseconds(700))
                titles = ClaudeSender.sidebarTitles()
            }
            let byTitle = Dictionary(known.values.map { ($0.chat.title, $0) }, uniquingKeysWith: { a, b in
                (a.chat.seen > b.chat.seen) ? a : b
            })
            var list = titles.map { byTitle[$0] ?? Known(chat: ClaudeChat(id: "", title: $0)) }
            let listed = Set(titles)
            list += known.values.filter { !listed.contains($0.chat.title) }.sorted { $0.chat.seen > $1.chat.seen }
            available = list
            availableSource = list.isEmpty ? .none : .window
        }
    }

    private var saveScheduled = false
    private func saveKnownSoon() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            guard self.knownDirty else { return }
            self.knownDirty = false
            // The newest few thousand are plenty.
            let items = self.known.values.sorted { ($0.updated ?? $0.chat.seen) > ($1.updated ?? $1.chat.seen) }.prefix(3000)
            try? JSONEncoder().encode(Array(items)).write(to: self.knownURL, options: .atomic)
        }
    }

    func add(_ chat: ClaudeChat, automatic: Bool = false) {
        guard !entries.contains(where: { $0.chat.matches(chat) }) else { return }
        entries.insert(Entry(chat: chat, automatic: automatic), at: 0)
        save()
    }


    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        if ClaudeSender.pendingChat.map(entry.chat.matches) == true { ClaudeSender.pendingChat = nil }
        save()
    }

    /// The chat open in Claude right now: a chosen chat without an address gets it, so it can be
    /// opened by link later even if it drops off the sidebar or gets renamed.
    func learn(_ open: ClaudeChat) {
        guard !open.id.isEmpty else { return }
        var changed = false
        for index in entries.indices {
            if entries[index].chat.id.isEmpty && entries[index].chat.title == open.title {
                entries[index].chat.id = open.id; changed = true
            } else if entries[index].chat.id == open.id && entries[index].chat.title != open.title {
                entries[index].chat.title = open.title; changed = true   // renamed in Claude
            }
        }
        if changed { save() }
    }

    /// A chat picked in the list: with its address when Cooldown knows it.
    func add(_ item: Known) { add(item.chat) }

    /// The chat open in Claude right now, if Cooldown can read it.
    @Published var current: ClaudeChat?

    func sent(to chat: ClaudeChat, now open: ClaudeChat) {
        guard let index = entries.firstIndex(where: { $0.chat.matches(chat) }) else { return }
        entries[index].lastSent = Date()
        if entries[index].chat.id.isEmpty, open.title == chat.title { entries[index].chat.id = open.id }
        save()
    }

    /// The Claude limit is back. One chat: a card for it. Several: one card that continues them
    /// all, one after another, with a single press.
    func limitReset() {
        if entries.count >= 2 {
            let chats = entries.map(\.chat)
            let names = chats.prefix(4).map { "«\($0.title)»" }.joined(separator: ", ") + (chats.count > 4 ? " и ещё \(chats.count - 4)" : "")
            ToastController.shared.show(ToastContent(
                key: "claude-chats-all", kind: .reset, provider: .claude,
                title: "Лимит Claude восстановился",
                body: "Ждут продолжения: \(names). Cooldown откроет их по очереди и отправит «\(ClaudeSender.text)».",
                actions: [.continueAllClaude(chats), .openPanel], life: .sticky))
            return
        }
        for entry in entries.prefix(1) {
            ToastController.shared.show(ToastContent(
                key: "claude-chat-\(entry.id)", kind: .reset, provider: .claude,
                title: "Продолжить «\(entry.chat.title)»?",
                body: "Лимит Claude восстановился. Cooldown откроет этот чат и отправит «\(ClaudeSender.text)».",
                actions: [.continueClaudeChat(entry.chat), .openClaude], life: .sticky))
        }
    }

    @Published private(set) var continuing = false

    /// Continues each chat in turn. Stops at the first one that cannot be sent, and says which.
    func continueAll(_ chats: [ClaudeChat]) async {
        guard !continuing else { return }
        continuing = true
        defer { continuing = false }
        var done = 0
        for chat in chats {
            do {
                try await ClaudeSender.continueChat(chat)
                done += 1
                // Give Claude a moment to take the message before opening the next chat.
                try? await Task.sleep(for: .seconds(2))
            } catch {
                ToastController.shared.show(ToastCatalog.failure("Остановлено на «\(chat.title)»",
                    (done > 0 ? "Продолжено чатов: \(done). " : "") + error.localizedDescription, provider: .claude))
                return
            }
        }
        ToastController.shared.show(ToastContent(key: "claude-all-done", kind: .info, provider: .claude,
                                                 title: "Продолжено чатов: \(done)",
                                                 body: chats.map { "«\($0.title)»" }.joined(separator: ", "), life: .auto(8)))
    }

    private func save() {
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
}
