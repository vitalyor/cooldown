import CryptoKit
import Foundation

/// Sealing and opening Link messages. See docs/LINK.md, "Keys".
public enum LinkCrypto {
    static let salt = Data("cooldown-link-v1".utf8)

    public enum Failure: Error { case badKey, badBox }

    /// The key a Mac and one phone share. Both sides get the same key from their own private key
    /// and the other's public key.
    public static func sharedKey(mine: Curve25519.KeyAgreement.PrivateKey, theirs: Data) throws -> SymmetricKey {
        guard let their = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirs) else { throw Failure.badKey }
        let secret = try mine.sharedSecretFromKeyAgreement(with: their)
        let a = mine.publicKey.rawRepresentation
        let info = a.lexicographicallyPrecedes(theirs) ? a + theirs : theirs + a
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
    }

    static func context(from: String, to: String, id: String) -> Data {
        Data("\(from)|\(to)|\(id)".utf8)
    }

    public static func seal(_ data: Data, key: SymmetricKey, from: String, to: String, id: String) throws -> String {
        try ChaChaPoly.seal(data, using: key, authenticating: context(from: from, to: to, id: id)).combined.base64EncodedString()
    }

    public static func open(_ text: String, key: SymmetricKey, from: String, to: String, id: String) throws -> Data {
        guard let data = Data(base64Encoded: text), let box = try? ChaChaPoly.SealedBox(combined: data),
              let plain = try? ChaChaPoly.open(box, using: key, authenticating: context(from: from, to: to, id: id))
        else { throw Failure.badBox }
        return plain
    }

    // MARK: Pairing

    /// The key for the phone's hello, from the secret that only the QR code carries.
    static func pairKey(_ secret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt,
                               info: Data("cooldown-pair".utf8), outputByteCount: 32)
    }

    public struct Hello: Codable, Equatable {
        public var key: Data
        public var name: String
        public init(key: Data, name: String) { self.key = key; self.name = name }
    }

    public static func sealHello(_ hello: Hello, secret: Data, code: String) throws -> String {
        let data = try JSONEncoder().encode(hello)
        return try ChaChaPoly.seal(data, using: pairKey(secret), authenticating: Data(code.utf8)).combined.base64EncodedString()
    }

    public static func openHello(_ text: String, secret: Data, code: String) throws -> Hello {
        guard let data = Data(base64Encoded: text), let box = try? ChaChaPoly.SealedBox(combined: data),
              let plain = try? ChaChaPoly.open(box, using: pairKey(secret), authenticating: Data(code.utf8)),
              let hello = try? JSONDecoder().decode(Hello.self, from: plain),
              hello.key.count == 32
        else { throw Failure.badBox }
        return hello
    }

    /// A new private key, as raw bytes for the Keychain.
    public static func newPrivateKey() -> Data { Curve25519.KeyAgreement.PrivateKey().rawRepresentation }

    public static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        // A zero-filled key or nonce would be silently insecure; this never fails on a working
        // system, and a crash is preferable to using predictable bytes.
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes)
    }
}

extension Data {
    /// Base64 without padding, safe in URLs.
    public var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(base64URL text: String) {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}

/// What the QR code on the Mac carries.
public struct PairingInvite: Equatable {
    public var relay: URL
    public var code: String
    public var secret: Data
    public var macKey: Data
    public var macName: String

    public init(relay: URL, code: String, secret: Data, macKey: Data, macName: String) {
        self.relay = relay; self.code = code; self.secret = secret; self.macKey = macKey; self.macName = macName
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = "cooldown"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "r", value: relay.absoluteString),
            URLQueryItem(name: "c", value: code),
            URLQueryItem(name: "s", value: secret.base64URL),
            URLQueryItem(name: "k", value: macKey.base64URL),
            URLQueryItem(name: "n", value: macName),
        ]
        return c.url!
    }

    public init?(url: URL) {
        guard url.scheme == "cooldown", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let r = item("r"), let relay = URL(string: r), relay.scheme == "https" || relay.host == "localhost",
              let code = item("c"), code.count >= 16,
              let s = item("s"), let secret = Data(base64URL: s), secret.count == 32,
              let k = item("k"), let key = Data(base64URL: k), key.count == 32 else { return nil }
        self.init(relay: relay, code: code, secret: secret, macKey: key, macName: item("n") ?? "Mac")
    }
}
