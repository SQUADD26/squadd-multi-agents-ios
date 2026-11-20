import AppIntents
import Foundation

/// An agent of a paired Squadd computer, as Shortcuts and Siri offer it: `<server URL>|<agent id>`,
/// so the same agent name on two computers is two choices and a saved Shortcut keeps its computer.
struct SquaddAgentEntity: AppEntity, Identifiable, Equatable {
    let id: String
    let botID: String
    let name: String
    let subtitle: String?
    /// The agent's own chat, the thread its link opens.
    let threadID: String
    let server: URL

    init?(bot: SquaddBot, server: URL) {
        guard let threadID = bot.threadId, !threadID.isEmpty else { return nil }
        let section = SquaddAgentSection(bot: bot)
        id = "\(server.absoluteString)|\(bot.id)"
        botID = bot.id
        name = section.name
        subtitle = section.subtitle
        self.threadID = threadID
        self.server = server
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "Agent") }
    static var defaultQuery = SquaddAgentQuery()

    var displayRepresentation: DisplayRepresentation {
        if let subtitle { return DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)") }
        return DisplayRepresentation(title: "\(name)")
    }

    /// The link that opens this agent's chat on its computer.
    var threadLink: SquaddThreadLink {
        SquaddThreadLink(threadID: threadID, botID: botID, server: server)
    }
}

struct SquaddAgentQuery: EntityQuery {
    func entities(for identifiers: [SquaddAgentEntity.ID]) async throws -> [SquaddAgentEntity] {
        await SquaddAgentProvider.entities(for: identifiers)
    }

    func suggestedEntities() async throws -> [SquaddAgentEntity] {
        await SquaddAgentProvider.activeServerAgents()
    }
}

/// Reads the agents behind the entity: the companion's `GET /api/bots` with the server's device
/// token. A server that isn't a paired Squadd one, or a companion that can't be reached, offers none.
enum SquaddAgentProvider {
    /// The active server's agents, when it is a paired Squadd server.
    static func activeServerAgents(
        active: URL? = ProfileEntityProvider.savedServerURL(), servers: [ServerAccount] = ServerRegistry.shared.servers,
        keychain: any KeychainStoring = KeychainStore(), session: URLSession = .shared
    ) async -> [SquaddAgentEntity] {
        guard let active else { return [] }
        return await agents(on: active, servers: servers, keychain: keychain, session: session)
    }

    /// The saved choices, each read again from its own computer.
    static func entities(
        for identifiers: [String], servers: [ServerAccount] = ServerRegistry.shared.servers,
        keychain: any KeychainStoring = KeychainStore(), session: URLSession = .shared
    ) async -> [SquaddAgentEntity] {
        let wanted = Set(identifiers)
        let computers = Set(identifiers.compactMap { $0.split(separator: "|").first.map(String.init) })
        var found: [SquaddAgentEntity] = []
        for computer in computers {
            guard let server = URL(string: computer) else { continue }
            found += await agents(on: server, servers: servers, keychain: keychain, session: session).filter { wanted.contains($0.id) }
        }
        return found
    }

    private static func agents(on server: URL, servers: [ServerAccount], keychain: any KeychainStoring,
                               session: URLSession) async -> [SquaddAgentEntity] {
        guard servers.contains(where: { $0.kind == .squadd && $0.id == server.absoluteString }),
              let token = (try? keychain.load(.squaddDeviceToken, scope: server.absoluteString)) ?? nil,
              let bots = try? await SquaddCompanionClient(server: server, token: token, session: session).bots()
        else { return [] }
        return bots.compactMap { SquaddAgentEntity(bot: $0, server: server) }
    }
}

/// "Open Agent": opens the app on an agent's chat on its computer, to write to it. Goes through
/// the same deep-link path as a thread link, so a cold launch or another active server still lands
/// there (`SquaddThreadLink`).
struct OpenSquaddAgentIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Agent"
    static var description = IntentDescription("Open an agent’s chat, ready to write to it.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Agent")
    var agent: SquaddAgentEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$agent)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppIntentRouter.shared.requestDeepLink(agent.threadLink.url)
        return .result()
    }
}
