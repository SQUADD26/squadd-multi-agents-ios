import SwiftData
import SwiftUI
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

        let intent = OpenSquaddAgentIntent()
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

    func testTheAppOpensThreadLinks() {
        let types = Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains(SquaddThreadLink.scheme), "iOS launches the app for openmausbot:// links")
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

/// Photographs a thread link opening in the real `ContentView`, through the same deep-link path
/// Siri and Shortcuts take, with the companion played back from the recordings: a link to a thread
/// on the inactive computer, one to a deleted thread, and one to a computer never paired (photos
/// only when `FOTO_DIR` is set, `TEST_RUNNER_FOTO_DIR`); and a link queued before the app appears.
@MainActor
final class SquaddThreadLinkPhotoTests: XCTestCase {
    private let studio = URL(string: "http://mac-studio.tailnet.test:8810")!
    private let laptop = URL(string: "http://macbook.tailnet.test:8810")!
    private var window: UIWindow?
    nonisolated(unsafe) private static var served: [String] = []

    override func tearDown() {
        URLProtocol.unregisterClass(SquaddHTTPFixture.self)
        SquaddHTTPFixture.handler = nil
        AppIntentRouter.shared.pendingDeepLink = nil
        window?.isHidden = true
        super.tearDown()
    }

    func testPhotoThreadLinks() async throws {
        let path = ProcessInfo.processInfo.environment["FOTO_DIR"]
        try XCTSkipIf(path == nil, "Only for photo runs")
        let dir = URL(fileURLWithPath: path!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manager = try twoPairedComputers()
        var router = try host(manager)

        // a. A link to Pesto's "hi" thread on the Mac Studio, with the MacBook active: the app
        // switches computer, reads its agents and marks the thread.
        let hi = SquaddThreadLink(threadID: "e0196fb1-7f3b-44b7-93a0-e7b1e93f7af1",
                                          botID: "b70a0bbd-64c1-491b-ad34-f441d52fe9f0", server: studio)
        Self.served = []
        router.requestDeepLink(hi.url)
        try await shoot("f1-link-opens-thread", dir: dir) {
            manager.state == .loggedIn(server: self.studio) && Self.served.contains("Bearer token-studio")
        }
        XCTAssertEqual(manager.state, .loggedIn(server: studio))

        // b. A thread deleted on the computer. Each alert gets a fresh app window.
        router = try host(manager)
        router.requestDeepLink(SquaddThreadLink(threadID: "deleted-thread", server: studio).url)
        try await shoot("f2-thread-not-found", dir: dir) { self.window?.rootViewController?.presentedViewController != nil }

        // c. A computer this iPhone never paired.
        router = try host(manager)
        router.requestDeepLink(SquaddThreadLink(threadID: "t", server: URL(string: "http://other.tailnet.test:8810")!).url)
        try await shoot("f3-computer-not-paired", dir: dir) { self.window?.rootViewController?.presentedViewController != nil }
        XCTAssertEqual(manager.state, .loggedIn(server: studio), "a link to an unpaired computer switches nothing")
    }

    /// Cold launch: Siri, a Shortcut or iOS opening an `openmausbot://` link queue it before the
    /// app's view exists; the view drains it as it appears and opens the computer the link names.
    func testALinkQueuedBeforeTheAppAppearsOpensOnItsComputer() async throws {
        let manager = try twoPairedComputers()
        let router = AppIntentRouter()
        router.requestDeepLink(SquaddThreadLink(threadID: "e0196fb1-7f3b-44b7-93a0-e7b1e93f7af1", server: studio).url)
        let switched = expectation(description: "switched to the Mac Studio")
        switched.assertForOverFulfill = false
        func observe() {
            withObservationTracking {
                if manager.state == .loggedIn(server: studio) { switched.fulfill() }
            } onChange: { DispatchQueue.main.async { MainActor.assumeIsolated { observe() } } }
        }
        observe()
        _ = try host(manager, router: router)
        await fulfillment(of: [switched], timeout: 5)
        XCTAssertNil(router.pendingDeepLink, "the link is opened once")
    }

    /// The MacBook active and the Mac Studio paired too, both answering with the recorded agents.
    private func twoPairedComputers() throws -> AuthManager {
        let bots = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Squadd/bots.json"))
        SquaddHTTPFixture.handler = { request in
            guard request.url?.path == "/api/bots" else { return (404, Data()) }
            Self.served.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            return (200, bots)
        }
        URLProtocol.registerClass(SquaddHTTPFixture.self)
        let keychain = InMemoryKeychainStore()
        let manager = AuthManager(keychain: keychain, headerStore: CustomHeaderStore(),
                                  serverRegistry: ServerRegistry.inMemory(keychain: keychain),
                                  hermesConnections: HermesConnections(), preferences: .ephemeral(), forgetPush: { _ in })
        try manager.addSquaddServer(address: studio, token: "token-studio")
        try manager.addSquaddServer(address: laptop, token: "token-laptop")
        XCTAssertEqual(manager.state, .loggedIn(server: laptop))
        return manager
    }

    /// Shows a fresh `ContentView` and returns the router it drains: the test host app's own
    /// ContentView drains `AppIntentRouter.shared`, so each window gets its own.
    private func host(_ manager: AuthManager, router: AppIntentRouter = AppIntentRouter()) throws -> AppIntentRouter {
        let container = try ModelContainer(for: CachedSession.self, CachedMessage.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        self.window?.isHidden = true
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(
            rootView: ContentView(authManager: manager, intentRouter: router).modelContainer(container))
        window.makeKeyAndVisible()
        self.window = window
        return router
    }

    /// Writes `<name>.png` once `ready` holds and the screen has settled (`readyPhoto`).
    private func shoot(_ name: String, dir: URL, until ready: () -> Bool) async throws {
        let window = try XCTUnwrap(window)
        try await readyPhoto(of: window, until: ready, limit: .seconds(5)).write(to: dir.appendingPathComponent("\(name).png"))
    }
}
