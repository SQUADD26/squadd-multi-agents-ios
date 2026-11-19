import Foundation

/// The connector routes a paired phone may use (`companion/src/routes.ts`): the catalog, what is
/// connected, a new sign-in link, and removing one account. Removing a whole service stays on the computer.
extension SquaddCompanionClient {
    func connectorCatalog() async throws -> SquaddConnectorCatalog {
        try JSONDecoder().decode(SquaddConnectorCatalog.self, from: await call("GET", "api/connectors/catalog"))
    }

    func connectedServices() async throws -> SquaddConnectedServices {
        try JSONDecoder().decode(SquaddConnectedServices.self, from: await call("GET", "api/connectors/connected"))
    }

    /// The service's sign-in page. Only an https link is opened.
    func authorizeConnector(slug: String) async throws -> URL {
        struct Answer: Decodable { let url: String }
        let answer = try JSONDecoder().decode(Answer.self, from: await call("POST", "api/connectors/\(Self.segment(slug))/authorize", body: [:]))
        guard let url = URL(string: answer.url), url.scheme == "https" else { throw SquaddError.invalidResponse }
        return url
    }

    func removeConnectorAccount(slug: String, accountId: String) async throws {
        _ = try await call("DELETE", "api/connectors/\(Self.segment(slug))/accounts/\(Self.segment(accountId))")
    }
}
