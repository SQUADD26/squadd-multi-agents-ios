import UserNotifications
import XCTest
@testable import HermesMobile

/// Closed-app push on a Squadd computer (#30), against answers and an APNs payload recorded from an isolated
/// `openmausbot` (origin/dev 3d12c2fd7: fake-engine harness with phone push on, its companion, a stand-in relay).
/// The recording paired a phone with the companion at `server`, so the payload's `pairing` is that address's tag.
@MainActor
final class SquaddPushTests: XCTestCase {
    private let server = URL(string: "http://127.0.0.1:22020")!
    private let otherServer = URL(string: "http://192.0.2.20:8810")!

    override func tearDown() {
        SquaddHTTPFixture.handler = nil
        super.tearDown()
    }

    func testEnableRegistersTheTokenOnThatComputerAndForgetRemovesIt() async throws {
        var requests: [(method: String, path: String, body: [String: String]?)] = []
        SquaddHTTPFixture.handler = { request in
            let body = request.bodyStreamData.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
            requests.append((request.httpMethod ?? "", request.url?.path ?? "", body))
            return (200, try! Self.fixture(request.httpMethod == "DELETE" ? "push-device-none.json" : "push-device-registered.json"))
        }
        let remote = RemoteNotificationsSpy()
        let registrar = makeRegistrar(remote: remote, servers: [server])

        async let enabled: Void = registrar.enable(for: server)
        await remote.waitForRequest()
        await registrar.didRegisterForRemoteNotifications(deviceToken: Data([0xab, 0x01]))
        try await enabled
        await registrar.forget(server: server)

        XCTAssertEqual(requests.map(\.method), ["PUT", "DELETE"])
        XCTAssertEqual(requests.map(\.path), ["/api/push/device", "/api/push/device"])
        let body = try XCTUnwrap(requests.first?.body)
        XCTAssertEqual(body["platform"], "apns")
        XCTAssertEqual(body["token"], "ab01")
        XCTAssertEqual(body["environment"], "sandbox")
        XCTAssertEqual(body["pairing"], SquaddPush.pairingTag(for: server))
    }

    func testLaunchReRegistersTheTokenOnlyWherePushIsOn() async throws {
        var puts: [String] = []
        SquaddHTTPFixture.handler = { request in
            let host = request.url?.host ?? ""
            if request.httpMethod == "PUT" { puts.append(host) }
            let on = host == "127.0.0.1"
            return (200, try! Self.fixture(on ? "push-device-registered.json" : "push-device-none.json"))
        }
        let remote = RemoteNotificationsSpy()
        let registrar = makeRegistrar(remote: remote, servers: [server, otherServer])

        await registrar.refreshOnLaunch()
        await remote.waitForRequest()
        await registrar.didRegisterForRemoteNotifications(deviceToken: Data([0xcd]))

        XCTAssertEqual(puts, ["127.0.0.1"])
    }

    func testRecordedPushOpensItsThreadOnTheServerThatSentIt() throws {
        let userInfo = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.fixture("apns-done.json")) as? [String: Any])
        let payload = try XCTUnwrap(SquaddPushPayload(userInfo: userInfo))
        let servers = [account(otherServer), account(server)]

        let opened = try XCTUnwrap(SquaddPush.server(for: payload, among: servers))
        let link = try XCTUnwrap(SquaddThreadLink(url: XCTUnwrap(SquaddPush.threadLink(payload, server: opened).url)))

        XCTAssertEqual(opened, server)
        XCTAssertEqual(link.threadID, "6f85c7af-a71e-487f-8072-abd6b0765715")
        XCTAssertEqual(link.botID, "c813261f-bd3e-4d86-909c-27416feff813")
        XCTAssertEqual(link.server, server)
        XCTAssertNil(SquaddPush.server(for: payload, among: [account(otherServer)]), "a computer this iPhone doesn't know opens nothing")
    }

    func testNotificationExtensionLeavesASquaddPushUntouched() throws {
        let userInfo = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.fixture("apns-done.json")) as? [String: Any])
        let content = UNMutableNotificationContent()
        content.title = "Finch finished"
        content.userInfo = userInfo

        PushPreview.rewrite(content, candidates: [])

        XCTAssertEqual(content.title, "Finch finished")
        XCTAssertEqual(content.body, "")
    }

    // MARK: - Helpers

    private func makeRegistrar(remote: RemoteNotificationsSpy, servers: [URL]) -> SquaddPushRegistrar {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SquaddHTTPFixture.self]
        let session = URLSession(configuration: configuration)
        let clients = Dictionary(uniqueKeysWithValues: servers.map { ($0, SquaddCompanionClient(server: $0, token: "device-token", session: session)) })
        return SquaddPushRegistrar(remoteNotifications: remote, requestAuthorization: { true }, isAuthorized: { true },
                                   clients: { clients }, environment: .sandbox)
    }

    private func account(_ url: URL) -> ServerAccount {
        ServerAccount(id: url.absoluteString, urlString: url.absoluteString, displayName: url.host() ?? "", initials: "",
                      headerLogoColorHex: HeaderLogoColor.defaultHex, createdAt: .now, updatedAt: .now, kind: .squadd)
    }

    private nonisolated static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Squadd/\(name)"))
    }
}

/// Records the registrar asking APNs for a token, so a test can answer it.
@MainActor private final class RemoteNotificationsSpy: RemoteNotificationRegistering {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var requested = false

    func registerForRemoteNotifications() {
        requested = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func unregisterForRemoteNotifications() {}

    func waitForRequest() async {
        if requested { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private extension URLRequest {
    /// URLProtocol sees a body as a stream, not `httpBody`.
    var bodyStreamData: Data? {
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
