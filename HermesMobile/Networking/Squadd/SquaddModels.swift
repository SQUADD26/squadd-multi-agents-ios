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
    let tasks: [SquaddTask]

    private enum CodingKeys: String, CodingKey { case id, name, title, threadId, unread, busy, createdAt, tasks }

    init(id: String, name: String?, title: String? = nil, threadId: String? = nil, unread: Bool? = nil,
         busy: Bool? = nil, createdAt: Double? = nil, tasks: [SquaddTask] = []) {
        self.id = id
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
    }
}

/// One task thread of an agent: its title and when it last changed.
struct SquaddTask: Decodable, Equatable, Identifiable {
    let threadId: String
    let title: String?
    /// Milliseconds since 1970.
    let updatedAt: Double?
    let unread: Bool?
    let busy: Bool?

    var id: String { threadId }

    private enum CodingKeys: String, CodingKey { case threadId, title, updatedAt, unread, busy }

    init(threadId: String, title: String?, updatedAt: Double? = nil, unread: Bool? = nil, busy: Bool? = nil) {
        self.threadId = threadId
        self.title = title
        self.updatedAt = updatedAt
        self.unread = unread
        self.busy = busy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threadId = try container.decode(String.self, forKey: .threadId)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        updatedAt = try? container.decodeIfPresent(Double.self, forKey: .updatedAt)
        unread = try? container.decodeIfPresent(Bool.self, forKey: .unread)
        busy = try? container.decodeIfPresent(Bool.self, forKey: .busy)
    }
}

/// `POST /api/pair`'s answer: the device token every later request carries as its bearer.
struct SquaddPairResponse: Decodable {
    let token: String
    let serverName: String?
}

/// An element that decodes to nil instead of failing the array around it.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}
