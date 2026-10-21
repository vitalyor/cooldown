import Foundation
import SQLite3

/// Codex's own list of conversations (~/.codex/state_*.sqlite, table `threads`): id, name, who
/// started it and where its session file is right now. Codex moves and splits session files
/// (continued conversations land in archived_sessions under a new name), so this index, not the
/// folder layout, says which file belongs to which conversation. Opened read-only.
enum CodexThreadIndex {
    struct Thread {
        let id: String
        let title: String
        let rolloutPath: String
        let isUser: Bool
        let updatedAt: Date
    }

    /// The newest state database (the number in its name goes up with Codex's schema).
    static var databaseURL: URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: CodexPaths.home.path)) ?? []
        let candidates = names.filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }
        let newest = candidates.max { number($0) < number($1) }
        return newest.map { CodexPaths.home.appendingPathComponent($0) }
    }

    private static func number(_ name: String) -> Int {
        Int(name.dropFirst("state_".count).dropLast(".sqlite".count)) ?? 0
    }

    /// One conversation by id, if the index has it.
    static func thread(id: String) -> Thread? {
        query("WHERE id = ? LIMIT 1") { sqlite3_bind_text($0, 1, id.lowercased(), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }?.first
    }

    /// Whether one of Codex's own reviewers ("approve for me") worked since `since`: then a
    /// permission request is being decided by Codex, not waiting for the person.
    static func reviewerActive(since: Date) -> Bool {
        guard let url = databaseURL else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM threads WHERE thread_source = 'guardian_review' AND COALESCE(updated_at_ms, updated_at * 1000) >= ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(since.timeIntervalSince1970 * 1000))
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Conversations updated since `since`, newest first; nil when the index cannot be read.
    static func updated(since: Date) -> [Thread]? {
        query("WHERE updated_at >= ? AND archived = 0 ORDER BY updated_at DESC LIMIT 50") {
            sqlite3_bind_int64($0, 1, Int64(since.timeIntervalSince1970))
        }
    }

    /// Whether a conversation is archived; nil when the index cannot say.
    static func isArchived(id: String) -> Bool? {
        var result: Bool?
        rows("SELECT archived FROM threads WHERE id = ? LIMIT 1", bind: {
            sqlite3_bind_text($0, 1, id.lowercased(), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }) { result = sqlite3_column_int64($0, 0) != 0 }
        return result
    }

    /// Every conversation the person can see in Codex (not its own reviewer runs), newest first.
    static func conversations() -> [CodexConversation]? {
        var list: [CodexConversation] = []
        let sql = """
            SELECT id, name, COALESCE(NULLIF(preview, ''), title), cwd, COALESCE(updated_at_ms, updated_at * 1000), archived
            FROM threads WHERE COALESCE(thread_source, '') <> 'guardian_review' AND (preview <> '' OR title <> '')
            ORDER BY COALESCE(updated_at_ms, updated_at * 1000) DESC
            """
        let ok = rows(sql, bind: { _ in }) { statement in
            func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
            guard let id = text(0) else { return }
            let row = CodexConversation(id: id.lowercased(), name: text(1), preview: text(2), cwd: text(3),
                                        updatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 4)) / 1000),
                                        archived: sqlite3_column_int64(statement, 5) != 0)
            if row.title != "Guardian review" { list.append(row) }
        }
        return ok ? list : nil
    }

    @discardableResult
    private static func rows(_ sql: String, bind: (OpaquePointer?) -> Void, each: (OpaquePointer?) -> Void) -> Bool {
        guard let url = databaseURL else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        while sqlite3_step(statement) == SQLITE_ROW { each(statement) }
        return true
    }

    private static func query(_ tail: String, bind: (OpaquePointer?) -> Void) -> [Thread]? {
        guard let url = databaseURL else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        let sql = """
            SELECT id, COALESCE(NULLIF(name, ''), title), rollout_path, COALESCE(thread_source, ''), updated_at
            FROM threads \(tail)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        var result: [Thread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
            let source = text(3)
            result.append(Thread(id: text(0).lowercased(), title: text(1), rolloutPath: text(2),
                                 isUser: source.isEmpty || source == "user",
                                 updatedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 4)))))
        }
        return result
    }
}
