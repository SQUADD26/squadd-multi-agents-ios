import XCTest
@testable import HermesMobile

/// The presence ping (#33): what it sends to a real `openmausbot` companion
/// (`Fixtures/Squadd/presence.json`, its recorded answer) and when it is sent.
@MainActor
final class SquaddPresenceTests: XCTestCase {
    private let server = URL(string: "http://192.0.2.10:8810")!

    override func tearDown() {
        SquaddHTTPFixture.handler = nil
        super.tearDown()
    }

    func testPingTellsTheComputerThePhoneIsHere() async throws {
        var seen: URLRequest?
        SquaddHTTPFixture.handler = { request in
            seen = request
            return (200, try! Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/Squadd/presence.json")))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SquaddHTTPFixture.self]
        let client = SquaddCompanionClient(server: server, token: "device-token", session: URLSession(configuration: configuration))

        try await client.presenceActive(timeZone: "Europe/Rome", language: "pt-BR")

        let request = try XCTUnwrap(seen)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/presence/active")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
        XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
        let body = try XCTUnwrap(request.httpBody ?? request.httpBodyStream.map(Self.read))
        let sent = try JSONDecoder().decode([String: String].self, from: body)
        XCTAssertEqual(sent["source"], "phone", "only a phone's ping counts as the phone")
        XCTAssertEqual(sent["timeZone"], "Europe/Rome")
        XCTAssertEqual(sent["language"], "pt-br", "the companion takes the tag in lower case")
    }

    func testPingsOnArrivalThenEveryMinuteUntilTheAppLeaves() async {
        var pings = 0
        var waits: [Duration] = []
        // The third wait is where the app left the foreground: the task is cancelled there.
        await SquaddPresence.keepAlive(ping: { pings += 1 }, sleep: { duration in
            waits.append(duration)
            if waits.count == 3 { throw CancellationError() }
        })
        XCTAssertEqual(pings, 3, "one ping on arrival, one after each minute, none after leaving")
        XCTAssertEqual(waits, [.seconds(60), .seconds(60), .seconds(60)])
    }

    func testNoPingOnceTheForegroundTaskIsCancelledAndAFailedPingKeepsGoing() async {
        // Cancelled before it runs, as when the scene leaves the foreground: the task can't start
        // before this main-actor test suspends.
        let task = Task { @MainActor () -> Int in
            var pings = 0
            await SquaddPresence.keepAlive(ping: { pings += 1 }, sleep: { _ in try Task.checkCancellation() })
            return pings
        }
        task.cancel()
        let pings = await task.value
        XCTAssertEqual(pings, 0, "a background scene pings nothing")

        var attempts = 0
        await SquaddPresence.keepAlive(ping: {
            attempts += 1
            throw SquaddError.status(503)
        }, sleep: { _ in if attempts == 2 { throw CancellationError() } })
        XCTAssertEqual(attempts, 2, "a computer that didn't answer gets the next minute's ping")
    }

    private nonisolated static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
