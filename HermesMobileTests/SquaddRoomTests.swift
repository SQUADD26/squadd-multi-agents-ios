import SwiftData
import SwiftUI
import XCTest
@testable import HermesMobile

/// A Squadd room (#21) against turns recorded from a real `openmausbot` companion (`Fixtures/Squadd/room-*`,
/// origin/dev, fake engine): a room of two agents, a send that mentions one, a send queued while the room
/// works, Stop, and the refused rename and delete.
@MainActor
final class SquaddRoomTests: XCTestCase {
    private let server = URL(string: "http://192.0.2.10:8811")!

    override func tearDown() {
        SquaddChatFixture.reset()
        super.tearDown()
    }

    func testMentionGoesToTheRoomAndTheReplyShowsWhoWroteIt() async throws {
        let room = try roomSection()
        let receipt = try JSONSerialization.jsonObject(with: Self.fixture("room-send-mention.json")) as? [String: Any]
        let threadId = try XCTUnwrap(receipt?["threadId"] as? String)
        let writer = try XCTUnwrap(room.members.first { $0.name == "Scrittura Web" })
        var sent: URLRequest?
        let posted = expectation(description: "the send reached the room")
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/threads/\(threadId)/messages"):
                return .reply(200, sent == nil ? Data(#"{"messages":[],"hasMore":false}"#.utf8) : try! Self.fixture("room-messages.json"))
            case ("POST", "/api/groups/\(room.id)/messages"):
                sent = request
                posted.fulfill()
                return .hold
            case ("GET", "/api/events"):
                return .hold
            default:
                return .reply(404, Data())
            }
        }
        let (model, coordinator) = makeChat(room, threadId: threadId)
        coordinator.makeSendID = { "send-mention-00000001" }
        await model.loadMessages()

        let sending = Task { await model.send("@Scrittura Web scrivi un titolo per il lancio") }
        await fulfillment(of: [posted], timeout: 5)
        let body = try XCTUnwrap(sent.flatMap { $0.httpBody ?? $0.httpBodyStream.map(Self.read) })
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(fields["threadId"] as? String, threadId)
        XCTAssertEqual(fields["mentions"] as? [String], [writer.id], "the mention names the member")
        SquaddChatFixture.answer("POST", status: 202, body: try Self.fixture("room-send-mention.json"))
        let outcome = await sending.value
        XCTAssertEqual(outcome, .started)

        SquaddChatFixture.stream(try Self.fixture("room-events-mention.sse"), finish: true)
        await waitUntil("the turn ends on the stored reply, under the member that wrote it") {
            model.activeStreamID == nil && model.messages.last?.content == "released" && model.messages.last?.name != nil
        }
        XCTAssertEqual(model.messages.last?.name, "Scrittura Web")
        XCTAssertEqual(model.messages.map(\.role), ["user", "assistant"])
    }

    func testSendWhileTheRoomWorksWaitsInTheQueueUntilItGoesIn() async throws {
        let room = try roomSection()
        let receipt = try JSONSerialization.jsonObject(with: Self.fixture("room-send-queued.json")) as? [String: Any]
        let threadId = try XCTUnwrap(receipt?["threadId"] as? String)
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/threads/\(threadId)/messages"): .reply(200, try! Self.fixture("room-messages.json"))
            case ("POST", "/api/groups/\(room.id)/messages"): .reply(202, try! Self.fixture("room-send-queued.json"))
            default: .hold
            }
        }
        let (model, coordinator) = makeChat(room, threadId: threadId)
        coordinator.makeSendID = { "send-queued-0000000001" }
        await model.loadMessages()
        let shown = model.messages.count

        let outcome = await model.send("@Ricerche e poi i prezzi")

        XCTAssertEqual(outcome, .started, "the composer clears")
        XCTAssertEqual(model.messages.count, shown, "a queued send is not a sent row yet")
        XCTAssertEqual(model.queuedPromptMessages.map(\.content), ["@Ricerche e poi i prezzi"])

        // The companion stores the queued send when the turn before ends: the recorded busy run's
        // frames up to its stored user row and the room updates after it, with this send's id and words.
        let events = String(decoding: try Self.fixture("room-events-busy.sse"), as: UTF8.self)
        let frames = events.components(separatedBy: "\n\n")
        let row = try XCTUnwrap(frames.firstIndex { $0.contains(#""sendId":"send-busy-"#) })
        let stored = frames[...(row + 2)].joined(separator: "\n\n")
            .replacingOccurrences(of: "send-busy-000000000001", with: "send-queued-0000000001")
            .replacingOccurrences(of: "@Ricerche cerca i concorrenti", with: "@Ricerche e poi i prezzi")
        SquaddChatFixture.stream(Data((stored + "\n\n").utf8))
        await waitUntil("the queued send goes in") { model.queuedPromptMessages.isEmpty }
        XCTAssertEqual(model.messages.last?.content, "@Ricerche e poi i prezzi")
        XCTAssertEqual(model.messages.last?.role, "user")
    }

    func testAQueuedMessageCanBeRemovedBeforeItRuns() async throws {
        let room = try roomSection()
        let receipt = try JSONSerialization.jsonObject(with: Self.fixture("room-send-queued.json")) as? [String: Any]
        let threadId = try XCTUnwrap(receipt?["threadId"] as? String)
        let queueId = try XCTUnwrap(receipt?["queueId"] as? String)
        var removed: String?
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/threads/\(threadId)/messages"): return .reply(200, try! Self.fixture("room-messages.json"))
            case ("POST", "/api/groups/\(room.id)/messages"): return .reply(202, try! Self.fixture("room-send-queued.json"))
            // `server/routes/channels.ts`: DELETE /api/groups/:id/queue/:queueId answers {ok:true}.
            case ("DELETE", let path?) where path.hasPrefix("/api/groups/\(room.id)/queue/"):
                removed = request.url?.lastPathComponent
                return .reply(200, Data(#"{"ok":true}"#.utf8))
            default: return .hold
            }
        }
        let (model, _) = makeChat(room, threadId: threadId)
        await model.loadMessages()
        _ = await model.send("@Ricerche e poi i prezzi")
        let queued = try XCTUnwrap(model.queuedPromptMessages.first)

        await model.cancelSquaddQueuedPrompt(queued)

        XCTAssertEqual(removed, queueId, "the companion's line loses this send")
        XCTAssertTrue(model.queuedPromptMessages.isEmpty)
    }

    func testStopInterruptsTheRoomsTurn() async throws {
        let room = try roomSection()
        let receipt = try JSONSerialization.jsonObject(with: Self.fixture("room-send-queued.json")) as? [String: Any]
        let threadId = try XCTUnwrap(receipt?["threadId"] as? String)
        var stop: URLRequest?
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/threads/\(threadId)/messages"): return .reply(200, try! Self.fixture("room-messages.json"))
            case ("POST", "/api/groups/\(room.id)/interrupt"):
                stop = request
                return .reply(200, Data(#"{"ok":true}"#.utf8))
            default: return .hold
            }
        }
        let (model, _) = makeChat(room, threadId: threadId)
        await model.loadMessages()
        let events = String(decoding: try Self.fixture("room-events-busy.sse"), as: UTF8.self)
        let started = try XCTUnwrap(events.range(of: #""type":"turn.started""#))
        let cut = try XCTUnwrap(events[started.upperBound...].range(of: "\n\n")).upperBound
        SquaddChatFixture.stream(Data(events[..<cut].utf8))
        await waitUntil("the turn runs") { model.activeStreamID != nil }

        let stopped = await model.cancelActiveStream()

        XCTAssertTrue(stopped)
        let body = try XCTUnwrap(stop.flatMap { $0.httpBody ?? $0.httpBodyStream.map(Self.read) })
        let fields = try JSONSerialization.jsonObject(with: body) as? [String: String]
        XCTAssertEqual(fields?["threadId"], threadId)
        SquaddChatFixture.stream(Data(events[cut...].utf8), finish: true)
        await waitUntil("the interrupted turn ends") { model.activeStreamID == nil }
    }

    func testAtPanelOffersTheMembersByTheirWholeName() throws {
        let room = try roomSection()
        let chat = SquaddRoomChat(id: room.id, members: room.members)

        XCTAssertEqual(chat.mentions.completions(query: "scr").map(\.tag), ["Scrittura Web"])
        XCTAssertEqual(Set(chat.mentions.completions(query: "").map(\.tag)), ["Scrittura Web", "Ricerche"],
                       "only the room's members, not every agent")
    }

    func testRefusedRenameKeepsTheOldName() async throws {
        let room = try roomSection()
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/bots"): .reply(200, try! Self.fixture("room-bots.json"))
            case ("PATCH", "/api/groups/\(room.id)"): .reply(400, try! Self.fixture("room-rename-invalid.json"))
            default: .reply(404, Data())
            }
        }
        let model = makeHome()
        await model.load()

        let renamed = await model.renameRoom(room.id, to: String(repeating: "n", count: 101))

        XCTAssertFalse(renamed)
        XCTAssertEqual(model.rooms.first?.name, room.name)
    }

    func testDeletingAWorkingRoomIsRefusedAndTheRoomStays() async throws {
        let room = try roomSection()
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/bots"): .reply(200, try! Self.fixture("room-bots.json"))
            case ("DELETE", "/api/groups/\(room.id)"): .reply(409, try! Self.fixture("room-delete-busy.json"))
            default: .reply(404, Data())
            }
        }
        let model = makeHome()
        await model.load()

        let failure = await model.deleteRoom(room.id)

        XCTAssertEqual(failure, String(localized: "The computer is busy. Try again when the agents have finished."))
        XCTAssertEqual(model.rooms.map(\.id), [room.id])
    }

    // MARK: - Helpers

    private func roomSection() throws -> SquaddRoomSection {
        let list = try JSONDecoder().decode(SquaddBotList.self, from: Self.fixture("room-bots.json"))
        return SquaddRoomSection(room: try XCTUnwrap(list.rooms.first), bots: list.bots)
    }

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SquaddChatFixture.self]
        return URLSession(configuration: configuration)
    }

    private func makeChat(_ room: SquaddRoomSection, threadId: String) -> (ChatViewModel, SquaddChatTurnCoordinator) {
        let chat = SquaddThreadChat(room: room, thread: SessionSummary(sessionId: threadId, title: "Lancio"),
                                    server: server, token: "device-token")
        let coordinator = SquaddChatTurnCoordinator(chat, session: session,
                                                    reconnectDelay: { _ in try await Task.sleep(for: .seconds(3600)) })
        addTeardownBlock { coordinator.stop() }
        let model = ChatViewModel(session: chat.session, server: server, streamingRevealTick: {}, backend: .squadd(coordinator))
        return (model, coordinator)
    }

    private func makeHome() -> SquaddAgentListModel {
        SquaddAgentListModel(client: SquaddCompanionClient(server: server, token: "device-token", session: session),
                             onUnpaired: {})
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

    private nonisolated static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Squadd/\(name)"))
    }
}

/// Photographs the room screens into `FOTO_DIR` (passed as `TEST_RUNNER_FOTO_DIR`) for the PR's evidence,
/// with the companion played back from the recorded room (`room-*`). Skipped everywhere else. Each class
/// keeps one window.
@MainActor
class SquaddRoomPhotoTestCase: XCTestCase {
    let server = URL(string: "http://mac-studio.tailnet.test:8810")!
    private var window: UIWindow?
    nonisolated(unsafe) static var served: [String] = []

    override func tearDown() {
        URLProtocol.unregisterClass(SquaddHTTPFixture.self)
        SquaddHTTPFixture.handler = nil
        window?.isHidden = true
        super.tearDown()
    }

    /// The photo folder, with the recorded room answering through `URLSession.shared`; skips outside photo runs.
    func photoDir() throws -> URL {
        let path = ProcessInfo.processInfo.environment["FOTO_DIR"]
        try XCTSkipIf(path == nil, "Only for photo runs")
        let dir = URL(fileURLWithPath: path!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.served = []
        SquaddHTTPFixture.handler = { request in
            let path = request.url?.path ?? ""
            Self.served.append(path)
            if path == "/api/bots" { return (200, Self.fixture("room-bots.json")) }
            if path.hasSuffix("/messages") { return (200, Self.fixture("room-messages.json")) }
            return (404, Data())
        }
        URLProtocol.registerClass(SquaddHTTPFixture.self)
        return dir
    }

    func manager() throws -> AuthManager {
        let keychain = InMemoryKeychainStore()
        let manager = AuthManager(keychain: keychain, headerStore: CustomHeaderStore(),
                                  serverRegistry: ServerRegistry.inMemory(keychain: keychain),
                                  hermesConnections: HermesConnections(), preferences: .ephemeral(), forgetPush: { _ in })
        try manager.addSquaddServer(address: server, token: "device-token")
        return manager
    }

    /// Shows `view` in the class's one window (made on the first shot) and writes `<name>.png` once it has drawn.
    fileprivate final func shoot<V: View>(_ name: String, _ view: V, dir: URL, until ready: () -> Bool) async throws {
        if window == nil {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            window?.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            window?.makeKeyAndVisible()
        }
        let container = try ModelContainer(for: CachedSession.self, CachedMessage.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        window?.rootViewController = UIHostingController(rootView: view.modelContainer(container))
        let window = try XCTUnwrap(window)
        try await readyPhoto(of: window, until: ready).write(to: dir.appendingPathComponent("\(name).png"))
    }

    /// The home started on `start`, photographed once the room list has loaded.
    fileprivate final func shootHome(_ name: String, start: SquaddHomeStart?) async throws {
        let dir = try photoDir()
        try await shoot(name, SquaddServerHome(authManager: try manager(), server: server, pendingThread: .constant(nil), start: start),
                        dir: dir) { Self.served.contains("/api/bots") }
    }

    nonisolated static func fixture(_ name: String) -> Data {
        try! Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Squadd/\(name)"))
    }
}

/// The home's room photo (`FOTO_DIR`) in SquaddServerHome: the room under the agents. One photo per
/// class, so each class stays under 3 s.
final class SquaddRoomHomePhotoTests: SquaddRoomPhotoTestCase {
    func testPhotoRoomHome() async throws {
        try await shootHome("r1-room-home", start: nil)
    }
}

/// The room's rename alert (`FOTO_DIR`) in SquaddServerHome.
final class SquaddRoomRenamePhotoTests: SquaddRoomPhotoTestCase {
    func testPhotoRoomRename() async throws {
        // The field's blinking cursor never lets two frames match, so the photo would wait out readyPhoto's limit.
        UITextField.appearance().tintColor = .clear
        defer { UITextField.appearance().tintColor = nil }
        try await shootHome("r2-room-rename", start: .renameRoom)
    }
}

/// The room's delete confirmation (`FOTO_DIR`) in SquaddServerHome.
final class SquaddRoomDeletePhotoTests: SquaddRoomPhotoTestCase {
    func testPhotoRoomDelete() async throws {
        try await shootHome("r3-room-delete-confirm", start: .deleteRoom)
    }
}

/// A room's chat (`FOTO_DIR`) in ChatView: each reply under the member that wrote it, and the `@`
/// panel offering the room's members.
final class SquaddRoomChatPhotoTests: SquaddRoomPhotoTestCase {
    func testPhotoRoomChat() async throws {
        let dir = try photoDir()
        let list = try JSONDecoder().decode(SquaddBotList.self, from: Self.fixture("room-bots.json"))
        let room = SquaddRoomSection(room: try XCTUnwrap(list.rooms.first), bots: list.bots)
        let thread = try XCTUnwrap(room.threads.first { $0.title?.hasPrefix("@Scrittura") == true })
        let chat = SquaddThreadChat(room: room, thread: thread, server: server, token: "device-token")
        let key = ChatView.draftKey(for: chat.session, server: chat.server)
        ChatDraftStore.shared.setDraft("@", for: key)
        addTeardownBlock { ChatDraftStore.shared.clearDraft(for: key) }

        try await shoot("r4-room-chat-mention", NavigationStack { ChatView(squaddThread: chat) }, dir: dir) {
            Self.served.contains { $0.hasSuffix("/messages") }
        }
    }
}
