import SwiftUI

/// Routes a Squadd server to its own screens and every other server to `webui`, the screen
/// `ContentView` already shows for it: the agent list while paired, the pair-again screen once not.
struct SquaddRoute<Webui: View>: View {
    @Bindable var authManager: AuthManager
    let server: URL
    @ViewBuilder let webui: () -> Webui

    var body: some View {
        if authManager.kind(of: server) == .squadd {
            if case .loggedIn = authManager.state {
                SquaddServerHome(authManager: authManager, server: server).id(server)
            } else {
                SquaddPairAgainView(authManager: authManager, server: server).id(server)
            }
        } else {
            webui()
        }
    }
}

/// A Squadd server's home, built like the Hermes Sessions home (`HermesSessionListView`): the same
/// header with the server's avatar and switcher, then each agent's task threads in session rows,
/// read from the companion's `GET /api/bots`. Threads don't open yet: chat is its own ticket.
struct SquaddServerHome: View {
    @Bindable var authManager: AuthManager
    let server: URL
    /// Made once in `.task`, not in `init`, so a pass of the parent reads no Keychain.
    @State private var model: SquaddAgentListModel?
    @State private var client: SquaddCompanionClient?
    @State private var editingAgent: SquaddBot?
    @State private var isCreatingAgent = false
    @State private var isShowingSettings = false
    @State private var isAddingServer = false

    var body: some View {
        NavigationStack {
            AppList(rows: .plain) {
                SessionsHeader(logoColor: HeaderLogoColor.color(for: identity.headerLogoColorHex), avatar: avatar,
                               isSearchDisabled: true, openSearch: {})
                    .sessionsTopChromeListRow()
                rows
            }
            .refreshable { await model?.load() }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task {
            if model == nil {
                let client = SquaddCompanionClient(server: server, token: authManager.squaddToken(for: server) ?? "")
                self.client = client
                model = SquaddAgentListModel(
                    fetch: { try await client.bots() },
                    onUnpaired: { [weak authManager, server] in authManager?.squaddUnpaired(server: server) }
                )
            }
            await model?.load()
        }
        .sheet(isPresented: $isShowingSettings) {
            NavigationStack {
                SettingsView(authManager: authManager, server: server)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingSettings = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $isAddingServer) { SquaddAddServerSheet(authManager: authManager) }
        .sheet(item: $editingAgent) { agentEditor(for: $0) }
        .sheet(isPresented: $isCreatingAgent) { agentEditor(for: nil) }
    }

    @ViewBuilder
    private func agentEditor(for bot: SquaddBot?) -> some View {
        if let client {
            SquaddAgentEditorView(
                client: client, bot: bot,
                onChange: { Task { await model?.load() } },
                onUnpaired: { [weak authManager, server] in authManager?.squaddUnpaired(server: server) }
            )
        }
    }

    private var newAgentButton: some View {
        Button { isCreatingAgent = true } label: {
            Label("New Agent", systemImage: "plus")
                .font(AppFont.subheadline().bold())
        }
        .disabled(client == nil)
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .sessionsScreenListRow()
    }

    @ViewBuilder
    private var rows: some View {
        switch model?.phase ?? .loading {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
                .sessionsScreenListRow()
        case .failed:
            ContentUnavailableView {
                Label("Can't Reach the Computer", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check that the computer is on and on the same network or tailnet.")
            } actions: {
                Button("Try Again") { Task { await model?.load() } }
            }
            .sessionsScreenListRow()
        case .loaded(let sections) where sections.isEmpty:
            ContentUnavailableView("No Agents", systemImage: "person.2",
                                   description: Text("Agents created on the computer show here."))
                .sessionsScreenListRow()
            newAgentButton
        case .loaded(let sections):
            newAgentButton
            ForEach(sections) { section in
                SquaddAgentHeader(section: section, client: client) { editingAgent = section.bot }
                    .sessionsScreenListRow()
                if section.threads.isEmpty {
                    Text("No threads yet")
                        .font(AppFont.subheadline())
                        .foregroundStyle(.appSecondary)
                        .padding(.horizontal, 24)
                        .sessionsScreenListRow()
                }
                ForEach(section.threads) { thread in
                    SessionRowView(session: thread, showsMessageCount: false, showsWorkspace: false,
                                   isUnread: section.unreadThreadIDs.contains(thread.id))
                        .padding(.horizontal, 12)
                        .sessionsScreenListRow()
                }
            }
        }
    }

    private var identity: ServerAccount {
        authManager.activeServer ?? ServerAccount(id: server.absoluteString, urlString: server.absoluteString,
                                                  displayName: server.host() ?? "", initials: "", headerLogoColorHex: HeaderLogoColor.defaultHex,
                                                  createdAt: .now, updatedAt: .now, kind: .squadd)
    }

    private var avatar: SessionsHeader.Avatar {
        SessionsHeader.Avatar(
            initials: identity.initials,
            color: HeaderLogoColor.color(for: identity.headerLogoColorHex),
            foreground: HeaderLogoColor.prefersDarkForeground(for: identity.headerLogoColorHex) ? .black : .white,
            servers: AvatarServerSwitcherModel(servers: authManager.servers, activeServerID: authManager.activeServerID),
            openSettings: { isShowingSettings = true },
            switchToServer: { authManager.switchActiveServer(to: $0) },
            addServer: { isAddingServer = true },
            manageServers: { isShowingSettings = true }
        )
    }
}

/// An agent's name over its threads, set like the Sessions list's own title row.
/// Tapping it opens the agent's editor.
private struct SquaddAgentHeader: View {
    let section: SquaddAgentSection
    let client: SquaddCompanionClient?
    let edit: () -> Void

    var body: some View {
        Button(action: edit) { content }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Edits the agent"))
    }

    private var content: some View {
        HStack(spacing: 8) {
            if let client {
                SquaddAgentAvatar(client: client, path: section.bot.avatarUrl, name: section.name)
            }
            Text(section.name)
                .font(AppFont.title3().bold())
                .foregroundStyle(.appPrimary)
            if let subtitle = section.subtitle {
                Text(subtitle)
                    .font(AppFont.subheadline())
                    .foregroundStyle(.appSecondary)
            }
            Spacer()
            if section.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
