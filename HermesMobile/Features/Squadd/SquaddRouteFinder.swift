import Foundation
import Network
import Observation

/// Keeps the active Squadd computer on its best route while its home is on screen (#9): picks one on
/// arrival, again whenever the network changes (Wi-Fi to cellular and back), and when Bonjour finds the
/// computer on this Wi-Fi. Nothing is asked of the person; the home shows the route in use.
@MainActor @Observable
final class SquaddRouteFinder {
    let server: URL
    /// The route in use; nil while the first walk runs and when no route answered.
    private(set) var route: SquaddEndpoint?
    private(set) var isSearching = true

    /// What the home's route row says.
    enum Status: Equatable { case finding, connected(SquaddEndpoint.Kind), unreachable }

    var status: Status {
        if let route { return .connected(route.kind) }
        return isSearching ? .finding : .unreachable
    }

    @ObservationIgnored private let book: SquaddRouteBook
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var found: [SquaddEndpoint] = []
    @ObservationIgnored private var walk = 0

    init(server: URL, book: SquaddRouteBook, session: URLSession = .shared) {
        self.server = server
        self.book = book
        self.session = session
    }

    /// After the first `find()`: picks again on every network change and Bonjour find, until the calling
    /// task ends, and runs `moved` when the route in use changed.
    func follow(changes: AsyncStream<Void> = SquaddRouteFinder.networkChanges(),
                bonjour: AsyncStream<SquaddEndpoint>? = nil,
                moved: @escaping @MainActor () async -> Void = {}) async {
        let bonjour = bonjour ?? book.name.map(Self.bonjour(named:))
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for await _ in changes {
                    if await self.find() { await moved() }
                }
            }
            if let bonjour {
                group.addTask { @MainActor in
                    for await endpoint in bonjour where !self.found.contains(endpoint) {
                        self.found.append(endpoint)
                        // A Bonjour route only helps when nothing better answers.
                        if self.route == nil, await self.find() { await moved() }
                    }
                }
            }
        }
    }

    /// Walks the routes and keeps the best that answers. True when the route in use changed.
    @discardableResult
    func find() async -> Bool {
        walk += 1
        let mine = walk
        isSearching = true
        let picked = await SquaddRoutes.pick(book.candidates(server: server, found: found), session: session)
        // A newer walk (a second network change) owns the result.
        guard mine == walk, !Task.isCancelled else { return false }
        let moved = picked != route
        route = picked
        isSearching = false
        SquaddRoutes.shared.set(picked, for: server)
        return moved
    }

    /// One event per change of the network path after the first, such as Wi-Fi giving way to cellular.
    nonisolated static func networkChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            let last = Box<String>()
            monitor.pathUpdateHandler = { path in
                let key = "\(path.status)" + path.availableInterfaces.map { "\($0.type):\($0.name)" }.joined(separator: ",")
                if let previous = last.value, previous != key { continuation.yield() }
                last.value = key
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "squadd.route.path"))
        }
    }

    /// The computer named `name` as Bonjour finds it on this Wi-Fi (`_openmausbot._tcp`, `name=` in its
    /// TXT record), resolved to an address the app can dial. Browsing asks iOS for the local network
    /// permission, whose prompt carries `NSLocalNetworkUsageDescription`.
    nonisolated static func bonjour(named name: String) -> AsyncStream<SquaddEndpoint> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "squadd.route.bonjour")
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_openmausbot._tcp", domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard case .bonjour(let txt) = result.metadata, txt["name"] == name else { continue }
                    // IPv4 only: the companion advertises A records, and a link-local IPv6 address can't go in a URL.
                    let parameters = NWParameters.tcp
                    (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
                    let connection = NWConnection(to: result.endpoint, using: parameters)
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint,
                               let endpoint = endpoint(host: host, port: port.rawValue) {
                                continuation.yield(endpoint)
                            }
                            connection.cancel()
                        case .failed, .waiting:
                            connection.cancel()
                        default:
                            break
                        }
                    }
                    connection.start(queue: queue)
                }
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: queue)
        }
    }

    nonisolated static func endpoint(host: NWEndpoint.Host, port: UInt16) -> SquaddEndpoint? {
        let authority: String
        switch host {
        case .ipv4(let address):
            authority = "\(address)".split(separator: "%").first.map(String.init) ?? ""
        case .ipv6(let address):
            // A link-local address needs its zone, which a URL can't carry: the tailnet and LAN routes cover it.
            guard !address.isLinkLocal else { return nil }
            authority = "[\(String("\(address)".split(separator: "%").first ?? ""))]"
        case .name(let name, _):
            authority = name
        @unknown default:
            return nil
        }
        return URL(string: "http://\(authority):\(port)").flatMap { SquaddEndpoint(url: $0, kind: .bonjour, priority: 300) }
    }
}

/// The last path seen, touched only on the monitor's own serial queue.
private final class Box<Value>: @unchecked Sendable {
    var value: Value?
}
