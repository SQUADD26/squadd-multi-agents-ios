import CryptoKit
import Foundation
import Network

/// An end-to-end route to one computer (`openmausbot/companion/src/e2e/README.md` §4–§9): a loopback listener on
/// `127.0.0.1`, where each accepted TCP connection becomes one yamux stream of a Noise session dialled through
/// Squadd Multi-Agents Relay. The app's HTTP stack talks to the listener as to any server, so chat, events and
/// attachments need nothing of their own.
final class SquaddE2ETunnel: @unchecked Sendable {
    enum Failure: Error, Equatable {
        /// Every relay node answered 4404: the computer isn't connected to the relay, or doesn't admit this phone.
        case offline
        /// No relay node could be reached.
        case relayUnreachable
        /// Message 2 failed, or the computer echoed a wrong `conn`: not the computer the QR pinned. Hard stop.
        case unverified
    }

    /// A WebSocket URL to dial and the prologue byte it uses; `hello` goes first on a relay.
    struct Route {
        let url: URL
        let transport: UInt8
        let hello: String?
    }

    static let loopbackHeader = "X-OMB-Loopback"

    let descriptor: SquaddE2E.Descriptor
    /// The pairing token while pairing, then the device token: what the psk and the relay admission come from.
    let credential: String
    /// Sent by the app on every request to the listener: other apps on this iPhone can reach `127.0.0.1` too.
    let secret = SquaddE2E.b64u(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    /// The computer removed this phone, inside the encryption (GoAway 3).
    var onRemoved: () -> Void = {}

    let queue = DispatchQueue(label: "squadd.e2e.tunnel")
    private let webSockets: URLSession
    private let relayURL: (String) -> URL
    private var listener: NWListener?
    /// The listener's port once `start()` returned.
    private(set) var port: UInt16?
    private var session: SquaddE2ESession?
    private var dialing: [(Result<SquaddE2ESession, Failure>) -> Void]?
    private var unverified = false

    init(descriptor: SquaddE2E.Descriptor, credential: String, webSockets: URLSession = .shared,
         relayURL: @escaping (String) -> URL = { URL(string: "wss://\($0)/v1/phone")! }) {
        self.descriptor = descriptor
        self.credential = credential
        self.webSockets = webSockets
        self.relayURL = relayURL
    }

    var routes: [Route] {
        guard let hostId = descriptor.hostId else { return [] }
        let adm = SquaddE2E.admission(credential: credential, hostId: hostId)
        let hello = #"{"t":"phone","v":1,"hid":"\#(SquaddE2E.b64u(hostId))","adm":"\#(SquaddE2E.b64u(adm))"}"#
        return descriptor.relays.map { Route(url: relayURL($0), transport: SquaddE2E.transportRelay, hello: hello) }
    }

    var psk: Data { SquaddE2E.psk(credential: credential, keyId: SquaddE2E.keyId(descriptor.transportKey)) }

    /// Starts the listener; the address the app sends requests to.
    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        queue.sync { self.listener = listener }
        self.port = port
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            session?.close()
            session = nil
        }
    }

    /// Opens the session now, so pairing can say why the computer can't be reached before it sends anything.
    func connect() async throws {
        let result: Result<SquaddE2ESession, Failure> = await withCheckedContinuation { continuation in
            queue.async { self.withSession { continuation.resume(returning: $0) } }
        }
        _ = try result.get()
    }

    // MARK: Session

    private func withSession(_ done: @escaping (Result<SquaddE2ESession, Failure>) -> Void) {
        if let session, session.isOpen { return done(.success(session)) }
        if unverified { return done(.failure(.unverified)) }
        if dialing != nil { dialing?.append(done); return }
        dialing = [done]
        dial(routes[...], sawOffline: false)
    }

    private func dial(_ remaining: ArraySlice<Route>, sawOffline: Bool) {
        guard let route = remaining.first else {
            return finishDial(.failure(sawOffline ? .offline : .relayUnreachable))
        }
        let session = SquaddE2ESession(route: route, tunnel: self, webSockets: webSockets)
        session.open { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .ready:
                self.session = session
                self.finishDial(.success(session))
            case .unverified:
                self.unverified = true
                self.finishDial(.failure(.unverified))
            case .closed(let code):
                self.dial(remaining.dropFirst(), sawOffline: sawOffline || code == 4404)
            }
        }
    }

    private func finishDial(_ result: Result<SquaddE2ESession, Failure>) {
        let waiting = dialing ?? []
        dialing = nil
        waiting.forEach { $0(result) }
    }

    func sessionEnded(_ ended: SquaddE2ESession, removed: Bool) {
        if session === ended { session = nil }
        if removed { onRemoved() }
    }

    // MARK: Loopback

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        var head = Data()
        let deadline = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + 2, execute: deadline)
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024 - head.count) { [weak self] data, _, isComplete, error in
                guard let self else { return connection.cancel() }
                head += data ?? Data()
                if let end = head.range(of: Data("\r\n\r\n".utf8)) {
                    deadline.cancel()
                    guard Self.admits(head[..<end.lowerBound], secret: self.secret, credential: self.credential) else { return connection.cancel() }
                    self.bridge(connection, first: head)
                } else if error != nil || isComplete || head.count >= 16 * 1024 {
                    deadline.cancel()
                    connection.cancel()
                } else {
                    read()
                }
            }
        }
        read()
    }

    /// Only this app may open a stream: the request head carries `X-OMB-Loopback: <secret>`, or the device token
    /// as its bearer, which no other app holds. Both compared full-length.
    static func admits(_ head: Data, secret: String, credential: String) -> Bool {
        let accepted = [(loopbackHeader.lowercased() + ":", secret), ("authorization:", "Bearer " + credential)]
        return String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n").dropFirst().contains { line in
            accepted.contains { name, expected in
                guard line.lowercased().hasPrefix(name) else { return false }
                return same(line.dropFirst(name.count).trimmingCharacters(in: .whitespaces), expected)
            }
        }
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        let (a, b) = (Array(a.utf8), Array(b.utf8))
        return a.count == b.count && zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func bridge(_ connection: NWConnection, first: Data) {
        withSession { result in
            guard case .success(let session) = result else {
                let reply = "HTTP/1.1 502 Bad Gateway\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
                return connection.send(content: Data(reply.utf8), isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            }
            session.carry(connection, first: first)
        }
    }
}
