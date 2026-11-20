import Foundation

/// `GET /api/bots` on a Squadd companion: the computer's agents, each with its own thread and
/// the threads of its tasks. Everything but the ids is optional and an agent or task that fails
/// to decode is skipped, so a companion that adds, drops or retypes a field never breaks the list.
struct SquaddBotList: Decodable, Equatable {
    let bots: [SquaddBot]

    private enum CodingKeys: String, CodingKey { case bots }

    init(bots: [SquaddBot]) { self.bots = bots }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bots = (try? container.decodeIfPresent([Lossy<SquaddBot>].self, forKey: .bots))?.compactMap(\.value) ?? []
    }
}

/// One agent. `threadId` is its own chat; `tasks` are the other threads it works in.
struct SquaddBot: Decodable, Equatable, Identifiable {
    let id: String
    let name: String?
    let title: String?
    let threadId: String?
    let unread: Bool?
    let busy: Bool?
    /// Milliseconds since 1970, as the companion sends every time.
    let createdAt: Double?
    var tasks: [SquaddTask]
    let description: String?
    /// The agent's standing instructions (the desktop's «soul»).
    let soul: String?
    /// A path on the companion (`/api/attachments/<file>`), read with the device token.
    let avatarUrl: String?
    let modelSelection: SquaddModelSelection?

    private enum CodingKeys: String, CodingKey {
        case id, name, title, threadId, unread, busy, createdAt, tasks, description, soul, avatarUrl, modelSelection
    }

    init(id: String, name: String?, title: String? = nil, threadId: String? = nil, unread: Bool? = nil,
         busy: Bool? = nil, createdAt: Double? = nil, tasks: [SquaddTask] = [], description: String? = nil, soul: String? = nil,
         avatarUrl: String? = nil, modelSelection: SquaddModelSelection? = nil) {
        self.id = id
        self.description = description
        self.soul = soul
        self.avatarUrl = avatarUrl
        self.modelSelection = modelSelection
        self.name = name
        self.title = title
        self.threadId = threadId
        self.unread = unread
        self.busy = busy
        self.createdAt = createdAt
        self.tasks = tasks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        threadId = try? container.decodeIfPresent(String.self, forKey: .threadId)
        unread = try? container.decodeIfPresent(Bool.self, forKey: .unread)
        busy = try? container.decodeIfPresent(Bool.self, forKey: .busy)
        createdAt = try? container.decodeIfPresent(Double.self, forKey: .createdAt)
        tasks = (try? container.decodeIfPresent([Lossy<SquaddTask>].self, forKey: .tasks))?.compactMap(\.value) ?? []
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        soul = try? container.decodeIfPresent(String.self, forKey: .soul)
        avatarUrl = try? container.decodeIfPresent(String.self, forKey: .avatarUrl)
        modelSelection = try? container.decodeIfPresent(SquaddModelSelection.self, forKey: .modelSelection)
    }
}

/// Which engine (`instanceId`) and model an agent runs on. `PATCH /api/bots/:id/model` takes the
/// same shape and refuses a model the instance does not offer.
struct SquaddModelSelection: Codable, Equatable {
    let instanceId: String
    let model: String
}

/// `POST /api/bots` and the bot `PATCH`es answer with the agent as it now stands.
struct SquaddBotEnvelope: Decodable {
    let bot: SquaddBot
}

/// `GET /api/instances`: the computer's engines and the models each offers. Only an engine whose
/// snapshot says `available` can run an agent; an engine or model that fails to decode is skipped.
struct SquaddInstanceList: Decodable {
    let instances: [SquaddInstance]

    private enum CodingKeys: String, CodingKey { case instances }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instances = (try? container.decodeIfPresent([Lossy<SquaddInstance>].self, forKey: .instances))?.compactMap(\.value) ?? []
    }
}

struct SquaddInstance: Decodable, Equatable {
    struct Model: Decodable, Equatable {
        let id: String
        let label: String?
        /// The desktop lists these under "Older".
        let older: Bool?
    }

    let instanceId: String
    let displayName: String?
    let isAvailable: Bool
    let models: [Model]

    private enum CodingKeys: String, CodingKey { case instanceId, displayName, snapshot, models }
    private enum SnapshotKeys: String, CodingKey { case state }
    private enum ModelsKeys: String, CodingKey { case options }

    init(instanceId: String, displayName: String?, isAvailable: Bool, models: [Model]) {
        self.instanceId = instanceId
        self.displayName = displayName
        self.isAvailable = isAvailable
        self.models = models
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instanceId = try container.decode(String.self, forKey: .instanceId)
        displayName = try? container.decodeIfPresent(String.self, forKey: .displayName)
        let snapshot = try? container.nestedContainer(keyedBy: SnapshotKeys.self, forKey: .snapshot)
        isAvailable = (try? snapshot?.decodeIfPresent(String.self, forKey: .state)) == "available"
        let models = try? container.nestedContainer(keyedBy: ModelsKeys.self, forKey: .models)
        self.models = (try? models?.decodeIfPresent([Lossy<Model>].self, forKey: .options))?.compactMap(\.value) ?? []
    }
}

/// One task thread of an agent. The desktop lists an agent's threads pinned first, then by
/// `lastThreadOrderAt` (else `createdAt`), newest first, and hides the archived ones.
struct SquaddTask: Decodable, Equatable, Identifiable {
    let threadId: String
    var title: String?
    /// Milliseconds since 1970, like every companion time.
    let updatedAt: Double?
    let createdAt: Double?
    let lastThreadOrderAt: Double?
    let unread: Bool?
    let busy: Bool?
    var pinned: Bool?
    var archivedAt: Double?
    var projectId: String?

    var id: String { threadId }
    var isPinned: Bool { pinned == true }
    var isArchived: Bool { archivedAt != nil }

    private enum CodingKeys: String, CodingKey {
        case threadId, title, updatedAt, createdAt, lastThreadOrderAt, unread, busy, pinned, archivedAt, projectId
    }

    init(threadId: String, title: String?, updatedAt: Double? = nil, createdAt: Double? = nil, lastThreadOrderAt: Double? = nil,
         unread: Bool? = nil, busy: Bool? = nil, pinned: Bool? = nil, archivedAt: Double? = nil, projectId: String? = nil) {
        self.threadId = threadId
        self.title = title
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.lastThreadOrderAt = lastThreadOrderAt
        self.unread = unread
        self.busy = busy
        self.pinned = pinned
        self.archivedAt = archivedAt
        self.projectId = projectId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threadId = try container.decode(String.self, forKey: .threadId)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        updatedAt = try? container.decodeIfPresent(Double.self, forKey: .updatedAt)
        createdAt = try? container.decodeIfPresent(Double.self, forKey: .createdAt)
        lastThreadOrderAt = try? container.decodeIfPresent(Double.self, forKey: .lastThreadOrderAt)
        unread = try? container.decodeIfPresent(Bool.self, forKey: .unread)
        busy = try? container.decodeIfPresent(Bool.self, forKey: .busy)
        pinned = try? container.decodeIfPresent(Bool.self, forKey: .pinned)
        archivedAt = try? container.decodeIfPresent(Double.self, forKey: .archivedAt)
        projectId = try? container.decodeIfPresent(String.self, forKey: .projectId)
    }

    /// The desktop sidebar's order (`orderedThreadList` in openmausbot's wire): pinned first, then
    /// the newest `lastThreadOrderAt` or `createdAt`; ties keep the companion's order.
    static func desktopOrder(_ tasks: [SquaddTask]) -> [SquaddTask] {
        tasks.enumerated().sorted { a, b in
            if a.element.isPinned != b.element.isPinned { return a.element.isPinned }
            let left = a.element.lastThreadOrderAt ?? a.element.createdAt ?? 0
            let right = b.element.lastThreadOrderAt ?? b.element.createdAt ?? 0
            return left != right ? left > right : a.offset < b.offset
        }.map(\.element)
    }
}

/// `POST /api/bots/:id/tasks` and `PATCH /api/bots/:id/tasks/:threadId`: the thread as saved.
struct SquaddTaskResponse: Decodable {
    let task: SquaddTask
}

/// `GET /api/search`: matches in the messages of every conversation the phone can see.
struct SquaddSearchResponse: Decodable {
    let hits: [SquaddSearchHit]

    private enum CodingKeys: String, CodingKey { case hits }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hits = (try? container.decodeIfPresent([Lossy<SquaddSearchHit>].self, forKey: .hits))?.compactMap(\.value) ?? []
    }
}

/// One search match: the snippet around it, and the agent (`name`) and thread (`task`) it is in.
/// A room's match has `groupId` and no `botId`.
struct SquaddSearchHit: Decodable, Equatable, Identifiable {
    let threadId: String
    let messageId: String
    let snippet: String
    let at: Double?
    let botId: String?
    let name: String?
    let task: String?

    var id: String { threadId + "/" + messageId }
}

/// `POST /api/pair`'s answer: the device token every later request carries as its bearer.
struct SquaddPairResponse: Decodable {
    let token: String
    let serverName: String?
    /// The computer's routes, best first (#9); a companion without them sends none.
    let endpoints: [SquaddEndpoint]

    private enum CodingKeys: String, CodingKey { case token, serverName, endpoints }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        serverName = try container.decodeIfPresent(String.self, forKey: .serverName)
        endpoints = ((try? container.decodeIfPresent([SquaddLossy<SquaddEndpoint>].self, forKey: .endpoints)) ?? nil)?
            .compactMap(\.value) ?? []
    }
}

/// An element that decodes to nil instead of failing the array around it.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}
