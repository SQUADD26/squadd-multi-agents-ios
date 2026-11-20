import CryptoKit
import Foundation
import Network

/// One WebSocket of a `SquaddE2ETunnel`, and the Noise session and yamux on it. Runs on the tunnel's queue.
final class SquaddE2ESession {
    enum Outcome { case ready, unverified, closed(Int) }

    private let route: SquaddE2ETunnel.Route
    private weak var tunnel: SquaddE2ETunnel?
    private let queue: DispatchQueue
    private let task: URLSessionWebSocketTask
    private let mux = SquaddYamux()
    private var keys: SquaddE2E.SessionKeys?
    private var opened: ((Outcome) -> Void)?
    private var pipes: [UInt32: SquaddE2EPipe] = [:]
    private var removed = false
    private var pingValue: UInt32 = 0
    private var awaitingPong: UInt32?
    private(set) var isOpen = false

    init(route: SquaddE2ETunnel.Route, tunnel: SquaddE2ETunnel, webSockets: URLSession) {
        self.route = route
        self.tunnel = tunnel
        queue = tunnel.queue
        task = webSockets.webSocketTask(with: route.url, protocols: [route.hello == nil ? "omb-e2e.v1" : "omb-relay.v1"])
        task.maximumMessageSize = 70_000
    }

    func open(_ done: @escaping (Outcome) -> Void) {
        opened = done
        task.resume()
        queue.asyncAfter(deadline: .now() + (route.hello == nil ? 10 : 20)) { [weak self] in
            if let self, self.keys == nil, self.opened != nil { self.fail(4002) }
        }
        guard let hello = route.hello else { return handshake() }
        send(.string(hello))
        receive { [weak self] message in
            guard let self else { return }
            guard case .string(let text) = message,
                  (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["t"] as? String == "ready"
            else { return self.fail(4400) }
            self.handshake()
        }
    }

    private func handshake() {
        guard let tunnel else { return fail(1000) }
        let conn = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let app = "ios/" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
        guard let hello = try? SquaddE2E.PhoneHandshake(remoteStatic: tunnel.descriptor.transportKey, psk: tunnel.psk,
                                                         transport: route.transport, payload1: SquaddE2E.payload1(conn: conn, app: app),
                                                         conn: SquaddE2E.b64u(conn))
        else { return fail(4000) }
        send(.data(hello.message1))
        receive { [weak self] message in
            guard let self else { return }
            guard case .data(let message2) = message, let keys = try? hello.finish(message2: message2) else {
                return self.end(.unverified)
            }
            self.keys = keys
            self.isOpen = true
            self.wireMux()
            let opened = self.opened
            self.opened = nil
            opened?(.ready)
            self.readRecords()
            self.keepAlive()
        }
    }

    private func wireMux() {
        mux.send = { [weak self] frame in
            guard let self, let keys = self.keys, let record = try? keys.send.seal(frame.encoded()) else { return }
            self.send(.data(record))
        }
        mux.onData = { [weak self] id, data in self?.pipes[id]?.deliver(data) }
        mux.onEnded = { [weak self] id in self?.pipes[id]?.peerFinished() }
        mux.onReset = { [weak self] id in self?.pipes.removeValue(forKey: id)?.cancel() }
        mux.onWritable = { [weak self] id in self?.pipes[id]?.flush() }
        mux.onPong = { [weak self] value in if self?.awaitingPong == value { self?.awaitingPong = nil } }
        mux.onGoAway = { [weak self] code in if code == SquaddYamux.goAwayRemoved { self?.removed = true } }
    }

    private func readRecords() {
        receive { [weak self] message in
            guard let self, let keys = self.keys, self.isOpen else { return }
            guard case .data(let record) = message,
                  let plaintext = try? keys.receive.open(record),
                  let frame = try? SquaddYamux.Frame.decode(plaintext),
                  (try? self.mux.receive(frame)) != nil
            else {
                self.mux.goAway(1)
                return self.fail(4000)
            }
            self.readRecords()
        }
    }

    private func keepAlive() {
        queue.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.isOpen else { return }
            if self.awaitingPong != nil { return self.fail(1001) }
            self.pingValue &+= 1
            let value = self.pingValue
            self.awaitingPong = value
            self.mux.ping(value)
            self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                if let self, self.isOpen, self.awaitingPong == value { self.fail(1001) }
            }
            self.keepAlive()
        }
    }

    func carry(_ connection: NWConnection, first: Data) {
        guard isOpen, let id = try? mux.open() else { return connection.cancel() }
        let pipe = SquaddE2EPipe(id: id, connection: connection, mux: mux)
        pipes[id] = pipe
        pipe.start(first: first) { [weak self] in self?.pipes.removeValue(forKey: id) }
    }

    func close() {
        guard isOpen else { return }
        mux.goAway(0)
        fail(1000)
    }

    private func fail(_ code: Int) {
        task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: nil)
        end(.closed(code))
    }

    private func end(_ outcome: Outcome) {
        if case .unverified = outcome { task.cancel(with: .normalClosure, reason: nil) }
        let wasOpen = isOpen
        isOpen = false
        mux.closeAll()
        pipes.values.forEach { $0.cancel() }
        pipes.removeAll()
        if let opened {
            self.opened = nil
            opened(outcome)
        } else if wasOpen {
            tunnel?.sessionEnded(self, removed: removed)
        }
    }

    private func send(_ message: URLSessionWebSocketTask.Message) {
        task.send(message) { [weak self] error in
            guard error != nil, let self else { return }
            self.queue.async { if self.isOpen || self.opened != nil { self.fail(1006) } }
        }
    }

    private func receive(_ handle: @escaping (URLSessionWebSocketTask.Message) -> Void) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .success(let message): handle(message)
                case .failure:
                    guard self.isOpen || self.opened != nil else { return }
                    let code = self.task.closeCode.rawValue
                    self.end(.closed(code == 0 ? 1006 : code))
                }
            }
        }
    }
}

/// One loopback TCP connection carried as one stream, both ways, within the stream's window.
final class SquaddE2EPipe {
    let id: UInt32
    private let connection: NWConnection
    private let mux: SquaddYamux
    private var outgoing = Data()
    private var localEnded = false
    private var reading = false
    private var finished: () -> Void = {}

    init(id: UInt32, connection: NWConnection, mux: SquaddYamux) {
        self.id = id
        self.connection = connection
        self.mux = mux
    }

    func start(first: Data, finished: @escaping () -> Void) {
        self.finished = finished
        outgoing = first
        flush()
    }

    /// Sends what the window allows, then reads more while less than 1 MiB waits.
    func flush() {
        while !outgoing.isEmpty {
            let sent = mux.write(id, outgoing)
            if sent == 0 { break }
            outgoing.removeFirst(sent)
        }
        if outgoing.isEmpty, localEnded { return mux.finish(id) }
        if !localEnded, !reading, outgoing.count < 1024 * 1024 { read() }
    }

    private func read() {
        reading = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: Int(SquaddYamux.maxDataPayload)) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.reading = false
            if error != nil { return self.mux.reset(self.id) }
            self.outgoing += data ?? Data()
            if isComplete { self.localEnded = true }
            self.flush()
        }
    }

    func deliver(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { return self.mux.reset(self.id) }
            self.mux.consumed(self.id, data.count)
        })
    }

    func peerFinished() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.connection.cancel()
            self.finished()
        })
    }

    func cancel() {
        connection.cancel()
    }
}
