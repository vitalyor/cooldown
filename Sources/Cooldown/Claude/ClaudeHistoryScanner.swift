import Foundation

/// Reads Claude Code transcripts (~/.claude/projects/**/*.jsonl) incrementally. Each assistant
/// response carries its token usage; one response is often written on several lines (one per
/// content block), so usage is counted once per response id, keeping the largest value seen.
final class ClaudeHistoryScanner: HistoryScanning {
    let root: URL
    let horizon: TimeInterval

    init(root: URL, horizon: TimeInterval = HistoryFile.horizon) {
        self.root = root
        self.horizon = horizon
    }

    private static let usageMarker = Array("\"output_tokens\"".utf8)
    private static let assistantMarker = Array("\"type\":\"assistant\"".utf8)

    func scan(cursors: [String: FileCursor], progress: (Double) -> Void) -> ScanOutput {
        var output = ScanOutput()
        let files = JSONLReader.files(under: root, horizon: horizon) { $0.hasSuffix(".jsonl") }
        output.cursors = JSONLReader.scan(files: files, cursors: cursors, progress: progress) { url, cursor, advanced in
            JSONLReader.read(url, cursor: &cursor, advanced: advanced) { bytes, length, cursor in
                handleLine(bytes, length, cursor: &cursor, output: &output)
            }
        }
        return output
    }

    private func handleLine(_ bytes: UnsafePointer<UInt8>, _ length: Int, cursor: inout FileCursor, output: inout ScanOutput) {
        guard JSONLReader.contains(bytes, length, Self.assistantMarker),
              JSONLReader.contains(bytes, length, Self.usageMarker),
              let object = (try? JSONSerialization.jsonObject(with: Data(bytes: bytes, count: length))) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let time = Num.date(object["timestamp"]) else { return }
        let model = message["model"] as? String ?? ""
        guard model != "<synthetic>" else { return }
        if let cwd = object["cwd"] as? String, !cwd.isEmpty { cursor.cwd = cwd }

        let fresh = Num.int(usage["input_tokens"]) ?? 0
        let written = Num.int(usage["cache_creation_input_tokens"]) ?? 0
        let read = Num.int(usage["cache_read_input_tokens"]) ?? 0
        let counts = TokenCounts(input: fresh + written + read, cached: read, output: Num.int(usage["output_tokens"]) ?? 0)
        guard !counts.isZero else { return }

        let id = (message["id"] as? String) ?? (object["uuid"] as? String) ?? UUID().uuidString
        var seen = cursor.seen ?? [:]
        let already = seen[id] ?? TokenCounts()
        let delta = counts - already
        seen[id] = TokenCounts(input: max(counts.input, already.input), cached: max(counts.cached, already.cached),
                               output: max(counts.output, already.output))
        // Repeats of one response sit next to each other, so a short memory is enough.
        if seen.count > 64, let current = seen[id] { seen = [id: current] }
        cursor.seen = seen
        guard !delta.isZero else { return }

        let key = BucketKey(hour: hourStart(time), project: cursor.cwd ?? "", model: model)
        output.tokens[key, default: TokenCounts()] = output.tokens[key, default: TokenCounts()] + delta
    }
}
