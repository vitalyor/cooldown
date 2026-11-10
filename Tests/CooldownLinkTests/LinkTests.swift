import CryptoKit
import XCTest
@testable import CooldownLink

final class LinkTests: XCTestCase {
    func account(_ device: String, key: Curve25519.KeyAgreement.PrivateKey) -> LinkAccount {
        LinkAccount(relay: URL(string: "https://relay.test")!, space: "s", device: device, token: "t", privateKey: key.rawRepresentation)
    }

    func pair() -> (LinkSession, LinkSession) {
        let macKey = Curve25519.KeyAgreement.PrivateKey(), phoneKey = Curve25519.KeyAgreement.PrivateKey()
        var mac = account("mac", key: macKey), phone = account("phone", key: phoneKey)
        mac.peers = [LinkPeer(id: "phone", name: "iPhone", key: phoneKey.publicKey.rawRepresentation)]
        phone.peers = [LinkPeer(id: "mac", name: "Mac", key: macKey.publicKey.rawRepresentation)]
        return (LinkSession(mac)!, LinkSession(phone)!)
    }

    /// The relay sets `from`; tests do the same.
    func relayed(_ f: LinkFrame, from: String) -> LinkFrame { var f = f; f.from = from; return f }

    func testSealOpen() throws {
        let (mac, phone) = pair()
        let card = LinkCard(key: "claude.reset", kind: "reset", provider: "claude", title: "Лимит сброшен", body: "Можно продолжать",
                            actions: [LinkAction(id: "continue", title: "Продолжить", style: .primary)], created: Date(timeIntervalSince1970: 1_761_390_000))
        let frame = try mac.envelope(.card(card), to: "phone", push: LinkPush(collapse: card.collapseID))
        let cipher = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(frame.box)))
        let cipherText = String(decoding: cipher, as: UTF8.self)
        XCTAssertFalse(cipherText.contains("Лимит"))
        XCTAssertFalse(cipherText.contains("Можно продолжать"))
        XCTAssertFalse(cipherText.contains("Продолжить"))
        let box = try phone.open(relayed(frame, from: "mac"))
        XCTAssertEqual(box.card, card)
        // The same box again is a replay.
        XCTAssertThrowsError(try phone.open(relayed(frame, from: "mac")))
    }

    func testBoxBoundToEnvelope() throws {
        let (mac, phone) = pair()
        var frame = try mac.envelope(.command(LinkCommand(op: .refresh)), to: "phone")
        frame.id = "another-id-000000"
        XCTAssertThrowsError(try phone.open(relayed(frame, from: "mac")))
        let good = try mac.envelope(.command(LinkCommand(op: .refresh)), to: "phone")
        XCTAssertThrowsError(try phone.open(relayed(good, from: "stranger")))
    }

    func testOldStateIgnored() throws {
        let (mac, phone) = pair()
        let info = LinkMac(name: "Mac", version: "1.4", locked: false, language: "ru")
        var newer = LinkBox.state(LinkState(limits: [], agents: [], watches: [], cards: [], mac: info))
        newer.ts = Date()
        var older = LinkBox.state(LinkState(limits: [], agents: [], watches: [], cards: [], mac: info))
        older.ts = Date().addingTimeInterval(-30)
        _ = try phone.open(relayed(try mac.envelope(newer, to: "phone"), from: "mac"))
        XCTAssertThrowsError(try phone.open(relayed(try mac.envelope(older, to: "phone"), from: "mac")))
    }

    func testExpiredCommand() throws {
        let (mac, phone) = pair()
        var box = LinkBox.command(LinkCommand(op: .refresh))
        box.ts = Date().addingTimeInterval(-3600)
        let frame = try phone.envelope(box, to: "mac", ttl: 600)
        XCTAssertThrowsError(try mac.open(relayed(frame, from: "phone")))
    }

    /// A carrier (the relay, a push) cannot keep an old box alive by raising the envelope's ttl:
    /// the sealed one decides.
    func testCarriedTTLCannotExtendABox() throws {
        let (mac, phone) = pair()
        var box = LinkBox.card(LinkCard(key: "k", kind: "attention", provider: "codex", title: "T", body: "B", actions: [], created: Date()))
        box.ts = Date().addingTimeInterval(-3 * 3600)
        var frame = try mac.envelope(box, to: "phone", ttl: 600)
        frame.ttl = 1_000_000_000
        XCTAssertThrowsError(try phone.open(relayed(frame, from: "mac")))
    }

    func testInviteAndHello() throws {
        let invite = PairingInvite(relay: URL(string: "https://cooldown.nolim.cloud")!, code: LinkCrypto.random(16).base64URL,
                                   secret: LinkCrypto.random(32), macKey: LinkCrypto.random(32), macName: "MacBook Виталия")
        let parsed = try XCTUnwrap(PairingInvite(url: invite.url))
        XCTAssertEqual(parsed, invite)
        let hello = LinkCrypto.Hello(key: LinkCrypto.random(32), name: "iPhone")
        let sealed = try LinkCrypto.sealHello(hello, secret: invite.secret, code: invite.code)
        XCTAssertEqual(try LinkCrypto.openHello(sealed, secret: invite.secret, code: invite.code), hello)
        XCTAssertThrowsError(try LinkCrypto.openHello(sealed, secret: LinkCrypto.random(32), code: invite.code))
        XCTAssertNil(PairingInvite(url: URL(string: "cooldown://pair?r=http://evil.example&c=0123456789abcdef&s=x&k=y")!))
    }

    func testLiveStateJSON() throws {
        let s = LiveState(items: [], countdowns: [.init(provider: "claude", until: 1_761_400_000, waiting: 1)], updated: 1_761_390_000)
        let json = String(data: try JSONEncoder().encode(s), encoding: .utf8)!
        XCTAssertTrue(json.contains("1761400000"))
    }

    @MainActor
    func testOldWriteFailureDoesNotDropNewConnection() async {
        let relay = URL(string: "http://127.0.0.1:1")!
        let client = LinkClient(relay: relay, token: "test")
        let old = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:1/v1/ws")!)
        client.start()
        defer { client.stop() }
        XCTAssertEqual(client.status, .connecting)
        client.writeFailed(URLError(.networkConnectionLost), frame: LinkFrame(t: "env"), on: old)
        XCTAssertEqual(client.status, .connecting)
    }
}

final class LinkConnectionLifecycleTests: XCTestCase {
    @MainActor
    func testOldReadyFrameCannotReviveStoppedOrDifferentConnection() async {
        let client = LinkClient(relay: URL(string: "http://127.0.0.1:1")!, token: "test")
        let old = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:1/v1/ws")!)
        var received = 0
        client.onFrame = { _ in received += 1 }
        client.start()
        client.handle(LinkFrame(t: "ready"), on: old)
        XCTAssertEqual(client.status, .connecting)
        XCTAssertEqual(received, 0)
        client.stop()
        client.handle(LinkFrame(t: "ready"), on: old)
        XCTAssertEqual(client.status, .off)
        XCTAssertEqual(received, 0)
    }

    func testNodeListSignature() throws {
        // Signed with a throwaway key, the same format `relay directory-sign` writes.
        let key = Curve25519.Signing.PrivateKey()
        let keyText = key.publicKey.rawRepresentation.base64EncodedString()
        func signed(_ text: String, with signer: Curve25519.Signing.PrivateKey) throws -> Data {
            let payload = Data(text.utf8)
            return try JSONEncoder().encode(["payload": payload.base64EncodedString(),
                                             "sig": try signer.signature(for: payload).base64EncodedString()])
        }
        let good = #"{"seq":3,"nodes":[{"id":"n1","url":"https://n1.example"}]}"#
        let list = try XCTUnwrap(LinkNodes.verify(try signed(good, with: key), key: keyText))
        XCTAssertEqual(list.seq, 3)
        XCTAssertEqual(list.nodes.first?.url.host, "n1.example")
        // Someone else's key is refused, and so is a list changed after signing.
        XCTAssertNil(LinkNodes.verify(try signed(good, with: Curve25519.Signing.PrivateKey()), key: keyText))
        var tampered = try JSONDecoder().decode([String: String].self, from: try signed(good, with: key))
        tampered["payload"] = Data(#"{"seq":9,"nodes":[{"id":"x","url":"https://evil.example"}]}"#.utf8).base64EncodedString()
        XCTAssertNil(LinkNodes.verify(try JSONEncoder().encode(tampered), key: keyText))
    }

    func testMovesOnlyToAClearlyFasterServer() {
        let a = URL(string: "https://a.example")!, b = URL(string: "https://b.example")!
        XCTAssertNil(LinkNodes.better(than: a, [a: 0.10, b: 0.08]), "a small gain is not worth moving")
        XCTAssertEqual(LinkNodes.better(than: a, [a: 0.10, b: 0.05]), b)
        XCTAssertEqual(LinkNodes.better(than: a, [b: 0.50]), b, "the current one stopped answering")
        XCTAssertNil(LinkNodes.better(than: a, [:]))
    }
}
