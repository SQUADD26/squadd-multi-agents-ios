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
        var request = URLRequest(url: server.appendingPathComponent("api/bots"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await Self.send(request, session: session)
        return try JSONDecoder().decode(SquaddBotList.self, from: data).bots
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
