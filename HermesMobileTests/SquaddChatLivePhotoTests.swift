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

    /// Finds the companion through the tunnel, pushes the first agent thread's chat, and waits for it to load.
    private func openLiveChat(_ environment: [String: String], token: String, folder: URL,
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
        let bot = try XCTUnwrap(bots.first { !$0.tasks.isEmpty }, "the companion has an agent with a thread")
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
