import Foundation

/// `GET /api/bots` on a Squadd companion: the computer's agents, each with its own thread and
/// the threads of its tasks. Everything but the ids is optional and an agent or task that fails
/// to decode is skipped, so a companion that adds, drops or retypes a field never breaks the list.
struct SquaddBotList: Codable, Equatable {
    let bots: [SquaddBot]
    /// The rooms: chats with several agents (`groups`).
    let rooms: [SquaddRoom]

    private enum CodingKeys: String, CodingKey { case bots, rooms = "groups" }

    init(bots: [SquaddBot], rooms: [SquaddRoom] = []) {
        self.bots = bots
        self.rooms = rooms
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bots = (try? container.decodeIfPresent([Lossy<SquaddBot>].self, forKey: .bots))?.compactMap(\.value) ?? []
        // A bot-to-bot channel (`dm`) is the agents' own, not a room the person opened.
        rooms = ((try? container.decodeIfPresent([Lossy<SquaddRoom>].self, forKey: .rooms))?.compactMap(\.value) ?? [])
            .filter { $0.isDirect != true }
    }
}

/// A room (`WireGroup`): several agents in one chat. Each of its `tasks` is a conversation of
/// its own, one thread the members share; `threadId` is the one open on the desktop.
struct SquaddRoom: Codable, Equatable, Identifiable {
    let id: String
    let threadId: String?
    var name: String?
    let memberIds: [String]
    let unread: Bool?
    let working: Bool?
    var tasks: [SquaddTask]
    let isDirect: Bool?

    private enum CodingKeys: String, CodingKey { case id, threadId, name, memberIds, unread, working, tasks, isDirect = "dm" }

    init(id: String, threadId: String?, name: String?, memberIds: [String], unread: Bool? = nil, working: Bool? = nil,
         tasks: [SquaddTask] = []) {
        self.id = id
        self.threadId = threadId
        self.name = name
        self.memberIds = memberIds
        self.unread = unread
        self.working = working
        self.tasks = tasks
        isDirect = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        threadId = try? container.decodeIfPresent(String.self, forKey: .threadId)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        memberIds = (try? container.decodeIfPresent([String].self, forKey: .memberIds)) ?? []
        unread = try? container.decodeIfPresent(Bool.self, forKey: .unread)
        working = try? container.decodeIfPresent(Bool.self, forKey: .working)
        tasks = (try? container.decodeIfPresent([Lossy<SquaddTask>].self, forKey: .tasks))?.compactMap(\.value) ?? []
        isDirect = try? container.decodeIfPresent(Bool.self, forKey: .isDirect)
    }
}

/// `PATCH /api/groups/:id` and `POST /api/groups/:id/tasks` answer with the room as it now stands.
struct SquaddRoomEnvelope: Decodable {
    let group: SquaddRoom
}

/// One agent. `threadId` is its own chat; `tasks` are the other threads it works in.
struct SquaddBot: Codable, Equatable, Identifiable {
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
    /// The agent's folders in their saved order (`PATCH /api/bots/:id/projects/order`).
    var projects: [SquaddProject]

    private enum CodingKeys: String, CodingKey {
        case id, name, title, threadId, unread, busy, createdAt, tasks, description, soul, avatarUrl, modelSelection, projects
    }

    init(id: String, name: String?, title: String? = nil, threadId: String? = nil, unread: Bool? = nil,
         busy: Bool? = nil, createdAt: Double? = nil, tasks: [SquaddTask] = [], description: String? = nil, soul: String? = nil,
         avatarUrl: String? = nil, modelSelection: SquaddModelSelection? = nil, projects: [SquaddProject] = []) {
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
        self.projects = projects
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
        projects = (try? container.decodeIfPresent([Lossy<SquaddProject>].self, forKey: .projects))?.compactMap(\.value) ?? []
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
    /// The engine can run the computer's agent tools (`capabilities.agentsMcp`): the desktop
    /// offers `/setup`, `/burst` and `/learn` only to an agent on such an engine.
    let runsAgents: Bool

    private enum CodingKeys: String, CodingKey { case instanceId, displayName, snapshot, models, capabilities }
    private enum SnapshotKeys: String, CodingKey { case state }
    private enum CapabilityKeys: String, CodingKey { case agentsMcp }
    private enum ModelsKeys: String, CodingKey { case options }

    init(instanceId: String, displayName: String?, isAvailable: Bool, models: [Model], runsAgents: Bool = false) {
        self.instanceId = instanceId
        self.displayName = displayName
        self.isAvailable = isAvailable
        self.models = models
        self.runsAgents = runsAgents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instanceId = try container.decode(String.self, forKey: .instanceId)
        displayName = try? container.decodeIfPresent(String.self, forKey: .displayName)
        let snapshot = try? container.nestedContainer(keyedBy: SnapshotKeys.self, forKey: .snapshot)
        isAvailable = (try? snapshot?.decodeIfPresent(String.self, forKey: .state)) == "available"
        let models = try? container.nestedContainer(keyedBy: ModelsKeys.self, forKey: .models)
        self.models = (try? models?.decodeIfPresent([Lossy<Model>].self, forKey: .options))?.compactMap(\.value) ?? []
        let capabilities = try? container.nestedContainer(keyedBy: CapabilityKeys.self, forKey: .capabilities)
        runsAgents = (try? capabilities?.decodeIfPresent(Bool.self, forKey: .agentsMcp)) == true
    }
}

extension SquaddBot {
    /// The desktop sidebar's layout of the open threads (`Sidebar.tsx`): folders ordered by where
    /// their first thread sits in `SquaddTask.desktopOrder`, folders with no open thread after them
    /// in the saved order, each with its threads; then the threads in no folder.
    var desktopLayout: (folders: [(project: SquaddProject, tasks: [SquaddTask])], loose: [SquaddTask]) {
        let open = SquaddTask.desktopOrder(tasks).filter { !$0.isArchived }
        func rank(_ project: SquaddProject) -> Int { open.firstIndex { $0.projectId == project.id } ?? .max }
        let folders = projects.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map { _, project in (project: project, tasks: open.filter { $0.projectId == project.id }) }
        let ids = Set(projects.map(\.id))
        return (folders, open.filter { !ids.contains($0.projectId ?? "") })
    }

    /// The saved folder order after moving `projectId` up (-1) or down (+1) in the shown order:
    /// it steps past folders until `desktopLayout` changes, since a folder with an open thread sits
    /// by that thread whatever the saved order says. Nil when no move changes what shows.
    func projects(movingFolder projectId: String, by offset: Int) -> [SquaddProject]? {
        guard var index = projects.firstIndex(where: { $0.id == projectId }) else { return nil }
        let shown = desktopLayout.folders.map(\.project.id)
        var moved = self
        while moved.projects.indices.contains(index + offset) {
            moved.projects.swapAt(index, index + offset)
            index += offset
            if moved.desktopLayout.folders.map(\.project.id) != shown { return moved.projects }
        }
        return nil
    }
}

/// One of an agent's folders: a name, maybe an emoji, and the threads whose `projectId` is its id.
/// Organizing only; a folder never owns settings or a working directory.
struct SquaddProject: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let emoji: String?

    init(id: String, name: String, emoji: String? = nil) {
        self.id = id
        self.name = name
        self.emoji = emoji
    }
}

/// `POST /api/bots/:id/projects`: the new folder.
struct SquaddProjectResponse: Decodable {
    let project: SquaddProject
}

/// One task thread of an agent. The desktop lists an agent's threads pinned first, then by
/// `lastThreadOrderAt` (else `createdAt`), newest first, and hides the archived ones.
struct SquaddTask: Codable, Equatable, Identifiable {
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
    /// A room's conversation says `working` where an agent's thread says `busy`.
    private enum RoomKeys: String, CodingKey { case working }

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
        busy = (try? container.decodeIfPresent(Bool.self, forKey: .busy))
            ?? (try? decoder.container(keyedBy: RoomKeys.self).decodeIfPresent(Bool.self, forKey: .working))
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
    /// `device.id`: the id the computer gave this iPhone, which a secret's envelope names.
    let deviceId: String?

    private enum CodingKeys: String, CodingKey { case token, serverName, endpoints, device }
    private struct Device: Decodable { let id: String }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        serverName = try container.decodeIfPresent(String.self, forKey: .serverName)
        endpoints = ((try? container.decodeIfPresent([SquaddLossy<SquaddEndpoint>].self, forKey: .endpoints)) ?? nil)?
            .compactMap(\.value) ?? []
        deviceId = (try? container.decodeIfPresent(Device.self, forKey: .device))?.id
    }
}

/// An element that decodes to nil instead of failing the array around it.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}
