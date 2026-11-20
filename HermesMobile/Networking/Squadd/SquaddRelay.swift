import Foundation

/// The relay tunnels this app holds, one per computer reached only through Squadd Multi-Agents Relay. Each
/// computer is known by `identity(hostId:)`, and `SquaddRoutes` sends its requests to the tunnel's listener.
final class SquaddRelay: @unchecked Sendable {
    static let shared = SquaddRelay()

    private let lock = NSLock()
    private var tunnels: [URL: SquaddE2ETunnel] = [:]
    var makeTunnel: (SquaddE2E.Descriptor, String) -> SquaddE2ETunnel = { SquaddE2ETunnel(descriptor: $0, credential: $1) }

    /// The name a relay-only computer is saved under: unique per host, and never resolvable, so nothing reaches
    /// it except through its tunnel.
    static func identity(hostId: Data) -> URL {
        URL(string: "https://h-\(hostId.map { String(format: "%02x", $0) }.joined()).e2e.invalid")!
    }

    static func isRelayIdentity(_ server: URL) -> Bool { server.host?.hasSuffix(".e2e.invalid") == true }

    /// The tunnel for `server` with `credential`'s keys, started once; its listener becomes the route.
    @discardableResult
    func open(server: URL, descriptor: SquaddE2E.Descriptor, credential: String) async throws -> SquaddEndpoint {
        if let tunnel = lock.withLock({ tunnels[server] }), tunnel.credential == credential, tunnel.descriptor == descriptor,
           let route = SquaddRoutes.shared.route(for: server), route.kind == .relay {
            return route
        }
        close(server: server)
        let tunnel = makeTunnel(descriptor, credential)
        let url = try await tunnel.start()
        guard let route = SquaddEndpoint(url: url, kind: .relay, priority: 0) else { throw SquaddError.invalidResponse }
        lock.withLock { tunnels[server] = tunnel }
        SquaddRoutes.shared.set(route, for: server)
        return route
    }

    /// Pairing waits for the session, so a computer that can't be reached says why.
    func connect(server: URL) async throws {
        try await lock.withLock({ tunnels[server] })?.connect()
    }

    func close(server: URL) {
        lock.withLock { tunnels.removeValue(forKey: server) }?.stop()
        if SquaddRoutes.shared.route(for: server)?.kind == .relay { SquaddRoutes.shared.set(nil, for: server) }
    }

    /// The listener's secret, for a request the app sends to it without a device token (pairing, health).
    func loopbackSecret(for url: URL?) -> String? {
        guard let url, url.host == "127.0.0.1" else { return nil }
        return lock.withLock { tunnels.values.first { $0.port.map(Int.init) == url.port }?.secret }
    }
}
