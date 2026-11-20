import SwiftUI
import XCTest
@testable import HermesMobile

/// The home's bell (#32) against a real `openmausbot` companion (origin/dev 9e05e3a04, fake Claude
/// engine): the list before a turn and the `/api/events` frames of that turn's notification and of its thread being read.
@MainActor
final class SquaddNotificationsTests: XCTestCase {
    private let server = URL(string: "http://192.0.2.10:8810")!
    private let botId = "267a03c8-e619-4a7c-9508-5a807144a211"
    private let threadId = "23bd5649-af55-40aa-b713-b648f0c35097"
    private let newID = "e3ac743b-bb79-431c-996b-9b3eb1601e88"

    override func tearDown() {
        SquaddChatFixture.reset()
        super.tearDown()
    }

    func testTheListComesFromTheComputerAndANewNotificationArrivesOnTop() async throws {
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/notifications"): return .reply(200, try! Self.fixture("notifications-before.json"))
            default: return .hold
            }
        }
        let model = makeModel()
        let following = await follow(model)
        defer { following.cancel() }

        SquaddChatFixture.stream(Data(try frames(upTo: "\"kind\":\"notify\"").utf8))

        await waitUntil("the notify frame lands") { model.items.count == 3 }
        XCTAssertEqual(model.items.first?.id, newID)
        XCTAssertEqual(model.items.first?.threadId, threadId)
        XCTAssertEqual(model.unreadCount, 3)
    }

    func testReadingANotificationReadsItsThreadOnTheComputerAndAReadElsewhereShowsHere() async throws {
        var marked: URLRequest?
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/notifications"): return .reply(200, try! Self.fixture("notifications-before.json"))
            case ("POST", let path) where path?.hasSuffix("/read") == true:
                marked = request
                return .reply(200, Data("{}".utf8))
            default: return .hold
            }
        }
        let model = makeModel()
        let following = await follow(model)
        defer { following.cancel() }
        SquaddChatFixture.stream(Data(try frames(upTo: "\"kind\":\"notify\"").utf8))
        await waitUntil("the list is in") { model.items.count == 3 }

        // Tapped here: the desktop's own read of the conversation.
        try await model.markRead(XCTUnwrap(model.items.last))
        XCTAssertEqual(marked?.url?.path, "/api/bots/\(botId)/read")
        let body = try XCTUnwrap(marked.flatMap { $0.httpBody ?? $0.httpBodyStream.map(Self.read) })
        XCTAssertEqual((try JSONSerialization.jsonObject(with: body) as? [String: String])?["threadId"], threadId)
        XCTAssertEqual(model.unreadCount, 0, "the computer reads every notification of the thread")

        // Read on the desktop: its frame reaches this app too.
        let other = makeModel()
        let otherFollowing = await follow(other)
        defer { otherFollowing.cancel() }
        SquaddChatFixture.stream(Data(try frames(upTo: "\"kind\":\"notify\"").utf8))
        await waitUntil("the other app has the list") { other.items.count == 3 }
        SquaddChatFixture.stream(Data(try Self.text("notifications-events.sse").components(separatedBy: "\n\n")
            .first { $0.contains("\"notifications.read\"") }!.appending("\n\n").utf8))
        await waitUntil("the read frame lands") { other.unreadCount == 0 }
    }

    func testTheHomeFollowsTheComputersNotificationsOnlyWhileInFront() async throws {
        let listed = expectation(description: "the home read the list")
        listed.assertForOverFulfill = false
        let loaded = expectation(description: "the home read its agents")
        loaded.assertForOverFulfill = false
        SquaddChatFixture.handler = { request in
            switch request.url?.path {
            case "/api/bots": loaded.fulfill(); return .reply(200, try! Self.fixture("bots.json"))
            case "/api/notifications": listed.fulfill(); return .reply(200, try! Self.fixture("notifications-before.json"))
            case "/api/events": return .hold
            default: return .reply(404, Data())
            }
        }
        var streams = 0
        SquaddChatFixture.didHold = { request in if request.url?.path == "/api/events" { streams += 1 } }
        URLProtocol.registerClass(SquaddChatFixture.self)
        defer { URLProtocol.unregisterClass(SquaddChatFixture.self) }
        let keychain = InMemoryKeychainStore()
        let manager = AuthManager(keychain: keychain, headerStore: CustomHeaderStore(),
                                  serverRegistry: ServerRegistry.inMemory(keychain: keychain),
                                  hermesConnections: HermesConnections(), preferences: .ephemeral(), forgetPush: { _ in })
        try manager.addSquaddServer(address: server, token: "device-token")
        let scene = PhaseHolder(), server = server
        let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first))
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: PhaseHost(holder: scene) {
            SquaddServerHome(authManager: manager, server: server, pendingThread: .constant(nil))
        })
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        // In the background the home reads its agents but opens no stream.
        await fulfillment(of: [loaded], timeout: 5)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(streams, 0)

        let opened = expectation(description: "the stream opened in front")
        SquaddChatFixture.didHold = { request in if request.url?.path == "/api/events" { opened.fulfill() } }
        scene.phase = .active
        await fulfillment(of: [opened], timeout: 5)
        SquaddChatFixture.stream(Data(try frames(upTo: "\"kind\":\"notify\"").utf8))
        await fulfillment(of: [listed], timeout: 5)
        if let folder = ProcessInfo.processInfo.environment["FOTO_DIR"] {
            try await readyPhoto(of: window).write(to: URL(fileURLWithPath: folder).appendingPathComponent("32-home-bell-unread.png"))
        }
    }

    // MARK: - Helpers

    private func makeModel() -> SquaddNotificationsModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SquaddChatFixture.self]
        let client = SquaddCompanionClient(server: server, token: "device-token", session: URLSession(configuration: configuration))
        return SquaddNotificationsModel(client: client, reconnectDelay: { _ in try await Task.sleep(for: .seconds(3600)) })
    }

    /// Starts `model` following the event stream and waits until the stream is held open.
    private func follow(_ model: SquaddNotificationsModel) async -> Task<Void, Never> {
        let opened = expectation(description: "the event stream opened")
        SquaddChatFixture.didHold = { request in
            if request.url?.path == "/api/events" { opened.fulfill() }
        }
        let task = Task { await model.follow() }
        await fulfillment(of: [opened], timeout: 5)
        SquaddChatFixture.didHold = nil
        return task
    }

    /// The recorded frames up to and including the first that contains `marker`.
    private func frames(upTo marker: String) throws -> String {
        let events = try Self.text("notifications-events.sse").components(separatedBy: "\n\n")
        let end = try XCTUnwrap(events.firstIndex { $0.contains(marker) })
        return events[...end].joined(separator: "\n\n") + "\n\n"
    }

    private nonisolated static func read(_ stream: InputStream) -> Data {
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

    private nonisolated static func text(_ name: String) throws -> String {
        String(decoding: try fixture(name), as: UTF8.self)
    }

    private nonisolated static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Squadd/\(name)"))
    }
}

@MainActor @Observable
private final class PhaseHolder {
    var phase: ScenePhase = .background
}

/// Hands its content the scene phase the test sets, as the system does for the app's scene.
private struct PhaseHost<Content: View>: View {
    let holder: PhaseHolder
    @ViewBuilder let content: () -> Content
    var body: some View { content().environment(\.scenePhase, holder.phase) }
}
