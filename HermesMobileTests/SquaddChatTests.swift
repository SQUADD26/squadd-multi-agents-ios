import SwiftUI
import SwiftData
import XCTest
import UIKit
import AVFoundation
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

    /// The `slash-*.json` fixtures are the companion's answers (openmausbot origin/dev 9e05e3a04): skills
    /// `goal`, `meeting-notes`, `old-digest` (turned off) and `weekly-report`; an agent on the Claude
    /// engine (`slash-bots.json`) and one on a computer with no engine yet (`slash-bots-no-engine.json`);
    /// the settings with skill drafting on and off.
    func testSlashPanelOffersTheDesktopsCommandsAndTheThreadsEnabledSkills() async throws {
        let (commands, skills, query) = try await slashCatalog(bots: "slash-bots.json", config: "slash-config.json")

        XCTAssertEqual(commands, ["goal", "learn", "setup", "burst", "branch", "fork", "undo", "compact"])
        XCTAssertEqual(skills, ["meeting-notes", "weekly-report"], "neither a turned-off skill nor one named like a built-in")
        XCTAssertEqual(query, "threadId=\(threadId)", "the skills this thread's turn sees")
    }

    func testAnAgentWithNoEngineIsOfferedOnlyTheGoalForkAndUndo() async throws {
        let (commands, _, _) = try await slashCatalog(bots: "slash-bots-no-engine.json", config: "slash-config.json")

        XCTAssertEqual(commands, ["goal", "branch", "fork", "undo", "compact"])
    }

    func testLearnLeavesThePanelWhenTheComputerTurnsSkillDraftingOff() async throws {
        let (commands, _, _) = try await slashCatalog(bots: "slash-bots.json", config: "slash-config-no-learn.json")

        XCTAssertEqual(commands, ["goal", "setup", "burst", "branch", "fork", "undo", "compact"])
    }

    func testGoalGoesWithoutItsPrefixInGoalModeAndOtherCommandsAsTyped() async throws {
        var bodies: [[String: String]] = []
        let botId = botId, threadId = threadId
        SquaddChatFixture.handler = { request in
            // After a send the chat reloads the thread, then listens.
            if request.url?.path == "/api/threads/\(threadId)/messages" { return .reply(200, try! Self.fixture("thread-before.json")) }
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

    // MARK: Stop, queue, compaction (#13): one session recorded from a real companion (origin/dev
    // 9e05e3a04, `control-*`). A long turn; two messages queued behind it; the second deleted, the
    // first steered in; Stop; then Compact. `: app <step>` comment lines mark where each of the
    // app's requests went in the stream; the thread before is the one after, cut before this session's rows.

    private let queuedFirst = "99a210df-bbcd-4b38-8128-f8d3f517c532", queuedSecond = "0512ba82-be3c-4a77-8582-ca6dfcdbf24b"

    func testQueuedMessagesSteerAndDeleteThroughTheCompanionAndLeaveWhenItSays() async throws {
        let events = try Self.text("control-events.sse")
        let bot = resumeBot, thread = resumeThread, first = queuedFirst, second = queuedSecond
        var asked: [URLRequest] = []
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/threads/\(thread)/messages"): return .reply(200, try! Self.fixture("control-thread-before.json"))
            case ("GET", _): return .hold
            case ("POST", "/api/bots/\(bot)/messages"): asked.append(request); return .reply(202, try! Self.fixture("control-send-queued.json"))
            case ("DELETE", "/api/bots/\(bot)/queue/\(second)"): asked.append(request); return .reply(200, Data(#"{"ok":true}"#.utf8))
            case ("POST", "/api/bots/\(bot)/queue/\(first)/steer"): asked.append(request); return .reply(200, try! Self.fixture("control-steer.json"))
            default: return .reply(404, Data())
            }
        }
        let (model, _) = makeChat(bot: resumeBot, thread: resumeThread)
        await model.loadMessages()
        let firstQueued = try XCTUnwrap(events.range(of: #"data: {"kind":"bot.queued""#)).lowerBound
        SquaddChatFixture.stream(Data(events[..<firstQueued].utf8))
        await waitUntil("the turn runs") { model.activeStreamID != nil }
        let rows = model.messages.count

        // Queue, from the send choices a working agent offers.
        _ = await model.submitStreamingMessage("Poi dimmi solo ok", behavior: .queue)
        XCTAssertEqual(try Self.fields(asked.last)["followUp"], "queue")
        XCTAssertEqual(model.messages.count, rows, "a queued message waits in the queue's rows, not the transcript")
        SquaddChatFixture.stream(Data(events[firstQueued..<events.range(of: ": app send-c ")!.lowerBound].utf8))
        await waitUntil("both queued messages show") { model.queuedPromptMessages.count == 2 }
        XCTAssertEqual(model.queuedPromptMessages.map(\.content), ["Poi dimmi solo ok", "Questo lo cancello"])

        await model.deleteQueuedPrompt(try XCTUnwrap(model.queuedPromptMessages.last?.messageId))
        XCTAssertEqual(asked.last?.url?.path, "/api/bots/\(bot)/queue/\(second)")
        XCTAssertEqual(try Self.fields(asked.last)["threadId"], thread)
        XCTAssertEqual(model.queuedPromptMessages.count, 2, "the row leaves when the companion's queue says so")
        SquaddChatFixture.stream(Data(Self.frames(events, from: "send-c", to: "delete-c").utf8))
        await waitUntil("the deleted message leaves") { model.queuedPromptMessages.count == 1 }

        await model.steerQueuedPrompt(try XCTUnwrap(model.queuedPromptMessages.first?.messageId))
        XCTAssertEqual(asked.last?.url?.path, "/api/bots/\(bot)/queue/\(first)/steer")
        SquaddChatFixture.stream(Data(Self.frames(events, from: "delete-c", to: "steer-b").utf8))
        await waitUntil("the steered message joins the running turn") {
            model.queuedPromptMessages.isEmpty && model.messages.last { $0.role == "user" }?.content == "Poi dimmi solo ok"
        }
        XCTAssertNil(model.sendErrorMessage)
    }

    func testStopAsksTheCompanionAndTheTurnEndsStoppedWhenTheStreamSays() async throws {
        let events = try Self.text("control-events.sse")
        let bot = resumeBot, thread = resumeThread
        var asked: URLRequest?
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/threads/\(thread)/messages"): return .reply(200, try! Self.fixture("control-thread-before.json"))
            case ("GET", _): return .hold
            case ("POST", "/api/bots/\(bot)/interrupt"): asked = request; return .reply(200, Data(#"{"ok":true}"#.utf8))
            default: return .reply(404, Data())
            }
        }
        let (model, coordinator) = makeChat(bot: resumeBot, thread: resumeThread, reconnectDelay: { _ in })
        await model.loadMessages()
        SquaddChatFixture.stream(Data(Self.frames(events, to: "interrupt").utf8))
        await waitUntil("the turn runs") { model.activeStreamID != nil }

        let replyID = try XCTUnwrap(model.streamingAssistantMessageID)
        let accepted = await model.cancelActiveStream()
        XCTAssertTrue(accepted)
        XCTAssertEqual(try Self.fields(asked)["turnId"], "5f3b225a-222f-4034-aefd-73028e608bad", "Stop names the running turn")
        XCTAssertEqual(try Self.fields(asked)["threadId"], thread)
        XCTAssertNotNil(model.activeStreamID, "accepted is not stopped")

        // The stream ends after these frames; its reconnect comes once every one of them is applied.
        let reopened = expectation(description: "the stream reopens after the stop's frames")
        SquaddChatFixture.didHold = { if $0.url?.path == "/api/events" { reopened.fulfill() } }
        SquaddChatFixture.stream(Data(Self.frames(events, from: "interrupt", to: "compact").utf8), finish: true)
        await fulfillment(of: [reopened], timeout: 5)
        XCTAssertNil(model.activeStreamID, "the stream ended the turn")
        XCTAssertEqual(coordinator.latestRunEnding?.ending, .cancelled, "a stopped turn is not a failed one")
        XCTAssertEqual(model.messages.first { $0.messageId == replyID }?.content?.isEmpty, false,
                       "the words written before Stop stay, though the companion stores none")
    }

    /// Opened while the agent already writes, the chat never saw `turn.started`: Stop names no
    /// turn, as the desktop does, and the companion stops the one running (recorded the same way).
    func testStopOnATurnJoinedMidReplyNamesNoTurnAndEndsWhenTheStreamSays() async throws {
        let events = try Self.text("control-stop-unnamed-events.sse")
        let blocks = events.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        let firstDelta = try XCTUnwrap(blocks.firstIndex { $0.contains(#""type":"content.delta""#) })
        let stopAt = try XCTUnwrap(blocks.firstIndex { $0.hasPrefix(": app interrupt") })
        func stream(_ part: ArraySlice<String>) -> Data { Data(part.map { $0 + "\n\n" }.joined().utf8) }
        let bot = resumeBot, thread = resumeThread
        var asked: URLRequest?
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/threads/\(thread)/messages"): return .reply(200, try! Self.fixture("control-thread-before.json"))
            case ("GET", _): return .hold
            case ("POST", "/api/bots/\(bot)/interrupt"): asked = request; return .reply(200, Data(#"{"ok":true}"#.utf8))
            default: return .reply(404, Data())
            }
        }
        let (model, coordinator) = makeChat(bot: resumeBot, thread: resumeThread, reconnectDelay: { _ in })
        await model.loadMessages()
        SquaddChatFixture.stream(stream(blocks[..<1]) + stream(blocks[firstDelta..<stopAt]))
        await waitUntil("the turn shows as running") { model.activeStreamID != nil }

        let accepted = await model.cancelActiveStream()
        XCTAssertTrue(accepted)
        XCTAssertEqual(try Self.fields(asked), ["threadId": thread], "no turn to name")
        XCTAssertNotNil(model.activeStreamID, "accepted is not stopped")

        let reopened = expectation(description: "the stream reopens after the stop's frames")
        SquaddChatFixture.didHold = { if $0.url?.path == "/api/events" { reopened.fulfill() } }
        SquaddChatFixture.stream(stream(blocks[stopAt...]), finish: true)
        await fulfillment(of: [reopened], timeout: 5)
        XCTAssertNil(model.activeStreamID, "the stream ended the turn")
        XCTAssertEqual(coordinator.latestRunEnding?.ending, .cancelled)
    }

    func testCompactAsksTheCompanionAndTheMarkerShowsWhenItLands() async throws {
        let events = try Self.text("control-events.sse")
        let bot = resumeBot, thread = resumeThread
        var asked: URLRequest?
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/threads/\(thread)/messages"):
                return .reply(200, try! Self.fixture(asked == nil ? "control-thread-before.json" : "control-thread-after.json"))
            case ("GET", _): return .hold
            case ("POST", "/api/bots/\(bot)/compact"): asked = request; return .reply(202, try! Self.fixture("control-compact.json"))
            default: XCTFail("only the compaction is asked for, \(request.url?.path ?? "")"); return .reply(404, Data())
            }
        }
        let (model, _) = makeChat(bot: resumeBot, thread: resumeThread)
        await model.loadMessages()
        func markers() -> Int { model.messages.filter { ChatMarkerMessageClassifier.classify($0) == .contextCompaction }.count }
        XCTAssertEqual(markers(), 1)

        let outcome = await model.send("/compact")
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(try Self.fields(asked)["threadId"], thread)
        XCTAssertEqual(markers(), 1, "the marker comes with the stream, not the request")

        let hello = String(events[..<events.range(of: "\n\n")!.upperBound])
        SquaddChatFixture.stream(Data((hello + Self.frames(events, from: "compact")).utf8))
        await waitUntil("the marker shows") { markers() == 2 }
    }

    func testARefusedActionKeepsWhatWasShownAndSaysWhy() async throws {
        let events = try Self.text("control-events.sse")
        let bot = resumeBot, thread = resumeThread, second = queuedSecond
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/threads/\(thread)/messages"): return .reply(200, try! Self.fixture("control-thread-before.json"))
            case ("GET", _): return .hold
            case ("POST", "/api/bots/\(bot)/interrupt"):
                return .reply(409, Data(#"{"error":"the bot switched tasks before it could be interrupted"}"#.utf8))
            case ("DELETE", "/api/bots/\(bot)/queue/\(second)"): return .reply(404, Data(#"{"error":"no such queued message"}"#.utf8))
            case ("POST", "/api/bots/\(bot)/compact"): return .reply(409, Data(#"{"error":"the bot is busy"}"#.utf8))
            default: return .reply(404, Data())
            }
        }
        let (model, _) = makeChat(bot: resumeBot, thread: resumeThread)
        await model.loadMessages()
        SquaddChatFixture.stream(Data(Self.frames(events, to: "send-c").utf8))
        await waitUntil("the queue shows") { model.queuedPromptMessages.count == 2 }

        let stopped = await model.cancelActiveStream()
        XCTAssertFalse(stopped)
        XCTAssertNotNil(model.activeStreamID)
        XCTAssertEqual(model.sendErrorMessage, "the bot switched tasks before it could be interrupted")

        await model.deleteQueuedPrompt(try XCTUnwrap(model.queuedPromptMessages.last?.messageId))
        XCTAssertEqual(model.queuedPromptMessages.count, 2)
        XCTAssertEqual(model.sendErrorMessage, "no such queued message")

        let shown = model.messages.map(\.messageId)
        let compacted = await model.submitStreamingMessage("/compact", behavior: .queue)
        XCTAssertEqual(compacted, .notDelivered, "the draft stays in the composer")
        XCTAssertEqual(model.messages.map(\.messageId), shown)
        XCTAssertEqual(model.sendErrorMessage, "the bot is busy")
        let typed = await model.send("/compact")
        XCTAssertEqual(typed, .kept, "typed outside a running turn too, the draft stays")
        XCTAssertEqual(model.messages.map(\.messageId), shown)
        XCTAssertEqual(model.sendErrorMessage, "the bot is busy")
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

    // MARK: Approvals (#14), against a shell approval recorded from a real companion (origin/dev 961cb8133)

    private let approvalBot = "65f42659-c570-4b77-abec-5f2e1d43e9f5"
    private let approvalThread = "c68d3fac-e54a-4658-8a2a-26b15fbe47e5"

    /// The waiting card shows above the composer with the choices it allows; each choice reaches
    /// the companion as the desktop sends it, and the card leaves once the computer took it.
    func testApprovalChoicesReachTheCompanionAndTheCardLeaves() async throws {
        let page = String(decoding: try Self.fixture("thread-approval-open.json"), as: UTF8.self)
            .replacingOccurrences(of: #""allowSession":true"#, with: #""allowSession":true,"allowKey":"shell:echo hi""#)
        let bot = approvalBot, thread = approvalThread
        let requestId = "a83c560b-98f7-44c5-8e05-1e17e60e5d6d"
        for (choice, expected) in [(ApprovalChoice.once, ["allow"]), (.session, ["allow+always"]),
                                   (.always, ["always-allow", "allow"]), (.deny, ["deny"])] {
            var asked: [String] = []
            var answer: [String: Any] = [:]
            SquaddChatFixture.handler = { request in
                switch (request.httpMethod, request.url?.path) {
                case ("GET", "/api/threads/\(thread)/messages"): return .reply(200, Data(page.utf8))
                case ("GET", _): return .hold
                case ("POST", "/api/bots/\(bot)/always-allow"):
                    XCTAssertEqual(try? Self.json(request)["allowKey"] as? String, "shell:echo hi")
                    asked.append("always-allow")
                    return .reply(200, Data(#"{"bot":{}}"#.utf8))
                case ("POST", "/api/threads/\(thread)/respond"):
                    answer = (try? Self.json(request)) ?? [:]
                    asked.append((answer["behavior"] as? String ?? "") + (answer["always"] as? Bool == true ? "+always" : ""))
                    return .reply(200, Data(#"{"ok":true,"outcome":"allowed-once"}"#.utf8))
                default: return .reply(404, Data())
                }
            }
            let (model, coordinator) = makeChat(bot: bot, thread: thread)
            await model.loadMessages()
            let approval = try XCTUnwrap(ChatView.squaddApproval(in: model), "the recorded card waits in the chat's request slot")
            XCTAssertEqual(approval.content.choices, [.once, .session, .always, .deny])
            XCTAssertEqual(approval.content.command, "echo hi")

            let answered = await coordinator.answerApproval(choice)
            XCTAssertTrue(answered)
            XCTAssertEqual(asked, expected, "\(choice)")
            XCTAssertEqual(answer["requestId"] as? String, requestId)
            XCTAssertNil(coordinator.pendingApproval, "the card leaves once the computer took the answer")
            coordinator.stop()
        }
    }

    /// Answered on the desktop, the card leaves the phone when its patch arrives; a refused answer
    /// keeps it, with the reason.
    func testApprovalAnsweredOnTheDesktopLeavesThePhone() async throws {
        let events = try Self.text("events-approval.sse")
        let thread = approvalThread
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/threads/\(thread)/messages"): return .reply(200, Data(#"{"messages":[],"hasMore":false}"#.utf8))
            case ("GET", _): return .hold
            case ("POST", "/api/threads/\(thread)/respond"): return .reply(409, Data(#"{"error":"no pending request"}"#.utf8))
            default: return .reply(404, Data())
            }
        }
        let (model, coordinator) = makeChat(bot: approvalBot, thread: thread)
        await model.loadMessages()
        let resolved = try XCTUnwrap(events.range(of: "id: 1cda109b:182")).lowerBound
        SquaddChatFixture.stream(Data(events[..<resolved].utf8))
        await waitUntil("the card shows") { coordinator.pendingApproval != nil }
        XCTAssertEqual(coordinator.pendingApproval?.content.choices, [.once, .session, .deny])

        let answered = await coordinator.answerApproval(.once)
        XCTAssertFalse(answered)
        XCTAssertNotNil(coordinator.approvalError)
        XCTAssertNotNil(coordinator.pendingApproval, "a refused answer keeps the card")

        SquaddChatFixture.stream(Data(events[resolved...].utf8))
        await waitUntil("the desktop's answer takes the card away") { coordinator.pendingApproval == nil }
    }

    // MARK: Questions (#15), against a question recorded from a real companion (origin/dev 961cb8133)

    private let questionBot = "fcfb2fc1-153d-47b4-a0bc-5e23ff873542"
    private let questionThread = "a0d291da-61ad-4b75-abb4-fdc3db19f630"

    /// The waiting question reaches the chat's request slot with its options and, being fixed, no typed reply; a tap
    /// answers it as the desktop does, and the card leaves once the computer took it.
    func testQuestionReachesTheSlotAndATapAnswersItAsTheDesktopDoes() async throws {
        let thread = questionThread
        var answer: [String: Any] = [:]
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/threads/\(thread)/messages"): return .reply(200, try! Self.fixture("thread-question-open.json"))
            case ("GET", _): return .hold
            case ("POST", "/api/threads/\(thread)/respond"):
                answer = (try? Self.json(request)) ?? [:]
                return .reply(200, Data(#"{"ok":true,"outcome":"answered"}"#.utf8))
            default: return .reply(404, Data())
            }
        }
        let (model, coordinator) = makeChat(bot: questionBot, thread: thread)
        await model.loadMessages()
        let prompt = try XCTUnwrap(ChatView.squaddQuestion(in: model), "the recorded question waits in the chat's request slot").prompt
        XCTAssertEqual(prompt.question, "Which color?")
        XCTAssertEqual(prompt.choices, ["Blue", "Green"])
        XCTAssertFalse(prompt.allowsTypedResponse, "a fixed question offers no typed reply")

        let answered = await coordinator.answerQuestion("Blue")
        XCTAssertTrue(answered)
        XCTAssertEqual(answer["requestId"] as? String, "3080de20-e9be-412a-a539-3a193e9ff60f")
        XCTAssertEqual(answer["behavior"] as? String, "answer")
        XCTAssertEqual(answer["message"] as? String, "The user answered your questions.\n\nQ: Which color?\nA: Blue",
                       "the recorded desktop's answer")
        XCTAssertNil(coordinator.pendingQuestion, "the card leaves once the computer took the answer")
    }

    /// A card with two questions asks them one after the other and sends both answers once; a refused send keeps
    /// the last question on screen with the reason.
    func testTwoQuestionsAreAskedInTurnAndSentOnce() async throws {
        let page = String(decoding: try Self.fixture("thread-question-open.json"), as: UTF8.self).replacingOccurrences(
            of: #""questions":[{"question":"Which color?","options":[{"label":"Blue"},{"label":"Green"}],"custom":false}]"#,
            with: #""questions":[{"question":"Which color?","options":[{"label":"Blue"},{"label":"Green"}],"custom":false},{"question":"Why?","options":[]}]"#)
        XCTAssertTrue(page.contains(#""question":"Why?""#), "the recorded card took the second question")
        let thread = questionThread
        var sent: [[String: Any]] = []
        var refuse = true
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/threads/\(thread)/messages"): return .reply(200, Data(page.utf8))
            case ("GET", _): return .hold
            case ("POST", "/api/threads/\(thread)/respond"):
                sent.append((try? Self.json(request)) ?? [:])
                return refuse ? .reply(409, Data(#"{"error":"no pending request"}"#.utf8)) : .reply(200, Data(#"{"ok":true}"#.utf8))
            default: return .reply(404, Data())
            }
        }
        let (model, coordinator) = makeChat(bot: questionBot, thread: thread)
        await model.loadMessages()

        _ = await coordinator.answerQuestion("Blue")
        XCTAssertTrue(sent.isEmpty, "the first answer waits for the second question")
        let second = try XCTUnwrap(ChatView.squaddQuestion(in: model)).prompt
        XCTAssertEqual(second.question, "Why?")
        XCTAssertTrue(second.allowsTypedResponse, "a question with no options takes a typed reply")

        let refused = await coordinator.answerQuestion("It's calm")
        XCTAssertFalse(refused)
        XCTAssertNotNil(coordinator.questionError)
        XCTAssertEqual(ChatView.squaddQuestion(in: model)?.prompt.question, "Why?", "a refused answer keeps the question")

        refuse = false
        let answered = await coordinator.answerQuestion("It's calm")
        XCTAssertTrue(answered)
        XCTAssertEqual(sent.last?["message"] as? String,
                       "The user answered your questions.\n\nQ: Which color?\nA: Blue\n\nQ: Why?\nA: It's calm")
        XCTAssertNil(coordinator.pendingQuestion)
    }

    /// Answered on the desktop, the question leaves the phone when its patch arrives.
    func testQuestionAnsweredOnTheDesktopLeavesThePhone() async throws {
        let events = try Self.text("events-question.sse")
        let thread = questionThread
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/threads/\(thread)/messages"): return .reply(200, Data(#"{"messages":[],"hasMore":false}"#.utf8))
            case ("GET", _): return .hold
            default: return .reply(404, Data())
            }
        }
        let (model, coordinator) = makeChat(bot: questionBot, thread: thread)
        await model.loadMessages()
        let answered = try XCTUnwrap(events.range(of: "id: 1cda109b:244")).lowerBound
        SquaddChatFixture.stream(Data(events[..<answered].utf8))
        await waitUntil("the question shows") { coordinator.pendingQuestion != nil }
        SquaddChatFixture.stream(Data(events[answered...].utf8))
        await waitUntil("the desktop's answer takes the question away") { coordinator.pendingQuestion == nil }
    }

    private nonisolated static func json(_ request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody ?? request.httpBodyStream.map(read))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // MARK: - Helpers

    /// The recorded frames between two `: app <step>` lines (from the start, or to the end, without one).
    private static func frames(_ events: String, from: String? = nil, to: String? = nil) -> String {
        func at(_ step: String) -> String.Index { events.range(of: ": app \(step) ")!.lowerBound }
        return String(events[(from.map(at) ?? events.startIndex)..<(to.map(at) ?? events.endIndex)])
    }

    /// A captured request's JSON body.
    private static func fields(_ request: URLRequest?) throws -> [String: String] {
        let body = try XCTUnwrap(request.flatMap { $0.httpBody ?? $0.httpBodyStream.map(read) })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
    }

    // MARK: Files (#23), against uploads recorded from a real companion (origin/dev 9e05e3a04)

    /// A photo goes to `/api/attachments`, any other file (a voice note) to `/api/files`, each with
    /// its staged id as `uploadId`; the message then carries a tag per stored path, and the sent
    /// row shows them.
    func testSendUploadsEachFileToItsRouteAndTagsTheMessage() async throws {
        var uploads: [URLRequest] = []
        var sentText: String?
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/attachments"):
                uploads.append(request); return .reply(201, try! Self.fixture("attachment-upload.json"))
            case ("POST", "/api/files"):
                uploads.append(request); return .reply(201, try! Self.fixture("file-upload.json"))
            case ("POST", let path) where path?.hasSuffix("/messages") == true:
                let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
                sentText = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: String])?["text"]
                return .reply(202, try! Self.fixture("send-receipt.json"))
            case ("GET", "/api/events"): return .hold
            default: return .reply(404, Data())
            }
        }
        let (model, _) = makeChat(copies: BotAttachmentCopies())
        let photo = await model.uploadAttachment(data: Self.photo, filename: "foto.png")
        let note = await model.uploadAttachment(data: Data("RIFF....WAVEfmt ".utf8), filename: "voice-note-prova.wav")
        XCTAssertTrue(uploads.isEmpty, "staging keeps a local copy only")

        let outcome = await model.send("Ecco la foto e la nota vocale")

        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(uploads.map(\.url?.path), ["/api/attachments", "/api/files"])
        XCTAssertEqual(uploads[0].value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertEqual(uploads[1].value(forHTTPHeaderField: "Content-Type"), "audio/wav", "the type the computer stores as .wav")
        let query = uploads.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] }
        XCTAssertEqual(query[0].first { $0.name == "uploadId" }?.value, photo?.id.uuidString.lowercased())
        XCTAssertEqual(query[1].first { $0.name == "uploadId" }?.value, note?.id.uuidString.lowercased())
        XCTAssertEqual(query[1].first { $0.name == "name" }?.value, "voice-note-prova.wav")
        let text = try XCTUnwrap(sentText)
        XCTAssertTrue(text.hasPrefix("Ecco la foto e la nota vocale\n\n<attached-image path=\"/tmp/openmausbot-verify-data-BYYG9b/attachments/6f1c0d7e-1a2b-4c3d-8e9f-000000000023.png\""))
        XCTAssertTrue(text.hasSuffix("<attached-file path=\"/tmp/openmausbot-verify-data-BYYG9b/attachments/6f1c0d7e-1a2b-4c3d-8e9f-000000000024.wav\" name=\"voice-note-prova.wav\" />"))
        XCTAssertTrue(model.pendingAttachments.isEmpty, "sent files leave the composer")
        XCTAssertEqual(model.messages.last?.attachments?.map(\.name), ["foto.jpg", "voice-note-prova.wav"])
    }

    /// A file the companion didn't store keeps the message and every file in the composer, sends
    /// no words, and Send again uploads it under the same id, so a store that did land counts once.
    func testFailedUploadStaysInTheComposerAndSendRetriesIt() async throws {
        var refusesUpload = true
        var uploadIDs: [String?] = []
        var sends = 0
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/files"):
                uploadIDs.append(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "uploadId" }?.value)
                return refusesUpload ? .reply(507, Data(#"{"error":"attachment storage is full"}"#.utf8))
                    : .reply(201, try! Self.fixture("file-upload.json"))
            case ("POST", let path) where path?.hasSuffix("/messages") == true:
                sends += 1; return .reply(202, try! Self.fixture("send-receipt.json"))
            case ("GET", "/api/events"): return .hold
            default: return .reply(404, Data())
            }
        }
        let (model, _) = makeChat(copies: BotAttachmentCopies())
        await model.uploadAttachment(data: Data("RIFF....WAVEfmt ".utf8), filename: "voice-note-prova.wav")

        let failed = await model.send("Ascolta")

        XCTAssertEqual(failed, .kept, "the composer keeps the words")
        XCTAssertEqual(model.pendingAttachments.map(\.name), ["voice-note-prova.wav"], "the file stays staged")
        XCTAssertEqual(sends, 0, "no words go without their file")
        XCTAssertNotNil(model.sendErrorMessage)
        XCTAssertFalse(model.messages.contains { $0.role == "user" }, "the prompt leaves the transcript")

        refusesUpload = false
        let retried = await model.send("Ascolta")

        XCTAssertEqual(retried, .started)
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(uploadIDs.count, 2)
        XCTAssertEqual(uploadIDs[0], uploadIDs[1], "the retry stores under the same id")
        XCTAssertTrue(model.pendingAttachments.isEmpty)
        XCTAssertNil(model.sendErrorMessage)
    }

    /// A stored row's tags become its attachments, its words without them; a voice note's bytes
    /// come back in ranged reads, as the companion serves them (206 with `Content-Range`).
    func testStoredFilesShowAsAttachmentsAndAVoiceNotePlaysFromRangedReads() async throws {
        let note = Data((0..<(SquaddCompanionClient.attachmentChunkBytes + 2_044)).map { UInt8(truncatingIfNeeded: $0) })
        var ranges: [String?] = []
        let threadId = threadId
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/threads/\(threadId)/messages"):
                return .reply(200, try! Self.fixture("thread-attachments.json"))
            case ("GET", "/api/attachments/7ea1d668-e4e9-4782-8c51-4c5a91bcd6b0.wav"):
                let range = request.value(forHTTPHeaderField: "Range")
                ranges.append(range)
                let bounds = range!.dropFirst("bytes=".count).split(separator: "-").map { Int($0)! }
                let end = min(bounds[1], note.count - 1)
                return .reply(206, note[bounds[0]...end], headers: ["Content-Range": "bytes \(bounds[0])-\(end)/\(note.count)"])
            default: return .hold
            }
        }
        let (model, _) = makeChat()
        await model.loadMessages()

        let row = try XCTUnwrap(model.messages.first { $0.role == "user" })
        XCTAssertEqual(row.content, "Ecco la foto e la nota vocale")
        XCTAssertEqual(row.attachments?.map(\.name), ["foto.png", "voice-note-live.wav"])
        XCTAssertEqual(row.attachments?.map(\.isImage), [true, false])
        XCTAssertEqual(row.attachments?.last?.inferredIsAudio, true, "the note draws as a player")

        let played = await model.attachmentRawData(path: try XCTUnwrap(row.attachments?.last?.path))

        XCTAssertEqual(played, note)
        XCTAssertEqual(ranges, ["bytes=0-\(SquaddCompanionClient.attachmentChunkBytes - 1)",
                                "bytes=\(SquaddCompanionClient.attachmentChunkBytes)-\(2 * SquaddCompanionClient.attachmentChunkBytes - 1)"])
    }

    // MARK: Listen (#25), against `/api/tts` answers recorded from a real companion

    /// Listen reads a reply in the computer's voice: `prepare` splits it into utterances, `speak`
    /// voices each, and they play as one track. Leaving the app stops it.
    /// #25: a Squadd chat's composer dictates on the phone only; other chats keep their choice.
    func testOnlyASquaddChatDictatesOnThePhoneAlone() {
        let (squadd, _) = makeChat()
        let webui = ChatViewModel(session: SessionSummary(sessionId: "webui-session", title: "Prova"), server: server)

        XCTAssertTrue(squadd.dictatesOnDevice)
        XCTAssertFalse(webui.dictatesOnDevice)
    }

    func testListenSpeaksEachPreparedUtteranceAsOneTrackAndStopsInTheBackground() async throws {
        let reply = "## Fatto\n\nHo letto il file e ho trovato **tre** punti."
        var prepared: String?
        var spoken: [String] = []
        let clip = try Self.fixture("tts-speak.wav")
        SquaddChatFixture.handler = { request in
            let text = (request.httpBody ?? request.httpBodyStream.map(Self.read))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }?["text"]
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/tts/prepare"):
                prepared = text; return .reply(200, try! Self.fixture("tts-prepare.json"))
            case ("POST", "/api/tts/speak"):
                spoken.append(text ?? ""); return .reply(200, clip, headers: ["Content-Type": "audio/wav"])
            default: return .hold
            }
        }
        var played: Data?
        let player = ListenPlayerSpy()
        let (model, _) = makeChat(listen: { played = $0; return player })
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(role: "assistant", content: reply, timestamp: 1_770_000_002, messageId: "reply-1"),
            visibleIndex: 0, messagesOffset: 0))

        model.toggleListening(to: context)
        await model.listenPreparationTask?.value

        XCTAssertEqual(prepared, context.listenText)
        XCTAssertEqual(spoken, ["Fatto. Ho letto il file note.md e ho trovato tre punti.",
                                "Il primo riguarda la chiave «redacted 46 chars».",
                                "Il secondo è la data.", "Il terzo è il prezzo."])
        let track = try Self.audioFile(try XCTUnwrap(played, "the computer's voice plays"))
        XCTAssertEqual(track.length, 4 * (try Self.audioFile(clip).length), "one track, every utterance in order")
        XCTAssertEqual(model.listeningMessageID, "reply-1")

        model.stopSquaddListening()

        XCTAssertNil(model.listeningMessageID)
        XCTAssertEqual(player.stops, 1)
    }

    private static func audioFile(_ data: Data) throws -> AVAudioFile {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try data.write(to: url)
        return try AVAudioFile(forReading: url)
    }

    /// Opaque, so staging re-encodes it as JPEG, as it does a camera photo.
    private static let photo = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: {
        let format = UIGraphicsImageRendererFormat(); format.opaque = true; return format
    }()).pngData { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    /// The `/` panel's built-ins and skills once the chat loaded its catalog from `bots` and `config`,
    /// and the skills request's query.
    private func slashCatalog(bots: String, config: String) async throws -> (commands: [String], skills: [String], query: String?) {
        let botId = try XCTUnwrap(JSONDecoder().decode(SquaddBotList.self, from: Self.fixture(bots)).bots.first?.id)
        var query: String?
        SquaddChatFixture.handler = { request in
            switch request.url?.path {
            case "/api/bots/\(botId)/skills": query = request.url?.query; return .reply(200, try! Self.fixture("slash-skills.json"))
            case "/api/bots": return .reply(200, try! Self.fixture(bots))
            case "/api/instances": return .reply(200, try! Self.fixture("slash-instances.json"))
            case "/api/config": return .reply(200, try! Self.fixture(config))
            default: return .hold
            }
        }
        let (model, _) = makeChat(bot: botId)

        await model.loadSkillSlashSuggestions()

        XCTAssertNil(model.lastError)
        let scope = try XCTUnwrap(model.squaddSlashScope)
        return (scope.offeredBuiltins.map(\.name), model.composerSkillSuggestions.map(\.name), query)
    }

    private func makeChat(server: URL? = nil, bot: String? = nil, thread: String? = nil, retrying: XCTestExpectation? = nil,
                          copies: (any ChatDraftAttachmentStoring)? = nil,
                          listen: (@MainActor (Data) throws -> any ListenAudioPlaying)? = nil,
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
                                  streamingRevealTick: {}, renderOnDeviceSpeech: { _ in throw CancellationError() },
                                  listenAudioSession: ListenSessionSpy(), listenAudioPlayerFactory: listen,
                                  draftAttachmentStore: copies ?? ChatDraftAttachmentStore.shared, backend: .squadd(coordinator))
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
    enum Answer {
        case reply(Int, Data, headers: [String: String] = [:]), hold, offline
    }

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
        case .reply(let status, let data, let headers):
            respond(status: status, headers: headers)
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

    private func respond(status: Int, headers: [String: String] = [:]) {
        // Without a Content-Type URLSession holds the first 512 bytes to sniff one, so a lone small frame never arrives.
        let type = request.url?.path == "/api/events" ? "text/event-stream" : "application/json"
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": type].merging(headers) { $1 })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
}

@MainActor
private final class ListenPlayerSpy: ListenAudioPlaying {
    var onFinish: (@MainActor () -> Void)?
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 4
    var rate: Float = 1
    private(set) var stops = 0
    func prepareToPlay() {}
    func play() -> Bool { true }
    func pause() {}
    func stop() { stops += 1 }
}

private struct ListenSessionSpy: ListenAudioSessionControlling {
    func activate() {}
    func deactivate() {}
}

/// The recorded shell approval above the composer (#14). Photos only, for photo runs (`FOTO_DIR`).
@MainActor
final class SquaddApprovalPhotoTests: XCTestCase {
    override func tearDown() {
        URLProtocol.unregisterClass(SquaddChatFixture.self)
        SquaddChatFixture.reset()
        super.tearDown()
    }

    func testPhotoApprovalCard() async throws {
        let path = ProcessInfo.processInfo.environment["FOTO_DIR"]
        try XCTSkipIf(path == nil, "Only for photo runs")
        let dir = URL(fileURLWithPath: path!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let page = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Squadd/thread-approval-open.json"))
        SquaddChatFixture.handler = { request in
            request.url?.path.hasSuffix("/messages") == true ? .reply(200, page) : .hold
        }
        URLProtocol.registerClass(SquaddChatFixture.self)
        let chat = SquaddThreadChat(server: URL(string: "http://192.0.2.10:8810")!, token: "device-token",
                                    botId: "65f42659-c570-4b77-abec-5f2e1d43e9f5",
                                    threadId: "c68d3fac-e54a-4658-8a2a-26b15fbe47e5", title: "Approval fixture")
        let continuity = ChatContinuity()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ChatView(session: chat.session, server: chat.server, onAPIError: { _ in }, continuity: continuity, squaddThread: chat)
        })
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, continuity.model?.squaddTurn?.pendingApproval == nil {
            // test-wait: a photo, not a check; `ChatContinuity` isn't observable.
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(continuity.model?.squaddTurn?.pendingApproval)
        try await readyPhoto(of: window).write(to: dir.appendingPathComponent("14-a-approval-card.png"))
    }
}

/// The recorded question above the composer (#15). Photos only, for photo runs (`FOTO_DIR`).
@MainActor
final class SquaddQuestionPhotoTests: XCTestCase {
    override func tearDown() {
        URLProtocol.unregisterClass(SquaddChatFixture.self)
        SquaddChatFixture.reset()
        super.tearDown()
    }

    func testPhotoQuestionCard() async throws {
        let path = ProcessInfo.processInfo.environment["FOTO_DIR"]
        try XCTSkipIf(path == nil, "Only for photo runs")
        let dir = URL(fileURLWithPath: path!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let page = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Squadd/thread-question-open.json"))
        SquaddChatFixture.handler = { request in
            request.url?.path.hasSuffix("/messages") == true ? .reply(200, page) : .hold
        }
        URLProtocol.registerClass(SquaddChatFixture.self)
        let chat = SquaddThreadChat(server: URL(string: "http://192.0.2.10:8810")!, token: "device-token",
                                    botId: "fcfb2fc1-153d-47b4-a0bc-5e23ff873542",
                                    threadId: "a0d291da-61ad-4b75-abb4-fdc3db19f630", title: "Question fixture")
        let continuity = ChatContinuity()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ChatView(session: chat.session, server: chat.server, onAPIError: { _ in }, continuity: continuity, squaddThread: chat)
        })
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, continuity.model?.squaddTurn?.pendingQuestion == nil {
            // test-wait: a photo, not a check; `ChatContinuity` isn't observable.
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(continuity.model?.squaddTurn?.pendingQuestion)
        try await readyPhoto(of: window).write(to: dir.appendingPathComponent("15-a-question-card.png"))
    }
}
