import Foundation

/// The phone's side of the yamux profile in `openmausbot/companion/src/e2e/README.md` §7 and
/// `companion/src/e2e/yamux.ts`: the phone opens every stream (odd IDs), the computer only accepts.
/// Not thread-safe: one queue drives it.
final class SquaddYamux {
    struct Failure: Error, Equatable {
        let reason: String
    }

    enum FrameType: UInt8 { case data = 0, windowUpdate = 1, ping = 2, goAway = 3 }

    struct Flags: OptionSet, Equatable {
        let rawValue: UInt16
        static let syn = Flags(rawValue: 0x1)
        static let ack = Flags(rawValue: 0x2)
        static let fin = Flags(rawValue: 0x4)
        static let rst = Flags(rawValue: 0x8)
    }

    struct Frame: Equatable {
        var type: FrameType
        var flags: Flags
        var streamId: UInt32
        /// Data: the payload size. WindowUpdate: the window delta. Ping: the opaque value. GoAway: the code.
        var length: UInt32
        var data = Data()

        static func data(_ streamId: UInt32, _ data: Data, flags: Flags = []) -> Frame {
            Frame(type: .data, flags: flags, streamId: streamId, length: UInt32(data.count), data: data)
        }

        static func window(_ streamId: UInt32, _ delta: UInt32, flags: Flags = []) -> Frame {
            Frame(type: .windowUpdate, flags: flags, streamId: streamId, length: delta)
        }

        static func ping(_ value: UInt32, flags: Flags = .syn) -> Frame { Frame(type: .ping, flags: flags, streamId: 0, length: value) }

        static func goAway(_ code: UInt32) -> Frame { Frame(type: .goAway, flags: [], streamId: 0, length: code) }

        func encoded() -> Data {
            var out = Data([0, type.rawValue])
            withUnsafeBytes(of: flags.rawValue.bigEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: streamId.bigEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: length.bigEndian) { out.append(contentsOf: $0) }
            return type == .data ? out + data : out
        }

        /// One record's plaintext is exactly one frame; everything checkable without stream state is checked here.
        static func decode(_ bytes: Data) throws -> Frame {
            let bytes = [UInt8](bytes)
            guard bytes.count >= headerBytes else { throw Failure(reason: "short_frame") }
            guard bytes[0] == 0 else { throw Failure(reason: "version") }
            guard let type = FrameType(rawValue: bytes[1]) else { throw Failure(reason: "type") }
            let flags = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
            guard flags & ~0xF == 0 else { throw Failure(reason: "flags") }
            let streamId = bytes[4..<8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let length = bytes[8..<12].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let frame = Frame(type: type, flags: Flags(rawValue: flags), streamId: streamId, length: length)
            if type == .data {
                guard length <= maxDataPayload else { throw Failure(reason: "data_too_large") }
                guard bytes.count == headerBytes + Int(length) else { throw Failure(reason: "data_length") }
                guard streamId != 0 else { throw Failure(reason: "stream_zero") }
                return Frame(type: type, flags: frame.flags, streamId: streamId, length: length, data: Data(bytes[headerBytes...]))
            }
            guard bytes.count == headerBytes else { throw Failure(reason: "trailing_bytes") }
            if type == .windowUpdate {
                guard streamId != 0 else { throw Failure(reason: "stream_zero") }
            } else {
                guard streamId == 0 else { throw Failure(reason: "session_frame_stream") }
                if type == .ping, flags != Flags.syn.rawValue, flags != Flags.ack.rawValue { throw Failure(reason: "ping_flags") }
                if type == .goAway, flags != 0 { throw Failure(reason: "goaway_flags") }
            }
            return frame
        }
    }

    static let headerBytes = 12
    static let maxDataPayload: UInt32 = 65_507
    static let initialWindow = 256 * 1024
    static let openWindowDelta = 2 * 1024 * 1024 - 256 * 1024
    static let windowUpdateAfter = 1024 * 1024
    static let maxStreams = 64
    static let goAwayRemoved: UInt32 = 3

    private struct Stream {
        var established = false
        var receiveWindow = SquaddYamux.initialWindow + SquaddYamux.openWindowDelta
        var sendWindow = SquaddYamux.initialWindow
        var uncredited = 0
        var localFin = false
        var remoteFin = false
    }

    /// Every frame to seal and send, in order.
    var send: (Frame) -> Void = { _ in }
    var onData: (UInt32, Data) -> Void = { _, _ in }
    /// The computer may send no more on this stream (FIN).
    var onEnded: (UInt32) -> Void = { _ in }
    /// Ended by RST from either side, or the session closing.
    var onReset: (UInt32) -> Void = { _ in }
    /// The computer granted more send window.
    var onWritable: (UInt32) -> Void = { _ in }
    var onGoAway: (UInt32) -> Void = { _ in }
    var onPong: (UInt32) -> Void = { _ in }

    private var streams: [UInt32: Stream] = [:]
    private var highestId: UInt32 = 0
    private(set) var peerGoneAway = false

    var activeStreams: Int { streams.count }

    func sendWindow(_ streamId: UInt32) -> Int { streams[streamId]?.sendWindow ?? 0 }

    /// Data may follow at once, within the first 256 KiB.
    func open() throws -> UInt32 {
        guard !peerGoneAway else { throw Failure(reason: "gone_away") }
        guard streams.count < Self.maxStreams else { throw Failure(reason: "too_many_streams") }
        let streamId = highestId == 0 ? 1 : highestId + 2
        guard streamId <= UInt32(Int32.max) else { throw Failure(reason: "ids_exhausted") }
        highestId = streamId
        streams[streamId] = Stream()
        send(.window(streamId, UInt32(Self.openWindowDelta), flags: .syn))
        return streamId
    }

    /// Sends up to the window and the frame cap; returns the bytes taken.
    @discardableResult
    func write(_ streamId: UInt32, _ data: Data) -> Int {
        guard var stream = streams[streamId], !stream.localFin else { return 0 }
        let size = min(data.count, stream.sendWindow, Int(Self.maxDataPayload))
        guard size > 0 else { return 0 }
        stream.sendWindow -= size
        streams[streamId] = stream
        send(.data(streamId, Data(data.prefix(size))))
        return size
    }

    func finish(_ streamId: UInt32) {
        guard var stream = streams[streamId], !stream.localFin else { return }
        stream.localFin = true
        streams[streamId] = stream
        send(.window(streamId, 0, flags: .fin))
        closeIfDone(streamId)
    }

    func reset(_ streamId: UInt32) {
        guard streams.removeValue(forKey: streamId) != nil else { return }
        send(.window(streamId, 0, flags: .rst))
        onReset(streamId)
    }

    /// The HTTP stack took `bytes`: they go back to the computer in 1 MiB steps.
    func consumed(_ streamId: UInt32, _ bytes: Int) {
        guard var stream = streams[streamId], !stream.remoteFin else { return }
        stream.uncredited += bytes
        if stream.uncredited >= Self.windowUpdateAfter {
            let delta = stream.uncredited
            stream.uncredited = 0
            stream.receiveWindow += delta
            send(.window(streamId, UInt32(delta)))
        }
        streams[streamId] = stream
    }

    func ping(_ value: UInt32) { send(.ping(value)) }

    func goAway(_ code: UInt32 = 0) { send(.goAway(code)) }

    func closeAll() {
        let ids = Array(streams.keys)
        streams.removeAll()
        ids.forEach(onReset)
    }

    /// A frame that breaks the profile throws: the caller then sends GoAway(1) and closes with 4000.
    func receive(_ frame: Frame) throws {
        switch frame.type {
        case .ping:
            if frame.flags == .syn { send(.ping(frame.length, flags: .ack)) } else { onPong(frame.length) }
            return
        case .goAway:
            peerGoneAway = true
            onGoAway(frame.length)
            return
        default: break
        }
        if frame.flags.contains(.syn) { throw Failure(reason: "computer_opened_stream") }
        if frame.flags.contains(.ack) {
            guard frame.type == .windowUpdate, frame.flags.isSubset(of: [.ack, .fin, .rst]) else { throw Failure(reason: "ack_flags") }
            guard var stream = try known(frame.streamId) else { return }
            guard !stream.established else { throw Failure(reason: "duplicate_ack") }
            stream.established = true
            streams[frame.streamId] = stream
            var rest = frame
            rest.flags.remove(.ack)
            try receiveOnStream(rest)
            return
        }
        guard try known(frame.streamId) != nil else { return }
        try receiveOnStream(frame)
    }

    /// A stream that ended is ignored, as an RST and the computer's last frames cross; an ID never opened is an error.
    private func known(_ streamId: UInt32) throws -> Stream? {
        guard streamId % 2 == 1, streamId <= highestId else { throw Failure(reason: "unknown_stream") }
        return streams[streamId]
    }

    private func receiveOnStream(_ frame: Frame) throws {
        let streamId = frame.streamId
        guard var stream = streams[streamId] else { return }
        if frame.flags.contains(.rst) {
            streams.removeValue(forKey: streamId)
            onReset(streamId)
            return
        }
        if frame.type == .data {
            if stream.remoteFin, frame.length > 0 || frame.flags.contains(.fin) { throw Failure(reason: "data_after_fin") }
            guard Int(frame.length) <= stream.receiveWindow else { throw Failure(reason: "window_exceeded") }
            stream.receiveWindow -= Int(frame.length)
            streams[streamId] = stream
            if frame.length > 0 { onData(streamId, frame.data) }
        } else if frame.length > 0 {
            stream.sendWindow += Int(frame.length)
            streams[streamId] = stream
            onWritable(streamId)
        }
        if frame.flags.contains(.fin) {
            guard var current = streams[streamId] else { return }
            if current.remoteFin { throw Failure(reason: "data_after_fin") }
            current.remoteFin = true
            streams[streamId] = current
            onEnded(streamId)
            closeIfDone(streamId)
        }
    }

    private func closeIfDone(_ streamId: UInt32) {
        if let stream = streams[streamId], stream.localFin, stream.remoteFin { streams.removeValue(forKey: streamId) }
    }
}
