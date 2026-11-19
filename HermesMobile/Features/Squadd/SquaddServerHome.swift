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

/// A Squadd server's home: its agents, each with its task threads in the session rows the
/// Sessions list uses, read from the companion's `GET /api/bots`.
struct SquaddServerHome: View {
    @Bindable var authManager: AuthManager
    let server: URL
    @State private var model: SquaddAgentListModel
    @State private var isShowingSettings = false

    init(authManager: AuthManager, server: URL) {
        self.authManager = authManager
        self.server = server
        let token = authManager.squaddToken(for: server) ?? ""
        _model = State(initialValue: SquaddAgentListModel(
            fetch: { try await SquaddCompanionClient(server: server, token: token).bots() },
            onUnpaired: { [weak authManager] in authManager?.squaddUnpaired(server: server) }
        ))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(authManager.activeServer?.displayName ?? server.host() ?? "")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { isShowingSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("Settings")
                    }
                }
        }
        .task { await model.load() }
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
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("Can't Reach the Computer", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check that the computer is on and on the same network or tailnet.")
            } actions: {
                Button("Try Again") { Task { await model.load() } }
            }
        case .loaded(let sections) where sections.isEmpty:
            ContentUnavailableView("No Agents", systemImage: "person.2",
                                   description: Text("Agents created on the computer show here."))
                .refreshable { await model.load() }
        case .loaded(let sections):
            List(sections) { section in
                Section {
                    if section.threads.isEmpty {
                        Text("No threads yet")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(section.threads) { thread in
                        SessionRowView(session: thread, showsMessageCount: false, showsWorkspace: false)
                    }
                } header: {
                    SquaddAgentHeader(section: section)
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await model.load() }
        }
    }
}

private struct SquaddAgentHeader: View {
    let section: SquaddAgentSection

    var body: some View {
        HStack(spacing: 6) {
            Text(section.name)
            if let subtitle = section.subtitle {
                Text(subtitle).foregroundStyle(.secondary)
            }
            if section.isBusy {
                Image(systemName: "ellipsis")
                    .accessibilityLabel("Working")
            }
        }
        .accessibilityElement(children: .combine)
    }
}
