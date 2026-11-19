import XCTest
@testable import HermesMobile

/// Thread links and the Open Agent intent (#27), against the agents recorded from a real
/// `openmausbot` companion (`Fixtures/Squadd/bots.json`).
@MainActor
final class SquaddThreadLinkTests: XCTestCase {
    private let mac = URL(string: "http://192.0.2.10:8810")!
    private let laptop = URL(string: "http://192.0.2.20:8810")!

    override func tearDown() {
        SquaddHTTPFixture.handler = nil
        AppIntentRouter.shared.pendingDeepLink = nil
        super.tearDown()
    }

    func testLinkOpensOnTheComputerItNamesElseTheActiveSquaddServer() throws {
        let servers = [account(mac), account(laptop)]

        // The desktop's own link names no computer: the active Squadd server takes it.
        let desktop = try XCTUnwrap(SquaddThreadLink(url: URL(string: "openmausbot://thread/5e423427-5373?bot=b70a")!))
        XCTAssertEqual(desktop.threadID, "5e423427-5373")
        XCTAssertEqual(desktop.botID, "b70a")
        XCTAssertEqual(desktop.account(in: servers, active: laptop)?.urlString, laptop.absoluteString)

        // One that names a computer opens there even when another is active, on either scheme.
        let named = SquaddThreadLink(threadID: "t 1", botID: "b", server: mac)
        let url = try XCTUnwrap(named.url)
        XCTAssertEqual(SquaddThreadLink(url: url), named)
        let appScheme = try XCTUnwrap(URL(string: url.absoluteString.replacingOccurrences(of: "openmausbot:", with: "\(HermesDeepLink.scheme):")))
        XCTAssertEqual(SquaddThreadLink(url: appScheme), named)
        XCTAssertEqual(named.account(in: servers, active: laptop)?.urlString, mac.absoluteString)
    }

    func testLinkToAComputerNeverPairedOpensNothing() {
        let link = SquaddThreadLink(threadID: "t", server: URL(string: "http://192.0.2.99:8810")!)
        XCTAssertNil(link.account(in: [account(mac)], active: mac))
        // No computer named and the active server isn't a Squadd one.
        XCTAssertNil(SquaddThreadLink(threadID: "t").account(in: [account(mac, kind: .webui)], active: mac))
        // Not thread links at all.
        for raw in ["openmausbot://pair?token=x", "openmausbot://thread/", "openmausbot://thread/a/b", "https://thread/x"] {
            XCTAssertNil(SquaddThreadLink(url: URL(string: raw)!), raw)
        }
    }

    func testLinkFindsItsThreadRowOrAgentAndMissesADeletedThread() throws {
        let bots = try JSONDecoder().decode(SquaddBotList.self, from: Self.fixture("bots.json")).bots
            + [SquaddBot(id: "solo", name: "Solo", threadId: "own-chat")]
        let sections = bots.map(SquaddAgentSection.init(bot:))

        XCTAssertEqual(SquaddThreadLink(threadID: "e0196fb1-7f3b-44b7-93a0-e7b1e93f7af1").row(in: sections),
                       "e0196fb1-7f3b-44b7-93a0-e7b1e93f7af1", "a task thread scrolls to its row")
        XCTAssertEqual(SquaddThreadLink(threadID: "own-chat").row(in: sections), "agent-solo",
                       "an agent's own chat with no task row scrolls to the agent")
        XCTAssertNil(SquaddThreadLink(threadID: "deleted").row(in: sections))
    }

    func testOpenAgentOffersTheActiveComputersAgentsAndOpensTheChosenOnesChat() async throws {
        SquaddHTTPFixture.handler = { _ in (200, try! Self.fixture("bots.json")) }
        let keychain = InMemoryKeychainStore()
        try keychain.save("token", forKey: .squaddDeviceToken, scope: mac.absoluteString)
        let servers = [account(mac), account(laptop)]

        let agents = await SquaddAgentProvider.activeServerAgents(active: mac, servers: servers, keychain: keychain, session: session())
        XCTAssertEqual(agents.map(\.name), ["Kiwi", "Pesto", "Squadd"])

        // A saved Shortcut finds its agent again on its own computer.
        let pesto = try XCTUnwrap(agents.first { $0.name == "Pesto" })
        let again = await SquaddAgentProvider.entities(for: [pesto.id], servers: servers, keychain: keychain, session: session())
        XCTAssertEqual(again, [pesto])

        var intent = OpenSquaddAgentIntent()
        intent.agent = pesto
        _ = try await intent.perform()
        let opened = try XCTUnwrap(AppIntentRouter.shared.pendingDeepLink.flatMap(SquaddThreadLink.init(url:)))
        XCTAssertEqual(opened, SquaddThreadLink(threadID: "5e423427-5373-4b0b-b212-0eb4f5c39be0",
                                                botID: "b70a0bbd-64c1-491b-ad34-f441d52fe9f0", server: mac))

        // The unpaired laptop (no token) and a webui server offer no agents.
        let unpaired = await SquaddAgentProvider.activeServerAgents(active: laptop, servers: servers, keychain: keychain, session: session())
        XCTAssertEqual(unpaired, [])
        let webui = await SquaddAgentProvider.activeServerAgents(active: mac, servers: [account(mac, kind: .webui)],
                                                                 keychain: keychain, session: session())
        XCTAssertEqual(webui, [])
    }

    // MARK: - Helpers

    private func account(_ url: URL, kind: ServerKind = .squadd) -> ServerAccount {
        ServerAccount(id: url.absoluteString, urlString: url.absoluteString, displayName: url.host() ?? "", initials: "",
                      headerLogoColorHex: HeaderLogoColor.defaultHex, createdAt: .now, updatedAt: .now, kind: kind)
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SquaddHTTPFixture.self]
        return URLSession(configuration: configuration)
    }

    private nonisolated static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Squadd/\(name)"))
    }
}
