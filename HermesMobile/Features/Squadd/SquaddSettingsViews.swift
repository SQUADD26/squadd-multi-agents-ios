import SwiftUI

/// The paired computer's own settings on a Squadd server's Settings page (#28): engines with the
/// Claude update, keys, each agent's tools and the team memory. Shown for the active server only,
/// as a Hermes server's sections are.
struct SquaddServerSections: View {
    @Bindable var authManager: AuthManager
    let server: URL
    /// Made once in `.task`, so a pass of the page reads no Keychain.
    @State private var model: SquaddSettingsModel?

    var body: some View {
        Section {
            link(String(localized: "Engines"), systemImage: "cpu") { SquaddEnginesPage(model: $0) }
            link(String(localized: "API Keys"), systemImage: "key") { SquaddKeysPage(model: $0) }
            link(String(localized: "Agents' Tools"), systemImage: "wrench.and.screwdriver") { SquaddAgentsToolsPage(model: $0) }
            link(String(localized: "Team Memory"), systemImage: "brain") { SquaddTeamMemoryPage(model: $0) }
            link(String(localized: "Connected Apps"), systemImage: "app.connected.to.app.below.fill") { [weak authManager, server] model in
                SquaddConnectorsPage(client: model.client, onUnpaired: { authManager?.squaddUnpaired(server: server) })
            }
        } header: {
            Text("Computer")
        } appFooter: {
            Text("Read from the paired computer. Keys, MCP servers and skills are changed on the computer.")
        }
        .task {
            guard model == nil else { return }
            let token = authManager.squaddToken(for: server) ?? ""
            model = SquaddSettingsModel(client: SquaddCompanionClient(server: server, token: token),
                                        onUnpaired: { [weak authManager, server] in authManager?.squaddUnpaired(server: server) })
        }
    }

    private func link<Page: View>(_ title: String, systemImage: String,
                                  @ViewBuilder page: @escaping (SquaddSettingsModel) -> Page) -> some View {
        NavigationLink {
            if let model { page(model) }
        } label: {
            SettingsLabel(title: title, systemImage: systemImage)
        }
        .disabled(model == nil)
    }
}

/// Loading, failure and empty states over a Squadd settings list.
struct SquaddPhaseOverlay: View {
    let phase: SquaddLoadPhase
    let isEmpty: Bool
    let emptyTitle: String
    let retry: () async -> Void

    var body: some View {
        switch phase {
        case .loading where isEmpty:
            ProgressView()
        case .failed(let message) where isEmpty:
            ContentUnavailableView {
                Label("Can't Reach the Computer", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await retry() } }
            }
        case .loaded where isEmpty:
            ContentUnavailableView(emptyTitle, systemImage: "tray")
        default:
            EmptyView()
        }
    }
}

struct SquaddEnginesPage: View {
    let model: SquaddSettingsModel

    private var ready: [SquaddEngine] { model.engines.filter { $0.snapshot?.state == "available" } }
    private var notSetUp: [SquaddEngine] { model.engines.filter { $0.snapshot?.state != "available" } }

    var body: some View {
        AppList {
            if let message = model.updateMessage {
                Section { Text(message) }
            }
            if !ready.isEmpty {
                Section(String(localized: "Ready")) {
                    ForEach(ready) { engine in row(engine) }
                }
            }
            if !notSetUp.isEmpty {
                Section {
                    ForEach(notSetUp) { engine in Text(engine.displayName ?? engine.instanceId) }
                } header: {
                    Text("Not Set Up")
                } appFooter: {
                    Text("Engines are installed and signed in on the computer.")
                }
            }
        }
        .settingsPage(String(localized: "Engines"))
        .overlay { SquaddPhaseOverlay(phase: model.enginesPhase, isEmpty: model.engines.isEmpty,
                                      emptyTitle: String(localized: "No Engines"), retry: model.loadEngines) }
        .refreshable { await model.loadEngines() }
        .task { await model.loadEngines() }
    }

    private func row(_ engine: SquaddEngine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(engine.displayName ?? engine.instanceId)
            Text(details(engine))
                .font(AppFont.footnote())
                .foregroundStyle(.appSecondary)
            if let update = engine.snapshot?.update?.title {
                Label(update, systemImage: "arrow.down.circle")
                    .font(AppFont.footnote())
                    .foregroundStyle(.orange)
            }
            if engine.isClaudeCode {
                Button {
                    Task { await model.updateClaude(engine) }
                } label: {
                    if model.updatingEngine == engine.id {
                        ProgressView()
                    } else {
                        Text("Update Claude")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(model.updatingEngine != nil)
                .accessibilityHint("Updates Claude Code on the computer. It waits if an agent is working.")
            }
        }
        .padding(.vertical, 2)
    }

    private func details(_ engine: SquaddEngine) -> String {
        var parts: [String] = []
        if let version = engine.snapshot?.version { parts.append(version) }
        if engine.snapshot?.authenticated == true { parts.append(String(localized: "Signed in")) }
        if let model = engine.models?.default { parts.append(model) }
        return parts.joined(separator: " · ")
    }
}

struct SquaddKeysPage: View {
    let model: SquaddSettingsModel

    var body: some View {
        AppList {
            if !model.keys.isEmpty {
                Section {
                    ForEach(model.keys) { key in
                        LabeledContent(key.name) {
                            Label(key.configured ? String(localized: "Set") : String(localized: "Not set"),
                                  systemImage: key.configured ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(key.configured ? Color.green : Color.appSecondary)
                        }
                    }
                } appFooter: {
                    Text("Keys are added and changed on the computer and never reach this iPhone.")
                }
            }
        }
        .settingsPage(String(localized: "API Keys"))
        .overlay { SquaddPhaseOverlay(phase: model.keysPhase, isEmpty: model.keys.isEmpty,
                                      emptyTitle: String(localized: "No Keys"), retry: model.loadKeys) }
        .refreshable { await model.loadKeys() }
        .task { await model.loadKeys() }
    }
}

struct SquaddAgentsToolsPage: View {
    let model: SquaddSettingsModel

    var body: some View {
        AppList {
            ForEach(model.agents) { agent in
                NavigationLink {
                    SquaddAgentToolsPage(model: model, agent: agent)
                } label: {
                    Text(agent.name ?? String(localized: "Unnamed Agent"))
                }
            }
        }
        .settingsPage(String(localized: "Agents' Tools"))
        .overlay { SquaddPhaseOverlay(phase: model.agentsPhase, isEmpty: model.agents.isEmpty,
                                      emptyTitle: String(localized: "No Agents"), retry: model.loadAgents) }
        .refreshable { await model.loadAgents() }
        .task { await model.loadAgents() }
    }
}

struct SquaddAgentToolsPage: View {
    let model: SquaddSettingsModel
    let agent: SquaddBot

    private var tools: SquaddSettingsModel.AgentTools? { model.tools[agent.id] }

    var body: some View {
        AppList {
            if let tools, tools.phase == .loaded {
                Section(String(localized: "MCP Servers")) {
                    if tools.servers.isEmpty { Text("None").foregroundStyle(.appSecondary) }
                    ForEach(tools.servers) { server in
                        LabeledContent(server.name) { onOff(server.isOn) }
                    }
                }
                Section {
                    if tools.skills.isEmpty { Text("None").foregroundStyle(.appSecondary) }
                    ForEach(tools.skills) { skill in
                        LabeledContent {
                            onOff(skill.enabled == true)
                        } label: {
                            Text(skill.name)
                            if let description = skill.description { Text(description) }
                        }
                    }
                } header: {
                    Text("Skills")
                } appFooter: {
                    Text("MCP servers and skills are added and switched on the computer.")
                }
            }
        }
        .settingsPage(agent.name ?? String(localized: "Unnamed Agent"))
        .overlay {
            SquaddPhaseOverlay(phase: tools?.phase ?? .loading, isEmpty: tools?.phase != .loaded,
                               emptyTitle: "", retry: { await model.loadTools(for: agent) })
        }
        .refreshable { await model.loadTools(for: agent) }
        .task { await model.loadTools(for: agent) }
    }

    private func onOff(_ isOn: Bool) -> some View {
        SettingsStatusPill(label: isOn ? String(localized: "On") : String(localized: "Off"),
                           tint: isOn ? .green : Color(.appTextSecondary))
    }
}
