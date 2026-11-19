import XCTest
@testable import HermesMobile

/// The Squadd companion backend (#2) against responses recorded from a real `openmausbot`
/// companion (`Fixtures/Squadd/`, origin/dev bc2f42dfa, fake engine, three bots).
@MainActor
final class SquaddCompanionTests: XCTestCase {
    private let server = URL(string: "http://192.0.2.10:8810")!
    private let otherServer = URL(string: "http://192.0.2.20:8810")!

    override func tearDown() {
        SquaddHTTPFixture.handler = nil
        super.tearDown()
    }

    func testBotsSendsBearerWithoutOriginAndReadsRecordedAgents() async throws {
        var seen: URLRequest?
        SquaddHTTPFixture.handler = { request in
            seen = request
            return (200, try! Self.fixture("bots.json"))
        }

        let bots = try await client(token: "device-token").bots()

        XCTAssertEqual(seen?.url?.path, "/api/bots")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
        XCTAssertNil(seen?.value(forHTTPHeaderField: "Origin"))
        XCTAssertEqual(bots.map(\.name), ["Kiwi", "Pesto", "Squadd"])
        let pesto = try XCTUnwrap(SquaddAgentSection(bot: bots[1]) as SquaddAgentSection?)
        XCTAssertEqual(pesto.threads.map(\.title), ["Weekly menu", "hi"])
        XCTAssertEqual(pesto.threads.first?.updatedAt, 1_795_088_901.806)
    }

    func testCompanionDriftNeverFailsTheList() throws {
        let json = Data("""
        {"bots":[
          {"id":"a","name":7,"busy":"yes","tasks":[{"threadId":"t","title":null,"extra":{}},{"title":"no id"}]},
          {"name":"no id"},
          {"id":"b","newField":[1,2]}
        ],"somethingNew":true}
        """.utf8)

        let bots = try JSONDecoder().decode(SquaddBotList.self, from: json).bots

        XCTAssertEqual(bots.map(\.id), ["a", "b"])
        XCTAssertEqual(bots[0].tasks.map(\.threadId), ["t"])
        XCTAssertEqual(SquaddAgentSection(bot: bots[1]).name, String(localized: "Unnamed Agent"))
    }

    func testRevokedTokenSendsTheServerToPairAgain() async throws {
        SquaddHTTPFixture.handler = { _ in (401, try! Self.fixture("unauthorized.json")) }
        let keychain = InMemoryKeychainStore()
        let manager = makeManager(keychain: keychain)
        try manager.addSquaddServer(address: server, token: "revoked")
        XCTAssertEqual(manager.state, .loggedIn(server: server))
        let token = try XCTUnwrap(manager.squaddToken(for: server))
        let model = SquaddAgentListModel(fetch: { try await self.client(token: token).bots() },
                                         onUnpaired: { manager.squaddUnpaired(server: self.server) })

        await model.load()

        XCTAssertEqual(manager.state, .loggedOut(server: server))
        XCTAssertNil(manager.squaddToken(for: server))
        try manager.repairSquaddServer(server, token: "fresh")
        XCTAssertEqual(manager.state, .loggedIn(server: server))
    }

    func testTwoSquaddServersKeepTheirOwnTokens() async throws {
        let keychain = InMemoryKeychainStore()
        let manager = makeManager(keychain: keychain)
        try manager.addSquaddServer(address: server, token: "token-a")
        try manager.addSquaddServer(address: otherServer, token: "token-b")
        XCTAssertThrowsError(try manager.addSquaddServer(address: server, token: "again"))

        manager.squaddUnpaired(server: server)
        XCTAssertEqual(manager.state, .loggedIn(server: otherServer), "a 401 from the inactive server changes nothing on screen")
        XCTAssertNil(manager.squaddToken(for: server))
        XCTAssertEqual(manager.squaddToken(for: otherServer), "token-b")

        let first = try XCTUnwrap(manager.servers.first { $0.id == server.absoluteString })
        manager.switchActiveServer(to: first)
        XCTAssertEqual(manager.state, .loggedOut(server: server))
        XCTAssertEqual(first.kind, .squadd)

        await manager.removeServer(first)
        XCTAssertEqual(manager.squaddToken(for: otherServer), "token-b")
        XCTAssertEqual(manager.state, .loggedIn(server: otherServer))
    }

    // MARK: - Helpers

    private func makeManager(keychain: InMemoryKeychainStore) -> AuthManager {
        AuthManager(keychain: keychain, headerStore: CustomHeaderStore(),
                    serverRegistry: ServerRegistry.inMemory(keychain: keychain),
                    hermesConnections: HermesConnections(), preferences: .ephemeral(), forgetPush: { _ in })
    }

    private func client(token: String) -> SquaddCompanionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SquaddHTTPFixture.self]
        return SquaddCompanionClient(server: server, token: token, session: URLSession(configuration: configuration))
    }

    private nonisolated static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Squadd/\(name)"))
    }
}

/// Answers every request with `handler`'s status and body.
final class SquaddHTTPFixture: URLProtocol {
    // The system builds the protocol instances; tests set this before a request and tearDown clears it.
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let (status, data) = Self.handler?(request) else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
