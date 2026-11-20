import SwiftUI
import XCTest
@testable import HermesMobile

/// Fork in a Squadd thread (#20), against a real `openmausbot` companion's answers (`Fixtures/Squadd/squadd-v-fork*`,
/// origin/dev 9e05e3a04, fake engine): the fork of the reply and the new thread it made.
@MainActor
final class SquaddForkTests: XCTestCase {
    static let forkThreadId = "4a54c142-6ef2-4371-abce-ad9fd6cbdd7a"
    static let greeting = "a2b19995-1e91-4141-8753-ac395449374c"

    override func tearDown() {
        SquaddChatFixture.reset()
        super.tearDown()
    }

    func testForkFromHereOnAReplyOpensTheNewThread() async throws {
        let fork = record()
        let (model, _) = makeChat(Self.source)
        await model.loadMessages()
        let greeting = try XCTUnwrap(model.messages.first { $0.messageId == Self.greeting })
        XCTAssertFalse(try XCTUnwrap(model.actionContext(for: greeting, visibleIndex: 0)).offersFork, "a card is no fork point")
        let reply = try XCTUnwrap(model.messages.first { $0.messageId == SquaddVersionsTests.firstReply })
        let context = try XCTUnwrap(model.actionContext(for: reply, visibleIndex: 2))
        XCTAssertTrue(context.offersFork, "Fork From Here is in the reply's menu")

        let opened = await model.forkSquaddThread(from: context)
        XCTAssertEqual(try XCTUnwrap(fork.request.flatMap(SquaddVersionsTests.body))["messageId"] as? String,
                       SquaddVersionsTests.firstReply)
        let chat = try XCTUnwrap(opened, "\(model.messageActionErrorMessage ?? "")")
        XCTAssertEqual(chat.threadId, Self.forkThreadId)
        XCTAssertEqual(chat.botId, SquaddVersionsTests.botId)

        let (forked, _) = makeChat(chat)
        await forked.loadMessages()
        XCTAssertTrue(forked.messages.contains { $0.content == "Scrivi tre parole" }, "the new thread holds the history")
    }

    func testSlashBranchForksFromTheNewestMessage() async throws {
        let fork = record()
        let (model, _) = makeChat(Self.source)
        await model.loadMessages()

        let result = await model.runSquaddSlashCommand("/branch")
        guard case .openedSquaddThread(let chat)? = result else { return XCTFail("\(String(describing: result))") }
        XCTAssertEqual(chat.threadId, Self.forkThreadId)
        XCTAssertEqual(try XCTUnwrap(fork.request.flatMap(SquaddVersionsTests.body))["messageId"] as? String,
                       SquaddVersionsTests.firstReply)
    }

    // MARK: - Helpers

    static let source = SquaddThreadChat(server: SquaddVersionsTests.server, token: "device-token", botId: SquaddVersionsTests.botId,
                                         threadId: SquaddVersionsTests.threadId, title: "Prova")

    final class Recorded { var request: URLRequest? }

    /// Answers the source thread, the fork and the new thread; returns the fork request once sent.
    static func answer(_ fork: Recorded) -> (URLRequest) -> SquaddChatFixture.Answer {
        { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/threads/\(SquaddVersionsTests.threadId)/messages"):
                return .reply(200, try! SquaddVersionsTests.fixture("squadd-v-thread-v1.json"))
            case ("POST", "/api/bots/\(SquaddVersionsTests.botId)/tasks/\(SquaddVersionsTests.threadId)/forks"):
                fork.request = request
                return .reply(201, try! SquaddVersionsTests.fixture("squadd-v-fork.json"))
            case ("GET", "/api/threads/\(forkThreadId)/messages"):
                return .reply(200, try! SquaddVersionsTests.fixture("squadd-v-fork-thread.json"))
            default:
                return .hold
            }
        }
    }

    private func record() -> Recorded {
        let fork = Recorded()
        SquaddChatFixture.handler = Self.answer(fork)
        return fork
    }

    private func makeChat(_ chat: SquaddThreadChat) -> (ChatViewModel, SquaddChatTurnCoordinator) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SquaddChatFixture.self]
        let coordinator = SquaddChatTurnCoordinator(chat, session: URLSession(configuration: configuration),
                                                    reconnectDelay: { _ in try await Task.sleep(for: .seconds(3600)) })
        addTeardownBlock { coordinator.stop() }
        let model = ChatViewModel(session: chat.session, server: chat.server, streamingRevealTick: {}, backend: .squadd(coordinator))
        return (model, coordinator)
    }
}

/// The new thread on screen after Fork From Here on the reply. Photos only, for photo runs (`FOTO_DIR`).
@MainActor
final class SquaddForkPhotoTests: XCTestCase {
    override func tearDown() {
        URLProtocol.unregisterClass(SquaddChatFixture.self)
        SquaddChatFixture.reset()
        super.tearDown()
    }

    func testPhotoForkedThread() async throws {
        let path = ProcessInfo.processInfo.environment["FOTO_DIR"]
        try XCTSkipIf(path == nil, "Only for photo runs")
        let dir = URL(fileURLWithPath: path!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fork = SquaddForkTests.Recorded()
        SquaddChatFixture.handler = SquaddForkTests.answer(fork)
        URLProtocol.registerClass(SquaddChatFixture.self)

        let source = SquaddChatTurnCoordinator(SquaddForkTests.source)
        addTeardownBlock { source.stop() }
        let model = ChatViewModel(session: SquaddForkTests.source.session, server: SquaddForkTests.source.server,
                                  streamingRevealTick: {}, backend: .squadd(source))
        await model.loadMessages()
        let reply = try XCTUnwrap(model.messages.first { $0.messageId == SquaddVersionsTests.firstReply })
        let opened = await model.forkSquaddThread(from: model.actionContext(for: reply, visibleIndex: 2))
        let chat = try XCTUnwrap(opened)

        let continuity = ChatContinuity()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ChatView(session: chat.session, server: chat.server, onAPIError: { _ in }, continuity: continuity, squaddThread: chat)
        })
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, continuity.model?.messages.contains(where: { $0.content == "Scrivi tre parole" }) != true {
            // test-wait: a photo, not a check; `ChatContinuity` isn't observable.
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(continuity.model?.squaddTurn?.chat.threadId, SquaddForkTests.forkThreadId)
        try await readyPhoto(of: window).write(to: dir.appendingPathComponent("20-a-forked-thread.png"))
    }
}
