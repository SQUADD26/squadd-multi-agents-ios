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
        // address is another network's: the second LAN address is this Wi-Fi.
        var botsHost: String?
        SquaddHTTPFixture.handler = { request in
            switch (request.url?.host, request.url?.path) {
            case (_, "/api/pair"): return (201, pair)
            case ("mac-di-prova.example.net", "/api/health"): return (502, Data("<html>Bad gateway</html>".utf8))
            case ("10.0.2.10", "/api/health"): return (200, try! SquaddPairingTests.fixture("health.json"))
            case (let host, "/api/bots"): botsHost = host; return (200, Data(#"{"bots":[]}"#.utf8))
            default: return (0, Data())
            }
        }
        let link = try XCTUnwrap(URL(string: String(decoding: try SquaddPairingTests.fixture("qr-link-routes.txt"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let invite = try XCTUnwrap(SquaddPairingInvite(url: link))
        XCTAssertEqual(invite.endpoints.map(\.kind), [.hosted, .lan, .lan, .lan, .bonjour], "the link's routes")
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
            request.url?.host == answering && request.url?.path == "/api/health" ? (200, health) : (0, Data())
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
            request.url?.host == "192.168.1.20" && request.url?.path == "/api/health" ? (200, health) : (0, Data())
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
