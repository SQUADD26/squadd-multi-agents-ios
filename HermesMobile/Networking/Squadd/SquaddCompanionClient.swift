import Foundation

/// What can go wrong talking to a Squadd companion.
enum SquaddError: Error, Equatable {
    /// 401: the computer no longer knows this iPhone's token (revoked from the desktop). Only a
    /// new pairing fixes it.
    case unpaired
    /// Any other non-2xx status.
    case status(Int)
    case invalidResponse
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
        let data = try await call("GET", "api/bots")
        return try JSONDecoder().decode(SquaddBotList.self, from: data).bots
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
        var components = URLComponents(url: server.appendingPathComponent("api/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let data = try await call("GET", components.url!)
        return try JSONDecoder().decode(SquaddSearchResponse.self, from: data).hits
    }

    /// A thread's visible conversation as Markdown, the desktop's own export.
    func exportMarkdown(threadId: String) async throws -> Data {
        try await call("GET", "api/threads/\(threadId)/export")
    }

    private func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        try await call(method, server.appendingPathComponent(path), body: body)
    }

    private func call(_ method: String, _ url: URL, body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await Self.send(request, session: session)
    }

    /// Redeems a six-digit pairing code (or the QR credential) shown on the computer for a
    /// device token. The code is single-use and lasts two minutes.
    static func pair(server: URL, code: String, deviceName: String, session: URLSession = .shared) async throws -> SquaddPairResponse {
        var request = URLRequest(url: server.appendingPathComponent("api/pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["code": code, "deviceName": deviceName])
        return try JSONDecoder().decode(SquaddPairResponse.self, from: await send(request, session: session))
    }

    private static func send(_ request: URLRequest, session: URLSession) async throws -> Data {
        var request = request
        request.setValue(nil, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SquaddError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw SquaddError.unpaired
        default: throw SquaddError.status(http.statusCode)
        }
    }
}
