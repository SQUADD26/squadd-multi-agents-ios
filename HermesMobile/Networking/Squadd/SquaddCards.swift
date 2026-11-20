import CryptoKit
import Foundation

// MARK: - Secret, sign-in and connector cards (#16)

/// A `secret` row's card (`SecretRequestCardData`, `phone-protocol/src/wire.ts`): the agent asks for a key.
struct SquaddSecretCard: Decodable, Equatable {
    let target: String
    let label: String
    let description: String?
    let placeholder: String?
    let requestKey: String
    /// `ref`, `file` or `email`; absent for a named credential.
    let delivery: String?
    let provided: Bool?
    let dismissed: Bool?
    let superseded: Bool?
    let stopped: Bool?

    var isOpen: Bool { provided != true && dismissed != true && superseded != true && stopped != true }

    /// Why this iPhone cannot take this secret, whatever the route: the computer refuses a provider key
    /// and the 1Password token from a phone (`assertPhoneSecretRequestMatches`), and an email account needs
    /// the computer's own form.
    var computerOnly: Bool {
        // shortcut: an email secret goes to the computer, as its form has more than the password; move it here with the email fields.
        Self.computerTargets.contains(target) || delivery == "email"
    }

    /// `PROVIDER_CREDENTIAL_TARGETS` and `onePasswordToken` (`credential-request.ts`, `phone-secret.ts`).
    static let computerTargets: Set<String> = [
        "openaiApiKey", "anthropicApiKey", "openrouterApiKey", "mistralApiKey", "cerebrasApiKey", "groqApiKey",
        "greenferenceApiKey", "modelgoApiKey", "metaApiKey", "deepseekApiKey", "onePasswordToken",
    ]
}

/// A `signin` row's card (`SignInRequestCardData`): the agent needs the person to sign in to `site` themselves,
/// in the place it works (`place`: `browser`, `vm`, `cloud` or `local`). A sign-in made on this iPhone would
/// not reach that browser (`sign-in-request.ts`), so the phone says where and takes Done or Cancel.
struct SquaddSignInCard: Decodable, Equatable {
    let url: String?
    let site: String
    let place: String?
    let reason: String?
    let done: Bool?
    let cancelled: Bool?
    let superseded: Bool?
    let stopped: Bool?
    let answeredInChat: Bool?

    var isOpen: Bool {
        done != true && cancelled != true && superseded != true && stopped != true && answeredInChat != true
    }
}

/// A `connector` row's card (`ConnectorCardData`, `connector-card.ts`): the agent needs a service connected.
/// `status` is `required`, `authorizing`, `connected` or `failed`.
struct SquaddConnectorCard: Decodable, Equatable {
    let slug: String
    let label: String
    let description: String?
    let status: String?
    let error: String?
    let dismissed: Bool?
    let superseded: Bool?
    let resumed: Bool?
    let stopped: Bool?

    /// Waits on the person until the agent went on with the service connected, or the card was put away.
    var isOpen: Bool { dismissed != true && superseded != true && stopped != true && resumed != true }
}

// MARK: - The secret's envelope

/// What a QR pairing leaves for secrets: the computer's HPKE key (`secretKey`, the 65-byte P-256 point) and the
/// id it gave this iPhone (`device.id`). The key is public; it lives in the Keychain beside the token it pairs with.
struct SquaddSecretPairing: Codable, Equatable {
    var deviceId: String
    /// Nil after a typed-code pairing, which carries no key.
    var secretKey: Data?

    static func saved(for server: URL, keychain: KeychainStoring = KeychainStore()) -> SquaddSecretPairing? {
        guard let json = (try? keychain.load(.squaddSecretPairing, scope: server.absoluteString)) ?? nil else { return nil }
        return try? JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }
}

/// The encrypted credential `POST …/secret-cards/:id/provide` takes (`phone-secret-envelope.ts`): HPKE base mode,
/// DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, AES-256-GCM, sealed to the computer's key and bound by the AAD to this
/// device, bot, thread, card, target and request. Only the computer's desktop app can open it.
enum SquaddSecretEnvelope {
    static let info = Data("OpenMausBot phone credential v1".utf8)
    static let suite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256

    struct Context: Equatable {
        let deviceId: String
        let botId: String
        let threadId: String
        let messageId: String
        let target: String
        let requestKey: String
    }

    enum Failure: Error, Equatable {
        /// Empty, or over the 4096 bytes the computer takes.
        case size
        case key
    }

    /// The first 16 bytes of the key's SHA-256, base64url: how the computer knows which key sealed it.
    static func keyId(_ publicKey: Data) -> String {
        Data(SHA256.hash(data: publicKey).prefix(16)).base64URL
    }

    /// The fields joined by a line break, in `phoneSecretAAD`'s order.
    static func aad(keyId: String, _ context: Context) -> Data {
        Data(["openmausbot-phone-credential-v1", keyId, context.deviceId, context.botId, context.threadId,
              context.messageId, context.target, context.requestKey].joined(separator: "\n").utf8)
    }

    /// The request body for `value`, trimmed as the computer trims it.
    static func seal(_ value: String, to publicKey: Data, _ context: Context) throws -> [String: Any] {
        let plaintext = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard (1...4096).contains(plaintext.count) else { throw Failure.size }
        guard let recipient = try? P256.KeyAgreement.PublicKey(x963Representation: publicKey) else { throw Failure.key }
        let keyId = keyId(publicKey)
        var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: suite, info: info)
        let ciphertext = try sender.seal(plaintext, authenticating: aad(keyId: keyId, context))
        return ["version": 1, "threadId": context.threadId, "keyId": keyId, "deviceId": context.deviceId,
                "target": context.target, "requestKey": context.requestKey,
                "encapsulatedKey": sender.encapsulatedKey.base64URL, "ciphertext": ciphertext.base64URL]
    }
}

extension Data {
    /// Unpadded base64url, the phone protocol's binary encoding.
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Nil for anything but canonical unpadded base64url.
    init?(base64URL: String) {
        guard base64URL.range(of: "^[A-Za-z0-9_-]*$", options: .regularExpression) != nil else { return nil }
        var base64 = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}

// MARK: - Routes

/// Why a secret card sends nothing from this iPhone.
enum SquaddSecretBlock: Error, Equatable {
    /// A provider key, the 1Password token or an email account: the computer takes it only in its own app.
    case computerOnly
    /// A typed-code pairing gave no key to seal with.
    case notPairedByQR
    /// The computer is reached on the local network, in plain HTTP.
    case localNetwork
}

extension SquaddCompanionClient {
    /// The route a secret goes by now: nil on a LAN or Bonjour one, where the companion speaks plain HTTP on a
    /// shared network and the token would cross it in the clear (`companion/README.md`).
    var secretRoute: SquaddEndpoint? {
        let route = SquaddRoutes.shared.route(for: server)
            ?? SquaddEndpoint(url: server, kind: SquaddRouteBook.kind(of: server), priority: 0)
        return route?.isLocal == false ? route : nil
    }

    /// Why this iPhone can't take `card`'s secret right now, in the order the person can fix it; nil when it can.
    func secretBlock(_ card: SquaddSecretCard, pairing: SquaddSecretPairing?) -> SquaddSecretBlock? {
        if card.computerOnly { return .computerOnly }
        if pairing?.secretKey == nil { return .notPairedByQR }
        if secretRoute == nil { return .localNetwork }
        return nil
    }

    /// Seals `value` for the card and sends it over the route checked here, never a LAN one.
    func provideSecret(_ value: String, card: SquaddSecretCard, pairing: SquaddSecretPairing?,
                       botId: String, threadId: String, messageId: String) async throws {
        if let block = secretBlock(card, pairing: pairing) { throw block }
        guard let route = secretRoute, let pairing, let key = pairing.secretKey else { throw SquaddSecretBlock.localNetwork }
        let body = try SquaddSecretEnvelope.seal(value, to: key, .init(
            deviceId: pairing.deviceId, botId: botId, threadId: threadId, messageId: messageId,
            target: card.target, requestKey: card.requestKey))
        _ = try await call("POST", "api/bots/\(Self.segment(botId))/secret-cards/\(Self.segment(messageId))/provide",
                           body: body, base: route.url, reportsRefusal: true)
    }

    func dismissSecret(botId: String, threadId: String, messageId: String) async throws {
        _ = try await call("POST", "api/bots/\(Self.segment(botId))/secret-cards/\(Self.segment(messageId))/dismiss",
                           body: ["threadId": threadId], reportsRefusal: true)
    }

    /// `done`: the person signed in where the card said; otherwise they cancel it. The agent goes on either way.
    func settleSignIn(done: Bool, botId: String, threadId: String, messageId: String) async throws {
        _ = try await call("POST", "api/bots/\(Self.segment(botId))/sign-in-cards/\(Self.segment(messageId))/\(done ? "done" : "cancel")",
                           body: ["threadId": threadId], reportsRefusal: true)
    }

    /// The service's sign-in page for the card. Only an https link is opened.
    func authorizeConnectorCard(botId: String, threadId: String, messageId: String) async throws -> URL {
        struct Answer: Decodable { let url: String }
        let data = try await call("POST", "api/bots/\(Self.segment(botId))/connector-cards/\(Self.segment(messageId))/authorize",
                                  body: ["threadId": threadId], reportsRefusal: true)
        guard let url = URL(string: try JSONDecoder().decode(Answer.self, from: data).url), url.scheme == "https" else {
            throw SquaddError.invalidResponse
        }
        return url
    }

    /// Asks the computer whether the service is connected now; it updates the card, and goes on with the agent's
    /// work once it is.
    func connectorCardStatus(botId: String, threadId: String, messageId: String) async throws -> Bool {
        struct Answer: Decodable { let connected: Bool? }
        let data = try await call("GET", "api/bots/\(Self.segment(botId))/connector-cards/\(Self.segment(messageId))/status?threadId=\(Self.segment(threadId))",
                                  reportsRefusal: true)
        return try JSONDecoder().decode(Answer.self, from: data).connected == true
    }

    func resumeConnectorCard(botId: String, threadId: String, messageId: String) async throws {
        _ = try await call("POST", "api/bots/\(Self.segment(botId))/connector-cards/\(Self.segment(messageId))/resume",
                           body: ["threadId": threadId], reportsRefusal: true)
    }

    func dismissConnectorCard(botId: String, threadId: String, messageId: String) async throws {
        _ = try await call("POST", "api/bots/\(Self.segment(botId))/connector-cards/\(Self.segment(messageId))/dismiss",
                           body: ["threadId": threadId], reportsRefusal: true)
    }
}
