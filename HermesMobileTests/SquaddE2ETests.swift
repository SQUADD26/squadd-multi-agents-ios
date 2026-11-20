import CryptoKit
import XCTest
@testable import HermesMobile

/// The phone's end-to-end layer against `openmausbot/companion/src/e2e/vectors/v1.json`, the bytes the computer
/// and the relay are tested with. A stale copy fails on its SHA-256.
final class SquaddE2ETests: XCTestCase {
    private lazy var vectors: [String: Any] = {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Squadd/e2e")
        let data = try! Data(contentsOf: dir.appendingPathComponent("v1.json"))
        let pinned = try! String(contentsOf: dir.appendingPathComponent("v1.sha256"), encoding: .utf8).prefix(64)
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), String(pinned))
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    private func dict(_ path: String...) -> [String: Any] {
        path.reduce(vectors) { $0[$1] as! [String: Any] }
    }

    private func hex(_ text: Any?) -> Data {
        let digits = Array((text as! String).utf8)
        return Data(stride(from: 0, to: digits.count, by: 2).map {
            UInt8(String(decoding: digits[$0..<$0 + 2], as: UTF8.self), radix: 16)!
        })
    }

    private var inputs: [String: Any] { dict("inputs") }

    private func token(_ name: String) -> String {
        inputs[name == "device" ? "deviceToken" : name == "pairing" ? "pairingToken" : "otherDeviceToken"] as! String
    }

    func testDerivationsAndPointsMatchTheVectors() {
        let v1 = dict("V1")
        let transport = hex(v1["transportPublic"])
        XCTAssertEqual(SquaddE2E.keyId(transport), hex(v1["keyId"]))
        let hostId = hex(inputs["hostId"])
        for credential in v1["credentials"] as! [[String: Any]] {
            let token = credential["token"] as! String
            XCTAssertEqual(SquaddE2E.psk(credential: token, keyId: SquaddE2E.keyId(transport)), hex(credential["psk"]), token)
            XCTAssertEqual(SquaddE2E.admission(credential: token, hostId: hostId), hex(credential["adm"]), token)
        }
        for point in v1["points"] as! [[String: Any]] {
            XCTAssertEqual(SquaddE2E.publicKey(hex(point["hex"])) != nil, point["valid"] as! Bool, point["name"] as! String)
        }
        XCTAssertNil(SquaddE2E.fromB64u("lz81isB3BuNV6rHgYgG3Wh"), "non-canonical base64url is refused")
    }

    /// V2 over the relay with the device's psk, V3 direct with the pairing token's: message 1, then the keys message 2 gives.
    func testHandshakeMatchesTheVectors() throws {
        for name in ["V2", "V3"] {
            let session = dict(name)
            let handshake = try phoneHandshake(session)
            XCTAssertEqual(handshake.message1, hex(session["message1"]), name)
            let keys = try handshake.finish(message2: hex(session["message2"]))
            XCTAssertEqual(keys.send.key, hex(session["kPc"]), name)
            XCTAssertEqual(keys.receive.key, hex(session["kCp"]), name)
            XCTAssertEqual(keys.handshakeHash, hex(session["handshakeHash"]), name)
        }
    }

    /// A message 2 from another key, tampered with, or with the wrong `conn` or `v` stops the session.
    func testEveryBadMessage2IsAHardStop() throws {
        let cases = (dict("V6")["handshake"] as! [[String: Any]]).filter { $0["side"] as? String == "phone" }
        XCTAssertEqual(cases.count, 6)
        for bad in cases {
            let handshake = try phoneHandshake(dict(bad["session"] as! String))
            XCTAssertThrowsError(try handshake.finish(message2: hex(bad["message2"])), bad["name"] as! String)
        }
    }

    func testRecordsMatchTheVectors() throws {
        let v4 = dict("V4")
        let phoneSends = SquaddE2E.RecordCipher(key: hex(v4["kPc"]))
        let phoneReceives = SquaddE2E.RecordCipher(key: hex(v4["kCp"]))
        for record in v4["records"] as! [[String: Any]] {
            if record["direction"] as! String == "pc" {
                XCTAssertEqual(try phoneSends.seal(hex(record["frame"])), hex(record["record"]))
            } else {
                XCTAssertEqual(try phoneReceives.open(hex(record["record"])), hex(record["frame"]))
            }
        }
        let tampered = (dict("V6")["records"] as! [[String: Any]]).filter { $0["receiver"] as? String == "phone" }
        XCTAssertEqual(tampered.count, 2)
        for bad in tampered {
            let cipher = SquaddE2E.RecordCipher(key: hex(v4["kCp"]))
            let failsAt = bad["failsAt"] as! Int
            for (index, record) in (bad["records"] as! [String]).map(hex).enumerated() {
                if index < failsAt { XCTAssertNoThrow(try cipher.open(record)) } else { XCTAssertThrowsError(try cipher.open(record), bad["name"] as! String) }
            }
        }
    }

    func testFramesMatchTheVectors() throws {
        for vector in vectors["V5"] as! [[String: Any]] {
            let bytes = hex(vector["hex"])
            let frame = try SquaddYamux.Frame.decode(bytes)
            XCTAssertEqual(frame.type.rawValue, UInt8(vector["type"] as! Int), vector["name"] as! String)
            XCTAssertEqual(frame.flags.rawValue, UInt16(vector["flags"] as! Int))
            XCTAssertEqual(frame.streamId, UInt32(vector["streamId"] as! Int))
            XCTAssertEqual(frame.length, UInt32(vector["length"] as! Int))
            XCTAssertEqual(frame.encoded(), bytes, vector["name"] as! String)
        }
        for bad in dict("V6")["frames"] as! [[String: Any]] {
            XCTAssertThrowsError(try SquaddYamux.Frame.decode(hex(bad["hex"])), bad["name"] as! String)
        }
    }

    /// The phone opens odd streams, sends within its window and grants the computer's data back after 1 MiB.
    func testStreamOpensSendsAndGrantsWindow() throws {
        let mux = SquaddYamux()
        var sent: [SquaddYamux.Frame] = []
        var received = Data()
        mux.send = { sent.append($0) }
        mux.onData = { _, data in received += data }
        let id = try mux.open()
        XCTAssertEqual(sent.last?.encoded(), hex((vectors["V5"] as! [[String: Any]])[0]["hex"]))
        XCTAssertEqual(mux.write(id, Data(count: 300_000)), Int(SquaddYamux.maxDataPayload))
        try mux.receive(.window(id, UInt32(SquaddYamux.openWindowDelta), flags: .ack))
        let chunk = Data(repeating: 7, count: Int(SquaddYamux.maxDataPayload))
        for _ in 0..<17 { try mux.receive(.data(id, chunk)) }
        XCTAssertEqual(received.count, 17 * chunk.count)
        mux.consumed(id, received.count)
        XCTAssertEqual(sent.last, .window(id, UInt32(received.count)), "the grant goes back once 1 MiB was taken")
        XCTAssertThrowsError(try mux.receive(.window(2, 0, flags: .syn)), "the computer never opens a stream")
    }

    func testDescriptorsMatchTheVectors() {
        let v7 = dict("V7")
        for valid in v7["valid"] as! [[String: Any]] {
            guard case .ok(let descriptor) = SquaddE2E.Descriptor.parse(valid["value"] as! String) else {
                return XCTFail(valid["name"] as! String)
            }
            let parsed = valid["parsed"] as! [String: Any]
            XCTAssertEqual(descriptor.transportKey, SquaddE2E.fromB64u(parsed["k"] as! String))
            XCTAssertEqual(descriptor.relays, parsed["r"] as? [String] ?? [], valid["name"] as! String)
        }
        for invalid in v7["invalid"] as! [[String: Any]] {
            let outcome = SquaddE2E.Descriptor.parse(invalid["value"] as! String)
            if invalid["outcome"] as? String == "update" {
                XCTAssertEqual(outcome, .update, invalid["name"] as! String)
            } else if case .reject = outcome {} else {
                XCTFail("\(invalid["name"] as! String) was accepted")
            }
        }
    }

    /// The loopback listener lets in only this app: its per-launch secret, or this device's token as bearer.
    func testLoopbackAdmitsOnlyThisApp() {
        let head = { (line: String) in Data("GET /api/bots HTTP/1.1\r\nHost: 127.0.0.1\r\n\(line)".utf8) }
        XCTAssertTrue(SquaddE2ETunnel.admits(head("x-omb-loopback: s3cret"), secret: "s3cret", credential: "omb_dev"))
        XCTAssertTrue(SquaddE2ETunnel.admits(head("Authorization: Bearer omb_dev"), secret: "s3cret", credential: "omb_dev"))
        XCTAssertFalse(SquaddE2ETunnel.admits(head("X-OMB-Loopback: s3crex"), secret: "s3cret", credential: "omb_dev"))
        XCTAssertFalse(SquaddE2ETunnel.admits(head("Authorization: Bearer omb_other"), secret: "s3cret", credential: "omb_dev"))
        XCTAssertFalse(SquaddE2ETunnel.admits(Data("GET /x-omb-loopback: s3cret HTTP/1.1\r\n".utf8), secret: "s3cret", credential: "omb_dev"))
    }

    /// The relay-only QR the server prints pairs through the relay, under a name only its tunnel reaches.
    func testRelayOnlyQRPairsThroughTheRelay() throws {
        let descriptor = (dict("V7")["valid"] as! [[String: Any]]).first { $0["name"] as? String == "relay" }!["value"] as! String
        let token = "omb_pair_" + String(repeating: "A", count: 43)
        let link = "openmausbot://pair?address=relay-only.invalid%3A443&token=\(token)&name=vps&e2e=\(descriptor)"
        let invite = try SquaddPairingInvite.scanned(link).get()
        XCTAssertEqual(invite.server, SquaddRelay.identity(hostId: hex(inputs["hostId"])))
        XCTAssertEqual(invite.e2e?.relays, ["relay1.openmausbot.com", "relay2.openmausbot.com"])
        XCTAssertEqual(invite.credential, token)
        XCTAssertEqual(SquaddPairingInvite.scanned("openmausbot://pair?address=relay-only.invalid%3A443&token=\(token)"), .failure(.relayOnly))
    }

    /// A LAN QR with the relay's descriptor pairs at its address and keeps the key for away from home.
    func testLANQRKeepsTheRelayKeyForLater() throws {
        let descriptor = (dict("V7")["valid"] as! [[String: Any]]).first { $0["name"] as? String == "relay" }!["value"] as! String
        let link = "openmausbot://pair?address=192.168.1.10%3A8810&token=omb_pair_" + String(repeating: "A", count: 43) + "&e2e=\(descriptor)"
        let invite = try SquaddPairingInvite.scanned(link).get()
        XCTAssertEqual(invite.server, URL(string: "http://192.168.1.10:8810"))
        XCTAssertEqual(invite.e2e?.relays, ["relay1.openmausbot.com", "relay2.openmausbot.com"])
    }

    private func phoneHandshake(_ session: [String: Any]) throws -> SquaddE2E.PhoneHandshake {
        let psk = SquaddE2E.psk(credential: token(session["psk"] as! String), keyId: SquaddE2E.keyId(hex(dict("V1")["transportPublic"])))
        return try SquaddE2E.PhoneHandshake(
            remoteStatic: hex(dict("V1")["transportPublic"]), psk: psk, transport: UInt8(session["transport"] as! Int),
            payload1: hex(session["payload1"]), conn: inputs["connB64u"] as! String,
            ephemeral: try P256.KeyAgreement.PrivateKey(rawRepresentation: hex(inputs["phoneEphemeralPrivate"])))
    }
}
