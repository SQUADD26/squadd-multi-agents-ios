import Foundation

/// What can go wrong talking to a Squadd companion.
enum SquaddError: Error, Equatable {
    /// 401: the computer no longer knows this iPhone's token (revoked from the desktop). Only a
    /// new pairing fixes it.
    case unpaired
    /// Any other non-2xx status.
    case status(Int)
    /// A request the companion or the computer refused, with the reason it gave (`{"error": …}`),
    /// for the screens that show it as is: an agent's name too long, a model the engine no longer offers.
    case refused(String)
    case invalidResponse
    /// `POST /api/pair` refused, with the phone protocol's `PairingErrorCode` (`pairing_code_wrong`,
    /// `pairing_not_open`, `pairing_too_many`, `pairing_device_limit`, …).
    case pairing(String)
}

/// The Squadd companion's HTTP contract (`openmausbot/companion/src/proxy.ts`). Every request
/// carries the device token as a bearer and no `Origin` header: the companion refuses any
/// request with one as a browser (403) before it looks at the token.
struct SquaddCompanionClient {
    let server: URL
    let token: String
    var session: URLSession = .shared

    /// The computer's agents and their task threads.
    func bots() async throws -> [SquaddBot] {
        var request = URLRequest(url: server.appendingPathComponent("api/bots"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await Self.send(request, session: session)
        return try JSONDecoder().decode(SquaddBotList.self, from: data).bots
    }

    /// The computer's engines and their models, for the agent model picker.
    func instances() async throws -> [SquaddInstance] {
        try JSONDecoder().decode(SquaddInstanceList.self, from: await send(request("api/instances"))).instances
    }

    /// Makes an agent. A paired device may give only who it is and its model: the companion refuses
    /// anything else and makes no agent.
    func createBot(name: String, title: String, description: String, instructions: String, model: SquaddModelSelection?) async throws -> SquaddBot {
        var body: [String: AnyEncodable] = ["name": .init(name), "title": .init(title), "description": .init(description)]
        // At creation the computer reads instructions from `settings`, as the desktop's New bot sends them.
        if !instructions.isEmpty { body["settings"] = .init(["soul": instructions]) }
        if let model { body["modelSelection"] = .init(model) }
        return try await botReply(request("api/bots", method: "POST", body: body))
    }

    /// Changes an agent's name, title, description and instructions. The computer refuses a name over
    /// 100 characters and instructions over its byte cap.
    func updateProfile(botID: String, name: String, title: String, description: String, instructions: String) async throws -> SquaddBot {
        try await botReply(request("api/bots/\(botID)/profile", method: "PATCH",
                                   body: ["name": name, "title": title, "description": description, "soul": instructions]))
    }

    /// Moves an agent to another model. The computer refuses a model its engine no longer offers
    /// and any change while the agent is working.
    func setModel(botID: String, _ model: SquaddModelSelection) async throws -> SquaddBot {
        try await botReply(request("api/bots/\(botID)/model", method: "PATCH", body: model))
    }

    /// Draws a new avatar from a short description, with the image key set on the computer.
    func generateAvatar(botID: String, prompt: String) async throws -> SquaddBot {
        try await botReply(request("api/bots/\(botID)/avatar/generate", method: "POST", body: ["prompt": prompt]))
    }

    /// An avatar's image bytes, from the path the agent carries in `avatarUrl`.
    func avatarData(path: String) async throws -> Data {
        try await send(request(path.hasPrefix("/") ? String(path.dropFirst()) : path))
    }

    private func botReply(_ request: URLRequest) async throws -> SquaddBot {
        try JSONDecoder().decode(SquaddBotEnvelope.self, from: await send(request)).bot
    }

    private func send(_ request: URLRequest) async throws -> Data {
        try await Self.send(request, session: session, reportsRefusal: true)
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: server.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func request(_ path: String, method: String, body: some Encodable) throws -> URLRequest {
        var request = request(path, method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// Redeems the QR's one-time credential or the six-digit code shown on the computer for a device
    /// token. Both last two minutes and work once. `replacesToken`, the token this iPhone already holds
    /// for that computer, makes the computer replace this iPhone instead of adding a second one.
    static func pair(server: URL, credential: String, deviceName: String, replacesToken: String? = nil,
                     session: URLSession = .shared) async throws -> SquaddPairResponse {
        var request = URLRequest(url: server.appendingPathComponent("api/pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = ["credential": credential, "deviceName": deviceName]
        body["replacesToken"] = replacesToken
        request.httpBody = try JSONEncoder().encode(body)
        return try JSONDecoder().decode(SquaddPairResponse.self, from: await send(request, session: session))
    }

    /// `reportsRefusal` turns a refusal that names its reason into `.refused`; pairing keeps the bare status.
    private static func send(_ request: URLRequest, session: URLSession, reportsRefusal: Bool = false) async throws -> Data {
        var request = request
        request.setValue(nil, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SquaddError.invalidResponse }
        // Only a refused pairing carries a `pairing_` code; a revoked token's 401 has none.
        let refusal = (try? JSONDecoder().decode(PairingRefusal.self, from: data))?.code
        switch http.statusCode {
        case 200..<300: return data
        case _ where refusal?.hasPrefix("pairing_") == true: throw SquaddError.pairing(refusal!)
        case 401: throw SquaddError.unpaired
        default:
            if reportsRefusal, let reason = (try? JSONDecoder().decode(Refusal.self, from: data))?.error {
                throw SquaddError.refused(reason)
            }
            throw SquaddError.status(http.statusCode)
        }
    }
}

private struct PairingRefusal: Decodable {
    let code: String
}

private struct Refusal: Decodable { let error: String }

/// A JSON value of any encodable type, for a body whose fields differ in type.
private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void
    init(_ value: some Encodable) { encodeValue = value.encode }
    func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}
