import Foundation

/// The companion routes behind the phone's Squadd settings (`companion/src/routes.ts`). Keys,
/// MCP servers and skills are read-only there; team memory and the Claude update are the writes.
extension SquaddCompanionClient {
    /// Which API keys the computer holds, as configured or not.
    func keyStatuses() async throws -> [SquaddKeyStatus] {
        try SquaddKeyStatus.statuses(fromConfig: await call("GET", "api/config"))
    }

    func engines() async throws -> [SquaddEngine] {
        try JSONDecoder().decode(SquaddEngineList.self, from: await call("GET", "api/instances?fresh=1")).instances
    }

    /// Updates one Claude Code install; the computer refuses (409) while a Claude turn runs.
    /// Answers the version it now reports.
    func updateClaude(instanceId: String) async throws -> String? {
        struct Answer: Decodable { let version: String? }
        let path = "api/instances/\(Self.segment(instanceId))/claude-update"
        return try JSONDecoder().decode(Answer.self, from: await call("POST", path, body: [:])).version
    }

    func mcpServers(botId: String) async throws -> [SquaddMCPServer] {
        try JSONDecoder().decode(SquaddMCPServerList.self, from: await call("GET", "api/bots/\(Self.segment(botId))/mcp-servers")).servers
    }

    func skills(botId: String) async throws -> [SquaddSkill] {
        try JSONDecoder().decode(SquaddSkillList.self, from: await call("GET", "api/bots/\(Self.segment(botId))/skills")).skills
    }

    /// The whole team's memory (the empty section; departments have their own).
    func teamMemory() async throws -> [SquaddMemoryEntry] {
        try Self.memory(await call("GET", "api/team-memory?section="))
    }

    func addMemory(kind: String, name: String, detail: String) async throws -> [SquaddMemoryEntry] {
        try Self.memory(await call("POST", "api/team-memory?section=", body: ["kind": kind, "name": name, "detail": detail]))
    }

    func editMemory(_ entry: SquaddMemoryEntry, kind: String, name: String, detail: String) async throws -> [SquaddMemoryEntry] {
        let body = ["kind": kind, "name": name, "detail": detail, "expectedRevision": entry.revision ?? ""]
        return try Self.memory(await call("PATCH", "api/team-memory/\(Self.segment(entry.id))?section=", body: body))
    }

    func deleteMemory(_ entry: SquaddMemoryEntry) async throws -> [SquaddMemoryEntry] {
        let revision = Self.segment(entry.revision ?? "")
        return try Self.memory(await call("DELETE", "api/team-memory/\(Self.segment(entry.id))?section=&revision=\(revision)"))
    }

    // MARK: - Plumbing

    /// `pathAndQuery` is relative to the server and already escaped.
    func call(_ method: String, _ pathAndQuery: String, body: [String: String]? = nil) async throws -> Data {
        guard let url = URL(string: pathAndQuery, relativeTo: base.appendingPathComponent("/")) else {
            throw SquaddError.invalidResponse
        }
        var request = URLRequest(url: url.absoluteURL)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return try await Self.send(request, session: session)
    }

    /// One escaped path segment or query value.
    static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_."))) ?? ""
    }

    private static func memory(_ data: Data) throws -> [SquaddMemoryEntry] {
        try JSONDecoder().decode(SquaddMemoryList.self, from: data).entries
    }
}
