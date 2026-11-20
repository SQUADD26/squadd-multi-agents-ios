import SwiftData
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

    // MARK: Resuming (#12): a turn recorded from a real companion (origin/dev 9e05e3a04, `resume-*`),
    // cut after its 12th piece and resumed with `Last-Event-ID: 5c85f42b:32`.

    private let resumeBot = "eef7d399-17ac-42e8-80f1-74818aa54d0f"
    private let resumeThread = "ae0770b2-1152-45a7-9d17-4053d27ea3a6"

    func testBackgroundAndNetworkChangeResumeAfterTheLastFrameWithoutRepeats() async throws {
        let cut = try Self.text("resume-cut.sse"), resumed = try Self.text("resume-resumed.sse")
        let reply = try Self.storedReply()
        let thread = resumeThread
        var cursors: [String?] = [], turnEnded = false
        var opened = expectation(description: "the stream opens")
        SquaddChatFixture.handler = { request in
            switch request.url?.path {
            case "/api/threads/\(thread)/messages":
                return .reply(200, try! Self.fixture(turnEnded ? "resume-thread-after.json" : "resume-thread-before.json"))
            case "/api/events":
                cursors.append(request.value(forHTTPHeaderField: "Last-Event-ID"))
                return .hold
            default: return .reply(404, Data())
            }
        }
        SquaddChatFixture.didHold = { if $0.url?.path == "/api/events" { opened.fulfill() } }
        let (model, _) = makeChat(bot: resumeBot, thread: resumeThread)
        await model.loadMessages()
        await fulfillment(of: [opened], timeout: 5)
        await waitUntil("the thread shows before the turn's frames come") { !model.messages.isEmpty }
        SquaddChatFixture.stream(Data(cut.utf8))
        await waitUntil("the first 12 pieces show") { Self.streamedText(model) == String(reply.prefix(48)) }

        model.suspendStreamForBackground()
        opened = expectation(description: "the stream reopens after the app comes back")
        await model.reconnectStreamIfNeeded()
        await fulfillment(of: [opened], timeout: 5)
        XCTAssertEqual(cursors.last, "5c85f42b:32", "it resumes after the last frame seen")

        // The resumed frames up to the 40th piece, then the first ones again, as a proxy may resend them.
        let middle = Self.end(ofDelta: 40, in: resumed)
        let firstFrames = resumed[..<Self.end(ofDelta: 3, in: resumed)]
        SquaddChatFixture.stream(Data((resumed[..<middle] + firstFrames).utf8))
        await waitUntil("each piece shows once") { Self.streamedText(model) == String(reply.prefix(48 + 40 * 4)) }

        opened = expectation(description: "a network change reopens the stream")
        await model.networkPathDidChange()
        await fulfillment(of: [opened], timeout: 5)
        XCTAssertEqual(cursors.last, Self.lastID(in: resumed[..<middle]))
        turnEnded = true
        SquaddChatFixture.stream(Data(resumed[middle...].utf8))
        await waitUntil("the turn ends on the stored reply") { model.activeStreamID == nil && model.messages.last?.content == reply }
        XCTAssertEqual(model.messages.filter { $0.content == reply }.count, 1)
    }

    func testALostResumeReloadsTheThreadAndTheRestOfTheReplyShowsAsWorking() async throws {
        let cut = try Self.text("resume-cut.sse"), resumed = try Self.text("resume-resumed.sse")
        // The hello a stale cursor gets (`resume-stale.sse`), with the cursor the companion had at the cut.
        let stale = try Self.text("resume-stale.sse").replacingOccurrences(of: "5c85f42b:189", with: "5c85f42b:54")
        let reply = try Self.storedReply()
        let thread = resumeThread
        var turnEnded = false
        // A row stored before the turn starts reloads the thread too, so a read may come more than once.
        func reads(_ description: String) -> XCTestExpectation {
            let read = expectation(description: description)
            read.assertForOverFulfill = false
            return read
        }
        var opened = expectation(description: "the stream opens"), reloaded = reads("the thread loads")
        SquaddChatFixture.handler = { request in
            switch request.url?.path {
            case "/api/threads/\(thread)/messages":
                reloaded.fulfill()
                return .reply(200, try! Self.fixture(turnEnded ? "resume-thread-after.json" : "resume-thread-before.json"))
            default: return .hold
            }
        }
        SquaddChatFixture.didHold = { if $0.url?.path == "/api/events" { opened.fulfill() } }
        let (model, coordinator) = makeChat(bot: resumeBot, thread: resumeThread, reconnectDelay: { _ in })
        await model.loadMessages()
        await fulfillment(of: [opened, reloaded], timeout: 5)
        await waitUntil("the thread shows before the turn's frames come") { !model.messages.isEmpty }
        opened = expectation(description: "the stream reopens on its own")
        SquaddChatFixture.stream(Data(cut.utf8), finish: true)
        await fulfillment(of: [opened], timeout: 5)

        reloaded = reads("the companion's lost frames reload the thread")
        SquaddChatFixture.stream(Data(stale.utf8))
        await fulfillment(of: [reloaded], timeout: 5)
        // The live frames after the hello; those up to its cursor were already sent and are dropped.
        let frames = resumed[resumed.range(of: "id: ")!.lowerBound...]
        let ending = frames[..<frames.range(of: "turn.completed")!.lowerBound].lastIndex(of: "\n")!
        SquaddChatFixture.stream(Data(frames[..<ending].utf8))
        await waitUntil("the reply goes on as working") { model.activeStreamID != nil }
        XCTAssertNil(coordinator.latestRunEnding, "a lost resume is not a failed turn")
        XCTAssertEqual(Self.streamedText(model) ?? "", "", "no reply with its beginning missing")

        turnEnded = true
        reloaded = reads("the turn's end reloads the thread")
        SquaddChatFixture.stream(Data(frames[ending...].utf8))
        await fulfillment(of: [reloaded], timeout: 5)
        await waitUntil("the stored reply comes when the turn ends") { model.activeStreamID == nil && model.messages.last?.content == reply }
        XCTAssertEqual(model.messages.filter { $0.content == reply }.count, 1)
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

    func testOfflineThreadShowsItsServersCachedTranscriptAndRefreshesWhenTheNetworkReturns() async throws {
        let cache = try ModelContext(ModelContainer(for: CachedSession.self, CachedMessage.self,
                                                    configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let threadId = threadId
        var online = true
        SquaddChatFixture.handler = { request in
            guard online else { return .offline }
            return request.url?.path == "/api/threads/\(threadId)/messages" ? .reply(200, try! Self.fixture("thread-after.json")) : .hold
        }
        let (live, liveTurn) = makeChat()
        await live.loadMessages(modelContext: cache)
        liveTurn.stop()
        let saved = live.messages.map(\.messageId)
        XCTAssertFalse(saved.isEmpty)

        online = false
        let retrying = expectation(description: "the stream waits to reconnect")
        let (offline, _) = makeChat(retrying: retrying)
        // The way `ChatView` opens a chat: it reconnects as it appears, then loads.
        await offline.reconnectStreamIfNeeded(modelContext: cache)
        await offline.loadMessages(modelContext: cache)
        XCTAssertEqual(offline.messages.map(\.messageId), saved, "the last read shows without the computer")
        XCTAssertTrue(offline.showsOfflineCache, "marked offline")
        XCTAssertNil(offline.errorMessage)

        let (elsewhere, _) = makeChat(server: URL(string: "http://192.0.2.11:8810")!)
        await elsewhere.loadMessages(modelContext: cache)
        XCTAssertTrue(elsewhere.messages.isEmpty, "another server never shows this server's thread")
        XCTAssertNotNil(elsewhere.errorMessage)

        await fulfillment(of: [retrying], timeout: 5)
        online = true
        await offline.networkPathDidChange(modelContext: cache)
        XCTAssertFalse(offline.showsOfflineCache, "the network came back: the computer's transcript replaces the copy")
        XCTAssertEqual(offline.messages.map(\.messageId), saved)
    }

    // MARK: - Helpers

    private func makeChat(server: URL? = nil, bot: String? = nil, thread: String? = nil, retrying: XCTestExpectation? = nil,
                          reconnectDelay: @escaping ChatStreamReconnectDelay = { _ in try await Task.sleep(for: .seconds(3600)) })
        -> (ChatViewModel, SquaddChatTurnCoordinator) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SquaddChatFixture.self]
        let server = server ?? self.server
        let threadId = thread ?? threadId
        let chat = SquaddThreadChat(server: server, token: "device-token", botId: bot ?? botId, threadId: threadId, title: "Prova")
        let coordinator = SquaddChatTurnCoordinator(chat, session: URLSession(configuration: configuration),
                                                    reconnectDelay: { delay in
                                                        retrying?.fulfill()
                                                        try await reconnectDelay(delay)
                                                    })
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

    private nonisolated static func text(_ name: String) throws -> String {
        String(decoding: try fixture(name), as: UTF8.self)
    }

    /// The reply the recorded turn stored.
    private static func storedReply() throws -> String {
        let page = try JSONDecoder().decode(SquaddMessagePage.self, from: fixture("resume-thread-after.json"))
        return try XCTUnwrap(page.messages.last { $0.role == "bot" && $0.kind == "text" }?.text)
    }

    /// Where the frame carrying the `n`th reply piece ends.
    private static func end(ofDelta n: Int, in frames: String) -> String.Index {
        let piece = frames.ranges(of: "\"content.delta\"")[n - 1]
        return frames[piece.upperBound...].range(of: "\n\n")!.upperBound
    }

    private static func lastID(in frames: Substring) -> String? {
        frames.components(separatedBy: "\n").last { $0.hasPrefix("id: ") }.map { String($0.dropFirst(4)) }
    }

    private static func streamedText(_ model: ChatViewModel) -> String? {
        model.streamingAssistantMessageID.flatMap { id in model.messages.first { $0.messageId == id } }?.content
    }

    private nonisolated static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Squadd/\(name)"))
    }
}

/// A companion that answers at once, or holds a request until the test answers it or streams
/// into it, the way `/api/events` stays open.
final class SquaddChatFixture: URLProtocol {
    enum Answer { case reply(Int, Data), hold, offline }

    nonisolated(unsafe) static var handler: ((URLRequest) -> Answer)?
    nonisolated(unsafe) private static var held: [SquaddChatFixture] = []
    private static let lock = NSLock()

    /// Called once a held request can take `stream` or `answer`.
    nonisolated(unsafe) static var didHold: ((URLRequest) -> Void)?

    static func reset() {
        lock.withLock { held = [] }
        handler = nil
        didHold = nil
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
        // The newest: a reopened stream's old connection may not have stopped yet.
        guard let events = lock.withLock({ held.last { $0.request.url?.path == "/api/events" } }) else { return XCTFail("no stream held") }
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
        case .offline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .hold:
            if request.url?.path == "/api/events" { respond(status: 200) }
            Self.lock.withLock { Self.held.append(self) }
            Self.didHold?(request)
        }
    }

    override func stopLoading() {
        Self.lock.withLock { Self.held.removeAll { $0 === self } }
    }

    private func respond(status: Int) {
        // Without a Content-Type URLSession holds the first 512 bytes to sniff one, so a lone small frame never arrives.
        let type = request.url?.path == "/api/events" ? "text/event-stream" : "application/json"
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
}
