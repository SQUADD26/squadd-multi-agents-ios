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
        defer { window.isHidden = true }

        // The thread may hold no row the chat shows yet, so loaded means a row or an error.
        let loaded = settle(seconds: 20) { continuity.model.map { !$0.isLoading && (!$0.messages.isEmpty || $0.errorMessage != nil) ? $0 : nil } ?? nil }
        if loaded == nil {
            note("not loaded: model \(continuity.model == nil ? "missing" : "on screen"), loading \(continuity.model?.isLoading ?? false), rows \(continuity.model?.messages.count ?? 0)")
            try? photograph(window, named: "7-squadd-chat-open", in: folder)
        }
        let model = try XCTUnwrap(loaded, "the thread loaded")
        note("transcript: \(model.messages.count) rows, error: \(model.errorMessage ?? "none")")
        try photograph(window, named: "7-squadd-chat-open", in: folder)

        let prompt = "Ciao dal simulatore iPhone: rispondimi parola per parola"
        let sending = Task { await model.send(prompt) }
        let shown = settle(seconds: 2) { model.messages.last?.content == prompt ? true : nil }
        note("prompt on screen before the companion answered: \(shown == true)")

        let partial = settle(seconds: 30) { () -> String? in
            guard model.activeStreamID != nil, let id = model.streamingAssistantMessageID,
                  let text = model.messages.first(where: { $0.messageId == id })?.content, text.count > 20 else { return nil }
            return text
        }
        note("partial reply: \(partial?.count ?? 0) characters")
        try photograph(window, named: "8-squadd-chat-streaming", in: folder)
        let outcome = await sending.value
        note("send outcome: \(outcome)")

        let reply = settle(seconds: 60) { () -> String? in
            guard model.activeStreamID == nil, let last = model.messages.last, last.role == "assistant",
                  last.content != model.messages.dropLast().last?.content else { return nil }
            return last.content
        }
        note("final reply: \(reply?.count ?? 0) characters: \(reply?.prefix(80) ?? "none")")
        note("rows: " + model.messages.map { "\($0.role ?? "?"):\($0.messageId ?? "?")" }.joined(separator: " "))
        try photograph(window, named: "9-squadd-chat-reply", in: folder)

        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(shown, true)
        let final = try XCTUnwrap(reply)
        let piece = try XCTUnwrap(partial)
        XCTAssertTrue(piece.count < final.count, "the reply arrived in pieces")
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

    /// Runs the main loop until `value` gives something or `seconds` pass.
    private func settle<T>(seconds: TimeInterval, _ value: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let found = value() { return found }
            // test-wait: a photo tool against a live server, not a check; the main loop must turn for the chat to draw.
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
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
