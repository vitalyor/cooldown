import Foundation

// What travels inside a sealed box. See docs/LINK.md, "Messages inside a box".
// Times are seconds since 1970, so the relay-side Live Activity payloads and these agree.

public struct LinkLimit: Codable, Equatable, Sendable {
    public var provider: String          // "codex" or "claude"
    public var session: Double?          // percent used, 0…100
    public var week: Double?
    public var sessionReset: Date?
    public var weekReset: Date?
    public var stale: Bool

    public init(provider: String, session: Double?, week: Double?, sessionReset: Date?, weekReset: Date?, stale: Bool = false) {
        self.provider = provider; self.session = session; self.week = week
        self.sessionReset = sessionReset; self.weekReset = weekReset; self.stale = stale
    }
}

public struct LinkAgent: Codable, Equatable, Sendable {
    public var provider: String
    public var working: Bool
    public var since: Date?
    public init(provider: String, working: Bool, since: Date? = nil) {
        self.provider = provider; self.working = working; self.since = since
    }
}

/// A chat Cooldown watches to continue after a limit resets.
public struct LinkWatch: Codable, Equatable, Identifiable, Sendable {
    public var provider: String
    public var id: String
    public var title: String
    public var state: String             // e.g. "running", "quota_limited", "waiting_reset"
    public var detail: String?           // a ready-made sentence in the Mac's language
    public var resumes: Int
    public var max: Int
    public var at: Date?                 // when Cooldown plans to continue
    public init(provider: String, id: String, title: String, state: String, detail: String? = nil, resumes: Int = 0, max: Int = 0, at: Date? = nil) {
        self.provider = provider; self.id = id; self.title = title; self.state = state
        self.detail = detail; self.resumes = resumes; self.max = max; self.at = at
    }
}

public struct LinkMac: Codable, Equatable, Sendable {
    public var name: String
    public var version: String
    public var locked: Bool
    public var language: String
    public init(name: String, version: String, locked: Bool, language: String) {
        self.name = name; self.version = version; self.locked = locked; self.language = language
    }
}

public struct LinkAction: Codable, Equatable, Identifiable, Sendable {
    public enum Style: String, Codable, Sendable { case primary, normal, destructive }
    public var id: String
    public var title: String
    public var style: Style
    /// Needs Face ID when pressed from the lock screen (answers to agent requests).
    public var auth: Bool
    /// Asks for a line of text first ("Ответить"): it goes to the agent's chat.
    public var input: Bool?
    public init(id: String, title: String, style: Style = .normal, auth: Bool = false, input: Bool? = nil) {
        self.id = id; self.title = title; self.style = style; self.auth = auth; self.input = input
    }
}

/// A card as the Mac shows it.
public struct LinkCard: Codable, Equatable, Identifiable, Sendable {
    public var key: String
    public var kind: String              // reset, finished, attention, warning, info, waiting
    public var provider: String?
    public var title: String
    public var body: String
    public var actions: [LinkAction]
    public var created: Date
    public var expires: Date?
    public var id: String { key }

    public init(key: String, kind: String, provider: String?, title: String, body: String,
                actions: [LinkAction], created: Date = Date(), expires: Date? = nil) {
        self.key = key; self.kind = kind; self.provider = provider; self.title = title; self.body = body
        self.actions = actions; self.created = created; self.expires = expires
    }

    /// The id the notification gets on the phone: opaque, so the relay learns nothing from it.
    public var collapseID: String { LinkCard.collapseID(key) }
    public static func collapseID(_ key: String) -> String {
        var hash: UInt64 = 1469598103934665603   // FNV-1a, enough to tell cards apart
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return "c" + String(hash, radix: 36)
    }
}

public struct LinkState: Codable, Equatable, Sendable {
    public var limits: [LinkLimit]
    public var agents: [LinkAgent]
    public var watches: [LinkWatch]
    public var cards: [LinkCard]         // cards still open on the Mac
    public var mac: LinkMac
    /// What the Live Activity shows, worked out on the Mac so phone and Mac agree; nil when none is wanted.
    public var live: LiveState?
    public var at: Date
    public init(limits: [LinkLimit], agents: [LinkAgent], watches: [LinkWatch], cards: [LinkCard], mac: LinkMac, live: LiveState? = nil, at: Date = Date()) {
        self.limits = limits; self.agents = agents; self.watches = watches; self.cards = cards; self.mac = mac; self.live = live; self.at = at
    }
}

/// A chat the phone can pick to watch or continue.
public struct LinkChat: Codable, Equatable, Identifiable, Sendable {
    public var provider: String
    public var id: String
    public var title: String
    public var subtitle: String?
    public var state: String?
    public var watched: Bool
    public var updated: Date?
    public init(provider: String, id: String, title: String, subtitle: String? = nil, state: String? = nil, watched: Bool = false, updated: Date? = nil) {
        self.provider = provider; self.id = id; self.title = title; self.subtitle = subtitle
        self.state = state; self.watched = watched; self.updated = updated
    }
}

public struct LinkCommand: Codable, Equatable, Sendable {
    public enum Op: String, Codable, Sendable { case cardAct = "card.act", chats, watch, refresh }
    public var id: String
    public var op: Op
    public var args: [String: String]
    public var ttl: TimeInterval
    public init(id: String = LinkID.make(), op: Op, args: [String: String] = [:], ttl: TimeInterval = 1800) {
        self.id = id; self.op = op; self.args = args; self.ttl = ttl
    }
}

public struct LinkResult: Codable, Equatable, Sendable {
    /// ok, stale, locked, queued, failed, unknown
    public var code: String
    public var cmd: String
    public var text: String
    public var chats: [LinkChat]?
    public var ok: Bool { code == "ok" || code == "queued" }
    public init(cmd: String, code: String, text: String, chats: [LinkChat]? = nil) {
        self.cmd = cmd; self.code = code; self.text = text; self.chats = chats
    }
}

/// One sealed message.
public struct LinkBox: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case state, card, resolve, cmd, result }
    public var m: Kind
    public var id: String
    public var ts: Date
    public var state: LinkState?
    public var card: LinkCard?
    public var key: String?
    public var by: String?
    public var cmd: LinkCommand?
    public var result: LinkResult?

    public init(_ m: Kind, id: String = LinkID.make(), ts: Date = Date()) { self.m = m; self.id = id; self.ts = ts }

    public static func state(_ s: LinkState) -> LinkBox { var b = LinkBox(.state); b.state = s; return b }
    public static func card(_ c: LinkCard) -> LinkBox { var b = LinkBox(.card); b.card = c; return b }
    public static func resolve(_ key: String, by: String) -> LinkBox { var b = LinkBox(.resolve); b.key = key; b.by = by; return b }
    public static func command(_ c: LinkCommand) -> LinkBox { var b = LinkBox(.cmd, id: c.id); b.cmd = c; return b }
    public static func result(_ r: LinkResult) -> LinkBox { var b = LinkBox(.result); b.result = r; return b }
}

public enum LinkID {
    /// A random id the relay accepts: 16 URL-safe characters.
    public static func make() -> String { LinkCrypto.random(12).base64URL }
}

public enum LinkJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

/// What the Live Activity shows: only what matters now, never a wall of numbers. Up to two
/// things that wait for a press, each with its buttons, and a countdown when a limit is spent.
/// Plain on purpose: iOS can't decrypt Live Activity pushes, so titles are general ("Codex is
/// waiting for your decision"), never chat names or commands. Times are seconds since 1970 as
/// plain numbers, because ActivityKit decodes pushed dates in its own default format.
public struct LiveState: Codable, Hashable, Sendable {
    public struct Button: Codable, Hashable, Sendable {
        public var id: String
        public var title: String
        public var primary: Bool
        public var destructive: Bool
        public var auth: Bool            // needs the phone unlocked (answers to agents)
        public init(id: String, title: String, primary: Bool = false, destructive: Bool = false, auth: Bool = false) {
            self.id = id; self.title = title; self.primary = primary; self.destructive = destructive; self.auth = auth
        }
    }
    /// One thing that waits for a press.
    public struct Item: Codable, Hashable, Sendable {
        public var id: String            // the card's opaque collapse id
        public var kind: String          // attention, reset, warning, …
        public var provider: String?
        public var title: String
        public var buttons: [Button]
        public init(id: String, kind: String, provider: String?, title: String, buttons: [Button]) {
            self.id = id; self.kind = kind; self.provider = provider; self.title = title; self.buttons = buttons
        }
    }
    /// A spent limit: when work can go on.
    public struct Countdown: Codable, Hashable, Sendable {
        public var provider: String
        public var until: Double         // seconds since 1970
        public var waiting: Int          // chats or tasks waiting for it
        public init(provider: String, until: Double, waiting: Int) { self.provider = provider; self.until = until; self.waiting = waiting }
    }
    /// An agent at work right now: since when (one stretch, short pauses included) and in how many chats.
    public struct Work: Codable, Hashable, Sendable {
        public var provider: String
        public var since: Double         // seconds since 1970
        public var count: Int
        public init(provider: String, since: Double, count: Int) { self.provider = provider; self.since = since; self.count = count }
    }
    public var items: [Item]             // at most two, most urgent first
    public var more: Int                 // further items not shown
    public var countdowns: [Countdown]   // soonest first
    public var working: [Work]?          // optional: older phones simply do not show it
    public var updated: Double
    public init(items: [Item], more: Int = 0, countdowns: [Countdown] = [], working: [Work]? = nil, updated: Double = 0) {
        self.items = items; self.more = more; self.countdowns = countdowns; self.working = working; self.updated = updated
    }
    public var isEmpty: Bool { items.isEmpty && countdowns.isEmpty && (working ?? []).isEmpty }
}
