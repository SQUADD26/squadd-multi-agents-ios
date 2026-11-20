import SwiftUI
import XCTest
@testable import HermesMobile

/// Versions and reactions in a Squadd thread (#19), against a real `openmausbot` companion's answers
/// (`Fixtures/Squadd/squadd-v-*`, origin/dev 9e05e3a04, fake engine): the thread before and after an
/// edit, the edit's `/api/events` frames, a version switch and a ❤️ put on and taken off.
@MainActor
final class SquaddVersionsTests: XCTestCase {
    static let server = URL(string: "http://192.0.2.10:8810")!
    static let botId = "5dc5acdd-6246-4554-9a6c-ed433109b2e2"
    static let threadId = "77970d46-59b0-4ff8-9ed8-58cd35e34d83"
    static let firstPrompt = "3a1ba769-7652-48e2-9c61-767c20058076"
    static let editedPrompt = "1c2755ca-d744-4c27-8775-8fd5a5d8babd"
    static let firstReply = "37e610cd-58f8-451e-896a-296d21de6646"

    override func tearDown() {
        SquaddChatFixture.reset()
        super.tearDown()
    }

    func testAnEditShowsTheNewVersionAndThePickerGoesBackToTheFirst() async throws {
        var thread = "squadd-v-thread-v1.json"
        var edit: URLRequest?
        var branch: URLRequest?
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/threads/\(Self.threadId)/messages"):
                return .reply(200, try! Self.fixture(thread))
            case ("POST", "/api/bots/\(Self.botId)/messages/\(Self.firstPrompt)/edit"):
                edit = request
                thread = "squadd-v-thread-v2.json"
                return .reply(202, try! Self.fixture("squadd-v-edit-receipt.json"))
            case ("POST", "/api/bots/\(Self.botId)/active-branch"):
                branch = request
                thread = "squadd-v-thread-back-to-v1.json"
                return .reply(200, try! Self.fixture("squadd-v-active-branch.json"))
            case ("GET", "/api/events"):
                return .hold
            default:
                return .reply(404, Data())
            }
        }
        let (model, squadd) = makeChat()
        squadd.makeSendID = { "ios-prova-v2-0001" }
        await model.loadMessages()
        let prompt = try XCTUnwrap(model.messages.first { $0.content == "Scrivi tre parole" })
        XCTAssertNil(squadd.marks[prompt.id]?.versions, "one version: no picker")

        let context = try XCTUnwrap(model.actionContext(for: prompt, visibleIndex: 1))
        XCTAssertTrue(context.offersHistoryActions, "Edit Message is in the prompt's menu")
        let edited = await model.editMessage(context, newText: "Scrivi quattro parole")
        XCTAssertTrue(edited)
        let fields = try XCTUnwrap(edit.flatMap(Self.body))
        XCTAssertEqual(fields["text"] as? String, "Scrivi quattro parole")
        XCTAssertEqual(fields["threadId"] as? String, Self.threadId)
        XCTAssertNotNil(fields["sendId"] as? String)

        SquaddChatFixture.stream(try Self.fixture("squadd-v-edit-events.sse"), finish: true)
        await waitUntil("the reply to the new version is in") {
            model.activeStreamID == nil && squadd.marks.values.contains { $0.versions != nil }
        }
        // The new version keeps the row it showed on at once, as a send's prompt does.
        let newVersion = try XCTUnwrap(model.messages.first { $0.content == "Scrivi quattro parole" })
        XCTAssertEqual(squadd.storedID(ofRow: newVersion.id), Self.editedPrompt)
        XCTAssertFalse(model.messages.contains { $0.content == "Scrivi tre parole" }, "the old version is off screen")
        XCTAssertEqual(squadd.marks[newVersion.id]?.versions?.index, 1, "the picker reads 2 of 2")
        XCTAssertEqual(squadd.marks[newVersion.id]?.versions?.ids.count, 2)

        await squadd.showVersion(-1, ofRow: newVersion.id)
        XCTAssertEqual(try XCTUnwrap(branch.flatMap(Self.body))["messageId"] as? String, Self.firstPrompt)
        let first = try XCTUnwrap(model.messages.first { $0.messageId == Self.firstPrompt })
        XCTAssertEqual(first.content, "Scrivi tre parole")
        XCTAssertFalse(model.messages.contains { $0.content == "Scrivi quattro parole" })
        XCTAssertEqual(squadd.marks[first.id]?.versions?.index, 0, "the picker reads 1 of 2")
    }

    func testAReactionIsInTheMenuAndChoosingItAgainTakesItOff() async throws {
        var reactions: [[String: Any]] = []
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/threads/\(Self.threadId)/messages"):
                return .reply(200, try! Self.fixture("squadd-v-thread-v1.json"))
            case ("POST", "/api/threads/\(Self.threadId)/messages/\(Self.firstReply)/reactions"):
                reactions.append(Self.body(request) ?? [:])
                return .reply(200, try! Self.fixture(reactions.count == 1 ? "squadd-v-reaction-on.json" : "squadd-v-reaction-off.json"))
            default:
                return .hold
            }
        }
        let (model, squadd) = makeChat()
        await model.loadMessages()
        let reply = try XCTUnwrap(model.messages.first { $0.messageId == Self.firstReply })

        let heart = try XCTUnwrap(Self.reactionMenu(ofRow: reply.id, in: squadd)?.children.first { $0.title == "❤️" })
        XCTAssertFalse(heart.isOn)
        heart.perform()
        await waitUntil("the ❤️ shows under the reply") { squadd.marks[reply.id]?.reactions == [.init(emoji: "❤️", count: 1)] }
        XCTAssertEqual(reactions.first?["emoji"] as? String, "❤️")
        XCTAssertEqual(reactions.first?["on"] as? Bool, true)

        let again = try XCTUnwrap(Self.reactionMenu(ofRow: reply.id, in: squadd)?.children.first { $0.title == "❤️" })
        XCTAssertTrue(again.isOn, "the menu shows it checked")
        again.perform()
        await waitUntil("the ❤️ is gone") { squadd.marks[reply.id] == nil }
        XCTAssertEqual(reactions.last?["on"] as? Bool, false)
    }

    // MARK: - Helpers

    /// SwiftUI builds its accessibility tree only while an assistive technology is on: turn it on for this
    /// app, as AccessibilitySnapshot does, so a test reads what VoiceOver would.
    static func turnOnAccessibility() throws {
        let library = try XCTUnwrap(dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW))
        let symbol = try XCTUnwrap(dlsym(library, "_AXSApplicationAccessibilitySetEnabled"))
        unsafeBitCast(symbol, to: (@convention(c) (Bool) -> Void).self)(true)
    }

    /// Every accessibility element under `root`, as VoiceOver walks them: containers opened, leaves kept,
    /// each node once (SwiftUI's nodes can point back up the tree).
    static func accessibilityElements(in root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        var found: [NSObject] = []
        var queue = [root]
        while let node = queue.popLast(), seen.count < 5000 {
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            if node.isAccessibilityElement { found.append(node) }
            let children = (node.accessibilityElements as? [NSObject])
                ?? (0..<min(max(0, node.accessibilityElementCount()), 500)).compactMap { node.accessibilityElement(at: $0) as? NSObject }
            queue += children + ((node as? UIView)?.subviews ?? [])
        }
        return found
    }

    /// The React submenu, as the message's long-press menu shows it.
    static func reactionMenu(ofRow rowID: String, in squadd: SquaddChatTurnCoordinator) -> ChatMessageActionItem? {
        let item = ChatMessageActionItem.squaddReactions(ofRow: rowID, in: squadd, isEnabled: true)
        let menu = [item].compactMap { $0 }.uiMenu()
        guard let react = menu.children.first as? UIMenu, react.title == String(localized: "React"),
              react.children.count == SquaddReaction.all.count else { return nil }
        return item
    }

    private func makeChat() -> (ChatViewModel, SquaddChatTurnCoordinator) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SquaddChatFixture.self]
        let chat = SquaddThreadChat(server: Self.server, token: "device-token", botId: Self.botId, threadId: Self.threadId, title: "Prova")
        let coordinator = SquaddChatTurnCoordinator(chat, session: URLSession(configuration: configuration),
                                                    reconnectDelay: { _ in try await Task.sleep(for: .seconds(3600)) })
        addTeardownBlock { coordinator.stop() }
        let model = ChatViewModel(session: chat.session, server: Self.server, streamingRevealTick: {}, backend: .squadd(coordinator))
        return (model, coordinator)
    }

    nonisolated static func body(_ request: URLRequest) -> [String: Any]? {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var read = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                read.append(buffer, count: count)
            }
            data = read
        }
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    nonisolated static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Squadd/\(name)"))
    }
}

/// The chat on screen with the same answers: the picker after the edit, back on the first version, and
/// the ❤️ under the reply. Photos only, for photo runs (`FOTO_DIR`).
@MainActor
final class SquaddVersionsPhotoTests: XCTestCase {
    override func tearDown() {
        URLProtocol.unregisterClass(SquaddChatFixture.self)
        SquaddChatFixture.reset()
        super.tearDown()
    }

    func testPhotoVersionsAndReactions() async throws {
        let path = ProcessInfo.processInfo.environment["FOTO_DIR"]
        try XCTSkipIf(path == nil, "Only for photo runs")
        let dir = URL(fileURLWithPath: path!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var thread = "squadd-v-thread-v2.json"
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/threads/\(SquaddVersionsTests.threadId)/messages"):
                return .reply(200, try! SquaddVersionsTests.fixture(thread))
            case ("POST", "/api/bots/\(SquaddVersionsTests.botId)/active-branch"):
                thread = "squadd-v-thread-back-to-v1.json"
                return .reply(200, try! SquaddVersionsTests.fixture("squadd-v-active-branch.json"))
            case ("POST", "/api/threads/\(SquaddVersionsTests.threadId)/messages/\(SquaddVersionsTests.firstReply)/reactions"):
                return .reply(200, try! SquaddVersionsTests.fixture("squadd-v-reaction-on.json"))
            default:
                return .hold
            }
        }
        URLProtocol.registerClass(SquaddChatFixture.self)
        try SquaddVersionsTests.turnOnAccessibility()
        let chat = SquaddThreadChat(server: SquaddVersionsTests.server, token: "device-token", botId: SquaddVersionsTests.botId,
                                    threadId: SquaddVersionsTests.threadId, title: "Prova")
        let continuity = ChatContinuity()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ChatView(session: chat.session, server: chat.server, onAPIError: { _ in }, continuity: continuity, squaddThread: chat)
        })
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let model = try await settle { continuity.model?.messages.contains { $0.messageId == SquaddVersionsTests.editedPrompt } == true ? continuity.model : nil }
        let squadd = try XCTUnwrap(model.squaddTurn)
        try await readyPhoto(of: window).write(to: dir.appendingPathComponent("19-a-version-2-of-2.png"))
        try assertOnePicker(in: window, reads: "2 of 2")

        await squadd.showVersion(-1, ofRow: SquaddVersionsTests.editedPrompt)
        XCTAssertTrue(model.messages.contains { $0.messageId == SquaddVersionsTests.firstPrompt }, "back on the first version")
        try await readyPhoto(of: window).write(to: dir.appendingPathComponent("19-b-version-1-of-2.png"))
        try assertOnePicker(in: window, reads: "1 of 2")

        await squadd.toggleReaction("❤️", onRow: SquaddVersionsTests.firstReply)
        XCTAssertNotNil(squadd.marks[SquaddVersionsTests.firstReply])
        try await readyPhoto(of: window).write(to: dir.appendingPathComponent("19-c-reaction.png"))
        try assertOnePicker(in: window, reads: "1 of 2")
    }

    /// VoiceOver's view of the chat: the picker is one adjustable element, its arrows no elements of
    /// their own, and the reply under it, with reactions and no versions, adds no second one.
    private func assertOnePicker(in window: UIWindow, reads value: String, line: UInt = #line) throws {
        window.layoutIfNeeded()
        let elements = SquaddVersionsTests.accessibilityElements(in: window)
        let pickers = elements.filter { $0.accessibilityLabel == String(localized: "Version") }
        XCTAssertEqual(pickers.count, 1, "found: \(elements.compactMap(\.accessibilityLabel))", line: line)
        let picker = try XCTUnwrap(pickers.first, line: line)
        XCTAssertEqual(picker.accessibilityValue, value, line: line)
        XCTAssertTrue(picker.accessibilityTraits.contains(.adjustable), line: line)
    }

    /// The chat's model once `value` gives it, within 10 s: the view makes it as it appears.
    private func settle(_ value: () -> ChatViewModel?) async throws -> ChatViewModel {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, value() == nil {
            // test-wait: a photo, not a check; `ChatContinuity` isn't observable.
            try await Task.sleep(for: .milliseconds(50))
        }
        return try XCTUnwrap(value(), "the edited thread showed")
    }
}
