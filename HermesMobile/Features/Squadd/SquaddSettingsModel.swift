import Foundation
import Observation

/// What a Squadd settings page shows while it reads the computer.
enum SquaddLoadPhase: Equatable {
    case loading
    case loaded
    case failed(String)
}

/// The paired computer's settings as the phone sees them (#28): engines with the Claude update,
/// which keys are set, each agent's MCP servers and skills, and the team memory. Built per server
/// from its device token, so nothing read here shows under another server.
@MainActor @Observable
final class SquaddSettingsModel {
    let client: SquaddCompanionClient
    private let onUnpaired: () -> Void

    private(set) var keys: [SquaddKeyStatus] = []
    private(set) var keysPhase = SquaddLoadPhase.loading

    private(set) var engines: [SquaddEngine] = []
    private(set) var enginesPhase = SquaddLoadPhase.loading
    /// The Claude install being updated; one at a time, as the computer allows.
    private(set) var updatingEngine: String?
    private(set) var updateMessage: String?

    private(set) var agents: [SquaddBot] = []
    private(set) var agentsPhase = SquaddLoadPhase.loading
    private(set) var tools: [String: AgentTools] = [:]

    private(set) var memory: [SquaddMemoryEntry] = []
    private(set) var memoryPhase = SquaddLoadPhase.loading
    /// Why the last memory change didn't land; cleared by the next one.
    private(set) var memoryError: String?

    struct AgentTools: Equatable {
        var servers: [SquaddMCPServer]
        var skills: [SquaddSkill]
        var phase: SquaddLoadPhase
    }

    init(client: SquaddCompanionClient, onUnpaired: @escaping () -> Void) {
        self.client = client
        self.onUnpaired = onUnpaired
    }

    func loadKeys() async {
        keysPhase = await phase { keys = try await client.keyStatuses() }
    }

    func loadEngines() async {
        enginesPhase = await phase { engines = try await client.engines() }
    }

    func updateClaude(_ engine: SquaddEngine) async {
        guard updatingEngine == nil else { return }
        updatingEngine = engine.id
        updateMessage = nil
        defer { updatingEngine = nil }
        do {
            let version = try await client.updateClaude(instanceId: engine.instanceId)
            updateMessage = version.map { String(localized: "Claude Code is now \($0).") }
                ?? String(localized: "Claude Code is up to date.")
        } catch {
            updateMessage = message(for: error)
        }
        await loadEngines()
    }

    func loadAgents() async {
        agentsPhase = await phase { agents = try await client.bots() }
    }

    func loadTools(for agent: SquaddBot) async {
        var tools = tools[agent.id] ?? AgentTools(servers: [], skills: [], phase: .loading)
        tools.phase = await phase {
            async let servers = client.mcpServers(botId: agent.id)
            async let skills = client.skills(botId: agent.id)
            (tools.servers, tools.skills) = try await (servers, skills)
        }
        self.tools[agent.id] = tools
    }

    func loadMemory() async {
        memoryPhase = await phase { memory = try await client.teamMemory() }
    }

    /// Adds, edits or deletes one memory. Only the computer's answer changes the list; a refusal
    /// leaves it as it was, and a conflict (changed meanwhile on the computer) reloads it.
    @discardableResult
    func changeMemory(_ change: @escaping (SquaddCompanionClient) async throws -> [SquaddMemoryEntry]) async -> Bool {
        memoryError = nil
        do {
            memory = try await change(client)
            return true
        } catch SquaddError.status(409) {
            memoryError = String(localized: "This memory changed on the computer. Here is its latest version.")
            await loadMemory()
        } catch {
            memoryError = message(for: error)
        }
        return false
    }

    // MARK: - Errors

    private func phase(_ work: () async throws -> Void) async -> SquaddLoadPhase {
        do {
            try await work()
            return .loaded
        } catch {
            return .failed(message(for: error))
        }
    }

    private func message(for error: Error) -> String {
        switch error {
        case SquaddError.unpaired:
            onUnpaired()
            return String(localized: "This iPhone is no longer paired with the computer.")
        case SquaddError.status(409):
            return String(localized: "The computer is busy. Try again when the agents have finished.")
        case SquaddError.status(403):
            return String(localized: "This can only be changed on the computer.")
        case SquaddError.status(let code):
            return String(localized: "The computer answered with an error (\(code)).")
        default:
            return String(localized: "Can't reach the computer.")
        }
    }
}
