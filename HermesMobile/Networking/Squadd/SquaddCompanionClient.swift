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
    /// The paired computer, as the server list knows it.
    let server: URL
    let token: String
    var session: URLSession = .shared

    /// Where requests go: the route `SquaddRoutes` found for this computer (#9), else the address it was
    /// paired at. Read per request, so a client made before a network change follows it.
    var base: URL { SquaddRoutes.shared.route(for: server)?.url ?? server }

    /// The computer's agents and their task threads.
    func bots() async throws -> [SquaddBot] {
        try await botList().bots
    }

    /// The agents and the rooms, as one `GET /api/bots` lists them.
    func botList() async throws -> SquaddBotList {
        try JSONDecoder().decode(SquaddBotList.self, from: await call("GET", "api/bots"))
    }

    /// Tells the computer the person has the app open (`POST /api/presence/active`, the route the
    /// companion's whitelist allows), so it knows to reach them on the phone. `threadId` is the chat
    /// on screen, if one is.
    func presenceActive(timeZone: String = TimeZone.current.identifier,
                        language: String? = Bundle.main.preferredLocalizations.first,
                        threadId: String? = nil) async throws {
        var body = ["source": "phone", "timeZone": timeZone]
        // The companion takes a BCP 47 tag in lower case (`it`, `pt-br`).
        if let language { body["language"] = language.lowercased() }
        if let threadId { body["threadId"] = threadId }
        _ = try await Self.send(request("api/presence/active", method: "POST", body: body), session: session)
    }

    /// Opens a new thread for `botId`. `select: false` leaves the desktop on the thread it shows.
    func createTask(botId: String, title: String? = nil) async throws -> SquaddTask {
        var body: [String: Any] = ["select": false]
        if let title { body["title"] = title }
        let data = try await call("POST", "api/bots/\(botId)/tasks", body: body)
        return try JSONDecoder().decode(SquaddTaskResponse.self, from: data).task
    }

    /// Changes a thread's settings: `title`, `pinned`, `archivedAt` (ms, or `NSNull()` to restore),
    /// `projectId` (or `NSNull()` to take it out of its folder). Returns the thread as saved.
    func patchTask(botId: String, threadId: String, _ changes: [String: Any]) async throws -> SquaddTask {
        let data = try await call("PATCH", "api/bots/\(botId)/tasks/\(threadId)", body: changes)
        return try JSONDecoder().decode(SquaddTaskResponse.self, from: data).task
    }

    func deleteTask(botId: String, threadId: String) async throws {
        _ = try await call("DELETE", "api/bots/\(botId)/tasks/\(threadId)")
    }

    /// A new, empty folder at the end of `botId`'s folders. Names are 1 to 80 characters.
    func createProject(botId: String, name: String) async throws -> SquaddProject {
        let data = try await call("POST", "api/bots/\(botId)/projects", body: ["name": name])
        return try JSONDecoder().decode(SquaddProjectResponse.self, from: data).project
    }

    /// Saves the folders' order; `projectIds` must name each of the agent's folders once.
    func reorderProjects(botId: String, projectIds: [String]) async throws {
        _ = try await call("PATCH", "api/bots/\(botId)/projects/order", body: ["projectIds": projectIds])
    }

    /// Deletes a folder. Its threads stay, outside any folder.
    func deleteProject(botId: String, projectId: String) async throws {
        _ = try await call("DELETE", "api/bots/\(botId)/projects/\(projectId)")
    }

    /// Message matches across every conversation this phone can see.
    func search(_ query: String) async throws -> [SquaddSearchHit] {
        let data = try await call("GET", "api/search?q=\(Self.segment(query))")
        return try JSONDecoder().decode(SquaddSearchResponse.self, from: data).hits
    }

    /// A thread's visible conversation as Markdown, the desktop's own export.
    func exportMarkdown(threadId: String) async throws -> Data {
        try await call("GET", "api/threads/\(threadId)/export")
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
        var request = URLRequest(url: base.appendingPathComponent(path))
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
    static func pair(server: URL, credential: String, deviceName: String, requestID: String,
                     replacesToken: String? = nil, session: URLSession = .shared) async throws -> SquaddPairResponse {
        var request = URLRequest(url: (SquaddRoutes.shared.route(for: server)?.url ?? server).appendingPathComponent("api/pair"))
        request.setValue(SquaddRelay.shared.loopbackSecret(for: request.url), forHTTPHeaderField: SquaddE2ETunnel.loopbackHeader)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = ["credential": credential, "deviceName": deviceName, "pairRequestId": requestID]
        body["replacesToken"] = replacesToken
        request.httpBody = try JSONEncoder().encode(body)
        return try JSONDecoder().decode(SquaddPairResponse.self, from: await send(request, session: session))
    }

    /// `reportsRefusal` turns a refusal that names its reason into `.refused`; pairing keeps the bare status.
    static func send(_ request: URLRequest, session: URLSession, reportsRefusal: Bool = false) async throws -> Data {
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
