import SwiftData
import SwiftUI
import XCTest
@testable import HermesMobile

/// The Squadd computer's settings on the phone (#28), against responses recorded from a real
/// `openmausbot` companion (`Fixtures/Squadd/settings-*.json`, origin/dev 3d12c2fd7, fake engine,
/// fake Anthropic and OpenRouter keys set on the desktop).
@MainActor
final class SquaddSettingsTests: XCTestCase {
    private let recorder = Recorder()
    private var requests: [URLRequest] { recorder.requests }
    private var bodies: [[String: String]] { recorder.bodies }
    private var unpaired = 0

    override func tearDown() {
        SquaddHTTPFixture.handler = nil
        super.tearDown()
    }

    func testKeysShowOnlyWhetherEachIsSet() async throws {
        let model = model { _ in (200, Self.fixture("settings-config.json")) }

        await model.loadKeys()

        XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
        XCTAssertEqual(requests.first?.url?.path, "/api/config")
        XCTAssertEqual(model.keys.filter(\.configured).map(\.name), ["Anthropic", "OpenRouter"])
        XCTAssertTrue(model.keys.contains { $0.name == "OpenAI" && !$0.configured })
    }

    func testClaudeUpdateRunsOnTheComputerThenRereadsTheEngines() async throws {
        let model = model { request in
            request.url?.path.hasSuffix("/claude-update") == true
                ? (200, Self.fixture("settings-claude-update.json")) : (200, Self.fixture("settings-instances.json"))
        }
        await model.loadEngines()
        let claude = try XCTUnwrap(model.engines.first { $0.isClaudeCode && $0.snapshot?.update != nil })
        XCTAssertFalse(try XCTUnwrap(model.engines.first { $0.id == "chatgpt" }).isClaudeCode)

        await model.updateClaude(claude)

        XCTAssertEqual(requests.map { "\($0.httpMethod!) \($0.url!.path)" },
                       ["GET /api/instances", "POST /api/instances/claude/claude-update", "GET /api/instances"])
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Content-Type"), "application/json") // else 415
        XCTAssertEqual(model.updateMessage, String(localized: "Claude Code is now \("2.1.232 (Claude Code)")."))
        XCTAssertNil(model.updatingEngine)
    }

    func testClaudeUpdateRefusedWhileAnAgentWorksSaysSo() async throws {
        let model = model { request in
            request.httpMethod == "POST" ? (409, Data(#"{"error":"wait for running Claude tasks to finish before updating"}"#.utf8))
                : (200, Self.fixture("settings-instances.json"))
        }
        await model.loadEngines()

        await model.updateClaude(try XCTUnwrap(model.engines.first(where: \.isClaudeCode)))

        XCTAssertEqual(model.updateMessage, String(localized: "The computer is busy. Try again when the agents have finished."))
    }

    func testAgentToolsShowNamesAndOnOffOnly() async throws {
        let model = model { request in
            request.url!.path.hasSuffix("/skills") ? (200, Self.fixture("settings-skills.json")) : (200, Self.fixture("settings-mcp-servers.json"))
        }
        let agent = SquaddBot(id: "bc844ffe-19d0-48c4-a873-4badc532e67f", name: "Fixture Starter")

        await model.loadTools(for: agent)

        let tools = try XCTUnwrap(model.tools[agent.id])
        XCTAssertEqual(Set(requests.map(\.url!.path)), ["/api/bots/\(agent.id)/mcp-servers", "/api/bots/\(agent.id)/skills"])
        XCTAssertEqual(tools.servers.map { "\($0.name) \($0.isOn)" }, ["linear true", "files false"])
        XCTAssertEqual(tools.skills.map { "\($0.name) \($0.enabled == true)" }, ["weekly-report true"])
        XCTAssertEqual(tools.phase, .loaded)
    }

    func testTeamMemoryAddEditDeleteSendWhatTheComputerChecks() async throws {
        let added = Self.fixture("settings-memory-added.json")
        let model = model { request in request.httpMethod == "DELETE" ? (200, Data(#"{"entries":[]}"#.utf8)) : (200, added) }

        let add = await model.changeMemory { try await $0.addMemory(kind: "term", name: "Kickoff", detail: "First call with a new client") }
        let entry = try XCTUnwrap(model.memory.first)
        let edit = await model.changeMemory { try await $0.editMemory(entry, kind: "term", name: "Kickoff", detail: "First video call") }
        let delete = await model.changeMemory { try await $0.deleteMemory(entry) }
        XCTAssertEqual([add, edit, delete], [true, true, true])

        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "PATCH", "DELETE"])
        XCTAssertEqual(requests.map { $0.url!.path }, ["/api/team-memory", "/api/team-memory/\(entry.id)", "/api/team-memory/\(entry.id)"])
        XCTAssertTrue(requests.allSatisfy { $0.url!.query!.hasPrefix("section=") }) // else 400 "section is required"
        XCTAssertEqual(bodies[0], ["kind": "term", "name": "Kickoff", "detail": "First call with a new client"])
        XCTAssertEqual(bodies[1]["expectedRevision"], entry.revision) // else 428
        XCTAssertEqual(requests[2].url!.query, "section=&revision=\(entry.revision!)")
        XCTAssertEqual(model.memory, [])
    }

    func testTeamMemoryChangedOnTheComputerReloadsInsteadOfOverwriting() async throws {
        let added = Self.fixture("settings-memory-added.json")
        let model = model { request in
            request.httpMethod == "PATCH" ? (409, Self.fixture("settings-memory-conflict.json")) : (200, added)
        }
        await model.loadMemory()
        let stale = try XCTUnwrap(model.memory.first)

        let saved = await model.changeMemory { try await $0.editMemory(stale, kind: "term", name: "Kickoff", detail: "mine") }

        XCTAssertFalse(saved)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PATCH", "GET"])
        XCTAssertEqual(model.memory.first?.detail, "First call with a new client")
        XCTAssertNotNil(model.memoryError)
    }

    func testRevokedTokenSendsTheServerToPairAgain() async {
        let model = model { _ in (401, Self.fixture("unauthorized.json")) }

        await model.loadKeys()

        XCTAssertEqual(unpaired, 1)
        XCTAssertEqual(model.keys, [])
    }

    // MARK: - Helpers

    private func model(_ answer: @escaping (URLRequest) -> (Int, Data)) -> SquaddSettingsModel {
        SquaddHTTPFixture.handler = { [recorder] request in
            recorder.record(request, body: Self.body(of: request))
            return answer(request)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SquaddHTTPFixture.self]
        let client = SquaddCompanionClient(server: URL(string: "http://192.0.2.10:8810")!, token: "device-token",
                                           session: URLSession(configuration: configuration))
        return SquaddSettingsModel(client: client, onUnpaired: { [unowned self] in unpaired += 1 })
    }

    /// URLProtocol sees a body as a stream.
    private nonisolated static func body(of request: URLRequest) -> [String: String]? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private nonisolated static func fixture(_ name: String) -> Data {
        try! Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Squadd/\(name)"))
    }
}

/// What the fixture saw, written from URLSession's thread and read by the test after each await.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _bodies: [[String: String]] = []
    var requests: [URLRequest] { lock.withLock { _requests } }
    var bodies: [[String: String]] { lock.withLock { _bodies } }

    func record(_ request: URLRequest, body: [String: String]?) {
        lock.withLock {
            _requests.append(request)
            if let body { _bodies.append(body) }
        }
    }
}

/// Photographs the Squadd settings screens into `FOTO_DIR` (passed as `TEST_RUNNER_FOTO_DIR`) for
/// the PR's evidence, with the companion played back from the recordings. Skipped everywhere else.
@MainActor
final class SquaddSettingsPhotoTests: XCTestCase {
    private let studio = URL(string: "http://mac-studio.tailnet.test:8810")!
    private var window: UIWindow?

    override func tearDown() {
        URLProtocol.unregisterClass(SquaddHTTPFixture.self)
        SquaddHTTPFixture.handler = nil
        window?.isHidden = true
        super.tearDown()
    }

    func testPhotoSquaddSettings() async throws {
        let path = ProcessInfo.processInfo.environment["FOTO_DIR"]
        try XCTSkipIf(path == nil, "Only for photo runs")
        let dir = URL(fileURLWithPath: path!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let recordings: [String: String] = [
            "/api/config": "settings-config.json", "/api/instances": "settings-instances.json",
            "/api/bots": "bots.json", "/api/team-memory": "settings-memory-added.json",
        ]
        SquaddHTTPFixture.handler = { request in
            let path = request.url!.path
            let name = recordings[path] ?? (path.hasSuffix("/skills") ? "settings-skills.json"
                : path.hasSuffix("/mcp-servers") ? "settings-mcp-servers.json" : nil)
            guard let name else { return (404, Data()) }
            return (200, try! Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/Squadd/\(name)")))
        }
        URLProtocol.registerClass(SquaddHTTPFixture.self)
        let keychain = InMemoryKeychainStore()
        let manager = AuthManager(keychain: keychain, headerStore: CustomHeaderStore(),
                                  serverRegistry: ServerRegistry.inMemory(keychain: keychain),
                                  hermesConnections: HermesConnections(), preferences: .ephemeral(), forgetPush: { _ in })
        try manager.addSquaddServer(address: studio, token: "token-a")
        let account = try XCTUnwrap(manager.activeServer)
        let model = SquaddSettingsModel(client: SquaddCompanionClient(server: studio, token: "token-a"), onUnpaired: {})

        try await shoot("f1-server-page", NavigationStack {
            SettingsServerPage(authManager: manager, account: account, onDefaultProfileSelected: { _ in })
        }, dir: dir) { true }
        try await shoot("f2-engines", NavigationStack { SquaddEnginesPage(model: model) }, dir: dir) { model.enginesPhase == .loaded }
        try await shoot("f3-keys", NavigationStack { SquaddKeysPage(model: model) }, dir: dir) { model.keysPhase == .loaded }
        try await shoot("f4-agents", NavigationStack { SquaddAgentsToolsPage(model: model) }, dir: dir) { model.agentsPhase == .loaded }
        let agent = try XCTUnwrap(model.agents.first)
        try await shoot("f5-agent-tools", NavigationStack { SquaddAgentToolsPage(model: model, agent: agent) }, dir: dir) {
            model.tools[agent.id]?.phase == .loaded
        }
        try await shoot("f6-team-memory", NavigationStack { SquaddTeamMemoryPage(model: model) }, dir: dir) { model.memoryPhase == .loaded }
        try await shoot("f7-memory-editor", SquaddMemoryEditor(model: model, entry: model.memory.first), dir: dir) { true }
    }

    /// Hosts `view` in a window of the app's scene, waits for `ready`, and writes `<name>.png`.
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
}
