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
/// header with the server's avatar, switcher and search, then each agent's threads in session rows,
/// in the desktop sidebar's order, read from the companion's `GET /api/bots`. A thread's menu and
/// swipes pin, rename, export, archive and delete it; archived threads wait under their agent.
/// Threads don't open yet: chat is its own ticket.
struct SquaddServerHome: View {
    @Bindable var authManager: AuthManager
    let server: URL
    /// What the home does once its agents first load; nil in the app. The photo runs use it to
    /// show the search and a thread's actions through the same handlers a tap reaches.
    var start: SquaddHomeStart?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Made once in `.task`, not in `init`, so a pass of the parent reads no Keychain.
    @State private var model: SquaddAgentListModel?
    @State private var client: SquaddCompanionClient?
    @State private var editingAgent: SquaddBot?
    @State private var isCreatingAgent = false
    @State private var isShowingSettings = false
    @State private var isAddingServer = false
    @State private var isSearchExpanded = false
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var renaming: SquaddThreadRef?
    @State private var deleting: SquaddThreadRef?
    @State private var exported: SessionExportShareItem?
    @State private var expandedArchives: Set<String> = []
    @State private var toast = ActionToastState()
    @State private var hasStarted = false

    var body: some View {
        NavigationStack {
            AppList(rows: .plain) {
                SessionsHeader(logoColor: HeaderLogoColor.color(for: identity.headerLogoColorHex), avatar: avatar,
                               field: SessionsHeader.Field(isExpanded: isSearchExpanded, text: $searchText,
                                                           isFocused: $isSearchFocused, close: closeSearch),
                               searchLabel: "Search threads", openSearch: openSearch)
                    .sessionsTopChromeListRow()
                if let hits = model?.searchHits {
                    SquaddSearchResults(hits: hits, query: searchText)
                } else {
                    rows
                }
            }
            .refreshable { await model?.load() }
            .toolbar(.hidden, for: .navigationBar)
        }
        .overlay(alignment: .bottom) {
            ActionToastView(state: toast)
                .frame(maxWidth: 420)
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
        }
        .task {
            if model == nil {
                let client = SquaddCompanionClient(server: server, token: authManager.squaddToken(for: server) ?? "")
                self.client = client
                model = SquaddAgentListModel(
                    client: client,
                    onUnpaired: { [weak authManager, server] in authManager?.squaddUnpaired(server: server) }
                )
            }
            await model?.load()
            if let start, !hasStarted {
                hasStarted = true
                begin(start)
            }
        }
        // Debounced: a new query cancels the one waiting.
        .task(id: searchText) {
            if !searchText.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled, let model else { return }
            if await !model.search(searchText) { toast.show(.failure(String(localized: "Couldn’t search the computer."))) }
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
        .sheet(item: $renaming) { thread in
            SessionRenameSheet(initialTitle: SessionRowView.displayTitle(for: thread.session), isSaving: false) {
                renaming = nil
            } onSave: { title in
                renaming = nil
                Task { await run {
                    await $0.rename(threadId: thread.threadId, botId: thread.botId, to: title)
                } }
            }
            .themedPageBackground()
            .presentationDetents([.medium])
        }
        .sheet(item: $exported) { item in
            FileShareSheet(fileURL: item.fileURL)
                .themedPageBackground()
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
                .onDisappear { try? FileManager.default.removeItem(at: item.fileURL.deletingLastPathComponent()) }
        }
        .confirmationDialog("Delete Thread?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { thread in
            Button("Delete", role: .destructive) {
                Task { await run {
                    await $0.delete(threadId: thread.threadId, botId: thread.botId)
                } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The thread and its messages are deleted on the computer too.")
        }
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
                SquaddAgentHeader(section: section, client: client) {
                    editingAgent = section.bot
                } newThread: {
                    Task { await run { await $0.createThread(botId: section.id) } }
                }
                .sessionsScreenListRow()
                if section.threads.isEmpty {
                    Text("No threads yet")
                        .font(AppFont.subheadline())
                        .foregroundStyle(.appSecondary)
                        .padding(.horizontal, 24)
                        .sessionsScreenListRow()
                }
                ForEach(section.threads) { thread in
                    threadRow(thread, in: section)
                }
                if !section.archived.isEmpty {
                    archiveToggle(section)
                    if expandedArchives.contains(section.id) {
                        ForEach(section.archived) { thread in
                            threadRow(thread, in: section)
                        }
                    }
                }
            }
        }
    }

    private func threadRow(_ thread: SessionSummary, in section: SquaddAgentSection) -> some View {
        let ref = SquaddThreadRef(botId: section.id, session: thread)
        return SessionRowView(session: thread, showsMessageCount: false, showsWorkspace: false,
                              isUnread: section.unreadThreadIDs.contains(thread.id), labelsArchived: true)
            .padding(.horizontal, 12)
            .contextMenu { SquaddThreadMenu(thread: ref, act: act) }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if thread.archived != true {
                    Button { act(.pin, ref) } label: {
                        Label(thread.pinned == true ? "Unpin" : "Pin", systemImage: "pin")
                    }
                    .tint(.accentColor)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button { act(.delete, ref) } label: { Label("Delete", systemImage: "trash") }
                    .tint(.red)
                Button { act(.archive, ref) } label: {
                    thread.archived == true
                        ? Label("Restore", systemImage: "tray.and.arrow.up")
                        : Label("Archive", systemImage: "archivebox")
                }
                .tint(.orange)
            }
            .sessionsScreenListRow()
    }

    private func archiveToggle(_ section: SquaddAgentSection) -> some View {
        let isOpen = expandedArchives.contains(section.id)
        return Button {
            withAnimation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion)) {
                if isOpen { expandedArchives.remove(section.id) } else { expandedArchives.insert(section.id) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(AppFont.caption(weight: .semibold))
                Text("Archived (\(section.archived.count))")
                Spacer()
            }
            .font(AppFont.subheadline())
            .foregroundStyle(.appSecondary)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOpen ? Text("Expanded") : Text("Collapsed"))
        .sessionsScreenListRow()
    }

    private func act(_ action: SquaddThreadAction, _ thread: SquaddThreadRef) {
        switch action {
        case .rename: renaming = thread
        case .delete: deleting = thread
        case .pin:
            Task { await run {
                await $0.setPinned(thread.session.pinned != true, threadId: thread.threadId, botId: thread.botId)
            } }
        case .archive:
            let archiving = thread.session.archived != true
            Task {
                guard await run({
                    await $0.setArchived(archiving, threadId: thread.threadId, botId: thread.botId)
                }), archiving else { return }
                let message = String(localized: "Archived")
                toast.show(ActionToast(
                    message: message, systemImage: "archivebox",
                    accessibilityLabel: String.localizedStringWithFormat(String(localized: "%@, %@"),
                                                                         SessionRowView.displayTitle(for: thread.session), message),
                    actionTitle: String(localized: "Undo"),
                    action: { Task { await run {
                        await $0.setArchived(false, threadId: thread.threadId, botId: thread.botId)
                    } } }
                ))
            }
        case .export:
            Task {
                if let url = await model?.export(threadId: thread.threadId, title: SessionRowView.displayTitle(for: thread.session)) {
                    exported = SessionExportShareItem(fileURL: url)
                } else {
                    toast.show(.failure(String(localized: "Couldn’t export the thread.")))
                }
            }
        }
    }

    /// Runs one model action and says so when the computer refused it; the row is already back.
    @discardableResult
    private func run(_ action: (SquaddAgentListModel) async -> Bool) async -> Bool {
        guard let model else { return false }
        let done = await action(model)
        if !done { toast.show(.failure(String(localized: "The computer didn’t take that change."))) }
        return done
    }

    private func begin(_ start: SquaddHomeStart) {
        guard case .loaded(let sections) = model?.phase else { return }
        switch start {
        case .search(let text):
            openSearch()
            searchText = text
        case .showArchived:
            expandedArchives = Set(sections.map(\.id))
        case .act(let action, let title):
            for section in sections {
                if let thread = (section.threads + section.archived).first(where: { $0.title == title }) {
                    act(action, SquaddThreadRef(botId: section.id, session: thread))
                    return
                }
            }
        }
    }

    private func openSearch() {
        withAnimation(SessionListMotion.searchChromeAnimation(reduceMotion: reduceMotion)) { isSearchExpanded = true }
        isSearchFocused = true
    }

    private func closeSearch() {
        searchText = ""
        isSearchFocused = false
        withAnimation(SessionListMotion.searchChromeAnimation(reduceMotion: reduceMotion)) { isSearchExpanded = false }
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
    let newThread: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: edit) { identity }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Edits the agent"))
            if section.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            }
            Button(action: newThread) {
                Image(systemName: "square.and.pencil")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel(Text("New Thread for \(section.name)"))
        }
        .padding(.leading, 24)
        .padding(.trailing, 14)
        .padding(.top, 20)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }

    private var identity: some View {
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
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A first step for `SquaddServerHome.start`.
enum SquaddHomeStart {
    case search(String)
    case showArchived
    /// The action on the first thread with this title.
    case act(SquaddThreadAction, threadTitle: String)
}

/// What a thread's menu and swipes ask the home to do.
enum SquaddThreadAction {
    case pin, rename, export, archive, delete
}

/// A thread row and the agent it belongs to, which every companion route names.
struct SquaddThreadRef: Identifiable {
    let botId: String
    let session: SessionSummary
    var threadId: String { session.id }
    var id: String { session.id }
}

/// A thread's long-press menu: the same actions, order and wording as a Hermes session's.
private struct SquaddThreadMenu: View {
    let thread: SquaddThreadRef
    let act: (SquaddThreadAction, SquaddThreadRef) -> Void

    var body: some View {
        if thread.session.archived != true {
            Button { act(.pin, thread) } label: {
                Label(thread.session.pinned == true ? "Unpin" : "Pin", systemImage: "pin")
            }
        }
        Button { act(.rename, thread) } label: { Label("Rename", systemImage: "pencil") }
        Button { act(.export, thread) } label: { Label("Export", systemImage: "square.and.arrow.up") }
        Button { act(.archive, thread) } label: {
            thread.session.archived == true
                ? Label("Restore", systemImage: "tray.and.arrow.up")
                : Label("Archive", systemImage: "archivebox")
        }
        Button(role: .destructive) { act(.delete, thread) } label: { Label("Delete", systemImage: "trash") }
    }
}

/// Search matches: each message's snippet under its thread and agent, or the system's
/// no-results view.
struct SquaddSearchResults: View {
    let hits: [SquaddSearchHit]
    let query: String

    var body: some View {
        if hits.isEmpty {
            ContentUnavailableView.search(text: query)
                .sessionsScreenListRow()
        } else {
            ForEach(hits) { hit in
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: hit.task ?? hit.name ?? "")
                        .font(AppFont.body(weight: .semibold))
                        .foregroundStyle(.appPrimary)
                        .lineLimit(1)
                    if let name = hit.name, hit.task != nil {
                        Text(verbatim: name)
                            .font(AppFont.caption())
                            .foregroundStyle(.appSecondary)
                    }
                    Text(verbatim: hit.snippet)
                        .font(AppFont.subheadline())
                        .foregroundStyle(.appSecondary)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .sessionsScreenListRow()
            }
        }
    }
}
