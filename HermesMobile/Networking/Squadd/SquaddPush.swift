import CryptoKit
import Foundation

/// Closed-app push on a Squadd companion, wire version 1 (`openmausbot/packages/phone-protocol/src/phone-push.ts`).
/// The phone registers its APNs token on its own computer with `PUT /api/push/device`; the computer sends a
/// content-free push through Squadd's relay: a title, a `kind` and opaque ids, never message text.
extension SquaddCompanionClient {
    /// `GET /api/push/device`: whether this iPhone is registered here, and whether the computer sends at all.
    func pushDevice() async throws -> SquaddPushAnswer {
        try JSONDecoder().decode(SquaddPushAnswer.self, from: await Self.send(pushRequest("GET"), session: session))
    }

    /// `PUT /api/push/device`: registers or updates this iPhone's APNs token, tagged with `pairing` so a tap
    /// opens the right computer. No `kinds`: the companion then pushes every kind.
    func registerPush(token: String, environment: PushEnvironment, pairing: String) async throws {
        var request = pushRequest("PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "platform": "apns", "token": token, "environment": environment.rawValue, "pairing": pairing,
        ])
        _ = try await Self.send(request, session: session)
    }

    /// `DELETE /api/push/device`: the computer stops pushing to this iPhone.
    func unregisterPush() async throws {
        _ = try await Self.send(pushRequest("DELETE"), session: session)
    }

    private func pushRequest(_ method: String) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("api/push/device"))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}

/// Every `/api/push/device` answer: `push` is `on`, `off` (the owner has not switched phone push on at the
/// computer) or `no-account`; `device` is this iPhone's registration, nil when it has none.
struct SquaddPushAnswer: Decodable, Equatable {
    let push: String?
    let isRegistered: Bool

    private enum CodingKeys: String, CodingKey { case push, device }

    init(push: String?, isRegistered: Bool) {
        self.push = push
        self.isRegistered = isRegistered
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        push = try? container.decodeIfPresent(String.self, forKey: .push)
        isRegistered = (try? container.decodeNil(forKey: .device)) == false
    }
}

/// What a Squadd push carries beside its title: `omb` (and its copy `body`) in the APNs payload.
struct SquaddPushPayload: Equatable {
    /// `approval`, `question`, `sign-in` or `done`; a kind added later still opens its thread.
    let kind: String
    let botId: String
    let threadId: String
    /// The tag this iPhone gave the computer (`SquaddPush.pairingTag`).
    let pairing: String?

    init?(userInfo: [AnyHashable: Any]) {
        guard let omb = (userInfo["omb"] ?? userInfo["body"]) as? [String: Any],
              let threadId = omb["threadId"] as? String, !threadId.isEmpty,
              let botId = omb["botId"] as? String else { return nil }
        kind = omb["kind"] as? String ?? ""
        self.botId = botId
        self.threadId = threadId
        pairing = omb["pairing"] as? String
    }
}

enum SquaddPush {
    /// The opaque tag (`PAIRING_TAG`, 8-64 of `[A-Za-z0-9_-]`) this iPhone gives one saved computer, echoed in
    /// every push. Derived from the address, so nothing is stored and the URL itself never leaves the phone.
    static func pairingTag(for server: URL) -> String {
        SHA256.hash(data: Data(server.absoluteString.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// A tapped notification: when it is a Squadd push, queues its thread on `AppIntentRouter` (which
    /// `ContentView` routes through `SquaddThreadLink`) and returns true, opening nothing when no configured
    /// computer sent it. False for any other notification.
    @MainActor static func openTapped(userInfo: [AnyHashable: Any], servers: [ServerAccount],
                                      router: AppIntentRouter = .shared) -> Bool {
        guard let payload = SquaddPushPayload(userInfo: userInfo) else { return false }
        if let server = server(for: payload, among: servers) {
            router.requestDeepLink(threadLink(payload, server: server).url)
        }
        return true
    }

    /// The thread a tapped push opens, on the server that sent it (`ContentView` switches there first).
    static func threadLink(_ payload: SquaddPushPayload, server: URL) -> SquaddThreadLink {
        SquaddThreadLink(threadID: payload.threadId, botID: payload.botId, server: server, kind: payload.kind)
    }

    /// The configured Squadd server a push names, or nil when none of them sent it.
    static func server(for payload: SquaddPushPayload, among servers: [ServerAccount]) -> URL? {
        servers.lazy.filter { $0.kind == .squadd }.compactMap { URL(string: $0.urlString) }
            .first { pairingTag(for: $0) == payload.pairing }
    }
}
