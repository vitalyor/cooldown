import CryptoKit
import Foundation
import Network
import Security

// MARK: Frames

public struct LinkPush: Codable, Equatable, Sendable {
    public var collapse: String?
    public var sound: Bool?
    public var level: String?      // passive, active, time-sensitive
    public var remove: [String]?
    public var silent: Bool?
    public var badge: Int?         // things waiting for a press, shown on the app icon
    public var urgent: Bool?       // priority 10 even for a quiet (passive) one
    public init(collapse: String? = nil, sound: Bool? = nil, level: String? = nil, remove: [String]? = nil, silent: Bool? = nil,
                badge: Int? = nil, urgent: Bool? = nil) {
        self.collapse = collapse; self.sound = sound; self.level = level; self.remove = remove; self.silent = silent
        self.badge = badge; self.urgent = urgent
    }
}

public struct LiveAlert: Codable, Equatable, Sendable {
    public var title: String
    public var body: String
    public var sound: String?            // a sound in the iPhone app's bundle, or "default"
    public init(title: String, body: String, sound: String? = nil) { self.title = title; self.body = body; self.sound = sound }
}

/// One WebSocket frame. Which fields are set depends on `t` (docs/LINK.md, "WebSocket frames").
public struct LinkFrame: Codable, Equatable, Sendable {
    public var t: String
    public var id: String?
    public var from: String?
    public var to: String?
    public var ts: Int64?
    public var ttl: Int64?
    public var keep: String?
    public var box: String?
    public var push: LinkPush?
    public var device: String?
    public var online: Bool?
    public var seen: Int64?
    public var name: String?
    public var hello: String?
    public var code: String?
    public var text: String?
    public var ids: [String]?
    public var ms: Int64?          // "delivered": how long the push took to be confirmed
    public var net: String?        // "delivered": the phone's network then (wifi, cellular...)
    // Live Activity
    public var event: String?
    public var state: LiveState?
    public var alert: LiveAlert?
    public var stale: Int64?
    public var dismiss: Int64?
    public var priority: Int?

    public init(t: String) { self.t = t }

    public static func live(_ event: String, _ state: LiveState, alert: LiveAlert? = nil, stale: Date? = nil, dismiss: Date? = nil, urgent: Bool = false) -> LinkFrame {
        var f = LinkFrame(t: "la")
        f.event = event; f.state = state; f.alert = alert
        f.stale = stale.map { Int64($0.timeIntervalSince1970) }
        f.dismiss = dismiss.map { Int64($0.timeIntervalSince1970) }
        f.priority = urgent ? 10 : 5
        return f
    }
}

// MARK: Account

public struct LinkPeer: Codable, Equatable, Identifiable, Sendable {
    public var id: String          // device id at the relay
    public var name: String
    public var key: Data           // its Curve25519 public key
    public var added: Date
    public init(id: String, name: String, key: Data, added: Date = Date()) { self.id = id; self.name = name; self.key = key; self.added = added }
}

/// Everything a device needs to talk over the relay. Kept in the Keychain as one item.
public struct LinkAccount: Codable, Equatable, Sendable {
    public var relay: URL
    public var space: String
    public var device: String
    public var token: String
    public var privateKey: Data
    public var peers: [LinkPeer]

    public init(relay: URL, space: String, device: String, token: String, privateKey: Data, peers: [LinkPeer] = []) {
        self.relay = relay; self.space = space; self.device = device; self.token = token
        self.privateKey = privateKey; self.peers = peers
    }

    public var publicKey: Data {
        (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey))?.publicKey.rawRepresentation ?? Data()
    }
}

/// The Keychain item that holds a LinkAccount.
public struct LinkVault: Sendable {
    public var service: String
    public var group: String?      // a shared access group, so the notification extension can read it

    public init(service: String = "com.vitalyor.cooldown.link", group: String? = nil) {
        self.service = service; self.group = group
    }

    private func query() -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: "account"]
        if let group { q[kSecAttrAccessGroup as String] = group }
        #if os(iOS)
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }

    public func load() -> LinkAccount? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(LinkAccount.self, from: data)
    }

    @discardableResult
    public func save(_ account: LinkAccount) -> Bool {
        guard let data = try? JSONEncoder().encode(account) else { return false }
        let q = query()
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            // Readable after the first unlock, so a push can be opened while the phone is locked.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    public func delete() { SecItemDelete(query() as CFDictionary) }
}

// MARK: Session

/// Seals and opens boxes for one account and drops replays.
public final class LinkSession: @unchecked Sendable {
    public private(set) var account: LinkAccount
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private var keys: [String: SymmetricKey] = [:]
    private var seen: [String] = []
    private var seenSet: Set<String> = []
    private var lastState: [String: Date] = [:]
    private let lock = NSLock()

    public enum Failure: Error { case unknownPeer, badBox, replay, tooOld }

    public init?(_ account: LinkAccount) {
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: account.privateKey) else { return nil }
        self.account = account
        self.privateKey = key
    }

    public func update(_ account: LinkAccount) {
        lock.lock(); defer { lock.unlock() }
        self.account = account
        keys = [:]
    }

    private func key(for peer: String) throws -> SymmetricKey {
        if let k = keys[peer] { return k }
        guard let p = account.peers.first(where: { $0.id == peer }) else { throw Failure.unknownPeer }
        let k = try LinkCrypto.sharedKey(mine: privateKey, theirs: p.key)
        keys[peer] = k
        return k
    }

    /// An envelope frame carrying `box` to `peer`.
    public func envelope(_ box: LinkBox, to peer: String, ttl: TimeInterval = 600, keep: String? = nil, push: LinkPush? = nil) throws -> LinkFrame {
        lock.lock(); defer { lock.unlock() }
        let data = try LinkJSON.encoder.encode(box)
        var f = LinkFrame(t: "env")
        f.id = box.id
        f.to = peer
        f.ttl = Int64(ttl)
        f.keep = keep
        f.push = push
        f.box = try LinkCrypto.seal(data, key: key(for: peer), from: account.device, to: peer, id: box.id)
        return f
    }

    /// Opens an envelope frame for this device. Throws for anything it shouldn't trust.
    public func open(_ frame: LinkFrame, now: Date = Date()) throws -> LinkBox {
        lock.lock(); defer { lock.unlock() }
        guard let from = frame.from, let id = frame.id, let text = frame.box else { throw Failure.badBox }
        let plain = try LinkCrypto.open(text, key: key(for: from), from: from, to: account.device, id: id)
        guard let box = try? LinkJSON.decoder.decode(LinkBox.self, from: plain), box.id == id else { throw Failure.badBox }
        let ttl = TimeInterval(frame.ttl ?? 600)
        if box.ts < now.addingTimeInterval(-(ttl + 300)) || box.ts > now.addingTimeInterval(300) { throw Failure.tooOld }
        if seenSet.contains(id) { throw Failure.replay }
        seenSet.insert(id)
        seen.append(id)
        if seen.count > 4000 {
            for old in seen.prefix(1000) { seenSet.remove(old) }
            seen.removeFirst(1000)
        }
        if box.m == .state {
            // A late, older state must not overwrite a newer one.
            if let last = lastState[from], box.ts < last { throw Failure.replay }
            lastState[from] = box.ts
        }
        return box
    }
}

// MARK: Relay calls

public enum LinkHTTP {
    public struct Failure: LocalizedError {
        public var status: Int
        public var reason: String
        public var errorDescription: String? { "relay \(status) \(reason)" }
    }

    public static func call(_ relay: URL, _ method: String, _ path: String, token: String? = nil, body: Encodable? = nil) async throws -> Data {
        var req = URLRequest(url: relay.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 20
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let reason = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? ""
            throw Failure(status: status, reason: reason)
        }
        return data
    }

    /// The same call, tried again when the network let it down (a weak mobile signal, a moment
    /// between networks): three tries over about ten seconds. Only for calls that are safe to
    /// repeat, like sending an envelope: its id makes a second copy harmless.
    public static func callRetrying(_ relay: URL, _ method: String, _ path: String, token: String? = nil, body: Encodable? = nil) async throws -> Data {
        var wait: UInt64 = 1
        for attempt in 1...3 {
            do {
                return try await call(relay, method, path, token: token, body: body)
            } catch let failure as Failure where failure.status < 500 && failure.status != 429 {
                throw failure
            } catch {
                if attempt == 3 { throw error }
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
                wait *= 3
            }
        }
        throw URLError(.cannotConnectToHost)
    }

    public static func json<T: Decodable>(_ type: T.Type, _ relay: URL, _ method: String, _ path: String, token: String? = nil, body: Encodable? = nil) async throws -> T {
        try JSONDecoder().decode(T.self, from: await call(relay, method, path, token: token, body: body))
    }
}

struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

public struct LinkDeviceRow: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var role: String
    public var name: String
    public var online: Bool
    public var seen: Int64
    public var push: Bool
    public var live: Bool?               // can show a Live Activity started from the Mac
    public var confirms: Bool?           // a newer app: confirms each notification, shows agents at work
    public var activities: Int?          // Live Activities the phone says are on screen
}

// MARK: Connection

/// Keeps one WebSocket to the relay open, reconnecting with backoff, and queues frames while
/// it is down.
@MainActor
public final class LinkClient {
    public enum Status: Equatable { case off, connecting, online, offline(String) }

    public private(set) var status: Status = .off { didSet { if status != oldValue { onStatus?(status) } } }
    public var onStatus: ((Status) -> Void)?
    public var onFrame: ((LinkFrame) -> Void)?

    private var relay: URL
    private var token: String
    private var task: URLSessionWebSocketTask?
    private var wanted = false
    private var attempt = 0
    private var retry: Task<Void, Never>?
    private var outbox: [LinkFrame] = []
    /// Envelopes written but not yet acknowledged by the relay. A connection can die with frames
    /// still in its buffer; those go again on the next one (the relay drops a second copy).
    private var unacked: [(id: String, frame: LinkFrame, at: Date)] = []
    private var monitor: NWPathMonitor?
    /// The network this device is on now (wifi, cellular), as confirmations tell the relay.
    public private(set) var network: String?
    private var generation = 0

    public init(relay: URL, token: String) {
        self.relay = relay
        self.token = token
    }

    public func start() {
        wanted = true
        watchNetwork()
        if task == nil { connect() }
    }

    public func stop() {
        wanted = false
        retry?.cancel()
        monitor?.cancel()
        monitor = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        status = .off
    }

    /// Sends now if connected, otherwise keeps the frame until the next connection.
    public func send(_ frame: LinkFrame) {
        if status == .online, let task {
            write(frame, on: task)
        } else {
            outbox.append(frame)
            if outbox.count > 200 { outbox.removeFirst(outbox.count - 200) }
        }
    }

    /// Confirms envelopes so the relay stops keeping them.
    public func got(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        var f = LinkFrame(t: "got")
        f.ids = ids
        f.net = network
        send(f)
    }

    private func write(_ frame: LinkFrame, on task: URLSessionWebSocketTask) {
        if frame.t == "env", let id = frame.id, !unacked.contains(where: { $0.id == id }) {
            unacked.append((id, frame, Date()))
            if unacked.count > 200 { unacked.removeFirst(unacked.count - 200) }
        }
        guard let data = try? JSONEncoder().encode(frame), let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.outbox.append(frame)
                self?.dropped(error.localizedDescription)
            }
        }
    }

    private func connect() {
        guard wanted else { return }
        generation += 1
        let mine = generation
        var url = URLComponents(url: relay.appendingPathComponent("v1/ws"), resolvingAgainstBaseURL: false)!
        url.scheme = relay.scheme == "http" ? "ws" : "wss"
        var req = URLRequest(url: url.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let t = URLSession.shared.webSocketTask(with: req)
        t.maximumMessageSize = 1 << 20
        task = t
        status = .connecting
        t.resume()
        receive(on: t, generation: mine)
    }

    private func receive(on t: URLSessionWebSocketTask, generation mine: Int) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, mine == self.generation else { return }
                switch result {
                case .failure(let error):
                    self.dropped(error.localizedDescription)
                case .success(let message):
                    var data: Data?
                    switch message {
                    case .string(let s): data = s.data(using: .utf8)
                    case .data(let d): data = d
                    @unknown default: break
                    }
                    if let data, let frame = try? JSONDecoder().decode(LinkFrame.self, from: data) {
                        self.handle(frame, on: t)
                    }
                    self.receive(on: t, generation: mine)
                }
            }
        }
    }

    /// A connection can die without a word (a NAT forgets it, Wi-Fi changes under a sleeping Mac):
    /// sending into it fails quietly. A ping every 30 s finds out within a minute and reconnects.
    private var heartbeat: Task<Void, Never>?

    private func beat(on t: URLSessionWebSocketTask, generation mine: Int) {
        heartbeat?.cancel()
        heartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled, mine == self.generation, self.task === t else { return }
                let answered = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                    let once = Once()
                    t.sendPing { error in once.run { done.resume(returning: error == nil) } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { once.run { done.resume(returning: false) } }
                }
                guard mine == self.generation, self.task === t else { return }
                if !answered {
                    self.dropped("no answer to ping")
                    return
                }
            }
        }
    }

    private func handle(_ frame: LinkFrame, on t: URLSessionWebSocketTask) {
        if frame.t == "ready" {
            attempt = 0
            status = .online
            beat(on: t, generation: generation)
            // Unacknowledged ones from the last connection first, then what queued meanwhile.
            let fresh = unacked.filter { Date().timeIntervalSince($0.at) < 3600 }
            let queued = Set(outbox.compactMap(\.id))
            let waiting = fresh.filter { !queued.contains($0.id) }.map(\.frame) + outbox
            unacked = []
            outbox = []
            for f in waiting { write(f, on: t) }
        } else if frame.t == "ack" || frame.t == "error", let id = frame.id {
            unacked.removeAll { $0.id == id }
        }
        onFrame?(frame)
    }

    private func dropped(_ reason: String) {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        guard wanted else { status = .off; return }
        status = .offline(reason)
        scheduleRetry()
    }

    private func scheduleRetry() {
        retry?.cancel()
        let delays: [Double] = [1, 2, 5, 10, 20, 30]
        let delay = delays[min(attempt, delays.count - 1)]
        attempt += 1
        retry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.task == nil else { return }
            self.connect()
        }
    }

    /// Checks the open connection at once (after a wake or a network change): no answer within five
    /// seconds and it is replaced; what it swallowed goes again on the new one.
    public func probe() {
        guard status == .online, let t = task else { return }
        let mine = generation
        Task { @MainActor [weak self] in
            let answered = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                let once = Once()
                t.sendPing { error in once.run { done.resume(returning: error == nil) } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { once.run { done.resume(returning: false) } }
            }
            guard let self, !answered, mine == self.generation, self.task === t else { return }
            self.dropped("no answer after a network change")
        }
    }

    /// Reconnects at once when the network comes back instead of waiting out the backoff.
    private func watchNetwork() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let kind = path.usesInterfaceType(.wifi) ? "wifi" : path.usesInterfaceType(.cellular) ? "cellular" : nil
            Task { @MainActor in self?.network = kind }
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self, self.wanted else { return }
                // Online over a network that just changed (Wi-Fi to cable, a new address): the old
                // connection may be dead already. A quick ping says so now, not in a minute.
                if self.status == .online { self.probe(); return }
                self.attempt = 0
                self.retry?.cancel()
                if self.task == nil { self.connect() }
            }
        }
        m.start(queue: .global(qos: .utility))
        monitor = m
    }
}

/// Runs its closure the first time only (a ping answered or timed out, whichever comes first).
public final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    public init() {}
    public func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}
