import CryptoKit
import Foundation

/// One relay server in the signed list.
public struct LinkNode: Codable, Equatable, Sendable {
    public var id: String
    public var url: URL
    public var region: String?
    public var weight: Double?
}

/// Which relay servers exist and which to use. Nobody chooses: the app reaches whichever works.
/// The list is signed with a key kept off the servers, so a server (or anyone between) can't add its own.
public enum LinkNodes {
    static let publicKey = "fOQhz3uscj/piWpIUtzEx6lOT0I2DTUUhu+6MyPBbW4="
    /// Used until a list has been fetched; new servers come through the list, without an app update.
    static let seeds = ["https://n1.cooldown.nolim.cloud", "https://n3.cooldown.nolim.cloud", "https://n2.cooldown.nolim.cloud", "https://n4.cooldown.nolim.cloud"].map { URL(string: $0)! }
    /// Reachable even if every server is down or blocked; the signature is what's trusted.
    static let fallback = URL(string: "https://raw.githubusercontent.com/vitalyor/cooldown/main/nodes.json")!

    struct Signed: Codable { var payload: String; var sig: String }
    struct List: Codable { var seq: Int64; var nodes: [LinkNode] }

    static func verify(_ data: Data, key: String = publicKey) -> (seq: Int64, nodes: [LinkNode])? {
        guard let signed = try? JSONDecoder().decode(Signed.self, from: data),
              let payload = Data(base64Encoded: signed.payload), let sig = Data(base64Encoded: signed.sig),
              let raw = Data(base64Encoded: key), let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              pub.isValidSignature(sig, for: payload),
              let list = try? JSONDecoder().decode(List.self, from: payload), !list.nodes.isEmpty
        else { return nil }
        return (list.seq, list.nodes)
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var seq: Int64 = 0
        var nodes: [LinkNode] = []
        var good: URL?
        var fetched = Date.distantPast
        var loaded = false
    }
    private static let state = State()
    private static let key = "cooldown.nodes"
    private static var defaults: UserDefaults {
        #if os(iOS)
        UserDefaults(suiteName: "group.com.vitalyor.cooldown") ?? .standard
        #else
        .standard
        #endif
    }

    private static func withState<T>(_ body: (State) -> T) -> T {
        state.lock.lock()
        defer { state.lock.unlock() }
        if !state.loaded {
            state.loaded = true
            if let data = defaults.data(forKey: key), let list = verify(data) { (state.seq, state.nodes) = list }
            state.good = defaults.url(forKey: key + ".good")
        }
        return body(state)
    }

    /// Takes a list if its signature holds and it is newer than the one here.
    @discardableResult
    static func adopt(_ data: Data) -> Bool {
        guard let list = verify(data) else { return false }
        return withState { s in
            guard list.seq > s.seq else { return false }
            (s.seq, s.nodes) = list
            defaults.set(data, forKey: key)
            return true
        }
    }

    /// Servers to try, best guess first: the last that worked, the given one, the list, the built-in ones.
    public static func candidates(_ preferred: URL) -> [URL] {
        withState { s in ordered(good: s.good, preferred: preferred, nodes: s.nodes, seeds: seeds) }
    }

    /// Once a signed list is known, an address not on it is a server that was removed: a pairing
    /// or a last success may still name it, and it is not tried. Before that, everything is.
    static func ordered(good: URL?, preferred: URL, nodes: [LinkNode], seeds: [URL]) -> [URL] {
        var seen = Set<URL>()
        let weighted = nodes.sorted { ($0.weight ?? 1) > ($1.weight ?? 1) }.map(\.url)
        let current = Set(weighted)
        let remembered = [good, preferred].compactMap { $0 }.filter { nodes.isEmpty || current.contains($0) || $0.host == "localhost" }
        return (remembered + weighted + (nodes.isEmpty ? seeds : [])).filter { seen.insert($0).inserted }
    }

    public static func next(after url: URL) -> URL {
        let all = candidates(url)
        guard let i = all.firstIndex(of: url), all.count > 1 else { return url }
        return all[(i + 1) % all.count]
    }

    public static func markGood(_ url: URL) {
        withState { s in
            guard s.good != url else { return }
            s.good = url
            defaults.set(url, forKey: key + ".good")
        }
    }

    /// Fetches the list from any server, or the fallback. At most every six hours.
    public static func refresh(from preferred: URL) async {
        let due: Bool = withState { s in
            guard Date().timeIntervalSince(s.fetched) > 6 * 3600 else { return false }
            s.fetched = Date()
            return true
        }
        guard due else { return }
        for url in candidates(preferred).map({ $0.appendingPathComponent("v1/nodes") }) + [fallback] {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200, verify(data) != nil {
                adopt(data)
                return
            }
        }
    }

    /// Round trip to every server, in seconds. Servers that don't answer are left out.
    public static func measure(from preferred: URL) async -> [URL: TimeInterval] {
        await withTaskGroup(of: (URL, TimeInterval?).self) { group in
            for url in candidates(preferred) {
                group.addTask {
                    var request = URLRequest(url: url.appendingPathComponent("v1/health"))
                    request.timeoutInterval = 5
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    let start = Date()
                    guard let (_, response) = try? await URLSession.shared.data(for: request),
                          (response as? HTTPURLResponse)?.statusCode == 200 else { return (url, nil) }
                    return (url, Date().timeIntervalSince(start))
                }
            }
            var times: [URL: TimeInterval] = [:]
            for await (url, time) in group { if let time { times[url] = time } }
            return times
        }
    }

    /// Whether to move: only to a clearly faster server (30%), so a connection doesn't hop about.
    public static func better(than current: URL, _ times: [URL: TimeInterval]) -> URL? {
        guard let best = times.min(by: { $0.value < $1.value }), best.key != current else { return nil }
        guard let now = times[current] else { return best.key }
        return best.value < now * 0.7 ? best.key : nil
    }
}
