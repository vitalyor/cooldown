import AppKit
import Darwin
import Foundation

// MARK: JSON helpers

/// Small helpers for the loosely typed JSON that Codex sends. Foundation turns JSON booleans and
/// numbers into NSNumber alike; these tell them apart, because a 0 or 1 must never read as a flag.
enum JSON {
    static func isNull(_ value: Any?) -> Bool { value == nil || value is NSNull }

    /// True only for a real JSON boolean (true/false), not for the numbers 0 and 1.
    static func isBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func bool(_ value: Any?) -> Bool? {
        guard isBool(value), let flag = value as? NSNumber else { return nil }
        return flag.boolValue
    }

    /// A real number (booleans are not numbers here).
    static func number(_ value: Any?) -> Double? {
        if isBool(value) { return nil }
        guard let real = (value as? NSNumber)?.doubleValue, real.isFinite else { return nil }
        return real
    }

    /// The value at a path of object keys, or nil as soon as a step is missing or not an object.
    static func dig(_ value: Any?, _ path: String...) -> Any? {
        path.reduce(value) { node, key in (node as? [String: Any])?[key] }
    }

    /// Whether a value says "yes, there is something": null, false, 0, "" and nothing are no, and
    /// so are an empty list and an empty object (an empty list of queued messages or of blocking
    /// flags means none). Anything else is yes, including values of an unknown kind.
    static func truthy(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let flag = bool(value) { return flag }
        if let number = number(value) { return number != 0 }
        if let text = value as? String { return !text.isEmpty }
        if let list = value as? [Any] { return !list.isEmpty }
        if let object = value as? [String: Any] { return !object.isEmpty }
        return true
    }

    static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A stable serialisation (sorted keys), to compare two pieces of state exactly.
    static func canonical(_ value: Any?) -> Data? {
        let wrapped: Any = ["v": value ?? NSNull()]
        guard JSONSerialization.isValidJSONObject(wrapped) else { return nil }
        return try? JSONSerialization.data(withJSONObject: wrapped, options: [.sortedKeys, .fragmentsAllowed])
    }
}

// MARK: The Codex app

/// The Codex desktop app: where it is, whether it runs, whether it is new enough, and its deep links.
enum CodexApp {
    static let bundleId = "com.openai.codex"
    /// Builds before this one speak an older local protocol.
    static let minimumBuild = 20770

    static var url: URL? {
        if let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) { return found }
        for path in ["/Applications/ChatGPT.app", "/Applications/Codex.app"] {
            let candidate = URL(fileURLWithPath: path)
            if Bundle(url: candidate)?.bundleIdentifier == bundleId { return candidate }
        }
        return nil
    }

    static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty }

    /// Throws when the app is missing or older than the protocol Cooldown speaks.
    static func checkVersion() throws {
        guard let url else { throw ResumeError.refused(L("Приложение Codex не установлено.")) }
        // Read Info.plist from disk each time: the app may have been updated while Cooldown runs.
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        guard let raw = info?["CFBundleVersion"] as? String, let build = Int(raw.split(separator: ".").first ?? "") else {
            throw ResumeError.refused(L("Не удалось узнать версию приложения Codex."))
        }
        guard build >= minimumBuild else {
            throw ResumeError.refused(L("Приложение Codex слишком старое. Обновите его."))
        }
    }

    static func open() {
        guard let url else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Shows a conversation in the app.
    static func open(thread: String) {
        guard let link = URL(string: "codex://threads/\(thread.lowercased())") else { return }
        NSWorkspace.shared.open(link)
    }

    /// Loads a conversation in the app without bringing it to the front.
    static func load(thread: String) {
        guard let link = URL(string: "codex://threads/\(thread.lowercased())") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(link, configuration: configuration)
    }
}

// MARK: The local socket

enum CodexIPCError: LocalizedError {
    /// The app is closed or its socket is not there: try again later.
    case unavailable
    /// No window has this conversation loaded right now: try again later.
    case threadUnavailable
    case timeout
    /// The socket or its folder looks wrong (owner, permissions): never connect.
    case unsafe(String)
    case connection(String)
    /// The app answered, but with an error or something Cooldown does not understand.
    case app(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return L("Приложение Codex не запущено.")
        case .threadUnavailable: return L("Диалог сейчас не открыт в приложении Codex.")
        case .timeout: return L("Приложение Codex не ответило вовремя.")
        case .unsafe(let text), .connection(let text), .app(let text): return text
        }
    }

    /// Problems that go away by themselves (the app closed, busy or still opening the chat).
    var isTemporary: Bool {
        switch self {
        case .unavailable, .threadUnavailable, .timeout, .connection: return true
        case .unsafe, .app: return false
        }
    }
}

/// One connection to the Codex app's local socket, speaking its framed JSON messages. Cooldown
/// is a quiet client: it says it can handle nothing and refuses every request addressed to it,
/// so it can never answer an approval by accident. Not thread-safe; use from one thread.
final class CodexIPCConnection {
    static let maxFrame = 32 * 1024 * 1024

    let timeout: TimeInterval
    /// Every broadcast that arrives, in order.
    var onBroadcast: (([String: Any]) -> Void)?
    private(set) var descriptor: Int32 = -1
    private(set) var clientId = ""
    private var buffer = Data()
    private var responses: [String: [String: Any]] = [:]

    init(timeout: TimeInterval) { self.timeout = timeout }
    deinit { close() }

    static var socketURL: URL { CodexPaths.home.appendingPathComponent("ipc/ipc.sock") }

    /// The folder must be a real directory and the socket a real socket, both the person's own
    /// and closed to everyone else. Anything else is refused as it is, permissions untouched.
    static func verifySocket() throws {
        let socket = socketURL
        var info = stat()
        guard lstat(socket.deletingLastPathComponent().path, &info) == 0 else { throw CodexIPCError.unavailable }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw CodexIPCError.unsafe(L("Папка сокета Codex доступна другим пользователям или не принадлежит вам."))
        }
        guard lstat(socket.path, &info) == 0 else { throw CodexIPCError.unavailable }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw CodexIPCError.unsafe(L("Сокет Codex доступен другим пользователям или не принадлежит вам."))
        }
    }

    func open() throws {
        close()
        try Self.verifySocket()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CodexIPCError.connection(L("Не удалось открыть соединение с Codex.")) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(Self.socketURL.path.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw CodexIPCError.connection(L("Слишком длинный путь к сокету Codex."))
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw CodexIPCError.unavailable
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        descriptor = fd
        let reply = try request("initialize", params: ["clientType": "cooldown"], version: 0)
        guard let id = JSON.nonEmptyString(JSON.dig(reply, "result", "clientId")) else {
            close()
            throw CodexIPCError.app(L("Codex не принял подключение."))
        }
        clientId = id
    }

    func close() {
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1
        buffer.removeAll()
        responses.removeAll()
    }

    // MARK: Conversations

    /// The id of the window that has the conversation loaded.
    func discoverOwner(_ thread: String) throws -> String {
        // The app takes about ten seconds to say that no window has a conversation, whatever
        // timeout the request carries; allow for that so "not loaded" is not read as a timeout.
        let reply = try request("thread-owner-discovery", params: ["hostId": "local", "conversationId": thread],
                                version: 1, wait: max(timeout, 13), allowError: true)
        if reply["resultType"] as? String == "success", let owner = JSON.nonEmptyString(reply["handledByClientId"]) {
            return owner
        }
        let problem = reply["error"] as? String ?? "?"
        switch problem {
        case "no-client-found": throw CodexIPCError.threadUnavailable   // not loaded right now
        default: throw CodexIPCError.app(L("Codex не сказал, где открыт диалог: %@", "\(problem)"))
        }
    }

    /// Following a conversation makes its window send the state (a snapshot, then patches).
    func setFollowing(_ thread: String, owner: String, _ on: Bool) throws {
        try write(["type": "broadcast", "method": "thread-stream-following-changed", "sourceClientId": clientId,
                   "version": 1, "targetClientIds": [owner],
                   "params": ["hostId": "local", "conversationId": thread, "following": on]])
    }

    /// A command to the window that owns the conversation; it must come back with `ok`.
    func answer(_ method: String, params: [String: Any]) throws {
        guard let thread = params["conversationId"] as? String else { throw CodexIPCError.app(L("Не указан диалог.")) }
        let owner = try discoverOwner(thread)
        let reply = try request(method, params: params, version: 1, target: owner)
        guard JSON.bool((reply["result"] as? [String: Any])?["ok"]) == true else {
            throw CodexIPCError.app(L("Codex не подтвердил ответ."))
        }
    }

    /// One fresh full state of a conversation straight from its owner window. Following is
    /// switched off and on, which always makes the owner send a new snapshot. When `keepFollowing`
    /// is set, following stays on so the caller can see whether the state moves on afterwards.
    func snapshot(_ thread: String, owner known: String? = nil, keepFollowing: Bool = false) throws -> [String: Any] {
        let owner = try known ?? discoverOwner(thread)
        let previous = onBroadcast
        var state: [String: Any]?
        var failure: Error?
        onBroadcast = { message in
            previous?(message)
            guard state == nil, failure == nil else { return }
            switch Self.stateChange(message, thread: thread, owner: owner) {
            case .snapshot(let value): state = value
            case .refused(let reason): failure = CodexIPCError.app(reason)
            case .patches, .unrelated: break
            }
        }
        defer {
            onBroadcast = previous
            if !keepFollowing { try? setFollowing(thread, owner: owner, false) }
        }
        try setFollowing(thread, owner: owner, false)
        try setFollowing(thread, owner: owner, true)
        let deadline = Date().addingTimeInterval(timeout)
        while state == nil && failure == nil {
            try read(deadline: deadline)
        }
        if let failure { throw failure }
        return state ?? [:]
    }

    enum StateChange {
        case snapshot([String: Any])
        case patches
        /// A state message in a form Cooldown does not know: never trust it.
        case refused(String)
        case unrelated
    }

    /// What a broadcast says about one conversation, trusting only its owner window.
    static func stateChange(_ message: [String: Any], thread: String, owner: String) -> StateChange {
        guard message["method"] as? String == "thread-stream-state-changed",
              let params = message["params"] as? [String: Any],
              params["conversationId"] as? String == thread, params["hostId"] as? String == "local",
              message["sourceClientId"] as? String == owner else { return .unrelated }
        guard JSON.number(message["version"]) == 11 else { return .refused(L("Незнакомая версия протокола Codex.")) }
        guard let change = params["change"] as? [String: Any] else { return .refused(L("Codex прислал состояние в незнакомом виде.")) }
        switch change["type"] as? String {
        case "snapshot":
            guard let state = change["conversationState"] as? [String: Any], state["id"] as? String == thread else {
                return .refused(L("Codex прислал состояние другого диалога."))
            }
            return .snapshot(state)
        case "patches":
            return .patches
        default:
            return .refused(L("Codex прислал состояние в незнакомом виде."))
        }
    }

    // MARK: Requests

    /// Sends a request and waits for its response, handling everything else that arrives meanwhile.
    @discardableResult
    func request(_ method: String, params: [String: Any], version: Int, target: String? = nil,
                 wait: TimeInterval? = nil, allowError: Bool = false) throws -> [String: Any] {
        guard descriptor >= 0 else { throw CodexIPCError.unavailable }
        let id = UUID().uuidString.lowercased()
        let limit = wait ?? timeout
        var message: [String: Any] = ["type": "request", "requestId": id, "sourceClientId": clientId, "method": method,
                                      "params": params, "version": version, "timeoutMs": Int(limit * 1000)]
        target.map { message["targetClientId"] = $0 }
        try write(message)
        let deadline = Date().addingTimeInterval(limit)
        while responses[id] == nil { try read(deadline: deadline) }
        let reply = responses.removeValue(forKey: id) ?? [:]
        if !allowError && reply["resultType"] as? String != "success" {
            throw CodexIPCError.app(L("Codex вернул ошибку: %@", "\(reply["error"] as? String ?? "?")"))
        }
        return reply
    }

    /// Reads and handles exactly one message, waiting for it until `deadline`.
    func read(deadline: Date) throws {
        while true {
            if let message = try takeFrame() {
                handle(message)
                return
            }
            try fill(deadline: deadline)
        }
    }

    /// Whether a whole message is already waiting (in the buffer or on the socket), without waiting.
    func hasPending() -> Bool {
        if buffer.count >= 4 { return true }
        var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        return poll(&item, 1, 0) > 0
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "response":
            if let id = message["requestId"] as? String { responses[id] = message }
        case "broadcast":
            onBroadcast?(message)
        case "client-discovery-request":
            // Cooldown is never the one to handle anything.
            if let id = message["requestId"] as? String {
                try? write(["type": "client-discovery-response", "requestId": id, "response": ["canHandle": false]])
            }
        case "request":
            // Nothing addressed to Cooldown is ever handled, approvals least of all.
            if let id = message["requestId"] as? String {
                try? write(["type": "response", "requestId": id, "resultType": "error", "method": message["method"] ?? "",
                            "error": "cooldown handles no requests"])
            }
        default:
            break
        }
    }

    // MARK: Framing

    private func write(_ message: [String: Any]) throws {
        guard descriptor >= 0 else { throw CodexIPCError.unavailable }
        let body = try JSONSerialization.data(withJSONObject: message)
        guard !body.isEmpty, body.count <= Self.maxFrame else { throw CodexIPCError.app(L("Слишком большое сообщение.")) }
        // The length goes first, as four little-endian bytes.
        var frame = withUnsafeBytes(of: UInt32(body.count).littleEndian) { Data($0) }
        frame.append(body)
        let deadline = Date().addingTimeInterval(timeout)
        var offset = 0
        while offset < frame.count {
            let sent = frame.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress! + offset, frame.count - offset, 0) }
            if sent > 0 { offset += sent; continue }
            if sent < 0 && (errno == EAGAIN || errno == EINTR) {
                try waitFor(Int16(POLLOUT), deadline: deadline)
                continue
            }
            throw CodexIPCError.connection(L("Соединение с приложением разорвано"))
        }
    }

    private func takeFrame() throws -> [String: Any]? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        guard length > 0, length <= UInt32(Self.maxFrame) else {
            throw CodexIPCError.connection(L("Codex прислал сообщение недопустимого размера."))
        }
        guard buffer.count >= 4 + Int(length) else { return nil }
        let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + Int(length))
        buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 4 + Int(length))
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw CodexIPCError.connection(L("Codex прислал сообщение в незнакомом формате."))
        }
        return object
    }

    private func fill(deadline: Date) throws {
        guard descriptor >= 0 else { throw CodexIPCError.unavailable }
        try waitFor(Int16(POLLIN), deadline: deadline)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.recv(descriptor, &chunk, chunk.count, 0)
        if count > 0 { buffer.append(contentsOf: chunk[0..<count]); return }
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
        throw CodexIPCError.connection(L("Соединение с приложением разорвано"))
    }

    private func waitFor(_ events: Int16, deadline: Date) throws {
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw CodexIPCError.timeout }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let ready = poll(&item, 1, Int32(min(left, 1) * 1000) + 1)
            if ready > 0 {
                if item.revents & Int16(POLLERR | POLLNVAL) != 0 { throw CodexIPCError.connection(L("Соединение с приложением разорвано")) }
                return
            }
            if ready < 0 && errno != EINTR { throw CodexIPCError.connection(L("Соединение с приложением разорвано")) }
        }
    }
}
