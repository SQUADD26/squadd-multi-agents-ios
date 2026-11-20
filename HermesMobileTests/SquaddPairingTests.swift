import AVFoundation
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
        var bodies: [[String: String]] = []
        SquaddHTTPFixture.handler = { request in
            seen = request
            bodies.append(try! Self.body(of: request))
            // The first reply is lost on the way, as on a weak network; the retry must be the same request.
            return bodies.count == 1 ? (502, Data()) : (201, try! Self.fixture("pair-qr.json"))
        }
        let link = try XCTUnwrap(URL(string: try String(decoding: Self.fixture("qr-link.txt"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let invite = try XCTUnwrap(SquaddPairingInvite(url: link))
        let keychain = InMemoryKeychainStore()
        let manager = makeManager(keychain: keychain)

        do {
            try await manager.pairSquadd(invite, deviceName: "iPhone di prova", session: session)
            XCTFail("a lost reply paired")
        } catch {}
        try await manager.pairSquadd(invite, deviceName: "iPhone di prova", session: session)

        XCTAssertEqual(bodies.count, 2)
        XCTAssertNotNil(bodies[0]["pairRequestId"]?.range(of: #"^[A-Za-z0-9._-]{16,128}$"#, options: .regularExpression),
                        "the companion ignores a pairRequestId outside its pattern")
        XCTAssertEqual(bodies[1]["pairRequestId"], bodies[0]["pairRequestId"], "a retry of one invite replays, it does not spend the code twice")
        XCTAssertEqual(seen?.url, computer.appendingPathComponent("api/pair"))
        XCTAssertNil(seen?.value(forHTTPHeaderField: "Origin"))
        let body = try XCTUnwrap(bodies.last)
        XCTAssertEqual(body["credential"], "omb_pair_" + String(repeating: "A", count: 43))
        XCTAssertEqual(body["deviceName"], "iPhone di prova")
        XCTAssertNil(body["replacesToken"], "a first pairing replaces nothing")
        XCTAssertEqual(manager.state, .loggedIn(server: computer))
        XCTAssertEqual(manager.squaddToken(for: computer), "omb_recorded-device-token")
        XCTAssertEqual(manager.activeServer?.displayName, "Mac di prova")
    }

    /// The desktop's QR carries its key for secrets (`secretKey`, built here by `phonePairingLink` at origin/dev
    /// 961cb8133); the pairing keeps it with the device id the companion gave, and a later typed-code pairing keeps
    /// the key while taking its new device id (#16).
    func testQRPairingKeepsTheComputersSecretKeyAndThisDevicesId() async throws {
        var reply = try Self.fixture("pair-qr.json")
        SquaddHTTPFixture.handler = { _ in (201, reply) }
        let link = try XCTUnwrap(URL(string: try String(decoding: Self.fixture("qr-link-secret.txt"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let keychain = InMemoryKeychainStore()
        let manager = makeManager(keychain: keychain)
        try await manager.pairSquadd(try XCTUnwrap(SquaddPairingInvite(url: link)), deviceName: "iPhone", session: session)

        let key = try XCTUnwrap(Data(base64URL: "BM0QEVKFG1Dp5TP1M-tCdVCuPXhn2oeC7O-vtX2Q41BM5UY2xml1DPseNax7YgYZQdjajZ44d_VPYdo2hGVKO-A"))
        XCTAssertEqual(SquaddSecretPairing.saved(for: computer, keychain: keychain),
                       SquaddSecretPairing(deviceId: "88ff1d3a-615e-4edb-9c48-74e6693bf7d8", secretKey: key))

        reply = Data(String(decoding: reply, as: UTF8.self)
            .replacingOccurrences(of: "88ff1d3a-615e-4edb-9c48-74e6693bf7d8", with: "0c0e7d0e-2b5c-4a35-9a43-3b3ab3a5c111").utf8)
        try await manager.pairSquadd(SquaddPairingInvite(server: computer, credential: "409706"), deviceName: "iPhone", session: session)
        XCTAssertEqual(SquaddSecretPairing.saved(for: computer, keychain: keychain),
                       SquaddSecretPairing(deviceId: "0c0e7d0e-2b5c-4a35-9a43-3b3ab3a5c111", secretKey: key))
    }

    func testTypedCodeIsTheCompanionsSixDigitsAndReachesTheSameServer() throws {
        let typed = try XCTUnwrap(SquaddPairingInvite(typedAddress: " 127.0.0.1:18810 ", code: "409 706"))
        XCTAssertEqual(typed.server, computer, "typed and scanned reach one server in the list")
        XCTAssertEqual(typed.credential, "409706")
        XCTAssertEqual(SquaddPairingInvite(typedAddress: "127.0.0.1:18810", code: "409-706")?.credential, "409706")
        // Five digits, or no address, are no pairing.
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

    /// A VPS or Cloud with no companion: the desktop's QR is its own `/pair#code=` page, and its code twelve symbols.
    func testServerQRAndTwelveSymbolCodePairAServerOrCloud() throws {
        let vps = URL(string: "https://vps.example.com")!
        let page = try XCTUnwrap(SquaddPairingInvite(url: URL(string: "https://vps.example.com/pair#code=RPXB-WCD6-C6Y7")!))
        XCTAssertEqual(page.server, vps)
        XCTAssertEqual(page.credential, "RPXB-WCD6-C6Y7")
        XCTAssertEqual(SquaddPairingInvite(url: URL(string: "openmausbot://pair?address=https%3A%2F%2Fvps.example.com&code=rpxbwcd6c6y7")!)?.credential,
                       "RPXB-WCD6-C6Y7")
        let typed = try XCTUnwrap(SquaddPairingInvite(typedAddress: "vps.example.com", code: "rpxb wcd6 c6y7"))
        XCTAssertEqual(typed.server, vps, "a name without a port is https")
        XCTAssertEqual(typed.credential, "RPXB-WCD6-C6Y7")
        XCTAssertNil(SquaddPairingInvite(url: URL(string: "https://vps.example.com/other#code=RPXB-WCD6-C6Y7")!))
        XCTAssertNil(SquaddPairingInvite(url: URL(string: "https://vps.example.com/pair#code=NOT-A-CODE")!))
        XCTAssertEqual(try SquaddPairingInvite.scanned("https://vps.example.com/pair#code=RPXB-WCD6-C6Y7").get().server, vps)
        let relayOnly = "openmausbot://pair?address=relay-only.invalid%3A443&token=omb_pair_" + String(repeating: "A", count: 43)
        XCTAssertEqual(SquaddPairingInvite.scanned(relayOnly), .failure(.relayOnly), "a name that never resolves is no route")
        XCTAssertEqual(SquaddPairingInvite.scanned("https://example.com/menu"), .failure(.notAPairingCode))
    }

    func testEachRefusalSaysWhatToDoAndAddsNothing() async throws {
        let manager = makeManager(keychain: InMemoryKeychainStore())
        var messages: Set<String> = []
        for (fixture, code) in [("code-expired.json", "pairing_not_open"), ("qr-used.json", "pairing_not_open"),
                                ("code-wrong.json", "pairing_code_wrong"), ("too-many.json", "pairing_too_many"),
                                ("device-limit.json", "pairing_device_limit"), ("qr-only.json", "pairing_qr_only")] {
            SquaddHTTPFixture.handler = { _ in (401, try! Self.fixture(fixture)) }
            do {
                try await manager.pairSquadd(SquaddPairingInvite(server: computer, credential: "409706"), deviceName: "iPhone", session: session)
                XCTFail("\(fixture) paired")
            } catch {
                XCTAssertEqual(error as? SquaddError, .pairing(code), fixture)
                messages.insert(squaddPairingFailure(error))
            }
        }
        // The companion answers an expired and a used code alike: no pairing is open.
        XCTAssertEqual(messages.count, 5, "expired and used share one message; the rest each have their own")
        XCTAssertEqual(squaddPairingFailure(SquaddError.pairing("pairing_new_reason")),
                       String(localized: "The computer refused the code. Codes work once and only for a few minutes: create a new one on the computer."))
        XCTAssertFalse(messages.contains(squaddPairingFailure(SquaddError.pairing("pairing_new_reason"))),
                       "every known refusal has its own message, not the catch-all")
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

/// Photographs the pairing screens into `FOTO_DIR` (passed as `TEST_RUNNER_FOTO_DIR`) for the PR's
/// evidence, the companion played back from the recorded replies. The simulator has no camera, so the
/// screen shows the way to the typed code. Skipped everywhere else.
@MainActor
final class SquaddPairingPhotoTests: XCTestCase {
    private let computer = URL(string: "http://127.0.0.1:18810")!
    private var window: UIWindow?
    nonisolated(unsafe) private static var served = 0

    override func tearDown() {
        URLProtocol.unregisterClass(SquaddHTTPFixture.self)
        SquaddHTTPFixture.handler = nil
        window?.isHidden = true
        super.tearDown()
    }

    func testPhotoPairingScreens() async throws {
        let path = ProcessInfo.processInfo.environment["FOTO_DIR"]
        try XCTSkipIf(path == nil, "Only for photo runs")
        let dir = URL(fileURLWithPath: path!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var reply = (401, try SquaddPairingTests.fixture("code-expired.json"))
        let bots = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Squadd/bots.json"))
        // URLSession.shared, the session the screens use, answers from the recordings.
        SquaddHTTPFixture.handler = { request in
            Self.served += 1
            return request.url?.path == "/api/bots" ? (200, bots) : reply
        }
        URLProtocol.registerClass(SquaddHTTPFixture.self)
        let keychain = InMemoryKeychainStore()
        let manager = AuthManager(keychain: keychain, headerStore: CustomHeaderStore(),
                                  serverRegistry: ServerRegistry.inMemory(keychain: keychain),
                                  hermesConnections: HermesConnections(), preferences: .ephemeral(), forgetPush: { _ in })
        let link = try XCTUnwrap(URL(string: String(decoding: try SquaddPairingTests.fixture("qr-link.txt"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let invite = try XCTUnwrap(SquaddPairingInvite(url: link))

        // a. The pairing screen: camera (none in the simulator, so the way to the code), then the code.
        try await shoot("a-pair-screen", SquaddAddServerSheet(authManager: manager), dir: dir) { true }

        // b. An openmausbot://pair link whose code expired.
        Self.served = 0
        try await shoot("b-link-expired", SquaddAddServerSheet(authManager: manager, invite: invite), dir: dir) { Self.served > 0 }

        // c. The computer already has 20 devices.
        reply = (401, try SquaddPairingTests.fixture("device-limit.json"))
        Self.served = 0
        try await shoot("c-device-limit", SquaddAddServerSheet(authManager: manager, invite: invite), dir: dir) { Self.served > 0 }

        // f. A computer that takes only its QR code refused the typed code.
        reply = (400, try SquaddPairingTests.fixture("qr-only.json"))
        Self.served = 0
        try await shoot("f-qr-only", SquaddAddServerSheet(authManager: manager, invite: invite), dir: dir) { Self.served > 0 }

        // e. The camera refused: the way to Settings, and the code below.
        try await shoot("e-camera-denied", NavigationStack {
            SquaddPairView(authManager: manager, onPaired: {}, camera: .denied)
        }, dir: dir) { true }

        // d. Paired: the computer's agents under its own name.
        reply = (201, try SquaddPairingTests.fixture("pair-qr.json"))
        try await manager.pairSquadd(invite, deviceName: "iPhone di prova")
        XCTAssertEqual(manager.state, .loggedIn(server: computer))
        Self.served = 0
        try await shoot("d-paired-home", SquaddRoute(authManager: manager, server: computer) { EmptyView() }, dir: dir) { Self.served > 0 }
    }

    /// The app opens an `openmausbot://pair` link the way iOS hands one over: `ContentView.onOpenURL`
    /// presents the pairing sheet in the app's own window, and the sheet pairs on appear.
    func testPhotoLinkOpensThePairingSheet() async throws {
        let path = ProcessInfo.processInfo.environment["FOTO_DIR"]
        try XCTSkipIf(path == nil, "Only for photo runs")
        let expired = try SquaddPairingTests.fixture("code-expired.json")
        Self.served = 0
        SquaddHTTPFixture.handler = { request in
            if request.url?.path == "/api/pair" { Self.served += 1 }
            return (401, expired)
        }
        URLProtocol.registerClass(SquaddHTTPFixture.self)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let app = try XCTUnwrap(scene.windows.first { $0.rootViewController != nil && !$0.isHidden })
        let link = try XCTUnwrap(URL(string: String(decoding: try SquaddPairingTests.fixture("qr-link.txt"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let opened = await UIApplication.shared.open(link)
        XCTAssertTrue(opened, "iOS hands openmausbot:// to this app")
        let photo = try await readyPhoto(of: app, until: { Self.served > 0 }, limit: .seconds(10))
        XCTAssertGreaterThan(Self.served, 0, "the link opened the pairing sheet, which sent the link's code to /api/pair")
        try photo.write(to: URL(fileURLWithPath: path!).appendingPathComponent("g-link-opens-sheet.png"))
        app.rootViewController?.dismiss(animated: false)
    }

    /// Hosts `view` in a window of the app's scene and writes `<name>.png` once `ready` holds and the
    /// screen sits still (`readyPhoto`).
    func shoot<V: View>(_ name: String, _ view: V, dir: URL, until ready: @MainActor () -> Bool) async throws {
        let container = try ModelContainer(for: CachedSession.self, CachedMessage.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window?.isHidden = true
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: view.modelContainer(container))
        window.makeKeyAndVisible()
        self.window = window
        try await readyPhoto(of: window, until: ready, limit: .seconds(10)).write(to: dir.appendingPathComponent("\(name).png"))
    }
}
