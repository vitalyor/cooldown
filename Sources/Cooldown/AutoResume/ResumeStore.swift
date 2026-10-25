import Darwin
import Foundation
import SQLite3

/// What auto-continue keeps on disk. Every change is a read-modify-write under a file lock (two
/// Cooldown copies share this folder) and lands with an atomic, fsynced rename, so a send intent
/// written before sending survives a crash.
struct ResumeData: Codable, Equatable {
    struct Watch: Codable, Equatable {
        var threadId: String
        var enabled: Bool
        var maxResumes: Int
        var status: String
        var reason: String
        var updated: Date
        /// The work settings seen when the failed turn was first found ready to continue.
        var fingerprint: String?
        var fingerprintTurn: String?
    }

    /// One continuation for one failed turn. `pending` means written but not confirmed by Codex:
    /// either about to be sent, or sent with an unknown outcome.
    struct Send: Codable, Equatable {
        var threadId: String
        var failedTurn: String
        var messageId: String
        var state: String
        var newTurn: String?
        var time: Date
    }

    var version = 1
    var migrated = false
    var watches: [Watch] = []
    var sends: [Send] = []

    func watch(_ id: String) -> Watch? { watches.first { $0.threadId == id } }
    func attempts(_ id: String) -> Int { sends.filter { $0.threadId == id }.count }
    func pending(_ id: String) -> Send? { sends.first { $0.threadId == id && $0.state == "pending" } }
    func send(for id: String, turn: String) -> Send? { sends.first { $0.threadId == id && $0.failedTurn == turn } }

    mutating func edit(_ id: String, _ body: (inout Watch) -> Void) {
        guard let index = watches.firstIndex(where: { $0.threadId == id }) else { return }
        body(&watches[index])
    }
}

final class ResumeStore {
    enum Failure: LocalizedError {
        case unsafe(String)
        case io(String)
        var errorDescription: String? {
            switch self {
            case .unsafe(let path): return L("Папка автопродолжения выглядит небезопасно: %@", "\(path)")
            case .io(let what): return L("Не удалось сохранить состояние автопродолжения: %@", "\(what)")
            }
        }
    }

    let folder: URL
    private let legacy: URL?
    private let lock = NSLock()
    private var held: [String: Int32] = [:]

    init(folder: URL, legacy: URL?) {
        self.folder = folder
        self.legacy = legacy
    }

    static let shared = ResumeStore(folder: Settings.appSupport.appendingPathComponent("CodexContinue", isDirectory: true),
                                    legacy: Settings.appSupport.appendingPathComponent("AutoResume/state.sqlite3"))

    private var file: URL { folder.appendingPathComponent("state.json") }

    // MARK: Reading and writing

    func load() throws -> ResumeData {
        lock.lock()
        defer { lock.unlock() }
        return try withFileLock { try read() }
    }

    /// Changes the stored data in one step; nothing is written if `body` throws.
    @discardableResult
    func update<T>(_ body: (inout ResumeData) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try withFileLock {
            var data = try read()
            let before = data
            let result = try body(&data)
            if data != before { try write(data) }
            return result
        }
    }

    private func read() throws -> ResumeData {
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        var data: ResumeData
        if fd < 0 {
            guard errno == ENOENT else { throw Failure.unsafe(file.path) }
            data = ResumeData()
        } else {
            defer { Darwin.close(fd) }
            try checkOwned(fd, file.path)
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            let bytes = try handle.readToEnd() ?? Data()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            do { data = try decoder.decode(ResumeData.self, from: bytes) } catch { throw Failure.io(L("файл состояния повреждён")) }
        }
        if !data.migrated {
            data.migrated = true
            data.watches += importLegacy().filter { row in !data.watches.contains { $0.threadId == row.threadId } }
            try write(data)
        }
        return data
    }

    private func write(_ data: ResumeData) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(data)
        let temporary = folder.appendingPathComponent(".state-\(getpid())-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.io(temporary.lastPathComponent) }
        var ok = bytes.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { if errno == EINTR { continue }; return false }
                offset += written
            }
            return true
        }
        ok = ok && fsync(fd) == 0
        Darwin.close(fd)
        guard ok, rename(temporary.path, file.path) == 0 else {
            unlink(temporary.path)
            throw Failure.io(file.lastPathComponent)
        }
        // The rename itself must reach the disk too.
        let directory = Darwin.open(folder.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if directory >= 0 { fsync(directory); Darwin.close(directory) }
    }

    /// The store-wide lock that keeps two Cooldown copies from overwriting each other's changes.
    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        try prepareFolder()
        let path = folder.appendingPathComponent("store.lock").path
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unsafe(path) }
        defer { Darwin.close(fd) }
        try checkOwned(fd, path)
        guard flock(fd, LOCK_EX) == 0 else { throw Failure.io("store.lock") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// The folder must be the person's own real directory, closed to everyone else.
    private func prepareFolder() throws {
        var info = stat()
        if lstat(folder.path, &info) != 0 {
            guard errno == ENOENT, mkdir(folder.path, 0o700) == 0 || errno == EEXIST, lstat(folder.path, &info) == 0 else {
                throw Failure.unsafe(folder.path)
            }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw Failure.unsafe(folder.path) }
        if info.st_mode & 0o777 != 0o700 { chmod(folder.path, 0o700) }
    }

    private func checkOwned(_ fd: Int32, _ path: String) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { throw Failure.unsafe(path) }
        if info.st_mode & 0o077 != 0 { fchmod(fd, 0o600) }
    }

    // MARK: One copy per conversation

    /// Takes the exclusive per-conversation lock for this process (true if held now).
    func claim(_ thread: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if held[thread] != nil { return true }
        guard (try? prepareFolder()) != nil else { return false }
        let path = folder.appendingPathComponent("watch-\(thread).lock").path
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        guard (try? checkOwned(fd, path)) != nil, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            return false
        }
        held[thread] = fd
        return true
    }

    func release(_ thread: String) {
        lock.lock()
        defer { lock.unlock() }
        if let fd = held.removeValue(forKey: thread) {
            flock(fd, LOCK_UN)
            Darwin.close(fd)
        }
    }

    // MARK: The previous version's data (read once)

    /// Enabled watches of the previous version (`AutoResume/state.sqlite3`): conversation and
    /// number of attempts only, nothing else is taken over.
    private func importLegacy() -> [ResumeData.Watch] {
        guard let legacy, FileManager.default.fileExists(atPath: legacy.path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(legacy.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT thread_id, max_resumes FROM watches WHERE enabled = 1", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [ResumeData.Watch] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: text).lowercased()
            guard ResumeRules.isThreadId(id), !rows.contains(where: { $0.threadId == id }) else { continue }
            let max = min(10, Swift.max(1, Int(sqlite3_column_int64(statement, 1))))
            rows.append(ResumeData.Watch(threadId: id, enabled: true, maxResumes: max, status: "starting",
                                         reason: L("Перенесено из прошлой версии Cooldown."), updated: Date()))
        }
        return rows
    }
}
