import SwiftData
import SwiftUI
import XCTest
@testable import HermesMobile

/// The real app against a real `openmausbot serve --relay` server, through a relay reached over a public tunnel
/// (`docs/agents/live-companion.md`): it scans the server's relay-only QR, pairs end to end through the relay, lists
/// the agents and photographs the home. Runs only when `SQUADD_RELAY_LIVE_LOOKUP` names the gist holding the relay's
/// address and a fresh QR link, one per line.
@MainActor
final class SquaddRelayLiveTests: XCTestCase {
    func testRelayQRPairsAndListsTheAgents() async throws {
        let environment = ProcessInfo.processInfo.environment
        let lookup = environment["SQUADD_RELAY_LIVE_LOOKUP"].flatMap(URL.init(string:))
        try XCTSkipIf(lookup == nil, "Only for the live relay run")
        let folder = URL(fileURLWithPath: environment["BRAND_PHOTOS_DIR"] ?? NSTemporaryDirectory())
        var notes: [String] = []
        defer { try? notes.joined(separator: "\n").write(to: folder.appendingPathComponent("relay-live.txt"), atomically: true, encoding: .utf8) }

        let keychain = InMemoryKeychainStore()
        let manager = AuthManager(keychain: keychain, headerStore: CustomHeaderStore(),
                                  serverRegistry: ServerRegistry.inMemory(keychain: keychain),
                                  hermesConnections: HermesConnections(), preferences: .ephemeral(), forgetPush: { _ in })
        var paired: SquaddPairingInvite?
        // The tunnel's address and the one-time QR both change: read them again until one pairing goes through.
        for attempt in 1...16 where paired == nil {
            let (data, _) = try await URLSession.shared.data(from: lookup!)
            struct Gist: Decodable { let files: [String: File]; struct File: Decodable { let content: String } }
            let lines = try JSONDecoder().decode(Gist.self, from: data).files.values.first?.content
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            guard lines.count == 2, let relay = URL(string: lines[0]) else { continue }
            SquaddRelay.shared.makeTunnel = { descriptor, credential in
                SquaddE2ETunnel(descriptor: descriptor, credential: credential, relayURL: { _ in relay.appendingPathComponent("v1/phone") })
            }
            do {
                let invite = try SquaddPairingInvite.scanned(lines[1]).get()
                try await manager.pairSquadd(invite, deviceName: "iPhone relay live")
                paired = invite
                notes.append("paired on attempt \(attempt) as \(invite.server.absoluteString)")
            } catch {
                notes.append("attempt \(attempt): \(error)")
                // test-wait: a live tunnel or QR moving on, not a check.
                try await Task.sleep(for: .seconds(15))
            }
        }
        let invite = try XCTUnwrap(paired, "the relay-only QR paired")
        XCTAssertTrue(SquaddRelay.isRelayIdentity(invite.server))
        let token = try XCTUnwrap(manager.squaddToken(for: invite.server), "the device token is saved")
        XCTAssertEqual(manager.squaddRoutes(for: invite.server).e2e, invite.e2e, "the pinned key is kept for the next launch")

        let route = try await SquaddRelay.shared.open(server: invite.server, descriptor: try XCTUnwrap(invite.e2e), credential: token)
        XCTAssertEqual(route.kind, .relay)
        let bots = try await SquaddCompanionClient(server: invite.server, token: token).botList()
        notes.append("agents through the relay with the device's own keys: \(bots.bots.map { $0.name ?? $0.id })")

        let container = try ModelContainer(for: CachedSession.self, CachedMessage.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: SquaddRoute(authManager: manager, server: invite.server) { EmptyView() }
            .modelContainer(container))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        // test-wait: the home walks to the relay route and loads the agents through it.
        try await Task.sleep(for: .seconds(4))
        try await readyPhoto(of: window, limit: .seconds(10)).write(to: folder.appendingPathComponent("relay-home.png"))
        SquaddRelay.shared.close(server: invite.server)
    }
}
