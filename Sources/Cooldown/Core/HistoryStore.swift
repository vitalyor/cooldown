import Foundation

struct FileCursor: Codable {
    var offset: UInt64
    var size: UInt64
    var cwd: String?
    var model: String?
    var lastTotals: TokenCounts?
    /// Recently counted responses by id, for logs that repeat one response on several lines.
    var seen: [String: TokenCounts]?
}

/// What a history scan found since the cursors it was given.
struct ScanOutput {
    var tokens: [BucketKey: TokenCounts] = [:]
    var samples: [LimitSample] = []
    var cursors: [String: FileCursor] = [:]
}

/// Reads one agent's local session files incrementally.
protocol HistoryScanning {
    func scan(cursors: [String: FileCursor], progress: (Double) -> Void) -> ScanOutput
}

struct HistoryFile: Codable {
    var version = 1
    var buckets: [TokenBucket] = []
    var samples: [LimitSample] = []
    var cursors: [String: FileCursor] = [:]

    static let horizon: TimeInterval = 45 * 86400

    mutating func merge(_ scan: ScanOutput) {
        if !scan.tokens.isEmpty {
            var sums: [BucketKey: TokenCounts] = [:]
            for bucket in buckets { sums[bucket.key, default: TokenCounts()] = sums[bucket.key, default: TokenCounts()] + bucket.counts }
            for (key, counts) in scan.tokens { sums[key, default: TokenCounts()] = sums[key, default: TokenCounts()] + counts }
            buckets = sums.map { TokenBucket(key: $0.key, counts: $0.value) }.sorted { $0.key.hour < $1.key.hour }
        }
        add(samples: scan.samples)
        for (path, cursor) in scan.cursors { cursors[path] = cursor }
    }

    mutating func add(samples new: [LimitSample]) {
        guard !new.isEmpty else { return }
        samples = Self.thin(samples + new)
    }

    /// One point per window per two minutes (the latest one) is plenty for any chart here.
    static func thin(_ all: [LimitSample]) -> [LimitSample] {
        var latest: [String: LimitSample] = [:]
        for sample in all {
            let slot = Int(sample.t.timeIntervalSince1970 / 120)
            let key = "\(sample.kind.rawValue)-\(slot)"
            if let existing = latest[key], existing.t >= sample.t { continue }
            latest[key] = sample
        }
        return latest.values.sorted { $0.t < $1.t }
    }

    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.horizon)
        buckets.removeAll { $0.key.hour < cutoff }
        samples.removeAll { $0.t < cutoff }
        // A file that is gone may only have moved (Codex moves continued conversations to
        // archived_sessions); its cursor is what keeps it from being counted twice, so cursors of
        // missing files are kept unless there are a great many.
        if cursors.count > 3000 {
            cursors = cursors.filter { FileManager.default.fileExists(atPath: $0.key) }
        }
    }
}

final class HistoryStore {
    let url: URL
    private let queue = DispatchQueue(label: "cooldown.history.save")

    init(provider: ProviderID) {
        url = Settings.appSupport.appendingPathComponent("history-\(provider.rawValue).json")
    }

    func load() -> HistoryFile {
        guard let data = try? Data(contentsOf: url) else { return HistoryFile() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(HistoryFile.self, from: data)) ?? HistoryFile()
    }

    func save(_ history: HistoryFile) {
        let url = self.url
        queue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            if let data = try? encoder.encode(history) { try? data.write(to: url, options: .atomic) }
        }
    }
}

/// Line-by-line reading of an append-only log from a byte offset, shared by the scanners.
enum JSONLReader {
    /// Calls `line` for every complete line after `cursor.offset` and moves the offset past it.
    static func read(_ url: URL, cursor: inout FileCursor, advanced: (UInt64) -> Void,
                     line: (UnsafePointer<UInt8>, Int, inout FileCursor) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: cursor.offset) } catch { return }

        var pending = Data()
        while true {
            guard let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty else { break }
            pending.append(chunk)
            var consumed = 0
            pending.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                let count = raw.count
                var start = 0
                while start < count {
                    guard let hit = memchr(base + start, 0x0A, count - start) else { break }
                    let end = base.distance(to: UnsafePointer<UInt8>(hit.assumingMemoryBound(to: UInt8.self)))
                    if end - start > 2 { line(base + start, end - start, &cursor) }
                    start = end + 1
                }
                consumed = start
            }
            if consumed > 0 {
                cursor.offset += UInt64(consumed)
                advanced(UInt64(consumed))
                pending = pending.subdata(in: pending.index(pending.startIndex, offsetBy: consumed)..<pending.endIndex)
            }
        }
    }

    static func contains(_ bytes: UnsafePointer<UInt8>, _ count: Int, _ pattern: [UInt8]) -> Bool {
        let length = pattern.count
        guard count >= length, let first = pattern.first else { return false }
        return pattern.withUnsafeBufferPointer { needle in
            var i = 0
            while i <= count - length {
                guard let hit = memchr(bytes + i, Int32(first), count - length + 1 - i) else { return false }
                let at = bytes.distance(to: UnsafePointer<UInt8>(hit.assumingMemoryBound(to: UInt8.self)))
                if memcmp(bytes + at, needle.baseAddress!, length) == 0 { return true }
                i = at + 1
            }
            return false
        }
    }

    /// Files under `root` whose name matches, changed within the horizon, sorted by path.
    static func files(under root: URL, horizon: TimeInterval, matching: (String) -> Bool) -> [(url: URL, size: UInt64)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles]) else { return [] }
        let cutoff = Date().addingTimeInterval(-horizon)
        var files: [(URL, UInt64)] = []
        for case let url as URL in enumerator {
            guard matching(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let size = values.fileSize, let modified = values.contentModificationDate, modified >= cutoff
            else { continue }
            files.append((url, UInt64(size)))
        }
        return files.sorted { $0.0.path < $1.0.path }
    }

    /// Runs `body` over every file that grew since its cursor, reporting overall progress.
    static func scan(files: [(url: URL, size: UInt64)], cursors: [String: FileCursor], progress: (Double) -> Void,
                     body: (URL, inout FileCursor, (UInt64) -> Void) -> Void) -> [String: FileCursor] {
        // A file Codex moved to another folder keeps its name and content: carry its cursor over,
        // or everything in it would be counted a second time.
        var byName: [String: FileCursor] = [:]
        for (path, cursor) in cursors { byName[(path as NSString).lastPathComponent] = cursor }
        func known(_ url: URL) -> FileCursor? { cursors[url.path] ?? byName[url.lastPathComponent] }
        var pending: UInt64 = 0
        for file in files {
            let offset = known(file.url)?.offset ?? 0
            if file.size > offset { pending += file.size - offset }
        }
        var done: UInt64 = 0
        var result: [String: FileCursor] = [:]
        withoutActuallyEscaping(progress) { report in
            for file in files {
                let path = file.url.path
                var cursor = known(file.url) ?? FileCursor(offset: 0, size: 0)
                if file.size < cursor.offset { cursor = FileCursor(offset: 0, size: 0) }
                if file.size > cursor.offset {
                    body(file.url, &cursor) { bytes in
                        done += bytes
                        if pending > 0 { report(min(1, Double(done) / Double(pending))) }
                    }
                }
                cursor.size = file.size
                result[path] = cursor
            }
        }
        return result
    }
}
