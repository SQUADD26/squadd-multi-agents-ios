import Foundation

/// `GET /api/connectors/catalog`: the apps the computer can connect, and whether connecting is set up.
struct SquaddConnectorCatalog: Decodable, Equatable {
    /// "ready" once the computer can connect apps; anything else is set up there.
    let setup: String?
    let cards: [Card]

    struct Card: Decodable, Equatable {
        let slug: String
        let label: String?
        let blurb: String?
        let categories: [String]?
    }

    private enum CodingKeys: String, CodingKey { case setup, cards }

    init(setup: String?, cards: [Card]) {
        self.setup = setup
        self.cards = cards
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        setup = try? container.decodeIfPresent(String.self, forKey: .setup)
        cards = (try? container.decodeIfPresent([SquaddLossy<Card>].self, forKey: .cards))?.compactMap(\.value) ?? []
    }
}

/// `GET /api/connectors/connected`: every service with an account, by slug.
struct SquaddConnectedServices: Decodable, Equatable {
    let services: [String: Service]

    struct Service: Decodable, Equatable {
        let accounts: [Account]

        private enum CodingKeys: String, CodingKey { case accounts }

        init(accounts: [Account]) { self.accounts = accounts }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accounts = (try? container.decodeIfPresent([SquaddLossy<Account>].self, forKey: .accounts))?.compactMap(\.value) ?? []
        }
    }

    struct Account: Decodable, Equatable, Identifiable {
        let id: String
        let status: String?
        let alias: String?

        /// Only an active account counts: a sign-in left open or failed is not a connection.
        var isActive: Bool { status?.caseInsensitiveCompare("active") == .orderedSame }
    }

    private enum CodingKeys: String, CodingKey { case services }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? container.decodeIfPresent([String: SquaddLossy<Service>].self, forKey: .services)) ?? [:]
        services = raw.compactMapValues(\.value)
    }
}

/// One app on the phone's Connected Apps page: the catalog card joined with its active accounts.
struct SquaddConnectorApp: Equatable, Identifiable {
    let slug: String
    let name: String
    let blurb: String?
    let accounts: [SquaddConnectedServices.Account]

    var id: String { slug }
    var isConnected: Bool { !accounts.isEmpty }

    /// Catalog order, then any connected service the catalog doesn't list.
    static func join(_ catalog: SquaddConnectorCatalog, _ connected: SquaddConnectedServices) -> [SquaddConnectorApp] {
        let active = connected.services.mapValues { $0.accounts.filter(\.isActive) }
        let listed = catalog.cards.map { card in
            SquaddConnectorApp(slug: card.slug, name: card.label ?? card.slug, blurb: card.blurb, accounts: active[card.slug] ?? [])
        }
        let known = Set(listed.map(\.slug))
        let extra = active.filter { !known.contains($0.key) && !$0.value.isEmpty }.sorted { $0.key < $1.key }
            .map { SquaddConnectorApp(slug: $0.key, name: $0.key, blurb: nil, accounts: $0.value) }
        return listed + extra
    }
}
