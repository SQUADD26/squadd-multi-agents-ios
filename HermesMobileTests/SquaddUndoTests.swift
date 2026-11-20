import SwiftUI
import XCTest
@testable import HermesMobile

/// Undo Last Exchange in a Squadd thread (#20), against a real `openmausbot` companion's answers
/// (`Fixtures/Squadd/squadd-u-*`, origin/dev 961cb8133, fake engine): a thread with two exchanges, its
/// `undo-exchange` and the thread after it, and a thread whose first message is the person's.
@MainActor
final class SquaddUndoTests: XCTestCase {
    static let botId = "ec2d21d4-9a8d-47bc-8302-b82f525e407c"
    static let threadId = "96ac76da-76b6-4d92-9362-2b29bfa96b7f"
    static let rootThreadId = "2f0c20d0-b2e1-4bb5-be34-88ebbe696d03"
    static let firstPrompt = "ccdb9a93-523f-4088-8154-a9e40da7e768"
    static let firstReply = "390f0a8e-adcd-4d45-8ca9-899a8ea63666"
    static let secondPrompt = "8d7a4ae6-009f-49fb-9dc4-97340294bc19"
    static let secondReply = "6a8991f4-cc7b-445a-9ff4-e6919c2b97ea"
    static let rootPrompt = "89668097-7031-45fe-972a-47bc96db1344"

    override func tearDown() {
        SquaddChatFixture.reset()
        super.tearDown()
    }

    func testUndoInTheLastExchangesMenuTakesItOffScreen() async throws {
        let undo = SquaddForkTests.Recorded()
        SquaddChatFixture.handler = Self.answer(undo)
        let (model, squadd) = makeChat(Self.threadId)
        await model.loadMessages()
        XCTAssertNil(Self.undoInMenu(ofRow: Self.firstReply, squadd), "only the last exchange offers it")
        let item = try XCTUnwrap(Self.undoInMenu(ofRow: Self.secondReply, squadd))
        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(Self.undoInMenu(ofRow: Self.secondReply, squadd, hasActiveStream: true)?.isEnabled, false, "off while a reply streams")

        item.perform()
        await waitUntil("the second exchange is off screen") { !model.messages.contains { $0.messageId == Self.secondPrompt } }
        XCTAssertEqual(try XCTUnwrap(undo.request.flatMap(SquaddVersionsTests.body))["threadId"] as? String, Self.threadId)
        XCTAssertTrue(model.messages.contains { $0.messageId == Self.firstReply }, "the first exchange stays")
        XCTAssertNotNil(Self.undoInMenu(ofRow: Self.firstReply, squadd), "the one before is next")
    }

    func testUndoIsOffWhenThePersonsMessageBeganTheThread() async throws {
        let undo = SquaddForkTests.Recorded()
        SquaddChatFixture.handler = Self.answer(undo)
        let (model, squadd) = makeChat(Self.rootThreadId)
        await model.loadMessages()
        let item = try XCTUnwrap(Self.undoInMenu(ofRow: Self.rootPrompt, squadd))
        XCTAssertFalse(item.isEnabled, "the menu shows Undo off")

        let result = await model.runSquaddSlashCommand("/undo")
        XCTAssertEqual(result, .unsupported(friendlyMessage: String(localized: "Nothing to undo in this conversation.")))
        XCTAssertNil(undo.request, "the computer isn't asked")
    }

    // MARK: - Helpers

    /// Undo in the list the row hands its long-press menu.
    static func undoInMenu(ofRow rowID: String, _ squadd: SquaddChatTurnCoordinator, hasActiveStream: Bool = false) -> ChatMessageActionItem? {
        ChatMessageActionItem.squaddRowItems(ofRow: rowID, in: squadd, isViewingCachedData: false, hasActiveStream: hasActiveStream)
            .first { $0.kind == .undo }
    }

    /// Answers both threads; the first thread reads as undone once `undo-exchange` came.
    static func answer(_ undo: SquaddForkTests.Recorded) -> (URLRequest) -> SquaddChatFixture.Answer {
        { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/threads/\(threadId)/messages"):
                let thread = undo.request == nil ? "squadd-u-thread-two.json" : "squadd-u-thread-undone.json"
                return .reply(200, try! SquaddVersionsTests.fixture(thread))
            case ("GET", "/api/threads/\(rootThreadId)/messages"):
                return .reply(200, try! SquaddVersionsTests.fixture("squadd-u-root-thread.json"))
            case ("POST", "/api/bots/\(botId)/undo-exchange"):
                undo.request = request
                return .reply(200, try! SquaddVersionsTests.fixture("squadd-u-undo.json"))
            default:
                return .hold
            }
        }
    }

    private func makeChat(_ threadId: String) -> (ChatViewModel, SquaddChatTurnCoordinator) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SquaddChatFixture.self]
        let chat = SquaddThreadChat(server: SquaddVersionsTests.server, token: "device-token", botId: Self.botId, threadId: threadId, title: "Prova")
        let coordinator = SquaddChatTurnCoordinator(chat, session: URLSession(configuration: configuration),
                                                    reconnectDelay: { _ in try await Task.sleep(for: .seconds(3600)) })
        addTeardownBlock { coordinator.stop() }
        let model = ChatViewModel(session: chat.session, server: chat.server, streamingRevealTick: {}, backend: .squadd(coordinator))
        return (model, coordinator)
    }
}

/// The thread before and after Undo Last Exchange. Photos only, for photo runs (`FOTO_DIR`).
@MainActor
final class SquaddUndoPhotoTests: XCTestCase {
    override func tearDown() {
        URLProtocol.unregisterClass(SquaddChatFixture.self)
        SquaddChatFixture.reset()
        super.tearDown()
    }

    func testPhotoBeforeAndAfterUndo() async throws {
        let path = ProcessInfo.processInfo.environment["FOTO_DIR"]
        try XCTSkipIf(path == nil, "Only for photo runs")
        let dir = URL(fileURLWithPath: path!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let undo = SquaddForkTests.Recorded()
        SquaddChatFixture.handler = SquaddUndoTests.answer(undo)
        URLProtocol.registerClass(SquaddChatFixture.self)
        let chat = SquaddThreadChat(server: SquaddVersionsTests.server, token: "device-token", botId: SquaddUndoTests.botId,
                                    threadId: SquaddUndoTests.threadId, title: "Prova")
        let continuity = ChatContinuity()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ChatView(session: chat.session, server: chat.server, onAPIError: { _ in }, continuity: continuity, squaddThread: chat)
        })
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, continuity.model?.messages.contains(where: { $0.messageId == SquaddUndoTests.secondPrompt }) != true {
            // test-wait: a photo, not a check; `ChatContinuity` isn't observable.
            try await Task.sleep(for: .milliseconds(50))
        }
        let model = try XCTUnwrap(continuity.model)
        try await readyPhoto(of: window).write(to: dir.appendingPathComponent("20-b-before-undo.png"))

        await model.squaddTurn?.undoLastExchange()
        XCTAssertFalse(model.messages.contains { $0.messageId == SquaddUndoTests.secondPrompt })
        try await readyPhoto(of: window).write(to: dir.appendingPathComponent("20-c-after-undo.png"))
    }
}
