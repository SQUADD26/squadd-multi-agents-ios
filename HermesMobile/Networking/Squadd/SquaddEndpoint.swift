import Foundation
import Network

/// One way to reach a paired computer, as the companion lists them best first
/// (`openmausbot/companion/src/endpoints.ts`): its hosted HTTPS address, its tailnet name, its LAN
/// addresses, then its Bonjour host name.
struct SquaddEndpoint: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case hosted, tailnet, lan, bonjour
    }

    let url: URL
    let kind: Kind
    let priority: Int

    /// On the same network as the computer: what a feature that must not cross a shared Wi-Fi checks
    /// (the secret card does not start on a LAN route).
    var isLocal: Bool { kind == .lan || kind == .bonjour }

    /// Only a bare origin in the scheme its kind uses: a hosted route is HTTPS, every other one plain HTTP
    /// (`qrEndpoints` in `pairing-link.ts`). Nil for anything else, which the phone skips.
    init?(url: URL, kind: Kind, priority: Int) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == (kind == .hosted ? "https" : "http"),
              components.host?.isEmpty == false, components.user == nil, components.password == nil,
              components.path.isEmpty || components.path == "/", components.query == nil, components.fragment == nil,
              let origin = try? AuthManager.normalizedServerURL(from: url.absoluteString)
        else { return nil }
        self.url = origin
        self.kind = kind
        self.priority = priority
    }

    private enum CodingKeys: String, CodingKey { case url, kind, priority }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let endpoint = Self(url: try container.decode(URL.self, forKey: .url),
                                  kind: try container.decode(Kind.self, forKey: .kind),
                                  priority: try container.decode(Int.self, forKey: .priority))
        else { throw DecodingError.dataCorruptedError(forKey: .url, in: container, debugDescription: "not a companion route") }
        self = endpoint
    }
}

/// What this iPhone keeps per paired computer to find it again: the companion's routes from the
/// pairing and its name, which its Bonjour advert carries (`name=` in the TXT record).
struct SquaddRouteBook: Codable, Equatable {
    var name: String?
    var endpoints: [SquaddEndpoint]

    /// Every route worth a try, best first: the saved ones, the computer found by Bonjour, and the
    /// address it was paired at, which may be none of them (a typed address).
    func candidates(server: URL, found: [SquaddEndpoint]) -> [SquaddEndpoint] {
        let pairedAt = SquaddEndpoint(url: server, kind: Self.kind(of: server), priority: 250)
        var seen = Set<URL>()
        return (endpoints + found + [pairedAt].compactMap { $0 })
            .sorted { $0.priority < $1.priority }
            .filter { seen.insert($0.url).inserted }
    }

    /// The kind of an address with no list to say it: HTTPS is hosted, a tailnet name or a Tailscale
    /// address (100.64.0.0/10) is the tailnet, anything else the LAN.
    static func kind(of url: URL) -> SquaddEndpoint.Kind {
        let host = url.host?.lowercased() ?? ""
        if url.scheme?.lowercased() == "https" { return .hosted }
        if host.hasSuffix(".ts.net") { return .tailnet }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4, octets[0] == 100, (64...127).contains(octets[1]) { return .tailnet }
        return .lan
    }
}

/// The route each paired computer is reached by right now. `SquaddCompanionClient` sends every
/// request through it, so all Squadd screens follow a network change; until a route is found, the
/// address the computer was paired at.
final class SquaddRoutes: @unchecked Sendable {
    static let shared = SquaddRoutes()

    private struct Health: Decodable { let app: String? }

    private let lock = NSLock()
    private var routes: [URL: SquaddEndpoint] = [:]

    func route(for server: URL) -> SquaddEndpoint? {
        lock.withLock { routes[server] }
    }

    func set(_ endpoint: SquaddEndpoint?, for server: URL) {
        lock.withLock { routes[server] = endpoint }
    }

    /// Asks every candidate's `GET /api/health` at once and keeps the best one, in the companion's
    /// order, where a companion answers: 200 with `{"app": "openmausbot"}`, the identity the companion
    /// writes itself (`proxy.ts`). Anything else is not this computer at work: a tunnel's own 502 page
    /// while the computer sleeps, a captive portal, or no answer within `timeout`. The walk ends as
    /// soon as every better route has failed.
    static func pick(_ candidates: [SquaddEndpoint], session: URLSession = .shared,
                     timeout: TimeInterval = 4) async -> SquaddEndpoint? {
        let ordered = candidates.sorted { $0.priority < $1.priority }
        return await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, endpoint) in ordered.enumerated() {
                group.addTask {
                    var request = URLRequest(url: endpoint.url.appendingPathComponent("api/health"), timeoutInterval: timeout)
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    guard let (data, response) = try? await session.data(for: request),
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          let health = try? JSONDecoder().decode(Health.self, from: data) else { return (index, false) }
                    return (index, health.app == "openmausbot")
                }
            }
            var results = [Bool?](repeating: nil, count: ordered.count)
            for await (index, answered) in group {
                results[index] = answered
                // The best route still in the running: return once it answered and none above it is pending.
                guard let best = results.firstIndex(where: { $0 != false }) else { return nil }
                if results[best] == true {
                    group.cancelAll()
                    return ordered[best]
                }
            }
            return nil
        }
    }
}
