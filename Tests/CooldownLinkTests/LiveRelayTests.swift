import CryptoKit
import XCTest
@testable import CooldownLink

/// Acts as an iPhone against a real relay and a running Cooldown. Skipped unless LINK_INVITE
/// holds a pairing link (Cooldown --link-invite <file> writes one).
final class LiveRelayTests: XCTestCase {
    @MainActor
    func testPhoneAgainstMac() async throws {
        guard let text = ProcessInfo.processInfo.environment["LINK_INVITE"], let invite = PairingInvite(url: URL(string: text)!) else {
            throw XCTSkip("no LINK_INVITE")
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        let hello = try LinkCrypto.sealHello(.init(key: key.publicKey.rawRepresentation, name: "Test iPhone"), secret: invite.secret, code: invite.code)
        struct Claimed: Decodable { var space: String; var device: String; var token: String; var mac: String }
        let c = try await LinkHTTP.json(Claimed.self, invite.relay, "POST", "v1/pair/claim",
                                        body: ["code": invite.code, "name": "Test iPhone", "hello": hello])
        let account = LinkAccount(relay: invite.relay, space: c.space, device: c.device, token: c.token, privateKey: key.rawRepresentation,
                                  peers: [LinkPeer(id: c.mac, name: invite.macName, key: invite.macKey)])
        let session = try XCTUnwrap(LinkSession(account))
        let client = LinkClient(relay: invite.relay, token: c.token)
        var boxes: [LinkBox] = []
        client.onFrame = { frame in
            guard frame.t == "env", let box = try? session.open(frame) else { return }
            boxes.append(box)
            client.got([frame.id!])
        }
        client.start()
        func wait(_ what: String, _ seconds: Double = 25, _ test: () -> Bool) async throws {
            let end = Date().addingTimeInterval(seconds)
            while !test() {
                if Date() > end { XCTFail("timed out: \(what)"); return }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        try await wait("state") { boxes.contains { $0.m == .state } }
        let state = try XCTUnwrap(boxes.last { $0.m == .state }?.state)
        print("STATE limits:", state.limits.map { "\($0.provider) \($0.session ?? -1)% week \($0.week ?? -1)%" },
              "agents:", state.agents.filter(\.working).map(\.provider), "watches:", state.watches.count, "cards:", state.cards.count,
              "mac:", state.mac)

        for provider in ["codex", "claude"] {
            let cmd = LinkCommand(op: .chats, args: ["provider": provider])
            client.send(try session.envelope(.command(cmd), to: c.mac))
            try await wait("chats \(provider)", 40) { boxes.contains { $0.result?.cmd == cmd.id } }
            let result = try XCTUnwrap(boxes.first { $0.result?.cmd == cmd.id }?.result)
            print("CHATS \(provider): \(result.code) \(result.chats?.count ?? 0)", result.chats?.prefix(3).map(\.title) ?? [], result.text)
        }
        // A press on a card that doesn't exist must be refused, not guessed.
        let bogus = LinkCommand(op: .cardAct, args: ["key": "nope", "action": "continue"])
        client.send(try session.envelope(.command(bogus), to: c.mac))
        try await wait("stale") { boxes.contains { $0.result?.cmd == bogus.id } }
        XCTAssertEqual(boxes.first { $0.result?.cmd == bogus.id }?.result?.code, "stale")
        // The same command again does nothing.
        client.send(try session.envelope(.command(bogus), to: c.mac))
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(boxes.filter { $0.result?.cmd == bogus.id }.count, 1)

        if ProcessInfo.processInfo.environment["LINK_KEEP"] == nil {
            _ = try await LinkHTTP.call(invite.relay, "DELETE", "v1/devices/\(c.device)", token: c.token)
        }
        client.stop()
    }
}
