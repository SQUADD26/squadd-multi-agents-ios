import SwiftData
import SwiftUI
import Network
import XCTest
@testable import HermesMobile

/// Choosing the route to a paired computer (#9) against a real companion's replies
/// (`Fixtures/Squadd/pairing/`: openmausbot origin/dev 9e05e3a04 with a hosted URL and its harness): the
/// routes its pairing lists, best first, and `GET /api/health`'s `{"app":"openmausbot"}`.
@MainActor
final class SquaddRouteTests: XCTestCase {
    private let pairedAt = URL(string: "http://10.0.7.2:18810")!

    override func tearDown() {
        SquaddHTTPFixture.handler = nil
        SquaddRoutes.shared.set(nil, for: pairedAt)
        super.tearDown()
    }

    func testPairingKeepsTheRoutesAndTheBestOneThatAnswersCarriesRequests() async throws {
        let manager = makeManager()
        let pair = try SquaddPairingTests.fixture("pair-routes.json")
        // The hosted tunnel answers with its own 502 page (the computer behind it sleeps) and the first LAN
        // address is another network's (404 stands for any reply that isn't the companion's): the second LAN
        // address is this Wi-Fi.
        var botsHost: String?
        SquaddHTTPFixture.handler = { request in
            switch (request.url?.host, request.url?.path) {
            case (_, "/api/pair"): return (201, pair)
            case ("mac-di-prova.example.net", "/api/health"): return (502, Data("<html>Bad gateway</html>".utf8))
            case ("10.0.2.10", "/api/health"): return (200, try! SquaddPairingTests.fixture("health.json"))
            case (let host, "/api/bots"): botsHost = host; return (200, Data(#"{"bots":[]}"#.utf8))
            default: return (404, Data())
            }
        }
        let invite = SquaddPairingInvite(server: pairedAt, credential: "omb_pair_" + String(repeating: "A", count: 43))
        try await manager.pairSquadd(invite, deviceName: "iPhone di prova", session: session)

        let book = manager.squaddRoutes(for: pairedAt)
        XCTAssertEqual(book.name, "Mac di prova")
        XCTAssertEqual(book.endpoints.count, 5)
        let finder = SquaddRouteFinder(server: pairedAt, book: book, session: session)
        await finder.find()
        XCTAssertEqual(finder.route?.url, URL(string: "http://10.0.2.10:18810"))
        XCTAssertEqual(finder.route?.isLocal, true)

        _ = try await SquaddCompanionClient(server: pairedAt, token: "t", session: session).bots()
        XCTAssertEqual(botsHost, "10.0.2.10", "requests follow the route, not the address paired at")
    }

    func testANetworkChangeMovesToTheRouteThatAnswersNow() async throws {
        let book = SquaddRouteBook(name: "Mac di prova",
                                   endpoints: try JSONDecoder().decode(SquaddPairResponse.self, from: SquaddPairingTests.fixture("pair-routes.json")).endpoints)
        let health = try SquaddPairingTests.fixture("health.json")
        // At home: only the Wi-Fi address answers. Then Wi-Fi is off: only the hosted address does.
        var answering = "10.0.7.2"
        SquaddHTTPFixture.handler = { request in
            request.url?.host == answering && request.url?.path == "/api/health" ? (200, health) : (404, Data())
        }
        let finder = SquaddRouteFinder(server: pairedAt, book: book, session: session)
        await finder.find()
        XCTAssertEqual(finder.route?.kind, .lan)

        let (changes, change) = AsyncStream<Void>.makeStream()
        let moved = expectation(description: "the route moved")
        let following = Task { await finder.follow(changes: changes, bonjour: AsyncStream { _ in }) { moved.fulfill() } }
        answering = "mac-di-prova.example.net"
        change.yield()
        await fulfillment(of: [moved])
        following.cancel()
        XCTAssertEqual(finder.route?.url, URL(string: "https://mac-di-prova.example.net"))
        XCTAssertEqual(finder.route?.isLocal, false, "off the LAN: a feature kept to the LAN stops")
        XCTAssertEqual(SquaddRoutes.shared.route(for: pairedAt)?.kind, .hosted)
    }

    func testBonjourFindsTheComputerWhenNoSavedRouteAnswers() async throws {
        // The computer moved to a new address on this Wi-Fi (DHCP): none of the saved ones answers.
        let book = SquaddRouteBook(name: "Mac di prova",
                                   endpoints: try JSONDecoder().decode(SquaddPairResponse.self, from: SquaddPairingTests.fixture("pair-routes.json")).endpoints)
        let health = try SquaddPairingTests.fixture("health.json")
        SquaddHTTPFixture.handler = { request in
            request.url?.host == "192.168.1.20" && request.url?.path == "/api/health" ? (200, health) : (404, Data())
        }
        let finder = SquaddRouteFinder(server: pairedAt, book: book, session: session)
        await finder.find()
        XCTAssertNil(finder.route)

        let found = try XCTUnwrap(SquaddRouteFinder.endpoint(host: .ipv4(try XCTUnwrap(IPv4Address("192.168.1.20"))), port: 18810))
        let (bonjour, advert) = AsyncStream<SquaddEndpoint>.makeStream()
        let moved = expectation(description: "the route moved")
        let following = Task { await finder.follow(changes: AsyncStream { _ in }, bonjour: bonjour) { moved.fulfill() } }
        advert.yield(found)
        await fulfillment(of: [moved])
        following.cancel()
        XCTAssertEqual(finder.route, found)
        XCTAssertEqual(finder.route?.kind, .bonjour)
    }

    // MARK: - Helpers

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SquaddHTTPFixture.self]
        return URLSession(configuration: configuration)
    }

    private func makeManager() -> AuthManager {
        let keychain = InMemoryKeychainStore()
        return AuthManager(keychain: keychain, headerStore: CustomHeaderStore(),
                           serverRegistry: ServerRegistry.inMemory(keychain: keychain),
                           hermesConnections: HermesConnections(), preferences: .ephemeral(), forgetPush: { _ in })
    }
}

/// Choosing the route on a real computer (#9), run only by a photo branch that sets `SQUADD_PAIR_URL` and
/// `SQUADD_PAIR_FEED` (a disposable companion behind a tunnel, as in `SquaddPairingLiveTests`): its pairing
/// lists a hosted HTTPS route (the tunnel) and LAN addresses the CI Mac can't reach. The app walks them,
/// keeps the hosted one, and the agents load over it.
@MainActor
final class SquaddRoutePhotoTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        super.tearDown()
    }

    func testRealRouteToACompanion() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let front = env["SQUADD_PAIR_URL"].flatMap(URL.init(string:)), let feed = env["SQUADD_PAIR_FEED"],
              let path = env["FOTO_DIR"] else { throw XCTSkip("Only against a live companion") }
        let dir = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var log: [String] = []
        func note(_ line: String) { log.append(line); print("ROUTE \(line)") }
        var opening = URLRequest(url: front.appendingPathComponent("feed"))
        opening.httpMethod = "POST"
        opening.setValue(feed, forHTTPHeaderField: "x-feed")
        let window = try JSONDecoder().decode([String: String].self, from: try await URLSession.shared.data(for: opening).0)
        let invite = SquaddPairingInvite(server: front, credential: try XCTUnwrap(window["token"]), name: "Mac di prova")
        let keychain = InMemoryKeychainStore()
        let manager = AuthManager(keychain: keychain, headerStore: CustomHeaderStore(),
                                  serverRegistry: ServerRegistry.inMemory(keychain: keychain),
                                  hermesConnections: HermesConnections(), preferences: .ephemeral(), forgetPush: { _ in })
        try await manager.pairSquadd(invite, deviceName: "iPhone CI", session: .shared)
        defer { SquaddRoutes.shared.set(nil, for: front) }
        let book = manager.squaddRoutes(for: front)
        XCTAssertTrue(book.endpoints.contains { $0.kind == .hosted }, "the computer lists its hosted route")
        note("paired; the computer lists: " + book.endpoints.map { "\($0.kind.rawValue) \($0.url.host ?? "") \($0.priority)" }.joined(separator: ", "))

        let finder = SquaddRouteFinder(server: front, book: book)
        let started = ContinuousClock.now
        await finder.find()
        XCTAssertEqual(finder.route?.kind, .hosted)
        note("route chosen: \(finder.route?.kind.rawValue ?? "none") in \(ContinuousClock.now - started); the LAN addresses don't answer from here")
        let bots = try await SquaddCompanionClient(server: front, token: try XCTUnwrap(manager.squaddToken(for: front))).bots()
        XCTAssertFalse(bots.isEmpty)
        note("GET /api/bots over that route -> \(bots.count) agent(s): \(bots.map(\.name).joined(separator: ", "))")

        // The home walks the routes itself: the photo waits for its walk, then for the agents.
        SquaddRoutes.shared.set(nil, for: front)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIWindow(windowScene: scene)
        host.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let container = try ModelContainer(for: CachedSession.self, CachedMessage.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        host.rootViewController = UIHostingController(rootView: SquaddRoute(authManager: manager, server: front) { EmptyView() }
            .modelContainer(container))
        host.makeKeyAndVisible()
        self.window = host
        let photo = try await readyPhoto(of: host, until: { SquaddRoutes.shared.route(for: front) != nil }, limit: .seconds(10))
        try photo.write(to: dir.appendingPathComponent("h-live-route-home.png"))
        try log.joined(separator: "\n").write(to: dir.appendingPathComponent("route-live-log.txt"), atomically: true, encoding: .utf8)
    }
}
