import SwiftUI
import XCTest
@testable import HermesMobile

/// The Squadd chat (#11) against a live companion, photographed: the thread as it opens, the
/// reply halfway through its stream, and the finished reply, plus a log of what arrived when.
/// Runs only where the environment names a disposable companion (`SQUADD_LIVE_URL`,
/// `SQUADD_LIVE_TOKEN`) and a photo folder, such as a photo branch's workflow; skipped everywhere else.
@MainActor
final class SquaddChatLivePhotoTests: XCTestCase {
    func testPhotographALiveConversation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["BRAND_PHOTOS_DIR"],
              let token = environment["SQUADD_LIVE_TOKEN"], !token.isEmpty,
              environment["SQUADD_LIVE_URL"] != nil || environment["SQUADD_LIVE_LOOKUP"] != nil else {
            throw XCTSkip("Live photos only: a photo branch's workflow with a companion in the secrets.")
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var log: [String] = []
        let started = Date()
        func note(_ line: String) { log.append(String(format: "%6.2fs  ", Date().timeIntervalSince(started)) + line) }
        defer { try? log.joined(separator: "\n").write(to: folder.appendingPathComponent("squadd-live-log.txt"), atomically: true, encoding: .utf8) }

        let (window, model, _) = try await openLiveChat(environment, token: token, folder: folder, note: note)
        defer { window.isHidden = true }
        note("transcript: \(model.messages.count) rows, error: \(model.errorMessage ?? "none")")
        let firstPage = model.messages.count
        let pagedBack = await model.loadOlderMessages()
        note("older page: \(firstPage) rows, more before: \(pagedBack), after scrolling up: \(model.messages.count) rows")
        try await readyPhoto(of: window).write(to: folder.appendingPathComponent("7-squadd-chat-open.png"))

        let prompt = "Ciao dal simulatore iPhone: rispondimi parola per parola"
        let sending = Task { await model.send(prompt) }
        let shown = try await settle(seconds: 2) { model.messages.last?.content == prompt ? true : nil }
        note("prompt on screen before the companion answered: \(shown == true)")

        let partial = try await settle(seconds: 30) { () -> String? in
            guard model.activeStreamID != nil, let id = model.streamingAssistantMessageID,
                  let text = model.messages.first(where: { $0.messageId == id })?.content, text.count > 20 else { return nil }
            return text
        }
        note("partial reply: \(partial?.count ?? 0) characters")
        try photograph(window, named: "8-squadd-chat-streaming", in: folder)
        let outcome = await sending.value
        note("send outcome: \(outcome)")

        let reply = try await settle(seconds: 60) { () -> String? in
            guard model.activeStreamID == nil, let last = model.messages.last, last.role == "assistant",
                  last.content != model.messages.dropLast().last?.content else { return nil }
            return last.content
        }
        note("final reply: \(reply?.count ?? 0) characters: \(reply?.prefix(80) ?? "none")")
        note("fences in the reply: " + ["diff", "mermaid", "html", "swift"].filter { reply?.contains("```" + $0) == true }.joined(separator: ", "))
        note("rows: " + model.messages.map { "\($0.role ?? "?"):\($0.messageId ?? "?")" }.joined(separator: " "))
        try await readyPhoto(of: window, until: { model.activeStreamID == nil })
            .write(to: folder.appendingPathComponent("9-squadd-chat-reply.png"))

        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(shown, true)
        let final = try XCTUnwrap(reply)
        let piece = try XCTUnwrap(partial)
        XCTAssertTrue(piece.count < final.count, "the reply arrived in pieces")
    }

    /// #12: the reply goes on while the app is in the background and after a network change, and
    /// the chat comes back to it at the right place, each piece once. Log `squadd-reattach-log.txt`.
    func testPhotographAReplyResumedAfterBackground() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["BRAND_PHOTOS_DIR"],
              let token = environment["SQUADD_LIVE_TOKEN"], !token.isEmpty,
              environment["SQUADD_LIVE_URL"] != nil || environment["SQUADD_LIVE_LOOKUP"] != nil else {
            throw XCTSkip("Live photos only: a photo branch's workflow with a companion in the secrets.")
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var log: [String] = []
        let started = Date()
        func note(_ line: String) { log.append(String(format: "%6.2fs  ", Date().timeIntervalSince(started)) + line) }
        defer { try? log.joined(separator: "\n").write(to: folder.appendingPathComponent("squadd-reattach-log.txt"), atomically: true, encoding: .utf8) }
        let (window, model, chat) = try await openLiveChat(environment, token: token, folder: folder, note: note)
        defer { window.isHidden = true }
        func streamed() -> String? {
            model.streamingAssistantMessageID.flatMap { id in model.messages.first { $0.messageId == id } }?.content
        }

        let sending = Task { await model.send("Rispondimi a lungo: esco dall'app e torno") }
        let opening = try await settle(seconds: 30) { streamed().flatMap { $0.count > 40 ? $0 : nil } }
        let before = try XCTUnwrap(opening, "the reply started")
        try await readyPhoto(of: window).write(to: folder.appendingPathComponent("10-squadd-before-background.png"))
        model.suspendStreamForBackground()
        note("to the background with \(before.count) characters on screen")
        // test-wait: the app stays away while the companion goes on writing.
        try await Task.sleep(for: .seconds(4))
        await model.reconnectStreamIfNeeded()
        let back = try await settle(seconds: 20) { streamed().flatMap { $0.count > before.count + 40 ? $0 : nil } }
        note("back: \(back?.count ?? 0) characters, the first \(before.count) unchanged: \(back?.hasPrefix(before) == true)")
        try await readyPhoto(of: window).write(to: folder.appendingPathComponent("11-squadd-after-background.png"))
        await model.networkPathDidChange()
        note("network change: the stream reopened after the last frame seen")
        _ = await sending.value

        let reply = try await settle(seconds: 60) { () -> String? in
            guard model.activeStreamID == nil, let last = model.messages.last, last.role == "assistant" else { return nil }
            return last.content
        }
        let page = try await SquaddCompanionClient(server: chat.server, token: token).messages(threadId: chat.threadId)
        let stored = page.messages.last { $0.role == "bot" && $0.kind == "text" }?.text
        let storedCount = page.messages.filter { $0.text == reply && $0.role == "bot" }.count
        note("final reply: \(reply?.count ?? 0) characters, the stored reply: \(reply == stored), rows with it: \(model.messages.filter { $0.content == reply }.count) on screen, \(storedCount) stored")
        try await readyPhoto(of: window, until: { model.activeStreamID == nil })
            .write(to: folder.appendingPathComponent("12-squadd-resumed-reply.png"))

        XCTAssertEqual(back?.hasPrefix(before), true, "the reply goes on from where it was")
        XCTAssertEqual(reply, stored)
        XCTAssertEqual(model.messages.filter { $0.content == reply }.count, storedCount, "each stored reply shows once")
    }

    /// #13: two messages queued behind a running reply show with Steer and Delete; one deleted,
    /// one steered in; Stop ends the turn; Compact leaves its marker. Log `squadd-control-log.txt`.
    func testPhotographStopQueueAndCompact() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["BRAND_PHOTOS_DIR"],
              let token = environment["SQUADD_LIVE_TOKEN"], !token.isEmpty,
              environment["SQUADD_LIVE_URL"] != nil || environment["SQUADD_LIVE_LOOKUP"] != nil else {
            throw XCTSkip("Live photos only: a photo branch's workflow with a companion in the secrets.")
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var log: [String] = []
        let started = Date()
        func note(_ line: String) { log.append(String(format: "%6.2fs  ", Date().timeIntervalSince(started)) + line) }
        defer { try? log.joined(separator: "\n").write(to: folder.appendingPathComponent("squadd-control-log.txt"), atomically: true, encoding: .utf8) }
        let (window, model, chat) = try await openLiveChat(environment, token: token, folder: folder, note: note)
        defer { window.isHidden = true }
        func streamed() -> String? {
            model.streamingAssistantMessageID.flatMap { id in model.messages.first { $0.messageId == id } }?.content
        }
        func markers() -> Int { model.messages.filter { ChatMarkerMessageClassifier.classify($0) == .contextCompaction }.count }

        let sending = Task { await model.send("Rispondimi a lungo, poi ti fermo") }
        _ = try await settle(seconds: 30) { streamed().flatMap { $0.count > 20 ? $0 : nil } }
        _ = await model.submitStreamingMessage("Poi dimmi solo ok", behavior: .queue)
        _ = await model.submitStreamingMessage("Questo lo cancello", behavior: .queue)
        let queued = try await settle(seconds: 10) { model.queuedPromptMessages.count == 2 ? model.queuedPromptMessages : nil }
        note("queued behind the running reply: \(queued?.compactMap(\.content) ?? [])")
        try await readyPhoto(of: window).write(to: folder.appendingPathComponent("13-squadd-queued.png"))

        await model.deleteQueuedPrompt(try XCTUnwrap(queued?.last?.messageId))
        let left = try await settle(seconds: 10) { model.queuedPromptMessages.count == 1 ? model.queuedPromptMessages : nil }
        note("after Delete: \(left?.compactMap(\.content) ?? [])")
        await model.steerQueuedPrompt(try XCTUnwrap(left?.first?.messageId))
        let steered = try await settle(seconds: 10) {
            model.queuedPromptMessages.isEmpty && model.messages.contains { $0.role == "user" && $0.content == "Poi dimmi solo ok" } ? true : nil
        }
        note("after Steer: queue empty and the message in the running turn: \(steered == true), still running: \(model.activeStreamID != nil)")
        try await readyPhoto(of: window).write(to: folder.appendingPathComponent("14-squadd-steered.png"))

        let accepted = await model.cancelActiveStream()
        note("Stop accepted: \(accepted), still running until the stream says: \(model.activeStreamID != nil)")
        _ = await sending.value
        let stopped = try await settle(seconds: 20) { model.activeStreamID == nil ? true : nil }
        let shown = model.messages.last { $0.role == "assistant" }?.content ?? ""
        note("stopped: \(stopped == true), reply cut at \(shown.count) characters, error: \(model.sendErrorMessage ?? "none")")
        try await readyPhoto(of: window, until: { model.activeStreamID == nil })
            .write(to: folder.appendingPathComponent("15-squadd-stopped.png"))

        let before = markers()
        let result = await model.send("/compact")
        let compacted = try await settle(seconds: 30) { markers() > before ? markers() : nil }
        let page = try await SquaddCompanionClient(server: chat.server, token: token).messages(threadId: chat.threadId)
        note("Compact: \(result), markers on screen \(before) → \(compacted ?? before), stored markers \(page.messages.filter { $0.kind == "compaction" }.count)")
        try await readyPhoto(of: window).write(to: folder.appendingPathComponent("16-squadd-compacted.png"))

        XCTAssertEqual(queued?.count, 2)
        XCTAssertEqual(steered, true)
        XCTAssertTrue(accepted)
        XCTAssertEqual(stopped, true)
        XCTAssertNotNil(compacted, "the compaction marker shows")
    }

    /// #14: the agent asks to run a shell command, the card shows above the composer, Allow once goes
    /// to the companion and the card leaves; the run then goes on. Log `squadd-approval-log.txt`.
    func testPhotographALiveApproval() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["BRAND_PHOTOS_DIR"],
              let token = environment["SQUADD_LIVE_TOKEN"], !token.isEmpty,
              environment["SQUADD_LIVE_URL"] != nil || environment["SQUADD_LIVE_LOOKUP"] != nil else {
            throw XCTSkip("Live photos only: a photo branch's workflow with a companion in the secrets.")
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var log: [String] = []
        let started = Date()
        func note(_ line: String) { log.append(String(format: "%6.2fs  ", Date().timeIntervalSince(started)) + line) }
        defer { try? log.joined(separator: "\n").write(to: folder.appendingPathComponent("squadd-approval-log.txt"), atomically: true, encoding: .utf8) }

        let (window, model, _) = try await openLiveChat(environment, token: token, folder: folder, note: note)
        defer { window.isHidden = true }
        let turn = try XCTUnwrap(model.squaddTurn)
        let sending = Task { await model.send("Run echo hi") }
        let approval = try await settle(seconds: 60) { turn.pendingApproval }
        note("card: \(approval.map { "\($0.card.title ?? "?") / \($0.card.subtitle ?? "?") / \($0.content.choices)" } ?? "none")")
        try await readyPhoto(of: window).write(to: folder.appendingPathComponent("14-b-live-approval.png"))

        let answered = await turn.answerApproval(.once)
        note("answered: \(answered), error: \(turn.approvalError ?? "none"), card after: \(turn.pendingApproval == nil ? "gone" : "still there")")
        note("send outcome: \(await sending.value)")
        let finished = try await settle(seconds: 60) { model.activeStreamID == nil && model.messages.last?.role == "assistant" ? true : nil }
        note("run finished: \(finished == true), last: \(model.messages.last?.content?.prefix(80) ?? "none")")
        try await readyPhoto(of: window).write(to: folder.appendingPathComponent("14-c-live-after-allow.png"))

        // Always allow: the card offers it where the computer gives a grant key (a read-only MCP tool here); once
        // chosen, the same request runs on the next turn without a card.
        let again = Task { await model.send("Read the notes") }
        let grantable = try await settle(seconds: 60) { turn.pendingApproval?.content.choices.contains(.always) == true ? turn.pendingApproval : nil }
        note("second card: \(grantable.map { "\($0.card.subtitle ?? "?") / \($0.content.choices) / key \($0.card.allowKey ?? "none")" } ?? "none")")
        try await readyPhoto(of: window).write(to: folder.appendingPathComponent("14-d-live-always-allow.png"))
        let always = await turn.answerApproval(.always)
        note("always: \(always), error: \(turn.approvalError ?? "none"), card after: \(turn.pendingApproval == nil ? "gone" : "still there")")
        note("send outcome: \(await again.value)")
        _ = try await settle(seconds: 60) { model.activeStreamID == nil ? true : nil }

        let rows = model.messages.count
        let third = Task { await model.send("Read the notes once more") }
        var askedAgain = false
        let thirdDone = try await settle(seconds: 60) { () -> Bool? in
            if turn.pendingApproval != nil { askedAgain = true }
            return model.activeStreamID == nil && model.messages.count > rows + 1 && model.messages.last?.role == "assistant" ? true : nil
        }
        note("third run: \(await third.value), finished \(thirdDone == true), asked again: \(askedAgain), last: \(model.messages.last?.content?.prefix(80) ?? "none")")
        try await readyPhoto(of: window).write(to: folder.appendingPathComponent("14-e-live-granted-run.png"))

        XCTAssertNotNil(approval, "the companion's card showed")
        XCTAssertTrue(answered)
        XCTAssertEqual(finished, true, "the run went on after Allow")
        XCTAssertNotNil(grantable, "the companion offered Always allow")
        XCTAssertTrue(always)
        XCTAssertEqual(thirdDone, true)
        XCTAssertFalse(askedAgain, "the saved grant let the tool run without a card")
    }

    /// #15: the agent asks a question with options, the card shows above the composer, a tap answers it on the
    /// companion and the card leaves; the run then goes on. Log `squadd-question-log.txt`.
    func testPhotographALiveQuestion() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["BRAND_PHOTOS_DIR"],
              let token = environment["SQUADD_LIVE_TOKEN"], !token.isEmpty,
              environment["SQUADD_LIVE_URL"] != nil || environment["SQUADD_LIVE_LOOKUP"] != nil else {
            throw XCTSkip("Live photos only: a photo branch's workflow with a companion in the secrets.")
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var log: [String] = []
        let started = Date()
        func note(_ line: String) { log.append(String(format: "%6.2fs  ", Date().timeIntervalSince(started)) + line) }
        defer { try? log.joined(separator: "\n").write(to: folder.appendingPathComponent("squadd-question-log.txt"), atomically: true, encoding: .utf8) }

        let (window, model, _) = try await openLiveChat(environment, token: token, folder: folder, note: note)
        defer { window.isHidden = true }
        let turn = try XCTUnwrap(model.squaddTurn)
        let sending = Task { await model.send("Ask me a color") }
        let question = try await settle(seconds: 60) { ChatView.squaddQuestion(in: model) }
        let prompt = question?.prompt
        note("card: \(prompt.map { "\($0.question) / \($0.choices) / typed reply \($0.allowsTypedResponse)" } ?? "none")")
        try await readyPhoto(of: window).write(to: folder.appendingPathComponent("15-b-live-question.png"))

        let answered = await turn.answerQuestion(prompt?.choices.last ?? "")
        note("answered: \(answered), error: \(turn.questionError ?? "none"), card after: \(turn.pendingQuestion == nil ? "gone" : "still there")")
        note("send outcome: \(await sending.value)")
        let finished = try await settle(seconds: 60) { model.activeStreamID == nil && model.messages.last?.role == "assistant" ? true : nil }
        note("run finished: \(finished == true), last: \(model.messages.last?.content?.prefix(80) ?? "none")")
        try await readyPhoto(of: window).write(to: folder.appendingPathComponent("15-c-live-after-answer.png"))

        XCTAssertNotNil(question, "the companion's question showed")
        XCTAssertTrue(answered)
        XCTAssertNil(turn.pendingQuestion)
        XCTAssertEqual(finished, true, "the run went on after the answer")
    }

    /// #16: the companion's secret, sign-in and connector cards, each opened in its agent's chat over the tunnel's
    /// HTTPS route. The secret goes sealed to the computer's key, with the device id and key a QR pairing would have
    /// saved (`SQUADD_LIVE_PAIRING`; the simulator has no camera); Done answers the sign-in; the connector's sign-in
    /// link comes from the computer and the card leaves once it says the service is connected. Log `squadd-cards-log.txt`.
    func testPhotographLiveSecretSignInAndConnectorCards() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["BRAND_PHOTOS_DIR"],
              let token = environment["SQUADD_LIVE_TOKEN"], !token.isEmpty,
              let pairingJSON = environment["SQUADD_LIVE_PAIRING"],
              environment["SQUADD_LIVE_URL"] != nil || environment["SQUADD_LIVE_LOOKUP"] != nil else {
            throw XCTSkip("Live photos only: a photo branch's workflow with a companion in the secrets.")
        }
        struct Pairing: Decodable { let deviceId: String; let secretKey: String }
        let pairing = try JSONDecoder().decode(Pairing.self, from: Data(pairingJSON.utf8))
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var log: [String] = []
        let started = Date()
        func note(_ line: String) { log.append(String(format: "%6.2fs  ", Date().timeIntervalSince(started)) + line) }
        defer { try? log.joined(separator: "\n").write(to: folder.appendingPathComponent("squadd-cards-log.txt"), atomically: true, encoding: .utf8) }

        let (secretWindow, secretModel, secretChat) = try await openLiveChat(environment, token: token, folder: folder, agent: "Secret agent", note: note)
        let secretTurn = try XCTUnwrap(secretModel.squaddTurn)
        secretTurn.secretPairing = { SquaddSecretPairing(deviceId: pairing.deviceId, secretKey: Data(base64URL: pairing.secretKey)) }
        let secretCard = try await settle(seconds: 30) { ChatView.squaddCard(in: secretModel) }
        note("route: \(SquaddRoutes.shared.route(for: secretChat.server)?.kind.rawValue ?? SquaddRouteBook.kind(of: secretChat.server).rawValue), block: \(String(describing: secretTurn.secretBlock))")
        note("secret card: \(secretCard.map { "\($0.kind)" } ?? "none")")
        try await readyPhoto(of: secretWindow).write(to: folder.appendingPathComponent("16-e-live-secret-card.png"))
        let provided = await secretTurn.provideSecret("live-weather-key-0001")
        note("provided: \(provided), error: \(secretTurn.cardError ?? "none"), card after: \(secretTurn.pendingCard == nil ? "gone" : "still there")")
        secretWindow.isHidden = true

        let (signInWindow, signInModel, _) = try await openLiveChat(environment, token: token, folder: folder, agent: "Sign-in agent", note: note)
        let signInTurn = try XCTUnwrap(signInModel.squaddTurn)
        let signInCard = try await settle(seconds: 30) { ChatView.squaddCard(in: signInModel) }
        note("sign-in card: \(signInCard.map { "\($0.kind)" } ?? "none")")
        try await readyPhoto(of: signInWindow).write(to: folder.appendingPathComponent("16-f-live-sign-in-card.png"))
        let done = await signInTurn.finishSignIn()
        note("done: \(done), error: \(signInTurn.cardError ?? "none"), card after: \(signInTurn.pendingCard == nil ? "gone" : "still there")")
        signInWindow.isHidden = true

        let (connectorWindow, connectorModel, _) = try await openLiveChat(environment, token: token, folder: folder, agent: "Connector agent", note: note)
        let connectorTurn = try XCTUnwrap(connectorModel.squaddTurn)
        let connectorCard = try await settle(seconds: 30) { ChatView.squaddCard(in: connectorModel) }
        note("connector card: \(connectorCard.map { "\($0.kind)" } ?? "none")")
        try await readyPhoto(of: connectorWindow).write(to: folder.appendingPathComponent("16-g-live-connector-card.png"))
        // The system sheet Connect opens, on the companion's real link: the workflow photographs the simulator's screen
        // (the sheet is the system's, outside the app's windows) once `sheet-open` appears, and answers `sheet-shot`.
        let (probeWindow, session) = try WebAuthenticationProbe.open()
        var sheetFinished = false
        let sheet = Task {
            await connectorTurn.connect { try await SquaddCardInset.openSignInPage($0, in: session) }
            sheetFinished = true
        }
        _ = try await settle(seconds: 3) { sheetFinished ? true : nil }
        note("sheet: \(sheetFinished ? "closed by itself" : "open"), error: \(connectorTurn.cardError ?? "none")")
        let sheetOpen = !sheetFinished && connectorTurn.cardError == nil
        try Data().write(to: folder.appendingPathComponent("sheet-open"))
        let shot = try await settle(seconds: 20) {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("sheet-shot").path) ? true : nil
        }
        note("screen photographed: \(shot == true)")
        sheet.cancel()
        _ = try await settle(seconds: 5) { sheetFinished ? true : nil }
        probeWindow.isHidden = true

        // The person signing in on the sheet is what the companion's broker stands for.
        var link: URL?
        await connectorTurn.connect { link = $0 }
        note("sign-in link: \(link?.absoluteString ?? "none"), error: \(connectorTurn.cardError ?? "none")")
        let left = try await settle(seconds: 30) { connectorTurn.pendingCard == nil ? true : nil }
        note("after the check: error \(connectorTurn.cardError ?? "none"), card \(left == true ? "gone" : "still there")")
        try await readyPhoto(of: connectorWindow).write(to: folder.appendingPathComponent("16-h-live-after-connect.png"))
        connectorWindow.isHidden = true

        XCTAssertNotNil(secretCard)
        XCTAssertTrue(provided, "the computer opened and saved the phone's envelope")
        XCTAssertNotNil(signInCard)
        XCTAssertTrue(done)
        XCTAssertTrue(sheetOpen, "the system sheet opened on the companion's link and waited")
        XCTAssertEqual(link?.host, "connect.composio.dev")
        XCTAssertEqual(left, true, "connected, the card left")
    }

    /// Finds the companion through the tunnel, pushes the first agent thread's chat (of the agent named `agent`, if
    /// given), and waits for it to load.
    private func openLiveChat(_ environment: [String: String], token: String, folder: URL, agent: String? = nil,
                              note: (String) -> Void) async throws -> (UIWindow, ChatViewModel, SquaddThreadChat) {
        // A free tunnel's address changes every few minutes: read it again until the companion answers.
        var address: URL?
        var bots: [SquaddBot] = []
        for attempt in 1...16 where address == nil {
            guard let candidate = try await Self.liveAddress(environment) else { continue }
            do {
                bots = try await SquaddCompanionClient(server: candidate, token: token).bots()
                address = candidate
            } catch {
                note("agents, attempt \(attempt): \(error)")
                // test-wait: a live tunnel moving to its next address, not a check.
                try await Task.sleep(for: .seconds(15))
            }
        }
        let server = try XCTUnwrap(address, "the companion answered")
        let bot = try XCTUnwrap(bots.first { !$0.tasks.isEmpty && (agent == nil || $0.name == agent) }, "the companion has an agent with a thread")
        let thread = try XCTUnwrap(bot.tasks.first)
        note("agent \(bot.name ?? bot.id), thread \(thread.threadId)")
        let chat = SquaddThreadChat(server: server, token: token, botId: bot.id, threadId: thread.threadId,
                                    title: thread.title.flatMap { $0.isEmpty ? nil : $0 } ?? bot.name)
        let continuity = ChatContinuity()
        // Pushed once the list shows, as a tap in `SquaddServerHome` does: the chat loads when its push completes.
        let window = try show(PushedChat(chat: chat) { chat in
            ChatView(session: SessionSummary(sessionId: chat.threadId, title: chat.title), server: server,
                     onAPIError: { _ in }, continuity: continuity, squaddThread: chat)
        })

        // The thread may hold no row the chat shows yet, so loaded means a row or an error.
        let loaded = try await settle(seconds: 20) { continuity.model.map { !$0.isLoading && (!$0.messages.isEmpty || $0.errorMessage != nil) ? $0 : nil } ?? nil }
        if loaded == nil {
            note("not loaded: model \(continuity.model == nil ? "missing" : "on screen"), loading \(continuity.model?.isLoading ?? false), rows \(continuity.model?.messages.count ?? 0)")
            try? photograph(window, named: "7-squadd-chat-open", in: folder)
            if let model = continuity.model {
                note("the view asked for the transcript: \(continuity.didLoadMessages)")
                await model.loadMessages()
                note("loaded by hand: rows \(model.messages.count), error \(model.errorMessage ?? "none")")
            }
        }
        let model = try XCTUnwrap(loaded, "the thread loaded")
        return (window, model, chat)
    }

    /// `SQUADD_LIVE_URL`, or the address the gist at `SQUADD_LIVE_LOOKUP` (GitHub's gist API) holds now.
    private static func liveAddress(_ environment: [String: String]) async throws -> URL? {
        if let fixed = environment["SQUADD_LIVE_URL"] { return URL(string: fixed) }
        guard let lookup = environment["SQUADD_LIVE_LOOKUP"].flatMap(URL.init(string:)) else { return nil }
        let (data, _) = try await URLSession.shared.data(from: lookup)
        struct Gist: Decodable { let files: [String: File]; struct File: Decodable { let content: String } }
        let text = try JSONDecoder().decode(Gist.self, from: data).files.values.first?.content
        return text.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func show(_ view: some View) throws -> UIWindow {
        // On the host app's scene, or the window never draws.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }

    /// Waits until `value` gives something or `seconds` pass. `Task.sleep`, not the run loop, so the
    /// chat's own async work (its `.task` loads) runs meanwhile.
    private func settle<T>(seconds: TimeInterval, _ value: () -> T?) async throws -> T? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let found = value() { return found }
            // test-wait: a photo tool against a live server, not a check.
            try await Task.sleep(for: .milliseconds(50))
        }
        return value()
    }

    private func photograph(_ window: UIWindow, named name: String, in folder: URL) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent("\(name).png"))
    }
}

/// A navigation stack that pushes `chat` after it first appears.
private struct PushedChat<Chat: View>: View {
    let chat: SquaddThreadChat
    @ViewBuilder let destination: (SquaddThreadChat) -> Chat
    @State private var path: [SquaddThreadChat] = []

    var body: some View {
        NavigationStack(path: $path) {
            Color.clear
                .navigationDestination(for: SquaddThreadChat.self, destination: destination)
                .onAppear { if path.isEmpty { path = [chat] } }
        }
    }
}
