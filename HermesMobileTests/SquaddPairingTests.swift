import SwiftData
import SwiftUI
import XCTest
@testable import HermesMobile

/// Pairing with a computer (#8) against replies recorded from a real `openmausbot` companion
/// (`Fixtures/Squadd/pairing/`, origin/dev 3d12c2fd7, `companion/src/index.ts` standing alone): the QR
/// link the desktop builds with `phonePairingLink`, a pairing, and each refusal.
@MainActor
final class SquaddPairingTests: XCTestCase {
    private let computer = URL(string: "http://127.0.0.1:18810")!

    override func tearDown() {
        SquaddHTTPFixture.handler = nil
        super.tearDown()
    }

    func testQRLinkPairsAndKeepsTheTokenInTheKeychain() async throws {
        var seen: URLRequest?
        SquaddHTTPFixture.handler = { request in
            seen = request
            return (201, try! Self.fixture("pair-qr.json"))
        }
        let link = try XCTUnwrap(URL(string: try String(decoding: Self.fixture("qr-link.txt"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let invite = try XCTUnwrap(SquaddPairingInvite(url: link))
        let keychain = InMemoryKeychainStore()
        let manager = makeManager(keychain: keychain)

        try await manager.pairSquadd(invite, deviceName: "iPhone di prova", session: session)

        XCTAssertEqual(seen?.url, computer.appendingPathComponent("api/pair"))
        XCTAssertNil(seen?.value(forHTTPHeaderField: "Origin"))
        let body = try Self.body(of: seen)
        XCTAssertEqual(body["credential"], "omb_pair_" + String(repeating: "A", count: 43))
        XCTAssertEqual(body["deviceName"], "iPhone di prova")
        XCTAssertNil(body["replacesToken"], "a first pairing replaces nothing")
        XCTAssertEqual(manager.state, .loggedIn(server: computer))
        XCTAssertEqual(manager.squaddToken(for: computer), "omb_recorded-device-token")
        XCTAssertEqual(manager.activeServer?.displayName, "Mac di prova")
    }

    func testTypedCodeIsTheCompanionsSixDigitsAndReachesTheSameServer() throws {
        let typed = try XCTUnwrap(SquaddPairingInvite(typedAddress: " 127.0.0.1:18810 ", code: "409 706"))
        XCTAssertEqual(typed.server, computer, "typed and scanned reach one server in the list")
        XCTAssertEqual(typed.credential, "409706")
        XCTAssertEqual(SquaddPairingInvite(typedAddress: "127.0.0.1:18810", code: "409-706")?.credential, "409706")
        // A server's twelve-symbol code, five digits, or no address are not a computer's pairing.
        XCTAssertNil(SquaddPairingInvite(typedAddress: "127.0.0.1:18810", code: "7KQ2-M9XD-H4TP"))
        XCTAssertNil(SquaddPairingInvite(typedAddress: "127.0.0.1:18810", code: "40970"))
        XCTAssertNil(SquaddPairingInvite(typedAddress: "", code: "409706"))
        // A link the desktop would never print: no port, a path, a short credential, another scheme.
        let token = "omb_pair_" + String(repeating: "A", count: 43)
        for bad in ["openmausbot://pair?address=127.0.0.1&token=\(token)",
                    "openmausbot://pair?address=http%3A%2F%2F127.0.0.1%3A18810%2Fx&token=\(token)",
                    "openmausbot://pair?address=127.0.0.1%3A18810&token=omb_pair_short",
                    "hermex://pair?address=127.0.0.1%3A18810&token=\(token)"] {
            XCTAssertNil(SquaddPairingInvite(url: URL(string: bad)!), bad)
        }
        XCTAssertEqual(SquaddPairingInvite(url: URL(string: "openmausbot://pair?address=https%3A%2F%2Fmac.example.com&token=\(token)")!)?.server,
                       URL(string: "https://mac.example.com")!)
    }

    func testPairingTheSameComputerAgainReplacesThisIPhone() async throws {
        let first = try Self.fixture("pair-qr.json")
        let second = Data(String(decoding: first, as: UTF8.self).replacingOccurrences(of: "omb_recorded-device-token", with: "omb_second-token").utf8)
        var bodies: [[String: String]] = []
        SquaddHTTPFixture.handler = { request in
            bodies.append(try! Self.body(of: request))
            return (201, bodies.count == 1 ? first : second)
        }
        let manager = makeManager(keychain: InMemoryKeychainStore())
        try await manager.pairSquadd(SquaddPairingInvite(server: computer, credential: "409706"), deviceName: "iPhone", session: session)

        try await manager.pairSquadd(SquaddPairingInvite(server: computer, credential: "883150"), deviceName: "iPhone", session: session)

        XCTAssertEqual(bodies.last?["replacesToken"], "omb_recorded-device-token")
        XCTAssertEqual(manager.servers.filter { $0.id == computer.absoluteString }.count, 1)
        XCTAssertEqual(manager.squaddToken(for: computer), "omb_second-token")
        XCTAssertEqual(manager.state, .loggedIn(server: computer))
    }

    func testEachRefusalSaysWhatToDoAndAddsNothing() async throws {
        let manager = makeManager(keychain: InMemoryKeychainStore())
        var messages: Set<String> = []
        for (fixture, code) in [("code-expired.json", "pairing_not_open"), ("qr-used.json", "pairing_not_open"),
                                ("code-wrong.json", "pairing_code_wrong"), ("too-many.json", "pairing_too_many"),
                                ("device-limit.json", "pairing_device_limit")] {
            SquaddHTTPFixture.handler = { _ in (401, try! Self.fixture(fixture)) }
            do {
                try await manager.pairSquadd(SquaddPairingInvite(server: computer, credential: "409706"), deviceName: "iPhone", session: session)
                XCTFail("\(fixture) paired")
            } catch {
                XCTAssertEqual(error as? SquaddError, .pairing(code), fixture)
                messages.insert(squaddPairingFailure(error))
            }
        }
        XCTAssertEqual(messages.count, 4, "expired and used share one message; the rest each have their own")
        XCTAssertTrue(messages.contains { $0.contains("20") }, "the device limit names it")
        XCTAssertTrue(manager.servers.isEmpty)
    }

    // MARK: - Helpers

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SquaddHTTPFixture.self]
        return URLSession(configuration: configuration)
    }

    private func makeManager(keychain: InMemoryKeychainStore) -> AuthManager {
        AuthManager(keychain: keychain, headerStore: CustomHeaderStore(),
                    serverRegistry: ServerRegistry.inMemory(keychain: keychain),
                    hermesConnections: HermesConnections(), preferences: .ephemeral(), forgetPush: { _ in })
    }

    /// URLProtocol sees the body as a stream.
    private nonisolated static func body(of request: URLRequest?) throws -> [String: String] {
        guard let request else { return [:] }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
        }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    nonisolated static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Squadd/pairing/\(name)"))
    }
}
