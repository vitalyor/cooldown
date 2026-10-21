import Foundation

/// Reads Codex session files (~/.codex/sessions/**/rollout-*.jsonl) incrementally.
/// Every `token_count` event carries the session's running token totals and a snapshot of the
/// account limits, so the past weeks of usage are available without having watched them live.
final class CodexHistoryScanner: HistoryScanning {
    let roots: [URL]
    let horizon: TimeInterval

    /// Codex keeps conversations under sessions/ and moves continued ones to archived_sessions/.
    init(root: URL) {
        roots = [root, root.deletingLastPathComponent().appendingPathComponent("archived_sessions")]
        horizon = HistoryFile.horizon
    }

    init(roots: [URL], horizon: TimeInterval) {
        self.roots = roots
        self.horizon = horizon
    }

    private static let tokenMarker = Array("\"token_count\"".utf8)
    private static let metaMarker = Array("\"type\":\"session_meta\"".utf8)
    private static let turnMarker = Array("\"type\":\"turn_context\"".utf8)

    func scan(cursors: [String: FileCursor], progress: (Double) -> Void) -> ScanOutput {
        var output = ScanOutput()
        let files = roots.flatMap { root in
            JSONLReader.files(under: root, horizon: horizon) { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }
        }
        output.cursors = JSONLReader.scan(files: files, cursors: cursors, progress: progress) { url, cursor, advanced in
            JSONLReader.read(url, cursor: &cursor, advanced: advanced) { bytes, length, cursor in
                handleLine(bytes, length, cursor: &cursor, output: &output)
            }
        }
        return output
    }

    private func handleLine(_ bytes: UnsafePointer<UInt8>, _ length: Int, cursor: inout FileCursor, output: inout ScanOutput) {
        let head = min(length, 400)
        let isToken = JSONLReader.contains(bytes, head, Self.tokenMarker)
        let isContext = !isToken && (JSONLReader.contains(bytes, head, Self.metaMarker) || JSONLReader.contains(bytes, head, Self.turnMarker))
        guard isToken || isContext else { return }

        guard let object = (try? JSONSerialization.jsonObject(with: Data(bytes: bytes, count: length))) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return }

        if isContext {
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty { cursor.cwd = cwd }
            if let model = payload["model"] as? String, !model.isEmpty { cursor.model = model }
            return
        }
        guard payload["type"] as? String == "token_count", let time = Num.date(object["timestamp"]) else { return }

        if let info = payload["info"] as? [String: Any], let totalRaw = info["total_token_usage"] as? [String: Any] {
            let total = counts(totalRaw)
            var delta = TokenCounts()
            if let previous = cursor.lastTotals, total.total >= previous.total {
                delta = total - previous
            } else if let last = info["last_token_usage"] as? [String: Any] {
                // First event of a file (or a restarted counter): only this response is new,
                // the running total may carry tokens already counted in an earlier file.
                delta = counts(last)
            }
            cursor.lastTotals = total
            if !delta.isZero {
                let key = BucketKey(hour: hourStart(time), project: cursor.cwd ?? "", model: cursor.model ?? "")
                output.tokens[key, default: TokenCounts()] = output.tokens[key, default: TokenCounts()] + delta
            }
        }

        if let limits = payload["rate_limits"] as? [String: Any] {
            let limitID = limits["limit_id"] as? String
            guard limitID == nil || limitID == "codex" else { return }
            for key in ["primary", "secondary"] {
                guard let raw = limits[key] as? [String: Any], let used = Num.double(raw["used_percent"]),
                      let resets = Num.double(raw["resets_at"]) else { continue }
                let minutes = Num.int(raw["window_minutes"]) ?? (key == "primary" ? 300 : 10080)
                output.samples.append(LimitSample(t: time, kind: .from(minutes: minutes), used: min(100, max(0, used)),
                                                  resetsAt: Date(timeIntervalSince1970: resets)))
            }
        }
    }

    private func counts(_ raw: [String: Any]) -> TokenCounts {
        TokenCounts(input: Num.int(raw["input_tokens"]) ?? 0,
                    cached: Num.int(raw["cached_input_tokens"]) ?? 0,
                    output: Num.int(raw["output_tokens"]) ?? 0,
                    reasoning: Num.int(raw["reasoning_output_tokens"]) ?? 0)
    }
}

func hourStart(_ date: Date) -> Date {
    Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 3600) * 3600)
}
