import SwiftUI
import XCTest
@testable import HermesMobile

/// The presence ping (#33): what it sends to a real `openmausbot` companion
/// (`Fixtures/Squadd/presence.json`, its recorded answer) and when it is sent.
@MainActor
final class SquaddPresenceTests: XCTestCase {
    private let server = URL(string: "http://192.0.2.10:8810")!

    override func tearDown() {
        SquaddHTTPFixture.handler = nil
        super.tearDown()
    }

    func testPingTellsTheComputerThePhoneIsHere() async throws {
        var seen: URLRequest?
        SquaddHTTPFixture.handler = { request in
            seen = request
            return (200, try! Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/Squadd/presence.json")))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SquaddHTTPFixture.self]
        let client = SquaddCompanionClient(server: server, token: "device-token", session: URLSession(configuration: configuration))

        try await client.presenceActive(timeZone: "Europe/Rome", language: "pt-BR")

        let request = try XCTUnwrap(seen)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/presence/active")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
        XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
        let body = try XCTUnwrap(request.httpBody ?? request.httpBodyStream.map(Self.read))
        let sent = try JSONDecoder().decode([String: String].self, from: body)
        XCTAssertEqual(sent["source"], "phone", "only a phone's ping counts as the phone")
        XCTAssertEqual(sent["timeZone"], "Europe/Rome")
        XCTAssertEqual(sent["language"], "pt-br", "the companion takes the tag in lower case")
    }

    func testPingsOnArrivalThenEveryMinuteUntilTheAppLeaves() async {
        var pings = 0
        var waits: [Duration] = []
        // The third wait is where the app left the foreground: the task is cancelled there.
        await SquaddPresence.keepAlive(ping: { pings += 1 }, sleep: { duration in
            waits.append(duration)
            if waits.count == 3 { throw CancellationError() }
        })
        XCTAssertEqual(pings, 3, "one ping on arrival, one after each minute, none after leaving")
        XCTAssertEqual(waits, [.seconds(60), .seconds(60), .seconds(60)])
    }

    func testNoPingOnceTheForegroundTaskIsCancelledAndAFailedPingKeepsGoing() async {
        // Cancelled before it runs, as when the scene leaves the foreground: the task can't start
        // before this main-actor test suspends.
        let task = Task { @MainActor () -> Int in
            var pings = 0
            await SquaddPresence.keepAlive(ping: { pings += 1 }, sleep: { _ in try Task.checkCancellation() })
            return pings
        }
        task.cancel()
        let pings = await task.value
        XCTAssertEqual(pings, 0, "a background scene pings nothing")

        var attempts = 0
        await SquaddPresence.keepAlive(ping: {
            attempts += 1
            throw SquaddError.status(503)
        }, sleep: { _ in if attempts == 2 { throw CancellationError() } })
        XCTAssertEqual(attempts, 2, "a computer that didn't answer gets the next minute's ping")
    }

    /// The real home with the scene phase driven by the test: it pings only while the scene is
    /// active, nothing while it is in the background, and again as soon as the app is back.
    func testTheHomePingsInFrontAndNotInTheBackground() async throws {
        let studio = URL(string: "http://mac-studio.tailnet.test:8810")!
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Squadd")
        let bots = try Data(contentsOf: fixtures.appendingPathComponent("bots.json"))
        let presence = try Data(contentsOf: fixtures.appendingPathComponent("presence.json"))
        let loaded = expectation(description: "agents read")
        loaded.assertForOverFulfill = false
        Self.phase = .background
        Self.pingedIn = []
        SquaddHTTPFixture.handler = { request in
            switch request.url?.path {
            case "/api/bots": loaded.fulfill(); return (200, bots)
            case "/api/presence/active":
                Self.pingedIn.append(Self.phase)
                Self.onPing?()
                return (200, presence)
            default: return (404, Data())
            }
        }
        URLProtocol.registerClass(SquaddHTTPFixture.self)
        defer { URLProtocol.unregisterClass(SquaddHTTPFixture.self) }
        let keychain = InMemoryKeychainStore()
        let manager = AuthManager(keychain: keychain, headerStore: CustomHeaderStore(),
                                  serverRegistry: ServerRegistry.inMemory(keychain: keychain),
                                  hermesConnections: HermesConnections(), preferences: .ephemeral(), forgetPush: { _ in })
        try manager.addSquaddServer(address: studio, token: "token-studio")
        let scene = PhaseHolder()
        let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first))
        window.rootViewController = UIHostingController(rootView: PhaseHost(holder: scene) {
            SquaddServerHome(authManager: manager, server: studio, pendingThread: .constant(nil))
        })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; Self.onPing = nil }

        // Opened in the background: the home reads its agents but tells the computer nothing.
        await fulfillment(of: [loaded], timeout: 5)
        for _ in 0..<20 { await Task.yield() }

        for round in 1...2 {
            let pinged = expectation(description: "ping \(round) once in front")
            Self.onPing = { pinged.fulfill() }
            Self.phase = .active
            scene.phase = .active
            await fulfillment(of: [pinged], timeout: 5)
            Self.phase = .background
            scene.phase = .background
            for _ in 0..<20 { await Task.yield() }
        }
        XCTAssertEqual(Self.pingedIn, [.active, .active], "one ping each time the app comes to the front, none in the background")
    }

    nonisolated(unsafe) private static var phase: ScenePhase = .background
    nonisolated(unsafe) private static var pingedIn: [ScenePhase] = []
    nonisolated(unsafe) private static var onPing: (() -> Void)?

    private nonisolated static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@Observable
private final class PhaseHolder {
    var phase: ScenePhase = .background
}

/// Hands its content the scene phase the test sets, as the system does for the app's scene.
private struct PhaseHost<Content: View>: View {
    let holder: PhaseHolder
    @ViewBuilder let content: () -> Content
    var body: some View { content().environment(\.scenePhase, holder.phase) }
}
