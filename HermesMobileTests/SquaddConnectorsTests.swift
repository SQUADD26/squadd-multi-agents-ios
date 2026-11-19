import XCTest
@testable import HermesMobile

/// Connected apps from the phone (#29), against responses recorded from a real `openmausbot`
/// companion (`Fixtures/Squadd/connectors-*.json`, origin/dev 3d12c2fd7, the repository's fake
/// connected-apps service `server/testing/broker-fake.ts`).
@MainActor
final class SquaddConnectorsTests: XCTestCase {
    private let recorder = Recorder()
    private var paths: [String] { recorder.requests.map { "\($0.httpMethod!) \($0.url!.path)" } }
    private var browsed: [URL] = []

    override func tearDown() {
        SquaddHTTPFixture.handler = nil
        super.tearDown()
    }

    func testCatalogAndConnectedAppsComeFromTheComputer() async {
        let model = model(connected: "connectors-connected.json")

        await model.load()

        XCTAssertEqual(Set(paths), ["GET /api/connectors/catalog", "GET /api/connectors/connected"])
        XCTAssertEqual(model.apps.count, 24)
        XCTAssertEqual(model.apps.filter(\.isConnected).map(\.slug), ["gmail"])
        XCTAssertEqual(model.apps.first { $0.slug == "gmail" }?.accounts.map(\.id), ["ca_gmail_1"])
    }

    func testAComputerWithoutConnectedAppsSaysSo() async {
        let model = model(catalog: "connectors-catalog-not-set-up.json", connected: "connectors-connected-empty.json")

        await model.load()

        XCTAssertEqual(model.state, .notSetUp)
    }

    func testConnectOpensTheServiceSignInThenRereadsTheList() async throws {
        var signedIn = false
        let model = model { request in
            switch request.url!.path {
            case "/api/connectors/gmail/authorize": return (200, Self.fixture("connectors-authorize.json"))
            case "/api/connectors/connected":
                return (200, Self.fixture(signedIn ? "connectors-connected.json" : "connectors-connected-empty.json"))
            default: return (200, Self.fixture("connectors-catalog.json"))
            }
        }
        await model.load()
        let gmail = try XCTUnwrap(model.apps.first { $0.slug == "gmail" })
        XCTAssertFalse(gmail.isConnected)

        await model.connect(gmail) { [unowned self] link in
            browsed.append(link)
            signedIn = true // the person finished the sign-in on the service's page
        }

        XCTAssertEqual(browsed, [URL(string: "https://backend.composio.dev/link/trs_5/gmail")!])
        let authorize = try XCTUnwrap(recorder.requests.first { $0.httpMethod == "POST" })
        XCTAssertEqual(authorize.url?.path, "/api/connectors/gmail/authorize")
        XCTAssertEqual(authorize.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(model.apps.first { $0.slug == "gmail" }?.isConnected, true)
        XCTAssertNil(model.busyApp)
    }

    func testCancelledSignInLeavesTheAppAsTheComputerHasIt() async throws {
        // The service's page was opened and closed: the computer may hold a sign-in it started, never active.
        let pending = Data(#"{"configured":true,"services":{"gmail":{"connected":false,"pending":true,"status":"INITIATED","accounts":[{"id":"ca_gmail_9","status":"INITIATED"}]}}}"#.utf8)
        let model = model { request in
            switch request.url!.path {
            case "/api/connectors/gmail/authorize": return (200, Self.fixture("connectors-authorize.json"))
            case "/api/connectors/connected": return (200, pending)
            default: return (200, Self.fixture("connectors-catalog.json"))
            }
        }
        await model.load()

        await model.connect(try XCTUnwrap(model.apps.first { $0.slug == "gmail" })) { [unowned self] in browsed.append($0) }

        XCTAssertEqual(browsed.count, 1)
        XCTAssertEqual(model.apps.first { $0.slug == "gmail" }?.isConnected, false)
        XCTAssertNil(model.busyApp)
        XCTAssertNil(model.actionError)
    }

    func testRefusedSignInOpensNothingAndSaysWhy() async throws {
        let model = model { request in
            request.httpMethod == "POST" ? (409, Data(#"{"error":"managed connector unavailable"}"#.utf8))
                : (200, Self.fixture(request.url!.path.hasSuffix("/connected") ? "connectors-connected-empty.json" : "connectors-catalog.json"))
        }
        await model.load()

        await model.connect(try XCTUnwrap(model.apps.first)) { [unowned self] in browsed.append($0) }

        XCTAssertEqual(browsed, [])
        XCTAssertNotNil(model.actionError)
        XCTAssertNil(model.busyApp)
        XCTAssertEqual(paths.suffix(2).sorted(), ["GET /api/connectors/catalog", "GET /api/connectors/connected"]) // re-read after the refusal
    }

    func testDisconnectRemovesOnlyThatAccount() async throws {
        let model = model(connected: "connectors-connected.json")
        await model.load()
        let gmail = try XCTUnwrap(model.apps.first { $0.slug == "gmail" })

        await model.disconnect(try XCTUnwrap(gmail.accounts.first), of: gmail)

        XCTAssertTrue(paths.contains("DELETE /api/connectors/gmail/accounts/ca_gmail_1"))
        XCTAssertFalse(paths.contains("DELETE /api/connectors/gmail"))
    }

    // MARK: - Helpers

    private func model(catalog: String = "connectors-catalog.json", connected: String) -> SquaddConnectorsModel {
        model { request in
            request.httpMethod == "DELETE" ? (200, Data("{}".utf8))
                : (200, Self.fixture(request.url!.path.hasSuffix("/connected") ? connected : catalog))
        }
    }

    private func model(_ answer: @escaping (URLRequest) -> (Int, Data)) -> SquaddConnectorsModel {
        SquaddHTTPFixture.handler = { [recorder] request in
            recorder.record(request, body: nil)
            return answer(request)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SquaddHTTPFixture.self]
        let client = SquaddCompanionClient(server: URL(string: "http://192.0.2.10:8810")!, token: "device-token",
                                           session: URLSession(configuration: configuration))
        return SquaddConnectorsModel(client: client, onUnpaired: {})
    }

    private nonisolated static func fixture(_ name: String) -> Data {
        try! Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Squadd/\(name)"))
    }
}
