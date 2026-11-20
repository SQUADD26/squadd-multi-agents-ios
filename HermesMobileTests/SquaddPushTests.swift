import SwiftData
import SwiftUI
import UserNotifications
import XCTest
@testable import HermesMobile

/// Closed-app push on a Squadd computer (#30), against answers and an APNs payload recorded from an isolated
/// `openmausbot` (origin/dev 3d12c2fd7: fake-engine harness with phone push on, its companion, a stand-in relay).
/// The recording paired a phone with the companion at `server`, so the payload's `pairing` is that address's tag.
@MainActor
final class SquaddPushTests: XCTestCase {
    private let server = URL(string: "http://127.0.0.1:22020")!
    private let otherServer = URL(string: "http://192.0.2.20:8810")!

    override func tearDown() {
        SquaddHTTPFixture.handler = nil
        super.tearDown()
    }

    func testEnableRegistersTheTokenOnThatComputerAndForgetRemovesIt() async throws {
        var requests: [(method: String, path: String, body: [String: String]?)] = []
        SquaddHTTPFixture.handler = { request in
            let body = request.bodyStreamData.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
            requests.append((request.httpMethod ?? "", request.url?.path ?? "", body))
            return (200, try! Self.fixture(request.httpMethod == "DELETE" ? "push-device-none.json" : "push-device-registered.json"))
        }
        let remote = RemoteNotificationsSpy()
        let registrar = makeRegistrar(remote: remote, servers: [server])

        async let enabled: Void = registrar.enable(for: server)
        await remote.waitForRequest()
        await registrar.didRegisterForRemoteNotifications(deviceToken: Data([0xab, 0x01]))
        try await enabled
        await registrar.forget(server: server)

        XCTAssertEqual(requests.map(\.method), ["PUT", "DELETE", "DELETE"])
        XCTAssertEqual(requests.map(\.path), ["/api/push/device", "/api/push/device", "/api/push/activity"])
        let body = try XCTUnwrap(requests.first?.body)
        XCTAssertEqual(body["platform"], "apns")
        XCTAssertEqual(body["token"], "ab01")
        XCTAssertEqual(body["environment"], "sandbox")
        XCTAssertEqual(body["pairing"], SquaddPush.pairingTag(for: server))
    }

    func testLaunchReRegistersTheTokenOnlyWherePushIsOn() async throws {
        var puts: [String] = []
        SquaddHTTPFixture.handler = { request in
            let host = request.url?.host ?? ""
            if request.httpMethod == "PUT" { puts.append(host) }
            let on = host == "127.0.0.1"
            return (200, try! Self.fixture(on ? "push-device-registered.json" : "push-device-none.json"))
        }
        let remote = RemoteNotificationsSpy()
        let registrar = makeRegistrar(remote: remote, servers: [server, otherServer])

        await registrar.refreshOnLaunch()
        await remote.waitForRequest()
        await registrar.didRegisterForRemoteNotifications(deviceToken: Data([0xcd]))

        XCTAssertEqual(puts, ["127.0.0.1"])
    }

    func testTappedRecordedPushOpensItsThreadOnTheServerThatSentIt() throws {
        let router = AppIntentRouter()
        let userInfo = try Self.recordedPush()

        XCTAssertTrue(SquaddPush.openTapped(userInfo: userInfo, servers: [account(otherServer), account(server)], router: router))
        let link = try XCTUnwrap(router.pendingDeepLink.flatMap(SquaddThreadLink.init(url:)))
        XCTAssertEqual(link.threadID, "6f85c7af-a71e-487f-8072-abd6b0765715")
        XCTAssertEqual(link.botID, "c813261f-bd3e-4d86-909c-27416feff813")
        XCTAssertEqual(link.server, server)

        router.pendingDeepLink = nil
        XCTAssertTrue(SquaddPush.openTapped(userInfo: userInfo, servers: [account(otherServer)], router: router))
        XCTAssertNil(router.pendingDeepLink, "a push from a computer this iPhone doesn't know opens nothing")
    }

    /// The thread link carries what is waiting there, so the chat opens the approval card, not just the thread.
    func testTappedPushTellsTheThreadWhichCardToOpen() throws {
        let router = AppIntentRouter()
        var approval = try Self.recordedPush()
        var omb = try XCTUnwrap(approval["omb"] as? [String: Any])
        omb["kind"] = "approval"
        approval["omb"] = omb

        for (userInfo, kind) in [(try Self.recordedPush(), "done"), (approval, "approval")] {
            router.pendingDeepLink = nil
            XCTAssertTrue(SquaddPush.openTapped(userInfo: userInfo, servers: [account(server)], router: router))
            let link = try XCTUnwrap(router.pendingDeepLink.flatMap(SquaddThreadLink.init(url:)))
            XCTAssertEqual(link.kind, kind)
            XCTAssertEqual(link.pinned(to: server).kind, kind, "the home that takes the link keeps the card")
        }
    }

    /// The hermex-push relay accepts only Hermex's bundle IDs, so this build can never register there (ADR 0004).
    func testThisBuildCannotRegisterWithTheHermexRelay() {
        XCTAssertNil(PushBuildIdentity(bundle: .main))
    }

    func testNotificationExtensionLeavesASquaddPushUntouched() throws {
        let userInfo = try Self.recordedPush()
        let content = UNMutableNotificationContent()
        content.title = "Finch finished"
        content.userInfo = userInfo

        PushPreview.rewrite(content, candidates: [])

        XCTAssertEqual(content.title, "Finch finished")
        XCTAssertEqual(content.body, "")
    }

    // MARK: - Helpers

    private func makeRegistrar(remote: RemoteNotificationsSpy, servers: [URL]) -> SquaddPushRegistrar {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SquaddHTTPFixture.self]
        let session = URLSession(configuration: configuration)
        let clients = Dictionary(uniqueKeysWithValues: servers.map { ($0, SquaddCompanionClient(server: $0, token: "device-token", session: session)) })
        return SquaddPushRegistrar(remoteNotifications: remote, requestAuthorization: { true }, isAuthorized: { true },
                                   clients: { clients }, environment: .sandbox, didEnable: {})
    }

    private func account(_ url: URL) -> ServerAccount {
        ServerAccount(id: url.absoluteString, urlString: url.absoluteString, displayName: url.host() ?? "", initials: "",
                      headerLogoColorHex: HeaderLogoColor.defaultHex, createdAt: .now, updatedAt: .now, kind: .squadd)
    }

    static func recordedPush() throws -> [AnyHashable: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("apns-done.json")) as? [String: Any])
    }

    nonisolated static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Squadd/\(name)"))
    }
}

/// Records the registrar asking APNs for a token, so a test can answer it.
@MainActor private final class RemoteNotificationsSpy: RemoteNotificationRegistering {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var requested = false

    func registerForRemoteNotifications() {
        requested = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func unregisterForRemoteNotifications() {}

    func waitForRequest() async {
        if requested { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private extension URLRequest {
    /// URLProtocol sees a body as a stream, not `httpBody`.
    var bodyStreamData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Photos for review (#30): the Notifications page of a Squadd computer with push on, and the thread a tapped
/// push opens, switching to the computer that sent it. Skipped unless `FOTO_DIR` is set (`TEST_RUNNER_FOTO_DIR`).
@MainActor
final class SquaddPushPhotoTests: XCTestCase {
    /// The computer the recorded push came from, and another one that is active when it is tapped.
    private let sender = URL(string: "http://127.0.0.1:22020")!
    private let laptop = URL(string: "http://macbook.tailnet.test:8810")!
    private var window: UIWindow?

    override func tearDown() {
        URLProtocol.unregisterClass(SquaddHTTPFixture.self)
        SquaddHTTPFixture.handler = nil
        window?.isHidden = true
        super.tearDown()
    }

    func testPhotoPushSettingsAndTappedThread() async throws {
        let path = ProcessInfo.processInfo.environment["FOTO_DIR"]
        try XCTSkipIf(path == nil, "Only for photo runs")
        let dir = URL(fileURLWithPath: path!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let registered = try SquaddPushTests.fixture("push-device-registered.json")
        // The agent and thread the recorded push names, as the sender's companion lists them.
        let bots = Data("""
        {"bots":[{"id":"c813261f-bd3e-4d86-909c-27416feff813","name":"Finch","threadId":"6f85c7af-a71e-487f-8072-abd6b0765715",
          "tasks":[{"threadId":"t-menu","title":"Weekly menu","updatedAt":1795112300000}]}]}
        """.utf8)
        // The thread the tap opens: the ask and the reply the push announced.
        let thread = Data("""
        {"hasMore":false,"messages":[
          {"id":"m1","role":"user","kind":"text","text":"Plan next week's dinners, vegetarian, under 30 minutes each.","at":1795112000000},
          {"id":"m2","role":"bot","kind":"text","text":"Done. Five dinners are in Weekly menu, with one shopping list.","at":1795112300000}]}
        """.utf8)
        let threadServed = Flag()
        SquaddHTTPFixture.handler = { request in
            switch request.url?.path {
            case "/api/bots": return (200, bots)
            case "/api/push/device": return (200, registered)
            case "/api/threads/6f85c7af-a71e-487f-8072-abd6b0765715/messages": threadServed.set(); return (200, thread)
            case "/api/events": return (200, Data("data: {\"kind\":\"hello\",\"cursor\":\"s:1\",\"resumed\":false}\n\n".utf8))
            default: return (404, Data())
            }
        }
        URLProtocol.registerClass(SquaddHTTPFixture.self)
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let manager = AuthManager(keychain: keychain, headerStore: CustomHeaderStore(), serverRegistry: registry,
                                  hermesConnections: HermesConnections(), preferences: .ephemeral(), forgetPush: { _ in })
        try manager.addSquaddServer(address: sender, token: "token-sender")
        try manager.addSquaddServer(address: laptop, token: "token-laptop")

        // a. Settings → Notifications on the sender, with push on.
        let client = SquaddCompanionClient(server: sender, token: "token-sender")
        let registrar = SquaddPushRegistrar(clients: { [sender] in [sender: client] }, environment: .sandbox)
        try host(NavigationStack { SquaddPushSettingsPage(server: sender, registrar: registrar) { EmptyView() } })
        try await shoot("n1-notifications-push-on", dir: dir)

        // b. The recorded push tapped while the laptop is active: the app switches to the sender and marks the thread.
        let router = AppIntentRouter()
        try host(ContentView(authManager: manager, intentRouter: router))
        XCTAssertTrue(SquaddPush.openTapped(userInfo: try SquaddPushTests.recordedPush(), servers: manager.servers,
                                            router: router))
        let queued = try XCTUnwrap(router.pendingDeepLink.flatMap(SquaddThreadLink.init(url:)))
        XCTAssertEqual(queued.server, sender)
        try await shoot("n2-tap-opens-thread", dir: dir) { manager.state == .loggedIn(server: sender) && threadServed.value }
        XCTAssertEqual(manager.state, .loggedIn(server: sender))
    }

    /// Readies the simulator for the recorded push `scripts/pr-ios-run live <issue> --push` sends with `simctl push`:
    /// notification permission (`ci/foto/tap_allow.py` taps Allow on the system alert) and the sender paired in the app's own Keychain, so the tap opens its
    /// thread. Skipped unless `PUSH_REAL` is set (`TEST_RUNNER_PUSH_REAL`).
    func testPrepareTheSimulatorForARealPush() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["PUSH_REAL"] == nil, "Only for the push photo job")
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        XCTAssertTrue(granted)
        let manager = AuthManager()
        do { try manager.addSquaddServer(address: sender, token: "token-sender") } catch AuthManager.SquaddAddError.alreadyConfigured {}
        XCTAssertTrue(manager.servers.contains { $0.id == sender.absoluteString && $0.kind == .squadd })
    }

    private func host<V: View>(_ view: V) throws {
        let container = try ModelContainer(for: CachedSession.self, CachedMessage.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        self.window?.isHidden = true
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: view.modelContainer(container))
        window.makeKeyAndVisible()
        self.window = window
    }

    private func shoot(_ name: String, dir: URL, until ready: () -> Bool = { true }) async throws {
        let window = try XCTUnwrap(window)
        try await readyPhoto(of: window, until: ready).write(to: dir.appendingPathComponent("\(name).png"))
    }
}

/// Set once from the fixture's request thread, read on the main actor.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    var value: Bool { lock.withLock { isSet } }
    func set() { lock.withLock { isSet = true } }
}
