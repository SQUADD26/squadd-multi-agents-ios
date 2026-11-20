import SwiftUI
import XCTest
@testable import HermesMobile

/// A real pairing with the app's own URLSession against a disposable `openmausbot` companion behind a
/// tunnel, run only by a photo branch's workflow that sets `SQUADD_PAIR_URL` and `SQUADD_PAIR_FEED`. The
/// tunnel's front opens pairing windows (`POST /feed`) and counts paired devices (`GET /feed/devices`);
/// every other path is the companion itself.
extension SquaddPairingPhotoTests {
    func testRealPairingWithACompanion() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let front = env["SQUADD_PAIR_URL"].flatMap(URL.init(string:)), let feed = env["SQUADD_PAIR_FEED"],
              let path = env["FOTO_DIR"] else { throw XCTSkip("Only against a live companion") }
        let dir = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var log: [String] = []
        func note(_ line: String) { log.append(line); print("LIVE \(line)") }
        func call(_ method: String, _ route: String) async throws -> Data {
            var request = URLRequest(url: front.appendingPathComponent(route))
            request.httpMethod = method
            request.setValue(feed, forHTTPHeaderField: "x-feed")
            return try await URLSession.shared.data(for: request).0
        }
        func openPairing() async throws -> (token: String, code: String) {
            let window = try JSONDecoder().decode([String: String].self, from: try await call("POST", "feed"))
            return (try XCTUnwrap(window["token"]), try XCTUnwrap(window["code"]))
        }
        struct Devices: Decodable { let devices: [[String: String]] }
        func deviceCount() async throws -> Int {
            try JSONDecoder().decode(Devices.self, from: try await call("GET", "feed/devices")).devices.count
        }
        let keychain = InMemoryKeychainStore()
        let manager = AuthManager(keychain: keychain, headerStore: CustomHeaderStore(),
                                  serverRegistry: ServerRegistry.inMemory(keychain: keychain),
                                  hermesConnections: HermesConnections(), preferences: .ephemeral(), forgetPush: { _ in })
        let before = try await deviceCount()
        note("devices before: \(before)")

        // 1. The QR link, as the desktop writes it.
        let first = try await openPairing()
        var link = URLComponents()
        link.scheme = "openmausbot"
        link.host = "pair"
        link.queryItems = [.init(name: "address", value: front.absoluteString), .init(name: "token", value: first.token),
                           .init(name: "name", value: "Mac di prova")]
        let invite = try XCTUnwrap(link.url.flatMap(SquaddPairingInvite.init(url:)))
        try await manager.pairSquadd(invite, deviceName: "iPhone CI", session: .shared)
        let server = invite.server
        let token = try XCTUnwrap(manager.squaddToken(for: server))
        XCTAssertEqual(manager.state, .loggedIn(server: server))
        note("QR link -> paired; token in the Keychain; active server «\(manager.activeServer?.displayName ?? "-")»")
        var authenticated = URLRequest(url: server.appendingPathComponent("api/bots"))
        authenticated.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let response = try await URLSession.shared.data(for: authenticated).1
        let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
        XCTAssertNotEqual(status, 401, "the computer knows the new token")
        note("GET /api/bots with the token -> \(status) (not 401: the computer knows this iPhone)")
        let paired = try await deviceCount()
        XCTAssertEqual(paired, before + 1)
        note("devices after pairing: \(paired)")

        // 2. A wrong typed code.
        let second = try await openPairing()
        let wrong = try XCTUnwrap(SquaddPairingInvite(typedAddress: server.absoluteString,
                                                      code: second.code == "000000" ? "111111" : "000000"))
        do {
            try await manager.pairSquadd(wrong, deviceName: "iPhone CI", session: .shared)
            XCTFail("a wrong code paired")
        } catch {
            XCTAssertEqual(error as? SquaddError, .pairing("pairing_code_wrong"))
            note("wrong code -> \(error) -> «\(squaddPairingFailure(error))»")
        }
        // The sheet sends the same wrong code (two of the five tries); its spinner keeps the screen moving
        // until the computer answers.
        try await shoot("f-live-wrong-code", SquaddAddServerSheet(authManager: manager, invite: wrong), dir: dir) { true }

        // 3. The right code: the same computer again, so this iPhone is replaced, not added.
        let again = try XCTUnwrap(SquaddPairingInvite(typedAddress: server.absoluteString, code: second.code))
        try await manager.pairSquadd(again, deviceName: "iPhone CI", session: .shared)
        XCTAssertNotEqual(manager.squaddToken(for: server), token)
        XCTAssertEqual(manager.servers.filter { $0.id == server.absoluteString }.count, 1)
        let after = try await deviceCount()
        XCTAssertEqual(after, before + 1, "replacesToken swapped this iPhone")
        note("right code, same computer -> paired again; servers in the list: 1; devices after: \(after)")
        try log.joined(separator: "\n").write(to: dir.appendingPathComponent("pairing-live-log.txt"), atomically: true, encoding: .utf8)
    }
}
