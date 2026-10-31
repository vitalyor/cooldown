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
        /// The reset this entry was already tried for automatically. A second look at the same
        /// reset (a restart, a repeated check) must not send a second message.
        var lastAutoReset: Date?
        var lastAttempt: Date?
        var lastOutcome: String?
        var id: String { chat.id.isEmpty ? chat.title : chat.id }
    }

    /// A chat Cooldown can offer in the picker.
    struct Known: Codable, Identifiable, Equatable {
        var chat: ClaudeChat
        var project: String?
        var updated: Date?
        var id: String { chat.id.isEmpty ? "title:" + chat.title : chat.id }
    }

    enum ListSource { case none, window }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var available: [Known] = []
    @Published private(set) var availableSource: ListSource = .none
    @Published private(set) var loadingAvailable = false
    /// Chats seen open in Claude's window, by id: grows by itself, no network needed.
    private var known: [String: Known] = [:]
    private var knownDirty = false
    private let knownURL: URL
    var cardsWaiting: Bool {
        get { UserDefaults.standard.bool(forKey: "claudeCardsWaiting") }
        set { UserDefaults.standard.set(newValue, forKey: "claudeCardsWaiting") }
    }
    private let url: URL

    init(url: URL = Settings.appSupport.appendingPathComponent("claude-chats.json"),
         knownURL: URL = Settings.appSupport.appendingPathComponent("claude-known-chats.json")) {
        self.url = url
        self.knownURL = knownURL
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

    /// Builds the picker list from Claude's sidebar, plus every chat Cooldown has seen open before.
    /// Nothing is fetched from claude.ai: the app's own window is the only source.
    func refreshAvailable() {
        loadingAvailable = true
        Task { @MainActor in
            defer { loadingAvailable = false }
            current = await ClaudeSender.observeOffMain()
            var titles = await ClaudeSender.sidebarTitlesOffMain()
            // Electron builds its accessibility tree on first request; ask again shortly.
            for _ in 0..<4 where titles.isEmpty && ClaudeSender.claudeApp != nil {
                try? await Task.sleep(for: .milliseconds(700))
                titles = await ClaudeSender.sidebarTitlesOffMain()
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
        entries[index].lastOutcome = "sent"
        if entries[index].chat.id.isEmpty, open.title == chat.title { entries[index].chat.id = open.id }
        save()
    }

    /// The automatic path is about to touch this chat for `reset`. Written before sending, so a
    /// crash between the write and the confirmation can never cause a second message.
    func markAutoAttempt(_ chat: ClaudeChat, reset: Date) throws {
        guard let index = entries.firstIndex(where: { $0.chat.matches(chat) }) else {
            throw ResumeError.refused(L("Уже не актуально."))
        }
        var updated = entries
        updated[index].lastAutoReset = reset
        updated[index].lastAttempt = Date()
        updated[index].lastOutcome = "trying"
        try JSONEncoder().encode(updated).write(to: url, options: .atomic)
        entries = updated
    }

    /// What came of the automatic attempt: "sent", "failed" or "uncertain". The reset stays on
    /// the entry, so this reset is not tried again automatically.
    func markAutoResult(_ chat: ClaudeChat, outcome: String) {
        guard let index = entries.firstIndex(where: { $0.chat.matches(chat) }) else { return }
        entries[index].lastOutcome = outcome
        entries[index].lastAttempt = Date()
        if outcome == "sent" { entries[index].lastSent = Date() }
        save()
    }

    /// Whether this reset was already handled for the chat (including an attempt with an unknown
    /// outcome). The times wobble between readings, so half an hour counts as the same reset.
    func autoTried(_ chat: ClaudeChat, reset: Date) -> Bool {
        guard let entry = entries.first(where: { $0.chat.matches(chat) }) else { return false }
        if let sent = entry.lastSent, sent >= reset.addingTimeInterval(-30 * 60) { return true }
        guard let tried = entry.lastAutoReset else { return false }
        return abs(tried.timeIntervalSince(reset)) < 30 * 60
    }

    /// The Claude limit is back. One chat: a card for it. Several: one card that continues them
    /// all, one after another, with a single press.
    func limitReset() {
        resetCards().forEach { ToastController.shared.show($0) }
    }

    /// A chosen chat is working again (continued here, by hand or from the phone): its
    /// "Continue" card is done, on the Mac and on the phone.
    func chatStarted(_ key: String) {
        let id = key.hasPrefix("chat:") ? String(key.dropFirst(5)) : key
        guard let entry = entries.first(where: { !$0.chat.id.isEmpty && $0.chat.id == id }) else { return }
        ToastController.shared.dismiss(key: "claude-chat-\(entry.id)")
    }

    /// A reset card was answered or closed, on the Mac or on the phone: it is not offered again.
    func cardClosed(_ key: String) {
        if key.hasPrefix("claude-chat-") || key == "claude-chats-all" { cardsWaiting = false }
    }

    /// Every half minute: a reset card still unanswered is shown again where it can be seen — on the
    /// Mac when someone is there, otherwise on the phone. Once the limit runs out again it is moot.
    func offerAgain() {
        guard cardsWaiting else { return }
        let cards = resetCards()
        if cards.isEmpty || AgentActivity.spent(.claude) != nil {
            cardsWaiting = false
            cards.forEach { ToastController.shared.dismiss(key: $0.key) }
            return
        }
        if ToastController.shared.canShow, !QuietHours.active, ToastController.idleSeconds < 60 {
            for card in cards where !ToastController.shared.isShowing(card.key) { ToastController.shared.show(card) }
        } else {
            cards.forEach { PhoneLink.shared.forward($0) }
        }
    }

    /// The cards for a Claude reset, shown on the Mac or sent to the phone.
    func resetCards() -> [ToastContent] {
        if entries.count >= 2 {
            let chats = entries.map(\.chat)
            let names = chats.prefix(4).map { "«\($0.title)»" }.joined(separator: ", ") + (chats.count > 4 ? L(" и ещё %@", "\(chats.count - 4)") : "")
            return [ToastContent(
                key: "claude-chats-all", kind: .reset, provider: .claude,
                title: L("Лимит Claude восстановился"),
                body: L("Ждут продолжения: %@. Cooldown откроет их по очереди и отправит «%@».", "\(names)", "\(ClaudeSender.text)"),
                actions: [.continueAllClaude(chats), .openPanel], life: .sticky)]
        }
        return entries.prefix(1).map(card(for:))
    }

    /// One chat's "Продолжить" card: used for a single reset and for the chats the automatic
    /// path could not finish.
    func card(for entry: Entry) -> ToastContent {
        ToastContent(
            key: "claude-chat-\(entry.id)", kind: .reset, provider: .claude,
            title: L("Продолжить «%@»?", "\(entry.chat.title)"),
            body: L("Лимит Claude восстановился. Cooldown откроет этот чат и отправит «%@».", "\(ClaudeSender.text)"),
            actions: [.continueClaudeChat(entry.chat), .openClaude], life: .sticky)
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
                ToastController.shared.show(ToastCatalog.failure(L("Остановлено на «%@»", "\(chat.title)"),
                    (done > 0 ? L("Продолжено чатов: %@. ", "\(done)") : "") + error.localizedDescription, provider: .claude))
                return
            }
        }
        ToastController.shared.show(ToastContent(key: "claude-all-done", kind: .info, provider: .claude,
                                                 title: L("Продолжено чатов: %@", "\(done)"),
                                                 body: chats.map { "«\($0.title)»" }.joined(separator: ", "), life: .auto(8)))
    }

    private func save() {
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
}
