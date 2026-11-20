import XCTest
@testable import HermesMobile

/// A Squadd agent's chat (#11) against one turn recorded from a real `openmausbot` companion
/// (`Fixtures/Squadd/`, origin/dev 3d12c2fd7, fake engine streaming 6 characters at a time): the
/// thread before and after the turn, the send's 202 and the `/api/events` frames in between.
@MainActor
final class SquaddChatTests: XCTestCase {
    private let server = URL(string: "http://192.0.2.10:8810")!
    private let botId = "96712972-b729-4d9c-86dd-39faf2b2c94d"
    private let threadId = "c5a9dd65-b836-482b-9e9b-752a656897a8"
    /// The send id the recorded turn was sent with, so its echo reads as this chat's own.
    private let recordedSendID = "ios-prova-0000000000000002"

    override func tearDown() {
        SquaddChatFixture.reset()
        super.tearDown()
    }

    func testRecordedTurnShowsThePromptAtOnceAndStreamsTheReplyInPlace() async throws {
        let events = try String(decoding: Self.fixture("turn-events.sse"), as: UTF8.self)
        var sent: URLRequest?
        let posted = expectation(description: "the send reached the companion")
        let threadId = threadId, botId = botId
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/threads/\(threadId)/messages"):
                return .reply(200, try! Self.fixture(sent == nil ? "thread-before.json" : "thread-after.json"))
            case ("POST", "/api/bots/\(botId)/messages"):
                sent = request
                posted.fulfill()
                return .hold
            case ("GET", "/api/events"):
                return .hold
            default:
                return .reply(404, Data())
            }
        }
        let (model, coordinator) = makeChat()
        let sendID = recordedSendID
        coordinator.makeSendID = { sendID }

        await model.loadMessages()
        XCTAssertEqual(model.messages.map(\.role), ["assistant", "user", "assistant"], "the digest row stays hidden")

        let sending = Task { await model.send("Rispondimi parola per parola") }
        await waitUntil("the prompt shows before the server answers") { model.messages.count == 4 }
        let prompt = try XCTUnwrap(model.messages.last)
        XCTAssertEqual(prompt.content, "Rispondimi parola per parola")
        await fulfillment(of: [posted], timeout: 5)
        let body = try XCTUnwrap(sent.flatMap { $0.httpBody ?? $0.httpBodyStream.map(Self.read) })
        let fields = try JSONSerialization.jsonObject(with: body) as? [String: String]
        XCTAssertEqual(fields?["threadId"], threadId)
        XCTAssertEqual(fields?["sendId"], recordedSendID)
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
        SquaddChatFixture.answer("POST", status: 202, body: try Self.fixture("send-receipt.json"))
        let outcome = await sending.value
        XCTAssertEqual(outcome, .started)

        // The frames up to the third piece of the reply, then the rest.
        let split = try XCTUnwrap(events.ranges(of: "\"content.delta\"").dropFirst(2).first)
        let cut = try XCTUnwrap(events[split.upperBound...].range(of: "\n\n")).upperBound
        SquaddChatFixture.stream(Data(events[..<cut].utf8))
        await waitUntil("the reply starts to show") {
            model.streamingAssistantMessageID.flatMap { id in model.messages.first { $0.messageId == id } }?.content?.isEmpty == false
        }
        let replyID = try XCTUnwrap(model.streamingAssistantMessageID)
        XCTAssertNotNil(model.activeStreamID)
        let partial = try XCTUnwrap(model.messages.first { $0.messageId == replyID }?.content)

        SquaddChatFixture.stream(Data(events[cut...].utf8), finish: true)
        let final = "Ciao! Ecco un **esempio** in markdown:\n\n- primo punto\n- secondo punto\n\n```swift\nlet saluto = \"ciao\"\nprint(saluto)\n```\n\nE una formula: $E = mc^2$."
        await waitUntil("the turn ends on the stored reply") {
            model.activeStreamID == nil && model.messages.last?.content == final
        }
        XCTAssertTrue(final.hasPrefix(partial) && partial.count < final.count, "the reply arrived in pieces")
        XCTAssertEqual(model.messages.map(\.role), ["assistant", "user", "assistant", "user", "assistant"])
        XCTAssertEqual(model.messages[3].messageId, prompt.messageId, "the stored prompt replaces its row in place")
        XCTAssertEqual(model.messages[4].messageId, replyID, "the stored reply replaces the streamed row in place")
        XCTAssertNil(model.sendErrorMessage)
    }

    func testRefusedSendGoesBackToTheComposerWithTheReason() async throws {
        let threadId = threadId
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/threads/\(threadId)/messages"): .reply(200, try! Self.fixture("thread-before.json"))
            case ("POST", _): .reply(409, Data(#"{"error":"the bot switched tasks before it could receive the message"}"#.utf8))
            default: .hold
            }
        }
        let (model, _) = makeChat()
        await model.loadMessages()

        let outcome = await model.send("Ciao")

        XCTAssertEqual(outcome, .kept, "the composer keeps the draft")
        XCTAssertEqual(model.messages.count, 3, "the prompt leaves the transcript")
        XCTAssertEqual(model.sendErrorMessage, String(localized: "The computer is busy. Try again when the agents have finished."))
    }

    func testRecordedFramesDecodeAndUnknownOnesAreIgnored() throws {
        var parser = SquaddSSEParser()
        var frames: [SquaddFrame] = []
        for line in String(decoding: try Self.fixture("turn-events.sse"), as: UTF8.self).components(separatedBy: "\n") {
            if let data = parser.feed(line) { frames.append(SquaddFrame.decode(data)) }
        }

        XCTAssertEqual(frames.first, .hello(cursor: "abd562ac:64", resumed: false))
        let reply = frames.compactMap { frame -> String? in
            if case .replyDelta(threadId, _, let text) = frame { return text } else { return nil }
        }
        XCTAssertEqual(reply.count, 25)
        XCTAssertTrue(reply.joined().hasPrefix("Ciao! Ecco un **esempio**"))
        XCTAssertTrue(frames.contains(.turnCompleted(threadId: threadId, ok: true)))
        XCTAssertTrue(frames.contains(.ignored), "bot, notify and token-usage frames are not the chat's")
        for unknown in [#"{"kind":"brand-new","x":1}"#, "not json", #"{"kind":"runtime","event":{"type":"later","threadId":"t"}}"#,
                        #"{"kind":"message","threadId":"t","message":{"role":"bot"}}"#] {
            XCTAssertEqual(SquaddFrame.decode(unknown), .ignored, unknown)
        }
    }

    /// `slash-skills.json` is the companion's answer (openmausbot origin/dev 9e05e3a04) for an agent
    /// with skills `goal`, `meeting-notes`, `old-digest` (turned off) and `weekly-report`.
    func testSlashPanelOffersTheThreadsEnabledSkillsButNotOneNamedLikeABuiltIn() async throws {
        let botId = botId
        var query: String?
        SquaddChatFixture.handler = { request in
            guard request.httpMethod == "GET", request.url?.path == "/api/bots/\(botId)/skills" else { return .hold }
            query = request.url?.query
            return .reply(200, try! Self.fixture("slash-skills.json"))
        }
        let (model, _) = makeChat()

        await model.loadSkillSlashSuggestions()

        XCTAssertEqual(query, "threadId=\(threadId)", "the skills this thread's turn sees")
        XCTAssertEqual(model.composerSkillSuggestions.map(\.name), ["meeting-notes", "weekly-report"])
        XCTAssertTrue(model.hasLoadedSkillSlashSuggestions)
    }

    func testGoalGoesWithoutItsPrefixInGoalModeAndOtherCommandsAsTyped() async throws {
        var bodies: [[String: String]] = []
        let botId = botId
        SquaddChatFixture.handler = { request in
            guard request.httpMethod == "POST", request.url?.path == "/api/bots/\(botId)/messages" else { return .hold }
            let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
            bodies.append((try? JSONSerialization.jsonObject(with: body)) as? [String: String] ?? [:])
            return .reply(202, try! Self.fixture("send-receipt.json"))
        }

        let (goalChat, _) = makeChat()
        let empty = await goalChat.send("/goal  ")
        XCTAssertEqual(empty, .kept, "the companion refuses an empty goal")
        XCTAssertEqual(goalChat.sendErrorMessage, String(localized: "Write the goal after /goal."))
        XCTAssertTrue(bodies.isEmpty)
        let goal = await goalChat.send("/Goal ship the weekly report")
        let (learnChat, _) = makeChat()
        let learn = await learnChat.send("/learn the report steps")

        XCTAssertEqual([goal, learn], [.started, .started])
        XCTAssertEqual(bodies.map { $0["text"] }, ["ship the weekly report", "/learn the report steps"])
        XCTAssertEqual(bodies.map { $0["mode"] }, ["goal", nil])
    }

    func testOlderPagesComeInFrontWithTheCursorOfTheOldestRow() async throws {
        func page(_ ids: [String], kind: String = "text", hasMore: Bool) -> Data {
            let rows = ids.map { #"{"id":"\#($0)","role":"user","kind":"\#(kind)","text":"row \#($0)","at":1}"# }
            return Data(#"{"messages":[\#(rows.joined(separator: ","))],"hasMore":\#(hasMore)}"#.utf8)
        }
        let threadId = threadId
        var cursors: [String] = []
        SquaddChatFixture.handler = { request in
            guard request.url?.path == "/api/threads/\(threadId)/messages" else { return .hold }
            switch request.url?.query {
            case nil: return .reply(200, page(["m3", "m4"], hasMore: true))
            case "before=m3": cursors.append("m3"); return .reply(200, page(["t1"], kind: "tool", hasMore: true))
            default: cursors.append(request.url?.query ?? ""); return .reply(200, page(["m1", "m2"], hasMore: false))
            }
        }
        let (model, _) = makeChat()

        await model.loadMessages()
        XCTAssertTrue(model.hasOlderMessages, "the companion said older rows remain")
        let loaded = await model.loadOlderMessages()

        XCTAssertTrue(loaded)
        XCTAssertEqual(cursors, ["m3", "before=t1"], "a page of only hidden rows reads on to the next one")
        XCTAssertEqual(model.messages.map(\.messageId), ["m1", "m2", "m3", "m4"])
        XCTAssertFalse(model.hasOlderMessages)
    }

    func testKeyboardShortcutsStepThroughTheHomeThreadsInOnScreenOrder() throws {
        let bots = try JSONDecoder().decode(SquaddBotList.self, from: Self.fixture("bots.json")).bots
        let chats = SquaddThreadChat.all(in: bots.map(SquaddAgentSection.init(bot:)), server: server, token: "device-token")

        XCTAssertEqual(chats.map(\.title), ["File a bug about the login screen", "Weekly menu", "hi", "New thread"])
        XCTAssertEqual(ChatShortcutNavigation.chat(atPosition: 3, in: chats)?.botId, bots[1].id, "⌘3 opens Pesto's second thread")
        XCTAssertEqual(ChatShortcutNavigation.adjacentChat(offset: 1, from: chats[1].id, in: chats), chats[2])
        XCTAssertEqual(ChatShortcutNavigation.adjacentChat(offset: 1, from: chats[3].id, in: chats), chats[0], "Next wraps")
    }

    func testDraftsStayWithTheirServerAndThread() async {
        let store = ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(10))
        let other = URL(string: "http://192.0.2.11:8810")!
        func key(_ server: URL, _ thread: String) -> ChatDraftKey {
            let chat = SquaddThreadChat(server: server, token: "device-token", botId: botId, threadId: thread, title: nil)
            return ChatView.draftKey(for: chat.session, server: chat.server)
        }

        store.setDraft("half a thought", for: key(server, threadId))

        let otherThread = await store.draft(for: key(server, "another-thread"))
        let otherServer = await store.draft(for: key(other, threadId))
        let reopened = await store.draft(for: key(server, threadId))
        XCTAssertNil(otherThread?.text)
        XCTAssertNil(otherServer?.text)
        XCTAssertEqual(reopened?.text, "half a thought")
    }

    // MARK: - Helpers

    private func makeChat() -> (ChatViewModel, SquaddChatTurnCoordinator) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SquaddChatFixture.self]
        let chat = SquaddThreadChat(server: server, token: "device-token", botId: botId, threadId: threadId, title: "Prova")
        let coordinator = SquaddChatTurnCoordinator(chat, session: URLSession(configuration: configuration),
                                                    retryDelay: { _ in try await Task.sleep(for: .seconds(3600)) })
        addTeardownBlock { coordinator.stop() }
        let model = ChatViewModel(session: SessionSummary(sessionId: threadId, title: "Prova"), server: server,
                                  streamingRevealTick: {}, backend: .squadd(coordinator))
        return (model, coordinator)
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

/// A companion that answers at once, or holds a request until the test answers it or streams
/// into it, the way `/api/events` stays open.
final class SquaddChatFixture: URLProtocol {
    enum Answer { case reply(Int, Data), hold }

    nonisolated(unsafe) static var handler: ((URLRequest) -> Answer)?
    nonisolated(unsafe) private static var held: [SquaddChatFixture] = []
    private static let lock = NSLock()

    static func reset() {
        lock.withLock { held = [] }
        handler = nil
    }

    /// Answers the held request with `method`.
    static func answer(_ method: String, status: Int, body: Data) {
        guard let request = lock.withLock({ held.first { $0.request.httpMethod == method } }) else { return XCTFail("no \(method) held") }
        request.respond(status: status)
        request.client?.urlProtocol(request, didLoad: body)
        request.client?.urlProtocolDidFinishLoading(request)
        lock.withLock { held.removeAll { $0 === request } }
    }

    /// Sends `data` down the held event stream, and ends it with `finish`.
    static func stream(_ data: Data, finish: Bool = false) {
        guard let events = lock.withLock({ held.first { $0.request.url?.path == "/api/events" } }) else { return XCTFail("no stream held") }
        events.client?.urlProtocol(events, didLoad: data)
        if finish {
            events.client?.urlProtocolDidFinishLoading(events)
            lock.withLock { held.removeAll { $0 === events } }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.handler?(request) ?? .hold {
        case .reply(let status, let data):
            respond(status: status)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .hold:
            if request.url?.path == "/api/events" { respond(status: 200) }
            Self.lock.withLock { Self.held.append(self) }
        }
    }

    override func stopLoading() {
        Self.lock.withLock { Self.held.removeAll { $0 === self } }
    }

    private func respond(status: Int) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
}
