import SwiftData
import SwiftUI
import XCTest
@testable import HermesMobile

/// A Squadd agent's Live Activity and Bot widget (#31). The turn is recorded from a real `openmausbot`
/// companion (origin/dev 961cb8133, fake engine in `hang` mode with an MCP elicitation the harness
/// asked about and allowed): `live-activity-*` in `Fixtures/Squadd/`.
@MainActor
final class SquaddLiveActivityTests: XCTestCase {
    private let server = URL(string: "http://192.0.2.10:8810")!
    private let otherServer = URL(string: "http://192.0.2.20:8810")!
    private let botId = "d379e8a5-40ce-451e-8330-d47048ccb917"
    private let threadId = "670e1277-8af6-4bd8-89e1-dc3380b08279"

    override func tearDown() {
        SquaddChatFixture.reset()
        SquaddHTTPFixture.handler = nil
        super.tearDown()
    }

    func testRecordedTurnWorksThenAsksThenWorksThenEndsTheActivity() async throws {
        let threadId = threadId
        SquaddChatFixture.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/threads/\(threadId)/messages"): .reply(200, Self.fixture("live-activity-thread-before.json"))
            case ("GET", "/api/events"): .hold
            default: .reply(404, Data())
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SquaddChatFixture.self]
        let activities = ActivityRecorder()
        let chat = SquaddThreadChat(server: server, token: "device-token", botId: botId, threadId: threadId, title: "Prova",
                                    botName: "Ricerche")
        let coordinator = SquaddChatTurnCoordinator(chat, session: URLSession(configuration: configuration), liveActivities: activities,
                                                    reconnectDelay: { _ in try await Task.sleep(for: .seconds(3600)) })
        addTeardownBlock { coordinator.stop() }

        let opened = expectation(description: "the event stream is open")
        SquaddChatFixture.didHold = { if $0.url?.path == "/api/events" { opened.fulfill() } }
        await coordinator.activate()
        await fulfillment(of: [opened], timeout: 5)
        SquaddChatFixture.stream(Self.fixture("live-activity-events.sse"))
        await waitUntil("the turn's end ends the activity") { activities.ended == [self.botId] }

        XCTAssertEqual(activities.shown.map { $0.ask }, [nil, "approval", nil], "working, the approval, working again")
        XCTAssertEqual(activities.shown.first?.bot, SquaddActivityBot(botId: botId, name: "Ricerche", threadId: threadId, server: server))
    }

    func testPushedStateDecodesAndItsTapOpensTheThreadOnTheComputerItStartedOn() throws {
        // `activityProps` version 1 as the control plane pushes it (`push-activity.ts`).
        let pushed = LiveActivityAttributes.ContentState(props: """
        {"version":1,"botId":"\(botId)","name":"Ricerche","color":"#7C5CFF","body":"cursor","mood":"needsYou","kind":"needsYou",\
        "ask":"approval","status":"Needs your approval","waiting":1,"since":1795156199676,"link":"openmausbot://chat/\(threadId)","answers":[]}
        """)
        let started = try XCTUnwrap(SquaddThreadLink(threadID: threadId, botID: botId, server: server).url)

        let props = try XCTUnwrap(SquaddBotActivityProps(pushed))
        let link = try XCTUnwrap(props.tapURL(startedAt: started.absoluteString).flatMap(SquaddThreadLink.init(url:)))

        XCTAssertTrue(props.needsYou)
        XCTAssertEqual(props.statusLine, "Needs your approval")
        XCTAssertEqual(link.threadID, threadId)
        XCTAssertEqual(link.server, server)
    }

    func testRegistrationGoesOnlyWherePushIsOnAndIsDeletedWhenNothingIsLeft() async throws {
        var requests: [(host: String, method: String, path: String, body: Data?)] = []
        let onHost = server.host
        SquaddHTTPFixture.handler = { request in
            requests.append((request.url?.host ?? "", request.httpMethod ?? "", request.url?.path ?? "", request.bodyData))
            let on = request.url?.host == onHost
            return (200, Self.fixture(on ? "push-device-registered.json" : "push-device-none.json"))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SquaddHTTPFixture.self]
        let session = URLSession(configuration: configuration)
        let clients = Dictionary(uniqueKeysWithValues: [server, otherServer].map {
            ($0, SquaddCompanionClient(server: $0, token: "device-token", session: session))
        })
        let activities = SquaddLiveActivities(clients: { clients })
        activities.startToken = "ab01"
        activities.tokens = [botId: (token: "cd02", server: server as URL?), "other-bot": (token: "ef03", server: otherServer as URL?)]

        await activities.syncNow()
        let put = try XCTUnwrap(requests.first { $0.method == "PUT" })
        activities.startToken = nil
        activities.tokens = [:]
        await activities.syncNow()

        XCTAssertEqual(requests.filter { $0.method != "GET" }.map { "\($0.host) \($0.method) \($0.path)" },
                       ["192.0.2.10 PUT /api/push/activity", "192.0.2.10 DELETE /api/push/activity"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(put.body)) as? [String: Any])
        XCTAssertEqual(body["scheme"] as? String, "openmausbot")
        XCTAssertEqual(body["startToken"] as? String, "ab01")
        XCTAssertEqual(body["activities"] as? [[String: String]], [["botId": botId, "token": "cd02"]], "only this computer's bot")
        XCTAssertEqual((body["headlines"] as? [String: String])?.values.allSatisfy { $0.contains("{name}") }, true)
        XCTAssertNotNil((body["statuses"] as? [String: Any])?["needsYou"])
    }

    func testSquaddAgentsFillTheBotWidgetWithTheirAvatarsAndASlotOpensTheAgentsChat() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = BotWidgetSnapshotFile(directory: directory)
        let kiwi = "f6b2d30c-6c88-403d-8ff8-4edc30531b55"

        await loadSquaddBotWidget(file: file, server: server, configured: [kiwi])

        let shown = try XCTUnwrap(file.read().servers.first)
        let slot = try XCTUnwrap(shown.bots.first { $0.title == "Kiwi" })
        XCTAssertEqual(shown.serverKey, BotHistoryCache.Scope.key(server))
        XCTAssertEqual(slot.profile, kiwi, "a slot names the agent's own chat")
        await waitUntil("the agent's avatar is drawn for the widget") {
            [false, true].allSatisfy { FileManager.default.fileExists(atPath: file.avatarURL(slot.avatar, dark: $0).path) }
        }
    }

    private nonisolated static func fixture(_ name: String) -> Data {
        try! Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Squadd/\(name)"))
    }
}

/// Reads `bots.json`, with Kiwi carrying the recorded avatar, through the home's model into `file`'s
/// Bot widget snapshot, whose `configured` threads a widget shows.
@MainActor func loadSquaddBotWidget(file: BotWidgetSnapshotFile, server: URL, configured: [String]) async {
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Squadd")
    let avatarPath = "/api/attachments/89144ba5-f349-4d34-87df-24def160fa8f.png"
    var bots = try! String(contentsOf: fixtures.appendingPathComponent("bots.json"), encoding: .utf8)
    bots.replaceSubrange(bots.range(of: #""avatarUrl": null"#)!, with: #""avatarUrl": "\#(avatarPath)""#)
    let avatar = try! Data(contentsOf: fixtures.appendingPathComponent("avatar.png"))
    SquaddHTTPFixture.handler = { request in
        switch request.url?.path {
        case "/api/bots": (200, Data(bots.utf8))
        case avatarPath: (200, avatar)
        default: (404, Data())
        }
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SquaddHTTPFixture.self]
    let key = BotHistoryCache.Scope.key(server)
    let widgets = BotWidgetPublisher(file: file, serverTitle: { _ in "Studio" }, reloadWidget: {},
                                     configuredBots: { configured.map { BotWidgetDestination(serverKey: key, profile: $0) } })
    let client = SquaddCompanionClient(server: server, token: "device-token", session: URLSession(configuration: configuration))
    await SquaddAgentListModel(client: client, widgets: widgets, onUnpaired: {}).load()
}

/// Observable, so a test waits on its calls.
@MainActor @Observable final class ActivityRecorder: SquaddLiveActivityDriving {
    private(set) var shown: [(bot: SquaddActivityBot, ask: String?)] = []
    private(set) var ended: [String] = []

    func show(_ bot: SquaddActivityBot, ask: String?) { shown.append((bot, ask)) }
    func end(botId: String) { ended.append(botId) }
}

private extension URLRequest {
    /// URLProtocol sees a body as a stream, not `httpBody`.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
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
}

/// Photos for review (#31): the agent's Live Activity on the Lock Screen and in the Dynamic Island,
/// working from the app's stream and waiting on an approval as the companion pushes it, and the Bot
/// widget with Squadd's agents. Skipped outside photo runs.
@MainActor
final class SquaddLiveActivityPhotoTests: XCTestCase {
    override func tearDown() {
        SquaddHTTPFixture.handler = nil
        super.tearDown()
    }

    /// r1: the Lock Screen cards and the Dynamic Island, working and asking; r2: the Bot widget,
    /// small and medium, as the home's read fills it.
    func testPhotoLiveActivityAndBotWidget() async throws {
        let path = ProcessInfo.processInfo.environment["FOTO_DIR"]
        try XCTSkipIf(path == nil, "Only for photo runs")
        let dir = URL(fileURLWithPath: path!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let working = SquaddBotActivityProps(botId: "b", name: "Ricerche", ask: nil, since: Date().addingTimeInterval(-74),
                                             link: "openmausbot://thread/t")
        let pushed = try XCTUnwrap(SquaddBotActivityProps(LiveActivityAttributes.ContentState(props: """
        {"version":1,"botId":"b","name":"Scrittura Web","color":"#7C5CFF","body":"cursor","mood":"needsYou","kind":"needsYou",\
        "ask":"approval","status":"Needs your approval","waiting":1,"since":\((Date().timeIntervalSince1970 - 12) * 1000),\
        "link":"openmausbot://chat/t","answers":[]}
        """)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 640)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.rootViewController = UIHostingController(rootView: VStack(spacing: 14) {
            ForEach([working, pushed], id: \.name) { props in
                SquaddBotActivityCard(props: props, isStale: false)
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            }
            ForEach([working, pushed], id: \.name) { props in
                HStack {
                    SquaddBotActivityMark(props: props, size: 22)
                    Spacer()
                    SquaddBotActivityCompactTrailing(props: props, isStale: false)
                }
                .padding(.horizontal, 8)
                .frame(width: 250, height: 37)
                .background(.black, in: Capsule())
            }
            HStack(spacing: 12) {
                SquaddBotActivityMark(props: pushed, size: 22)
                    .frame(width: 37, height: 37)
                    .background(.black, in: Circle())
                Text(verbatim: "minimal").font(.caption).foregroundStyle(.secondary)
            }
            SquaddBotActivityCard(props: pushed, isStale: false)
                .padding(20)
                .background(.black, in: RoundedRectangle(cornerRadius: 40))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [.indigo, .black], startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .dark))
        try await readyPhoto(of: window).write(to: dir.appendingPathComponent("r1-live-activity.png"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = BotWidgetSnapshotFile(directory: directory)
        let server = URL(string: "http://192.0.2.10:8810")!
        let threads = ["f6b2d30c-6c88-403d-8ff8-4edc30531b55", "5e423427-5373-4b0b-b212-0eb4f5c39be0",
                       "4a16f61d-ddfe-4a9a-87b9-54c02dfe44d1"]
        await loadSquaddBotWidget(file: file, server: server, configured: threads)
        let entities = try XCTUnwrap(file.read().servers.first).bots.map {
            BotWidgetEntity(serverKey: BotHistoryCache.Scope.key(server), bot: $0)
        }
        let rendered = { (entity: BotWidgetEntity) in
            let slot = entity.destination.flatMap { file.read().bot(serverKey: $0.serverKey, profile: $0.profile) }
            return slot.map { FileManager.default.fileExists(atPath: file.avatarURL($0.avatar, dark: false).path) } ?? false
        }
        await waitUntil("every agent's avatar is drawn") { entities.allSatisfy(rendered) }
        var small = BotWidgetConfigurationIntent(), medium = BotWidgetConfigurationIntent()
        small.bot = entities.first { $0.title == "Kiwi" }
        medium.bots = entities
        window.rootViewController = UIHostingController(rootView: VStack(spacing: 24) {
            BotWidgetView(entry: BotWidgetEntry(date: Date(), configuration: small, family: .systemSmall, file: file))
                .padding(16)
                .frame(width: 170, height: 170)
                .background(.background, in: RoundedRectangle(cornerRadius: 22))
            BotWidgetView(entry: BotWidgetEntry(date: Date(), configuration: medium, family: .systemMedium, file: file))
                .padding(16)
                .frame(width: 364, height: 170)
                .background(.background, in: RoundedRectangle(cornerRadius: 22))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.85))
        .environment(\.colorScheme, .light))
        try await readyPhoto(of: window).write(to: dir.appendingPathComponent("r2-bot-widget.png"))
    }
}
