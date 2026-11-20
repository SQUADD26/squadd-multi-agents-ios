import CryptoKit
import Foundation

/// The phone's half of the companion's end-to-end layer, `Noise_NKpsk0_P256_AESGCM_SHA256`, as
/// `openmausbot/companion/src/e2e/README.md` specifies it and `companion/src/e2e/vectors/v1.json` pins it.
enum SquaddE2E {
    struct Failure: Error, Equatable {
        let reason: String
    }

    static let transportRelay: UInt8 = 0x01
    static let transportDirect: UInt8 = 0x02
    static let publicKeyBytes = 65
    static let tagBytes = 16
    static let maxRecordBytes = 65_535
    static let maxRecordPlaintext = maxRecordBytes - tagBytes
    static let maxHandshakePayload = 512
    static let maxHandshakeMessage = publicKeyBytes + maxHandshakePayload + tagBytes

    // MARK: base64url, strict

    static func b64u(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The URL-safe alphabet only, no padding, and canonical: decoding then encoding gives the same text.
    static func fromB64u(_ text: String) -> Data? {
        guard text.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95 }),
              text.count % 4 != 1 else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), b64u(data) == text else { return nil }
        return data
    }

    // MARK: Derivations (README §2)

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func hmac(_ key: Data, _ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    /// The first 16 bytes of `SHA256(T.pub)`.
    static func keyId(_ transportKey: Data) -> Data { sha256(transportKey).prefix(16) }

    static func psk(credential: String, keyId: Data) -> Data {
        hmac(sha256(Data(credential.utf8)), Data("omb-e2e psk v1".utf8) + keyId)
    }

    static func admission(credential: String, hostId: Data) -> Data {
        hmac(sha256(Data(credential.utf8)), Data("omb-relay admission v1".utf8) + hostId)
    }

    /// An uncompressed P-256 point on the curve; CryptoKit refuses every other encoding.
    static func publicKey(_ bytes: Data) -> P256.KeyAgreement.PublicKey? {
        guard bytes.count == publicKeyBytes, bytes.first == 0x04 else { return nil }
        return try? P256.KeyAgreement.PublicKey(x963Representation: bytes)
    }

    static func dh(_ privateKey: P256.KeyAgreement.PrivateKey, _ publicBytes: Data) throws -> Data {
        guard let key = publicKey(publicBytes), let secret = try? privateKey.sharedSecretFromKeyAgreement(with: key)
        else { throw Failure(reason: "bad_point") }
        return secret.withUnsafeBytes { Data($0) }
    }

    /// Noise's HKDF: `temp = HMAC(ck, ikm)`, `out_i = HMAC(temp, out_{i-1} ‖ i)`.
    static func hkdf(_ chainingKey: Data, _ ikm: Data, outputs: Int) -> [Data] {
        let temp = hmac(chainingKey, ikm)
        var out: [Data] = []
        var previous = Data()
        for index in 1...outputs {
            previous = hmac(temp, previous + Data([UInt8(index)]))
            out.append(previous)
        }
        return out
    }

    static func nonce(_ n: UInt64) -> Data {
        Data(count: 4) + withUnsafeBytes(of: n.bigEndian) { Data($0) }
    }

    static func seal(key: Data, n: UInt64, ad: Data, plaintext: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce(n)), authenticating: ad)
        return box.ciphertext + box.tag
    }

    static func open(key: Data, n: UInt64, ad: Data, ciphertext: Data) throws -> Data {
        guard ciphertext.count >= tagBytes else { throw Failure(reason: "short_ciphertext") }
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce(n)), ciphertext: ciphertext.dropLast(tagBytes),
                                            tag: ciphertext.suffix(tagBytes))
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: ad)
        } catch {
            throw Failure(reason: "aead")
        }
    }

    // MARK: Records (README §6)

    /// One direction of a session: every record is opened or sealed with the next nonce, never sent.
    final class RecordCipher {
        let key: Data
        private(set) var n: UInt64 = 0

        init(key: Data) { self.key = key }

        func seal(_ plaintext: Data) throws -> Data {
            guard plaintext.count <= SquaddE2E.maxRecordPlaintext else { throw Failure(reason: "record_too_large") }
            guard n < 1 << 32 else { throw Failure(reason: "nonce_exhausted") }
            defer { n += 1 }
            return try SquaddE2E.seal(key: key, n: n, ad: Data(), plaintext: plaintext)
        }

        func open(_ record: Data) throws -> Data {
            guard record.count >= SquaddE2E.tagBytes, record.count <= SquaddE2E.maxRecordBytes else { throw Failure(reason: "record_size") }
            guard n < 1 << 32 else { throw Failure(reason: "nonce_exhausted") }
            defer { n += 1 }
            return try SquaddE2E.open(key: key, n: n, ad: Data(), ciphertext: record)
        }
    }

    struct SessionKeys {
        let send: RecordCipher
        let receive: RecordCipher
        let handshakeHash: Data
    }

    // MARK: Handshake (README §5)

    /// The initiator: message 1 on init, `finish(message2:)` for the session keys. Every failure is a hard stop.
    final class PhoneHandshake {
        private(set) var h: Data
        private(set) var ck: Data
        private var k: Data?
        private var n: UInt64 = 0
        private let ephemeral: P256.KeyAgreement.PrivateKey
        private let conn: String
        private(set) var message1 = Data()

        init(remoteStatic: Data, psk: Data, transport: UInt8, payload1: Data, conn: String,
             ephemeral: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey()) throws {
            guard SquaddE2E.publicKey(remoteStatic) != nil else { throw Failure(reason: "bad_point") }
            guard psk.count == 32 else { throw Failure(reason: "bad_psk") }
            guard payload1.count <= SquaddE2E.maxHandshakePayload else { throw Failure(reason: "payload_too_large") }
            var name = Data("Noise_NKpsk0_P256_AESGCM_SHA256".utf8)
            name += Data(count: 32 - name.count)
            h = name
            ck = name
            self.ephemeral = ephemeral
            self.conn = conn
            mixHash(Data("omb-e2e/1".utf8) + Data([0x00, transport]))
            mixHash(remoteStatic)
            mixKeyAndHash(psk)
            let e = ephemeral.publicKey.x963Representation
            mixHash(e)
            mixKey(e)
            mixKey(try SquaddE2E.dh(ephemeral, remoteStatic))
            message1 = e + (try encryptAndHash(payload1))
        }

        func finish(message2: Data) throws -> SessionKeys {
            let message2 = Data(message2)
            guard message2.count >= SquaddE2E.publicKeyBytes + SquaddE2E.tagBytes, message2.count <= SquaddE2E.maxHandshakeMessage
            else { throw Failure(reason: "message2_size") }
            let re = message2.prefix(SquaddE2E.publicKeyBytes)
            let ee = try SquaddE2E.dh(ephemeral, re)
            mixHash(re)
            mixKey(re)
            mixKey(ee)
            let payload2 = try decryptAndHash(message2.dropFirst(SquaddE2E.publicKeyBytes))
            guard let value = try? JSONSerialization.jsonObject(with: payload2) as? [String: Any],
                  (value["v"] as? NSNumber).map({ $0 == 1 && CFGetTypeID($0) != CFBooleanGetTypeID() }) == true
            else { throw Failure(reason: "payload2_version") }
            guard value["conn"] as? String == conn else { throw Failure(reason: "payload2_conn") }
            let keys = SquaddE2E.hkdf(ck, Data(), outputs: 2)
            return SessionKeys(send: RecordCipher(key: keys[0]), receive: RecordCipher(key: keys[1]), handshakeHash: h)
        }

        private func mixHash(_ data: Data) { h = SquaddE2E.sha256(h + data) }

        private func mixKey(_ ikm: Data) {
            let out = SquaddE2E.hkdf(ck, ikm, outputs: 2)
            ck = out[0]
            k = out[1]
            n = 0
        }

        private func mixKeyAndHash(_ ikm: Data) {
            let out = SquaddE2E.hkdf(ck, ikm, outputs: 3)
            ck = out[0]
            mixHash(out[1])
            k = out[2]
            n = 0
        }

        private func encryptAndHash(_ plaintext: Data) throws -> Data {
            guard let k else { throw Failure(reason: "no_key") }
            let out = try SquaddE2E.seal(key: k, n: n, ad: h, plaintext: plaintext)
            n += 1
            mixHash(out)
            return out
        }

        private func decryptAndHash(_ ciphertext: Data) throws -> Data {
            guard let k else { throw Failure(reason: "no_key") }
            let ciphertext = Data(ciphertext)
            let out = try SquaddE2E.open(key: k, n: n, ad: h, ciphertext: ciphertext)
            n += 1
            mixHash(ciphertext)
            return out
        }
    }

    static func payload1(conn: Data, app: String) -> Data {
        Data(#"{"v":1,"conn":"\#(b64u(conn))","app":"\#(app.prefix(40))"}"#.utf8)
    }

    // MARK: Descriptor (README §3)

    /// The `e2e` parameter of a pairing link and field of a pair reply.
    struct Descriptor: Codable, Equatable, Sendable {
        /// The computer's transport key `T.pub`, 65 bytes.
        let transportKey: Data
        /// The relay identity: the 16-byte hostId and the nodes to try, in order. Nil when the computer has no relay.
        let hostId: Data?
        let relays: [String]
        let localOnly: Bool

        enum Parse: Equatable {
            case ok(Descriptor)
            /// A newer version: say to update the app, never fall back to plain pairing.
            case update
            case reject(String)
        }

        static func parse(_ text: String) -> Parse {
            guard text.count <= 1024 else { return .reject("too_long") }
            guard let bytes = SquaddE2E.fromB64u(text) else { return .reject("base64") }
            guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return .reject("json") }
            return parse(object)
        }

        static func parse(_ fields: [String: Any]) -> Parse {
            guard let version = fields["v"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
                  version.doubleValue == version.doubleValue.rounded(), version.doubleValue >= 1
            else { return .reject("version") }
            if version.doubleValue > 1 { return .update }
            guard let key = (fields["k"] as? String).flatMap(SquaddE2E.fromB64u), SquaddE2E.publicKey(key) != nil
            else { return .reject("key") }
            guard (fields["h"] == nil) == (fields["r"] == nil) else { return .reject("relay_pair") }
            let routes = fields["routes"]
            guard routes == nil || routes as? String == "any" || routes as? String == "local" else { return .reject("routes") }
            let localOnly = routes as? String == "local"
            guard fields["h"] != nil else { return .ok(Descriptor(transportKey: key, hostId: nil, relays: [], localOnly: localOnly)) }
            guard let hostId = (fields["h"] as? String).flatMap(SquaddE2E.fromB64u), hostId.count == 16 else { return .reject("host_id") }
            guard let relays = fields["r"] as? [Any], (1...4).contains(relays.count) else { return .reject("relays") }
            let hosts = relays.compactMap { $0 as? String }
            guard hosts.count == relays.count,
                  hosts.allSatisfy({ $0.range(of: #"^relay[1-9][0-9]?\.openmausbot\.com$"#, options: .regularExpression) != nil })
            else { return .reject("relay_host") }
            return .ok(Descriptor(transportKey: key, hostId: hostId, relays: hosts, localOnly: localOnly))
        }
    }
}
