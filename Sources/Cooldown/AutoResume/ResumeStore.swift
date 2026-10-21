import Darwin
import Foundation
import SQLite3

/// The private ledger of auto-continue: which conversations are watched, and every message
/// intent written down *before* it is sent. An intent that never got a confirmed answer stays
/// "dispatching" forever, and such a conversation is never sent anything again automatically.
/// Used from one queue only.
final class ResumeStore {
    struct Watch: Equatable {
        var threadId: String
        var enabled: Bool
        var maxResumes: Int
        var status: String
        var reason: String
        var updated: Date
    }

    struct Attempt {
        var failedTurn: String
        var messageId: String
        var state: String
        var created: Date
    }

    enum StoreError: Error, LocalizedError {
        case unsafe(String)
        var errorDescription: String? { if case .unsafe(let text) = self { return text }; return nil }
    }

    let directory: URL
    private var db: OpaquePointer?
    private var locks: [String: Int32] = [:]

    init(directory: URL = Settings.appSupport.appendingPathComponent("AutoResume", isDirectory: true)) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
            throw StoreError.unsafe("Папка состояния автопродолжения должна принадлежать вам")
        }
        if info.st_mode & 0o077 != 0 { chmod(directory.path, 0o700) }
        let path = directory.appendingPathComponent("state.sqlite3").path
        if lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { throw StoreError.unsafe("База состояния не может быть ссылкой") }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            throw StoreError.unsafe("Не удалось открыть базу состояния автопродолжения")
        }
        chmod(path, 0o600)
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA synchronous=FULL")
        try exec("""
        CREATE TABLE IF NOT EXISTS watches (
          thread_id TEXT PRIMARY KEY, enabled INTEGER NOT NULL,
          max_resumes INTEGER NOT NULL, status TEXT NOT NULL,
          reason TEXT NOT NULL, pid INTEGER, updated REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS attempts (
          thread_id TEXT NOT NULL, failed_turn TEXT NOT NULL,
          message_id TEXT NOT NULL, fingerprint TEXT NOT NULL,
          state TEXT NOT NULL, resumed_turn TEXT, created REAL NOT NULL,
          PRIMARY KEY(thread_id, failed_turn)
        );
        """)
    }

    deinit {
        locks.values.forEach { Darwin.close($0) }
        sqlite3_close(db)
    }

    // MARK: SQL helpers

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.unsafe("Ошибка базы состояния: " + String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Runs one statement; `row` is called for each result row.
    @discardableResult
    private func run(_ sql: String, _ values: [Any?] = [], row: ((OpaquePointer?) -> Void)? = nil) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.unsafe("Ошибка базы состояния: " + String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let flag as Bool: sqlite3_bind_int64(statement, position, flag ? 1 : 0)
            case let text as String: sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case let number as Int: sqlite3_bind_int64(statement, position, Int64(number))
            case let number as Double: sqlite3_bind_double(statement, position, number)
            default: sqlite3_bind_null(statement, position)
            }
        }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW { row?(statement); continue }
            if code == SQLITE_DONE { return Int(sqlite3_changes(db)) }
            throw StoreError.unsafe("Ошибка базы состояния: " + String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private static func watch(_ s: OpaquePointer?) -> Watch {
        Watch(threadId: text(s, 0), enabled: sqlite3_column_int64(s, 1) != 0, maxResumes: Int(sqlite3_column_int64(s, 2)),
              status: text(s, 3), reason: text(s, 4), updated: Date(timeIntervalSince1970: sqlite3_column_double(s, 5)))
    }

    private let watchColumns = "thread_id, enabled, max_resumes, status, reason, updated"

    // MARK: Watches

    func arm(_ id: String, maxResumes: Int) throws {
        try run("""
            INSERT INTO watches VALUES (?,1,?,'starting','Ожидает запуска',NULL,?)
            ON CONFLICT(thread_id) DO UPDATE SET enabled=1, max_resumes=excluded.max_resumes,
            status='starting', reason='Ожидает запуска', pid=NULL, updated=excluded.updated
            """, [id, maxResumes, Date().timeIntervalSince1970])
    }

    func get(_ id: String) -> Watch? {
        var result: Watch?
        try? run("SELECT \(watchColumns) FROM watches WHERE thread_id=?", [id]) { result = Self.watch($0) }
        return result
    }

    func all() -> [Watch] {
        var rows: [Watch] = []
        try? run("SELECT \(watchColumns) FROM watches ORDER BY updated DESC") { rows.append(Self.watch($0)) }
        return rows
    }

    /// `onlyEnabled`: a paused watch keeps its "paused" status instead of being overwritten.
    func update(_ id: String, status: String, reason: String, disable: Bool = false, onlyEnabled: Bool = false) {
        _ = try? run("""
            UPDATE watches SET status=?, reason=?, pid=?, updated=?, enabled=CASE WHEN ? THEN 0 ELSE enabled END
            WHERE thread_id=? AND (?=0 OR enabled=1)
            """, [status, reason, Int(getpid()), Date().timeIntervalSince1970, disable, id, onlyEnabled])
    }

    func stop(_ id: String) {
        update(id, status: "paused", reason: "Вы выключили автопродолжение", disable: true)
    }

    // MARK: Attempts

    func attempt(_ id: String, turn: String) -> Attempt? {
        var result: Attempt?
        try? run("SELECT failed_turn, message_id, state, created FROM attempts WHERE thread_id=? AND failed_turn=?", [id, turn]) {
            result = Attempt(failedTurn: Self.text($0, 0), messageId: Self.text($0, 1), state: Self.text($0, 2),
                             created: Date(timeIntervalSince1970: sqlite3_column_double($0, 3)))
        }
        return result
    }

    func count(_ id: String) -> Int {
        var result = 0
        try? run("SELECT count(*) FROM attempts WHERE thread_id=?", [id]) { result = Int(sqlite3_column_int64($0, 0)) }
        return result
    }

    func uncertain(_ id: String) -> Bool {
        var found = false
        try? run("SELECT 1 FROM attempts WHERE thread_id=? AND state='dispatching' LIMIT 1", [id]) { _ in found = true }
        return found
    }

    /// Writes the intent down first, atomically with the pause and budget checks. Nil: not allowed.
    func claim(_ id: String, turn: String, fingerprint: String) -> String? {
        guard (try? exec("BEGIN IMMEDIATE")) != nil else { return nil }
        guard let watch = get(id), watch.enabled, count(id) < watch.maxResumes, attempt(id, turn: turn) == nil else {
            try? exec("ROLLBACK")
            return nil
        }
        let message = UUID().uuidString.lowercased()
        do {
            try run("INSERT INTO attempts VALUES (?,?,?,?,'dispatching',NULL,?)", [id, turn, message, fingerprint, Date().timeIntervalSince1970])
            try exec("COMMIT")
            return message
        } catch {
            try? exec("ROLLBACK")
            return nil
        }
    }

    func acknowledged(_ id: String, turn: String, resumedTurn: String) {
        _ = try? run("UPDATE attempts SET state='sent', resumed_turn=? WHERE thread_id=? AND failed_turn=?", [resumedTurn, id, turn])
    }

    /// The last local check right before the app is asked to start a turn: still watched, this
    /// exact intent, still within the budget.
    func canDispatch(_ id: String, turn: String, messageId: String) -> Bool {
        var allowed = false
        try? run("""
            SELECT 1 FROM watches w JOIN attempts a ON a.thread_id=w.thread_id
            WHERE w.thread_id=? AND w.enabled=1 AND a.failed_turn=? AND a.message_id=? AND a.state='dispatching'
            AND (SELECT count(*) FROM attempts WHERE thread_id=w.thread_id) <= w.max_resumes
            """, [id, turn, messageId]) { _ in allowed = true }
        return allowed
    }

    // MARK: One watcher per conversation

    /// An exclusive lock on the conversation, so two watchers can never run for it.
    func lock(_ id: String) throws {
        guard locks[id] == nil else { return }
        let path = directory.appendingPathComponent(id + ".lock").path
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.unsafe("Не удалось создать блокировку задачи") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw StoreError.unsafe("Для этой задачи уже работает другое наблюдение")
        }
        locks[id] = fd
    }

    func unlock(_ id: String) {
        if let fd = locks.removeValue(forKey: id) { Darwin.close(fd) }
    }

    // MARK: Moving over from the separate Python tool

    /// Brings watches and the whole send ledger over from codex-auto-resume
    /// (~/.codex-auto-resume/state.sqlite3), once. Live watches there are switched off first, so
    /// the old watcher process stops itself and only Cooldown watches from now on; those that
    /// were on stay on here. Returns the ids whose old watcher may still be shutting down.
    @discardableResult
    func importLegacy() -> [String] {
        let marker = directory.appendingPathComponent(".imported-legacy")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return [] }
        let legacyDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex-auto-resume")
        let path = legacyDir.appendingPathComponent("state.sqlite3").path
        defer { FileManager.default.createFile(atPath: marker.path, contents: Data()) }
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        var legacy: OpaquePointer?
        guard sqlite3_open_v2(path, &legacy, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            sqlite3_close(legacy)
            return []
        }
        defer { sqlite3_close(legacy) }
        sqlite3_busy_timeout(legacy, 5000)
        func rows(_ sql: String) -> [[Any?]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(legacy, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            var result: [[Any?]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append((0..<sqlite3_column_count(statement)).map { column -> Any? in
                    switch sqlite3_column_type(statement, column) {
                    case SQLITE_INTEGER: return Int(sqlite3_column_int64(statement, column))
                    case SQLITE_FLOAT: return sqlite3_column_double(statement, column)
                    case SQLITE_NULL: return nil
                    default: return Self.text(statement, column)
                    }
                })
            }
            return result
        }
        let watches = rows("SELECT thread_id, enabled, max_resumes, status, reason, updated FROM watches")
        let live = watches.filter { ($0[1] as? Int ?? 0) != 0 }.compactMap { $0[0] as? String }
        // Switch the old watchers off before taking over: each one notices within a second and exits.
        sqlite3_exec(legacy, "UPDATE watches SET enabled=0, status='paused', reason='Перенесено в Cooldown' WHERE enabled=1", nil, nil, nil)
        for row in watches {
            guard let id = row[0] as? String, get(id) == nil else { continue }
            _ = try? run("INSERT INTO watches VALUES (?,?,?,?,?,NULL,?)",
                         [id, live.contains(id), row[2] as? Int ?? 3, live.contains(id) ? "starting" : (row[3] as? String ?? "stopped"),
                          row[4] as? String ?? "", (row[5] as? Double) ?? Double(row[5] as? Int ?? 0)])
        }
        for row in rows("SELECT thread_id, failed_turn, message_id, fingerprint, state, resumed_turn, created FROM attempts") {
            _ = try? run("INSERT OR IGNORE INTO attempts VALUES (?,?,?,?,?,?,?)",
                         [row[0], row[1], row[2], row[3], row[4], row[5], (row[6] as? Double) ?? Double(row[6] as? Int ?? 0)])
        }
        return live
    }

    /// Whether the old tool's watcher for this conversation has exited (its lock is free).
    static func legacyWatcherGone(_ id: String) -> Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex-auto-resume/\(id).lock").path
        let fd = Darwin.open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return true }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(fd, LOCK_UN)
        return true
    }
}
