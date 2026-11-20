import SwiftData
import SwiftUI
import XCTest
@testable import HermesMobile

/// Making and changing a Squadd agent (#22) against answers recorded from a real `openmausbot`
/// companion (`Fixtures/Squadd/`, origin/dev 3d12c2fd7, fake engine, fake image API).
@MainActor
final class SquaddAgentEditorTests: XCTestCase {
    private let server = URL(string: "http://192.0.2.10:8810")!
    private let recorder = Recorder()
    private var requests: [URLRequest] { recorder.requests }

    override func tearDown() {
        SquaddHTTPFixture.handler = nil
        super.tearDown()
    }

    func testNewAgentOffersOnlyAvailableEnginesAndSendsOnlyWhatAPhoneMaySet() async throws {
        answer { request in
            request.url?.path == "/api/instances" ? (200, Self.fixture("instances.json")) : (201, Self.fixture("bot-create.json"))
        }
        var changes = 0
        let editor = SquaddAgentEditor(client: client(), onChange: { changes += 1 })

        await editor.loadModels()
        // `chatgpt` and `openrouter` are listed but unavailable on the recorded computer.
        XCTAssertEqual(editor.modelGroups.map(\.id), ["claude"])
        let opus = try XCTUnwrap(editor.modelGroups[0].allModels.first { $0.id == "claude-opus-5-5" })
        await editor.selectModel(opus)
        editor.draft = .init(name: "Ricerca", title: "Analista", description: "Cerca e riassume", instructions: "Rispondi breve.")
        let saved = await editor.save()

        XCTAssertTrue(saved)
        let create = try XCTUnwrap(requests.last)
        XCTAssertEqual(create.httpMethod, "POST")
        XCTAssertEqual(create.url?.path, "/api/bots")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: recorder.lastBody) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["name", "title", "description", "settings", "modelSelection"])
        XCTAssertEqual(body["settings"] as? [String: String], ["soul": "Rispondi breve."])
        XCTAssertEqual(body["modelSelection"] as? [String: String], ["instanceId": "claude", "model": "claude-opus-5-5"])
        XCTAssertEqual(editor.bot?.name, "Ricerca")
        XCTAssertFalse(editor.isNew, "the new agent stays open for its avatar")
        XCTAssertEqual(changes, 1)
    }

    func testRefusedProfileChangeGoesBackWithTheComputersReason() async throws {
        answer { _ in (400, Self.fixture("bot-profile-invalid.json")) }
        let editor = try SquaddAgentEditor(client: client(), bot: recordedBot())

        editor.draft.name = String(repeating: "n", count: 101)
        let saved = await editor.save()

        XCTAssertFalse(saved)
        XCTAssertEqual(requests.last?.httpMethod, "PATCH")
        XCTAssertEqual(editor.draft.name, "Ricerca")
        XCTAssertEqual(editor.errorMessage, "name must be at most 100 characters")
    }

    func testModelChangesOnlyOnceTheComputerAcceptsIt() async throws {
        let bot = try recordedBot()
        let editor = SquaddAgentEditor(client: client(), bot: bot)
        let gpt = ModelCatalogOption(id: "gpt-x", displayName: "GPT X", providerID: "chatgpt")
        let haiku = ModelCatalogOption(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5", providerID: "claude")

        answer { _ in (400, Self.fixture("bot-model-invalid.json")) }
        await editor.selectModel(gpt)
        XCTAssertEqual(editor.model, SquaddModelSelection(instanceId: "claude", model: "claude-opus-5-5"))
        XCTAssertEqual(editor.modelError, #"model "gpt-x" is not offered by instance "chatgpt""#)

        answer { _ in (200, Self.fixture("bot-model.json")) }
        await editor.selectModel(haiku)
        XCTAssertEqual(requests.last?.url?.path, "/api/bots/\(bot.id)/model")
        XCTAssertEqual(editor.model, SquaddModelSelection(instanceId: "claude", model: "claude-haiku-5-5"))
        XCTAssertNil(editor.modelError)
    }

    func testGeneratedAvatarReplacesTheAgentsImage() async throws {
        answer { _ in (201, Self.fixture("bot-avatar.json")) }
        let editor = try SquaddAgentEditor(client: client(), bot: recordedBot())

        editor.avatarPrompt = "a friendly owl"
        await editor.generateAvatar()

        XCTAssertEqual(requests.last?.url?.path.hasSuffix("/avatar/generate"), true)
        XCTAssertEqual(editor.bot?.avatarUrl?.hasPrefix("/api/attachments/"), true)
        XCTAssertNil(editor.errorMessage)
    }

    private func answer(_ reply: @escaping (URLRequest) -> (Int, Data)) {
        SquaddHTTPFixture.handler = { [recorder] request in
            recorder.record(request, body: Self.body(of: request))
            return reply(request)
        }
    }

    private func client() -> SquaddCompanionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SquaddHTTPFixture.self]
        return SquaddCompanionClient(server: server, token: "device-token", session: URLSession(configuration: configuration))
    }

    private func recordedBot() throws -> SquaddBot {
        try JSONDecoder().decode(SquaddBotEnvelope.self, from: Self.fixture("bot-create.json")).bot
    }

    private nonisolated static func fixture(_ name: String) -> Data {
        try! Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Squadd/\(name)"))
    }

    /// URLProtocol sees a body as a stream.
    private nonisolated static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// What the fixture saw, written from URLProtocol's thread and read by the test.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(URLRequest, Data)] = []

    func record(_ request: URLRequest, body: Data) { lock.withLock { seen.append((request, body)) } }
    var requests: [URLRequest] { lock.withLock { seen.map(\.0) } }
    var lastBody: Data { lock.withLock { seen.last?.1 ?? Data() } }
}

/// Photographs the agent screens into `FOTO_DIR` (passed as `TEST_RUNNER_FOTO_DIR`) for the PR's
/// evidence, with the companion played back from the recorded answers. Skipped everywhere else.
@MainActor
final class SquaddAgentPhotoTests: XCTestCase {
    private let server = URL(string: "http://mac-studio.tailnet.test:8810")!
    private var window: UIWindow?
    // Replies served so far, counted on the fixture's thread: a shot waits for the reply its screen shows.
    nonisolated(unsafe) private static var botsServed = 0
    nonisolated(unsafe) private static var avatarsServed = 0

    override func tearDown() {
        URLProtocol.unregisterClass(SquaddHTTPFixture.self)
        SquaddHTTPFixture.handler = nil
        window?.isHidden = true
        super.tearDown()
    }

    func testPhotoAgentScreens() async throws {
        let path = ProcessInfo.processInfo.environment["FOTO_DIR"]
        try XCTSkipIf(path == nil, "Only for photo runs")
        let dir = URL(fileURLWithPath: path!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var profileReply = (200, Self.fixture("bot-profile.json"))
        (Self.botsServed, Self.avatarsServed) = (0, 0)
        SquaddHTTPFixture.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/api/bots" { Self.botsServed += 1 }
            if path.hasPrefix("/api/attachments/") { Self.avatarsServed += 1 }
            switch (request.httpMethod ?? "GET", path) {
            case ("GET", "/api/bots"): return (200, Self.fixture("bots.json"))
            case ("GET", "/api/instances"): return (200, Self.fixture("instances.json"))
            case ("GET", let path) where path.hasPrefix("/api/attachments/"): return (200, Self.fixture("avatar.png"))
            case ("POST", "/api/bots"): return (201, Self.fixture("bot-create.json"))
            case ("PATCH", let path) where path.hasSuffix("/profile"): return profileReply
            case ("PATCH", let path) where path.hasSuffix("/model"): return (400, Self.fixture("bot-model-invalid.json"))
            default: return (404, Data())
            }
        }
        let client = client()

        // 0. The home: New Agent above the agents; tapping an agent's name opens its editor.
        URLProtocol.registerClass(SquaddHTTPFixture.self) // the home reads through URLSession.shared
        let keychain = InMemoryKeychainStore()
        let manager = AuthManager(keychain: keychain, headerStore: CustomHeaderStore(),
                                  serverRegistry: ServerRegistry.inMemory(keychain: keychain),
                                  hermesConnections: HermesConnections(), preferences: .ephemeral(), forgetPush: { _ in })
        try manager.addSquaddServer(address: server, token: "device-token")
        try await shoot("0-home", SquaddRoute(authManager: manager, server: server) { EmptyView() }, dir: dir) {
            Self.botsServed > 0
        }

        // a. A new agent: name, title, description and a model from the computer's engines.
        let new = SquaddAgentEditor(client: client)
        await new.loadModels()
        new.draft = .init(name: "Ricerca", title: "Analista", description: "Cerca e riassume", instructions: "Rispondi breve.")
        if let opus = new.modelGroups.first?.allModels.first(where: { $0.id == "claude-opus-5-5" }) { await new.selectModel(opus) }
        try await shoot("a-new-agent", SquaddAgentEditorView(editor: new), dir: dir)

        // a2. Once made, the same sheet shows the agent with its avatar section.
        await new.save()
        try await shoot("a2-created", SquaddAgentEditorView(editor: new), dir: dir)

        // b. The model picker: only the engines the computer can run, no typed model.
        try await shoot("b-model-picker", picker(new), dir: dir)

        // c. An existing agent with the avatar the computer drew.
        let drawn = try JSONDecoder().decode(SquaddBotEnvelope.self, from: Self.fixture("bot-avatar.json")).bot
        let edit = SquaddAgentEditor(client: client, bot: drawn)
        await edit.loadModels()
        try await shoot("c-edit-agent", SquaddAgentEditorView(editor: edit), dir: dir) {
            Self.avatarsServed > 0
        }

        // d. A name the computer refuses: the old name is back, with the computer's reason.
        profileReply = (400, Self.fixture("bot-profile-invalid.json"))
        edit.draft.name = String(repeating: "n", count: 101)
        await edit.save()
        try await shoot("d-refused-name", SquaddAgentEditorView(editor: edit), dir: dir)

        // e. A model the engine no longer offers: the agent keeps its model, with the reason.
        await edit.selectModel(ModelCatalogOption(id: "gpt-x", displayName: "GPT X", providerID: "chatgpt"))
        try await shoot("e-refused-model", picker(edit), dir: dir)
    }

    private func picker(_ editor: SquaddAgentEditor) -> some View {
        ModelPickerSheet(configuration: .squaddAgent, modelGroups: editor.modelGroups,
                         selectedModelID: editor.model?.model, selectedModelProviderID: editor.model?.instanceId,
                         isSelected: { $0.id == editor.model?.model && $0.providerID == editor.model?.instanceId },
                         loadStatus: editor.modelsStatus, errorMessage: editor.modelError, onSelect: { _ in })
    }

    private func client() -> SquaddCompanionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SquaddHTTPFixture.self]
        return SquaddCompanionClient(server: server, token: "device-token", session: URLSession(configuration: configuration))
    }

    /// Hosts `view` in a window of the app's scene and writes `<name>.png` once it has drawn.
    private func shoot<V: View>(_ name: String, _ view: V, dir: URL, until ready: () -> Bool = { true }) async throws {
        let container = try ModelContainer(for: CachedSession.self, CachedMessage.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window?.isHidden = true
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: view.modelContainer(container))
        window.makeKeyAndVisible()
        self.window = window
        try await readyPhoto(of: window, until: ready).write(to: dir.appendingPathComponent("\(name).png"))
    }

    private nonisolated static func fixture(_ name: String) -> Data {
        try! Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Squadd/\(name)"))
    }
}
