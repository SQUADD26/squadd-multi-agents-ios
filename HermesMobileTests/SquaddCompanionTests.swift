import SwiftData
import SwiftUI
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
        XCTAssertEqual(pesto.unreadThreadIDs.count, 2)
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
        let model = SquaddAgentListModel(client: client(token: token),
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

    // MARK: - Threads (#17), against the isolated companion's recordings (origin/dev 3d12c2fd7)

    private let starter = "115b3d10-f305-4bef-8826-12c4856a6c97"
    private let pinnedThread = "ad0bec87-7c36-40ca-a3ce-b5a991c6e22f"
    private let sugarThread = "efb8fa96-47ef-4968-bb13-ce9aacada117"

    func testThreadsFollowTheDesktopOrderAndArchivedWaitApart() async throws {
        SquaddHTTPFixture.handler = { _ in (200, try! Self.fixture("bots-organized.json")) }
        let model = SquaddAgentListModel(client: client(token: "t"), onUnpaired: {})

        await model.load()

        let section = try XCTUnwrap(sections(model).first)
        XCTAssertEqual(section.threads.map(\.title), ["Rinominato", "ciao zucchero"], "pinned first, then the newest")
        XCTAssertEqual(section.archived.map(\.title), ["Prova B"])
    }

    func testThreadActionsUseTheTaskRoutes() async throws {
        var seen: [(String, String, [String: Any])] = []
        SquaddHTTPFixture.handler = { request in
            let body = request.httpBodyStream.flatMap { stream -> [String: Any]? in
                stream.open(); defer { stream.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while case let n = stream.read(&buffer, maxLength: buffer.count), n > 0 { data.append(buffer, count: n) }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            } ?? [:]
            seen.append((request.httpMethod ?? "", request.url?.path ?? "", body))
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/bots"): return (200, try! Self.fixture("bots-organized.json"))
            case ("POST", _): return (201, try! Self.fixture("task-create.json"))
            case ("DELETE", _): return (200, try! Self.fixture("task-delete.json"))
            default: return (200, try! Self.fixture("task-patch.json"))
            }
        }
        let model = SquaddAgentListModel(client: client(token: "t"), onUnpaired: {})
        await model.load()
        let tasks = "/api/bots/\(starter)/tasks"

        let created = await model.createThread(botId: starter)
        let renamed = await model.rename(threadId: sugarThread, botId: starter, to: "Zucchero")
        let unpinned = await model.setPinned(false, threadId: pinnedThread, botId: starter)
        let archived = await model.setArchived(true, threadId: sugarThread, botId: starter, now: Date(timeIntervalSince1970: 2))
        let restored = await model.setArchived(false, threadId: sugarThread, botId: starter)
        let deleted = await model.delete(threadId: sugarThread, botId: starter)

        XCTAssertEqual([created, renamed, unpinned, archived, restored, deleted], [true, true, true, true, true, true])
        let calls = seen.dropFirst()
        XCTAssertEqual(calls.map { "\($0.0) \($0.1)" }, ["POST \(tasks)", "PATCH \(tasks)/\(sugarThread)", "PATCH \(tasks)/\(pinnedThread)",
                                                     "PATCH \(tasks)/\(sugarThread)", "PATCH \(tasks)/\(sugarThread)", "DELETE \(tasks)/\(sugarThread)"])
        let bodies = calls.map(\.2)
        XCTAssertEqual(bodies[0]["select"] as? Bool, false, "a phone's new thread never moves the desktop off its thread")
        XCTAssertEqual(bodies[1]["title"] as? String, "Zucchero")
        XCTAssertEqual(bodies[2]["pinned"] as? Bool, false)
        XCTAssertEqual(bodies[3]["archivedAt"] as? Double, 2000)
        XCTAssertTrue(bodies[4]["archivedAt"] is NSNull, "restore sends null")
        let section = try XCTUnwrap(sections(model).first)
        XCTAssertTrue(section.threads.contains { $0.title == "Prova A" }, "the created thread is listed")
        XCTAssertFalse((section.threads + section.archived).contains { $0.id == sugarThread })
    }

    func testRefusedChangesPutTheThreadBack() async throws {
        var refusing = false
        SquaddHTTPFixture.handler = { request in
            if refusing { return (400, try! Self.fixture("task-patch-400.json")) }
            return (200, try! Self.fixture("bots-organized.json"))
        }
        let model = SquaddAgentListModel(client: client(token: "t"), onUnpaired: {})
        await model.load()
        let before = try sections(model)
        refusing = true

        let unpinned = await model.setPinned(false, threadId: pinnedThread, botId: starter)
        let deleted = await model.delete(threadId: sugarThread, botId: starter)

        XCTAssertFalse(unpinned)
        XCTAssertFalse(deleted)
        XCTAssertEqual(try sections(model), before)
    }

    func testSearchReadsHitsAndSaysWhenNothingMatches() async throws {
        var queries: [String?] = []
        SquaddHTTPFixture.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
            queries.append(query)
            return (200, try! Self.fixture(query == "zucchero" ? "search-hits.json" : "search-empty.json"))
        }
        let model = SquaddAgentListModel(client: client(token: "t"), onUnpaired: {})

        await model.search("zucchero")
        XCTAssertEqual(model.searchHits?.map(\.task), ["ciao zucchero"])
        XCTAssertEqual(model.searchHits?.first?.snippet, "ciao zucchero")
        await model.search("nessunrisultatoxyz")
        XCTAssertEqual(model.searchHits, [])
        await model.search("  ")
        XCTAssertNil(model.searchHits, "clearing the field ends the search")
        XCTAssertEqual(queries, ["zucchero", "nessunrisultatoxyz"])
    }

    func testExportWritesTheDesktopMarkdownToAFile() async throws {
        var path: String?
        SquaddHTTPFixture.handler = { request in
            path = request.url?.path
            return (200, try! Self.fixture("export.md"))
        }
        let model = SquaddAgentListModel(client: client(token: "t"), onUnpaired: {})

        let exported = await model.export(threadId: sugarThread, title: "ciao/zucchero")

        let file = try XCTUnwrap(exported)

        XCTAssertEqual(path, "/api/threads/\(sugarThread)/export")
        XCTAssertEqual(file.lastPathComponent, "ciao-zucchero.md")
        XCTAssertEqual(try Data(contentsOf: file), try Self.fixture("export.md"))
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    private func sections(_ model: SquaddAgentListModel) throws -> [SquaddAgentSection] {
        guard case .loaded(let sections) = model.phase else { XCTFail("not loaded"); return [] }
        return sections
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

/// Photographs the real Squadd screens into `FOTO_DIR` (passed as `TEST_RUNNER_FOTO_DIR`) for the
/// PR's evidence, with the companion played back from the recorded responses: a valid server, a
/// second server, a revoked token, the Face ID lock and Settings. Skipped everywhere else.
@MainActor
final class SquaddScreenPhotoTests: XCTestCase {
    private let studio = URL(string: "http://mac-studio.tailnet.test:8810")!
    private let laptop = URL(string: "http://macbook.tailnet.test:8810")!
    private let revoked = URL(string: "http://old-mac.tailnet.test:8810")!
    private var window: UIWindow?
    nonisolated(unsafe) private static var botsServed = 0

    override func tearDown() {
        URLProtocol.unregisterClass(SquaddHTTPFixture.self)
        SquaddHTTPFixture.handler = nil
        window?.isHidden = true
        super.tearDown()
    }

    func testPhotoSquaddScreens() async throws {
        let path = ProcessInfo.processInfo.environment["FOTO_DIR"]
        try XCTSkipIf(path == nil, "Only for photo runs")
        let dir = URL(fileURLWithPath: path!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bots = try Self.fixture("bots.json"), unauthorized = try Self.fixture("unauthorized.json")
        // URLSession.shared, the session the screens use, answers from the recordings.
        SquaddHTTPFixture.handler = { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer revoked" { return (401, unauthorized) }
            guard request.url?.path == "/api/bots" else { return (404, Data()) } // nothing else was recorded
            Self.botsServed += 1
            return (200, bots)
        }
        URLProtocol.registerClass(SquaddHTTPFixture.self)
        let keychain = InMemoryKeychainStore()
        let manager = AuthManager(keychain: keychain, headerStore: CustomHeaderStore(),
                                  serverRegistry: ServerRegistry.inMemory(keychain: keychain),
                                  hermesConnections: HermesConnections(), preferences: .ephemeral(), forgetPush: { _ in })

        // a. A valid server: its agents and their threads.
        try add(studio, name: "Mac Studio", initials: "MS", color: "#2E7D32", token: "token-a", to: manager)
        try await shoot("a-agents", home(manager, studio), dir: dir) { Self.botsServed > 0 }

        // b. A second server, then back to the first from the avatar's switcher.
        try add(laptop, name: "MacBook", initials: "MB", color: "#1565C0", token: "token-b", to: manager)
        XCTAssertEqual(manager.state, .loggedIn(server: laptop))
        Self.botsServed = 0
        try await shoot("b1-second-server", home(manager, laptop), dir: dir) { Self.botsServed > 0 }
        manager.switchActiveServer(to: try XCTUnwrap(manager.servers.first { $0.id == studio.absoluteString }))
        XCTAssertEqual(manager.squaddToken(for: laptop), "token-b")
        Self.botsServed = 0
        try await shoot("b2-back-to-first", home(manager, studio), dir: dir) { Self.botsServed > 0 }

        // c. The desktop revoked this iPhone: the companion's 401 sends it to pair again.
        try add(revoked, name: "Old Mac", initials: "OM", color: "#6A1B9A", token: "revoked", to: manager)
        try await shoot("c-pair-again", home(manager, revoked), dir: dir) { manager.state == .loggedOut(server: self.revoked) }
        XCTAssertNil(manager.squaddToken(for: revoked))

        // d. The Face ID lock covers a Squadd server like any other: on, cold launch, no unlock yet.
        manager.switchActiveServer(to: try XCTUnwrap(manager.servers.first { $0.id == studio.absoluteString }))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SquaddScreenPhotoTests"))
        defaults.set(true, forKey: AppLock.enabledKey)
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: "SquaddScreenPhotoTests") }
        let lock = AppLock(defaults: defaults, authenticator: StillLocked())
        await lock.sceneDidBecomeActive()?.value // the scene is up and Face ID failed: the lock, not the cover
        XCTAssertTrue(lock.isLocked)
        try await shoot("d-face-id-lock", ZStack { home(manager, studio); AppLockView(lock: lock, icon: .current) }, dir: dir) { true }

        // e. Settings from a Squadd server: the index, then the server's own page.
        try await shoot("e1-settings", NavigationStack { SettingsView(authManager: manager, server: studio) }, dir: dir) { true }
        let account = try XCTUnwrap(manager.activeServer)
        XCTAssertEqual(account.kind, .squadd)
        try await shoot("e2-server-page", NavigationStack {
            SettingsServerPage(authManager: manager, account: account, onDefaultProfileSelected: { _ in })
        }, dir: dir) { true }
        // The Settings pages that take the server: push and About read it, with the companion answering.
        try await shoot("e3-notifications", NavigationStack { SettingsNotificationsPage(server: studio) }, dir: dir) { true }
        try await shoot("e4-about", NavigationStack { SettingsAboutPage(server: account) }, dir: dir) { true }
    }

    /// #17: an agent's threads in the desktop's order (pinned first) with its archived ones folded
    /// below, then search with matches and with none.
    func testPhotoSquaddThreads() async throws {
        let path = ProcessInfo.processInfo.environment["FOTO_DIR"]
        try XCTSkipIf(path == nil, "Only for photo runs")
        let dir = URL(fileURLWithPath: path!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let organized = try Self.fixture("bots-organized.json")
        SquaddHTTPFixture.handler = { request in
            guard request.url?.path == "/api/bots" else { return (404, Data()) }
            Self.botsServed += 1
            return (200, organized)
        }
        URLProtocol.registerClass(SquaddHTTPFixture.self)
        let keychain = InMemoryKeychainStore()
        let manager = AuthManager(keychain: keychain, headerStore: CustomHeaderStore(),
                                  serverRegistry: ServerRegistry.inMemory(keychain: keychain),
                                  hermesConnections: HermesConnections(), preferences: .ephemeral(), forgetPush: { _ in })
        try add(studio, name: "Mac Studio", initials: "MS", color: "#2E7D32", token: "token-a", to: manager)
        Self.botsServed = 0
        try await shoot("f1-threads", home(manager, studio), dir: dir) { Self.botsServed > 0 }

        let hits = try JSONDecoder().decode(SquaddSearchResponse.self, from: try Self.fixture("search-hits.json")).hits
        try await shoot("f2-search-hits", AppList(rows: .plain) { SquaddSearchResults(hits: hits, query: "zucchero") }, dir: dir) { true }
        try await shoot("f3-search-empty", AppList(rows: .plain) { SquaddSearchResults(hits: [], query: "nessunrisultatoxyz") }, dir: dir) { true }
    }

    private func add(_ url: URL, name: String, initials: String, color: String, token: String, to manager: AuthManager) throws {
        try manager.addSquaddServer(address: url, token: token)
        let account = try XCTUnwrap(manager.servers.first { $0.id == url.absoluteString })
        manager.updateServerIdentity(account, displayName: name, initials: initials, headerLogoColorHex: color)
    }

    /// What `ContentView` shows for a logged-in or logged-out Squadd server.
    private func home(_ manager: AuthManager, _ server: URL) -> some View {
        SquaddRoute(authManager: manager, server: server) { EmptyView() }
    }

    /// Hosts `view` in a window of the app's scene, waits for `ready` and the frames after it, and
    /// writes `<name>.png`.
    private func shoot<V: View>(_ name: String, _ view: V, dir: URL, until ready: @escaping @MainActor () -> Bool) async throws {
        let container = try ModelContainer(for: CachedSession.self, CachedMessage.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window?.isHidden = true
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: view.modelContainer(container))
        window.makeKeyAndVisible()
        self.window = window
        let landed = expectation(description: "\(name) landed")
        func check(_ remaining: Int) {
            if ready() || remaining == 0 { landed.fulfill(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { check(remaining - 1) } }
        }
        check(100)
        await fulfillment(of: [landed], timeout: 10)
        try await Task.sleep(for: .seconds(1)) // test-wait: lets the reply draw before the shot; a photo for review, never an assertion
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: dir.appendingPathComponent("\(name).png"))
    }

    private nonisolated static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Squadd/\(name)"))
    }
}

/// A Face ID that never unlocks, so the lock stays on screen.
@MainActor private final class StillLocked: AppLockAuthenticator {
    func capability() -> AppLockCapability { AppLockCapability(method: .faceID, hasPasscode: true) }
    func authenticate(reason: String) async -> Bool { false }
}
