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

    func testSquaddAgentsFillTheBotWidgetAndASlotOpensTheAgentsChat() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = BotWidgetSnapshotFile(directory: directory)
        let publisher = BotWidgetPublisher(file: file, serverTitle: { _ in "Studio" }, reloadWidget: {}, configuredBots: { [] })
        let list = try JSONDecoder().decode(SquaddBotList.self, from: Self.fixture("bots.json"))
        let agents = list.bots.map(SquaddAgentSection.init(bot:))

        publisher.publish(agents, squaddServer: server)

        let shown = try XCTUnwrap(file.read().servers.first)
        let agent = try XCTUnwrap(agents.first { $0.threadID != nil })
        XCTAssertEqual(shown.serverKey, BotHistoryCache.Scope.key(server))
        XCTAssertEqual(shown.bots.first { $0.title == agent.name }?.profile, agent.threadID, "a slot names the agent's own chat")
    }

    private nonisolated static func fixture(_ name: String) -> Data {
        try! Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Squadd/\(name)"))
    }
}

/// Observable, so a test waits on its calls.
@MainActor @Observable private final class ActivityRecorder: SquaddLiveActivityDriving {
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

/// Photos for review (#31): the agent's Live Activity as the Lock Screen shows it, working from the
/// app's stream, then waiting on an approval as the companion pushes it. Skipped outside photo runs.
@MainActor
final class SquaddLiveActivityPhotoTests: XCTestCase {
    func testPhotoLiveActivityWorkingAndNeedsYou() async throws {
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
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 360)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.rootViewController = UIHostingController(rootView: VStack(spacing: 16) {
            ForEach([working, pushed], id: \.name) { props in
                SquaddBotActivityCard(props: props, isStale: false)
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [.indigo, .black], startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .dark))
        try await readyPhoto(of: window).write(to: dir.appendingPathComponent("r1-live-activity.png"))
    }
}
