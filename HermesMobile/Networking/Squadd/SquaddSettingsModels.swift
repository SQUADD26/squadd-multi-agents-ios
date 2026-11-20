import Foundation

/// One API key the computer may hold, from `GET /api/config`: only whether it is configured.
/// The companion never sends a key, and this type has nowhere to keep one.
struct SquaddKeyStatus: Identifiable, Equatable {
    let id: String
    let name: String
    let configured: Bool

    /// The keys the desktop's Keys page lists, by their `/api/config` field. A field the
    /// computer doesn't send (an older desktop) is left out rather than shown as missing.
    static let catalog: [(id: String, name: String)] = [
        ("anthropic", "Anthropic"), ("openai", "OpenAI"), ("openrouter", "OpenRouter"), ("xai", "xAI"),
        ("mistral", "Mistral"), ("cerebras", "Cerebras"), ("groq", "Groq"), ("greenference", "Greenference"),
        ("modelgo", "ModelGo"), ("meta", "Meta"), ("deepseek", "DeepSeek"), ("opencodeGo", "OpenCode"),
        ("openaiCompat", "OpenAI-compatible"), ("tts", "ElevenLabs"), ("box", "boat.dev"),
        ("composio", "Composio"), ("treg", "treg"), ("postiz", "Postiz"),
    ]

    /// Reads only each catalog entry's `configured` boolean; every other field, including the
    /// last characters the desktop shows itself, is dropped here.
    static func statuses(fromConfig data: Data) throws -> [SquaddKeyStatus] {
        guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SquaddError.invalidResponse
        }
        return catalog.compactMap { entry in
            guard let field = config[entry.id] as? [String: Any] else { return nil }
            return SquaddKeyStatus(id: entry.id, name: entry.name, configured: field["configured"] as? Bool == true)
        }
    }
}

/// `GET /api/instances`: the computer's engines (one per configured provider install).
struct SquaddEngineList: Decodable {
    let instances: [SquaddEngine]

    private enum CodingKeys: String, CodingKey { case instances }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instances = (try? container.decodeIfPresent([SquaddLossy<SquaddEngine>].self, forKey: .instances))?
            .compactMap(\.value) ?? []
    }
}

struct SquaddEngine: Decodable, Equatable, Identifiable {
    let instanceId: String
    let driverKind: String?
    let displayName: String?
    let snapshot: Snapshot?
    let models: Models?

    var id: String { instanceId }
    /// The companion's whitelist reaches `claude-update` only, and only Claude Code installs take it.
    var isClaudeCode: Bool { driverKind == "claudeAgent" }

    struct Snapshot: Decodable, Equatable {
        let state: String?
        let version: String?
        let authenticated: Bool?
        let update: Update?

        private enum CodingKeys: String, CodingKey { case state, version, authenticated, update }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            state = try? container.decodeIfPresent(String.self, forKey: .state)
            version = try? container.decodeIfPresent(String.self, forKey: .version)
            authenticated = try? container.decodeIfPresent(Bool.self, forKey: .authenticated)
            update = try? container.decodeIfPresent(Update.self, forKey: .update)
        }
    }

    /// The desktop's "update needed" notice. Its shell command stays on the computer.
    struct Update: Decodable, Equatable {
        let title: String?
        let message: String?
    }

    struct Models: Decodable, Equatable {
        let `default`: String?
    }

    private enum CodingKeys: String, CodingKey { case instanceId, driverKind, displayName, snapshot, models }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instanceId = try container.decode(String.self, forKey: .instanceId)
        driverKind = try? container.decodeIfPresent(String.self, forKey: .driverKind)
        displayName = try? container.decodeIfPresent(String.self, forKey: .displayName)
        snapshot = try? container.decodeIfPresent(Snapshot.self, forKey: .snapshot)
        models = try? container.decodeIfPresent(Models.self, forKey: .models)
    }
}

/// `GET /api/bots/:id/mcp-servers`: names and on/off only; commands and addresses stay on the computer.
struct SquaddMCPServerList: Decodable {
    let servers: [SquaddMCPServer]

    private enum CodingKeys: String, CodingKey { case servers }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        servers = (try? container.decodeIfPresent([SquaddLossy<SquaddMCPServer>].self, forKey: .servers))?
            .compactMap(\.value) ?? []
    }
}

struct SquaddMCPServer: Decodable, Equatable, Identifiable {
    let name: String
    /// On for this agent (`on`), falling back to on for the computer (`enabled`).
    let isOn: Bool

    var id: String { name }

    private enum CodingKeys: String, CodingKey { case name, on, enabled }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        let on = try? container.decodeIfPresent(Bool.self, forKey: .on)
        let enabled = try? container.decodeIfPresent(Bool.self, forKey: .enabled)
        isOn = (on ?? enabled) == true
    }
}

/// `GET /api/bots/:id/skills`.
struct SquaddSkillList: Decodable {
    let skills: [SquaddSkill]

    private enum CodingKeys: String, CodingKey { case skills }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        skills = (try? container.decodeIfPresent([SquaddLossy<SquaddSkill>].self, forKey: .skills))?
            .compactMap(\.value) ?? []
    }
}

struct SquaddSkill: Decodable, Equatable, Identifiable {
    let name: String
    let description: String?
    let enabled: Bool?

    var id: String { name }
}

/// `/api/team-memory`: the team's shared facts. Every write answers with the whole list.
struct SquaddMemoryList: Decodable {
    let entries: [SquaddMemoryEntry]

    private enum CodingKeys: String, CodingKey { case entries }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = (try? container.decodeIfPresent([SquaddLossy<SquaddMemoryEntry>].self, forKey: .entries))?
            .compactMap(\.value)
            // Replaced and deleted revisions stay in the file as history; the desktop hides them too.
            .filter { $0.status == nil || $0.status == "accepted" || $0.status == "proposed" } ?? []
    }
}

struct SquaddMemoryEntry: Decodable, Equatable, Identifiable {
    let id: String
    let kind: String
    let name: String
    let detail: String?
    let status: String?
    /// Sent back with an edit or delete, so a change made meanwhile on the computer is refused (409).
    let revision: String?

    /// The kinds the computer accepts, in its order.
    static let kinds = ["person", "place", "decision", "term"]
}

/// An element that decodes to nil instead of failing the array around it.
struct SquaddLossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}
