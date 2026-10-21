import AppKit
import Darwin
import Foundation

/// Why talking to the Codex app did not work. Only `.connection`, `.threadUnavailable` and
/// `.timeout` are temporary; none of them is ever evidence that allows sending.
enum CodexIPCError: Error, LocalizedError {
    /// The app answered something unsafe or unexpected; nothing was retried.
    case app(String)
    /// The app is closed, asleep or restarting.
    case connection(String)
    /// The app is connected, but the chosen conversation is not loaded in it.
    case threadUnavailable
    case timeout

    var errorDescription: String? {
        switch self {
        case .app(let text), .connection(let text): return text
        case .threadUnavailable: return "Выбранный диалог пока не открыт в приложении Codex"
        case .timeout: return "Приложение Codex не ответило вовремя"
        }
    }

    var isTransient: Bool {
        if case .app = self { return false }
        return true
    }
}

/// The Codex desktop app: where it is and whether its local protocol is a known one.
enum CodexApp {
    static let bundleId = "com.openai.codex"
    /// Oldest build the protocol below was checked against. Newer builds are accepted because
    /// every exchange is validated and fails closed; older ones are refused.
    static let minimumBuild = 20770

    static var url: URL? {
        let fm = FileManager.default
        let candidates = ["/Applications/ChatGPT.app", "/Applications/Codex.app"].map { URL(fileURLWithPath: $0) }
            + [NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)].compactMap { $0 }
        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("Contents/Info.plist").path) && info($0)?.id == bundleId }
    }

    private static func info(_ url: URL) -> (id: String?, version: String?, build: String?)? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return (plist["CFBundleIdentifier"] as? String, plist["CFBundleShortVersionString"] as? String, plist["CFBundleVersion"] as? String)
    }

    /// Throws unless a recognizable Codex app of a supported build is installed.
    @discardableResult
    static func checkVersion() throws -> URL {
        guard let url, let info = info(url), info.id == bundleId, let build = info.build, let number = Int(build),
              build.allSatisfy(\.isNumber) else {
            throw CodexIPCError.app("Не найдено распознаваемое приложение Codex")
        }
        guard number >= minimumBuild else { throw CodexIPCError.app("Версия приложения Codex старее проверенной; обновите приложение") }
        return url
    }

    /// Opens Codex on that conversation (the app's own codex:// link), or just the app.
    static func open(thread id: String) {
        guard UUID(uuidString: id) != nil, let url = URL(string: "codex://threads/\(id.lowercased())") else { open(); return }
        NSWorkspace.shared.open(url)
    }

    static func open() {
        for id in [bundleId, "com.openai.chat"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
    }

    static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty }

    /// Brings the chosen conversation up in the app, in the background. Only navigation: no
    /// prompt is filled in or sent, and success only means the request went out.
    static func openThread(_ id: String) throws {
        let app = try checkVersion()
        guard let uuid = UUID(uuidString: id) else { throw CodexIPCError.app("Нужен точный идентификатор диалога") }
        guard let link = URL(string: "codex://threads/" + uuid.uuidString.lowercased()) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open([link], withApplicationAt: app, configuration: configuration)
    }
}

/// One connection to the Codex app's local socket (~/.codex/ipc/ipc.sock): length-prefixed JSON
/// frames. Cooldown is only ever a follower: it never claims a conversation, never handles the
/// app's requests (approvals included) and never answers "I can handle this" to discovery.
/// Blocking calls with deadlines; used from one background queue.
final class CodexIPCConnection {
    static let maxFrame = 32 * 1024 * 1024
    static let continuation = "Лимит восстановился. Продолжи прерванную работу в этой сессии. Сначала сверь текущий "
        + "прогресс и рабочую папку; не повторяй уже выполненные шаги, не расширяй объём работы, "
        + "не обходи подтверждения. Если работа уже завершена или нужно решение пользователя, "
        + "прямо скажи об этом и остановись."

    private var fd: Int32 = -1
    private let timeout: TimeInterval
    private var clientId = "initializing-client"
    private(set) var owner: String?
    private var threadId: String?
    private var snapshotValue: [String: Any]?
    private var snapshotPending = false
    private(set) var stateGeneration = 0

    init(timeout: TimeInterval = 12) { self.timeout = timeout }

    deinit { close() }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    // MARK: Connecting

    func open() throws {
        try CodexApp.checkVersion()
        let socketPath = CodexPaths.home.appendingPathComponent("ipc/ipc.sock").path
        let directory = (socketPath as NSString).deletingLastPathComponent
        var dirInfo = stat(), sockInfo = stat()
        guard lstat(directory, &dirInfo) == 0, lstat(socketPath, &sockInfo) == 0 else {
            throw CodexIPCError.connection("Приложение Codex не запущено")
        }
        guard (dirInfo.st_mode & S_IFMT) == S_IFDIR, (sockInfo.st_mode & S_IFMT) == S_IFSOCK else {
            throw CodexIPCError.app("Путь IPC — не сокет в обычном каталоге")
        }
        for info in [dirInfo, sockInfo] where info.st_uid != getuid() || info.st_mode & 0o077 != 0 {
            throw CodexIPCError.app("Небезопасные права или владелец IPC; права автоматически не меняются")
        }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CodexIPCError.connection("Не удалось открыть сокет") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(); throw CodexIPCError.app("Слишком длинный путь IPC") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close()
            throw CodexIPCError.connection("Приложение Codex не принимает подключения")
        }
        do {
            let reply = try request("initialize", ["clientType": "cooldown"], version: 0)
            guard let id = JSON.nonEmptyString((reply["result"] as? [String: Any])?["clientId"]) else {
                throw CodexIPCError.app("Приложение не выдало идентификатор подключения")
            }
            clientId = id
        } catch {
            close()
            throw error
        }
    }

    // MARK: Frames

    private func send(_ message: [String: Any]) throws {
        guard fd >= 0 else { throw CodexIPCError.connection("Соединение с приложением закрыто") }
        guard let data = try? JSONSerialization.data(withJSONObject: message), data.count > 0, data.count <= Self.maxFrame else {
            throw CodexIPCError.app("Сообщение IPC слишком большое")
        }
        var length = UInt32(data.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(data)
        try frame.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                if sent < 0 {
                    if errno == EINTR { continue }
                    throw CodexIPCError.connection("Соединение с приложением разорвано")
                }
                offset += sent
            }
        }
    }

    /// Waits until the socket has data or the deadline passes.
    private func wait(until deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CodexIPCError.timeout }
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, Int32(min(remaining * 1000, 60_000).rounded(.up)))
            if ready > 0 { return }
            if ready < 0 && errno != EINTR { throw CodexIPCError.connection("Соединение с приложением разорвано") }
        }
    }

    private func exact(_ count: Int, deadline: Date) throws -> Data {
        var data = Data(count: count)
        var filled = 0
        while filled < count {
            try wait(until: deadline)
            let got = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + filled, count - filled, 0) }
            if got == 0 { throw CodexIPCError.connection("Соединение с приложением разорвано") }
            if got < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw CodexIPCError.connection("Соединение с приложением разорвано")
            }
            filled += got
        }
        return data
    }

    /// Reads one frame and handles what the app may ask of any client.
    @discardableResult
    func read(deadline: Date) throws -> [String: Any] {
        let header = try exact(4, deadline: deadline)
        let size = Int(header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
        guard size > 0, size <= Self.maxFrame else { throw CodexIPCError.app("Длина сообщения IPC не поддерживается") }
        let body = try exact(size, deadline: deadline)
        guard let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw CodexIPCError.app("Сообщение IPC не является объектом")
        }
        let type = message["type"] as? String
        if type == "client-discovery-request" {
            try send(["type": "client-discovery-response", "requestId": message["requestId"] ?? NSNull(), "response": ["canHandle": false]])
        }
        if type == "request" {
            // In particular: never become an approval handler or a conversation's owner.
            try send(["type": "response", "requestId": message["requestId"] ?? NSNull(), "resultType": "error", "error": "unsupported-by-cooldown"])
        }
        if type == "broadcast", message["method"] as? String == "thread-stream-state-changed",
           let params = message["params"] as? [String: Any], let threadId,
           params["conversationId"] as? String == threadId, params["hostId"] as? String == "local",
           let owner, message["sourceClientId"] as? String == owner {
            guard Num.int(message["version"]) == 11, !JSON.isBool(message["version"]) else {
                throw CodexIPCError.app("Изменилась версия протокола состояния приложения")
            }
            stateGeneration += 1
            let change = params["change"] as? [String: Any]
            switch change?["type"] as? String {
            case "snapshot":
                snapshotValue = change?["conversationState"] as? [String: Any]
                snapshotPending = false
            case "patches":
                // Never infer the current state from a partial or missed patch stream.
                snapshotValue = nil
            default:
                throw CodexIPCError.app("Формат изменения состояния приложения не поддерживается")
            }
        }
        return message
    }

    func request(_ method: String, _ params: [String: Any], version: Int, target: String? = nil) throws -> [String: Any] {
        let requestId = UUID().uuidString.lowercased()
        var message: [String: Any] = ["type": "request", "requestId": requestId, "sourceClientId": clientId, "method": method,
                                      "params": params, "version": version, "timeoutMs": Int(timeout * 1000)]
        if let target { message["targetClientId"] = target }
        try send(message)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let reply = try read(deadline: deadline)
            guard reply["type"] as? String == "response", reply["requestId"] as? String == requestId else { continue }
            guard reply["resultType"] as? String == "success" else {
                if reply["error"] as? String == "no-client-found" { throw CodexIPCError.threadUnavailable }
                throw CodexIPCError.app("Приложение отклонило запрос или интерфейс несовместим; автоматического повтора не было")
            }
            guard reply["method"] as? String == method else { throw CodexIPCError.app("Метод ответа приложения не совпадает") }
            return reply
        }
    }

    private func follow(_ enabled: Bool) throws {
        guard let owner, let threadId else { return }
        try send(["type": "broadcast", "method": "thread-stream-following-changed", "sourceClientId": clientId,
                  "targetClientIds": [owner], "version": 1,
                  "params": ["hostId": "local", "conversationId": threadId, "following": enabled]])
    }

    // MARK: Conversation state

    /// A fresh full state of one conversation from its owner window.
    func snapshot(_ id: String) throws -> [String: Any] {
        guard let uuid = UUID(uuidString: id) else { throw CodexIPCError.app("Нужен точный идентификатор диалога") }
        let thread = uuid.uuidString.lowercased()
        threadId = thread
        let reply = try request("thread-owner-discovery", ["hostId": "local", "conversationId": thread], version: 1)
        guard let handler = reply["handledByClientId"] as? String else { throw CodexIPCError.app("Не указан владелец задачи в приложении") }
        owner = handler
        try follow(false)
        snapshotValue = nil
        snapshotPending = true
        try follow(true)
        let deadline = Date().addingTimeInterval(timeout)
        while snapshotValue == nil { try read(deadline: deadline) }
        guard let state = snapshotValue, state["id"] as? String == thread else {
            throw CodexIPCError.app("Приложение вернуло не совпадающий статус задачи")
        }
        return state
    }

    /// Consumes events that already arrived before sending, never applying patches. A busy or
    /// half-received stream cancels the send rather than draining forever.
    private func drainPending() throws {
        let deadline = Date().addingTimeInterval(timeout)
        for _ in 0..<128 {
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&item, 1, 0) <= 0 { return }
            try read(deadline: deadline)
        }
        throw CodexIPCError.app("Состояние приложения всё ещё меняется; текущее возобновление отменено")
    }

    /// Starts the next turn with the continuation text, inheriting every setting of the
    /// conversation. Re-reads the state first and refuses if anything moved since `expected`.
    func resume(_ id: String, expected: String, messageId: String, guard allowed: () -> Bool) throws -> String {
        try CodexApp.checkVersion()   // stop if the app updated while waiting
        let state = try snapshot(id)
        guard ResumePolicy.decide(state).action == .resume, (try? ResumePolicy.fingerprint(state)) == expected else {
            throw CodexIPCError.app("Статус задачи изменился до отправки; возобновление отменено")
        }
        let generation = stateGeneration
        try drainPending()
        guard generation == stateGeneration else { throw CodexIPCError.app("До отправки получен новый статус задачи; возобновление отменено") }
        guard let thread = threadId else { throw CodexIPCError.app("Диалог не выбран") }
        let request: [String: Any] = ["threadId": thread, "clientUserMessageId": messageId,
                                      "input": [["type": "text", "text": Self.continuation, "text_elements": [Any]()]]]
        guard allowed() else {
            throw CodexIPCError.app("Наблюдение остановлено или изменилось разрешение на отправку; возобновление отменено")
        }
        let reply = try self.request("thread-follower-start-turn", ["conversationId": thread, "turnStart": ["request": request]],
                                     version: 2, target: owner)
        guard let turnId = JSON.nonEmptyString((((reply["result"] as? [String: Any])?["result"] as? [String: Any])?["turn"] as? [String: Any])?["id"]) else {
            throw CodexIPCError.app("Результат возобновления неизвестен; проверьте в приложении, автоматической повторной отправки не будет")
        }
        return turnId
    }
}
