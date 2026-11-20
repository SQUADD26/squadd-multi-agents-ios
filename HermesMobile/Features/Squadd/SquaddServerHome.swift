import SwiftUI

/// Routes a Squadd server to its own screens and every other server to `webui`, the screen
/// `ContentView` already shows for it: the agent list while paired, the pair-again screen once not.
struct SquaddRoute<Webui: View>: View {
    @Bindable var authManager: AuthManager
    let server: URL
    /// A thread link waiting for this server's home (`SquaddThreadLink`).
    var pendingThread: Binding<SquaddThreadLink?> = .constant(nil)
    /// A share from another app waiting for this server's home (#24).
    var pendingShare: SharedImportReservation?
    var didRouteShare: (SharedImportReservation) -> Void = { _ in }
    var didDeclineShare: (SharedImportReservation) -> Void = { _ in }
    @ViewBuilder let webui: () -> Webui

    var body: some View {
        if authManager.kind(of: server) == .squadd {
            if case .loggedIn = authManager.state {
                SquaddServerHome(authManager: authManager, server: server, pendingThread: pendingThread, pendingShare: pendingShare,
                                 didRouteShare: didRouteShare, didDeclineShare: didDeclineShare).id(server)
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
/// A thread opens in the chat (#11); a thread link marks its row and opens it.
struct SquaddServerHome: View {
    @Bindable var authManager: AuthManager
    let server: URL
    @Binding var pendingThread: SquaddThreadLink?
    /// A share from another app (#24): the user picks an agent, and a new thread of that agent
    /// opens with the share's words and files in its composer. It routes once the thread opens,
    /// or when the user cancels; a thread the computer refused leaves it queued.
    var pendingShare: SharedImportReservation?
    var didRouteShare: (SharedImportReservation) -> Void = { _ in }
    var didDeclineShare: (SharedImportReservation) -> Void = { _ in }
    /// What the home does once its agents first load; nil in the app. The photo runs use it to
    /// show the search and a thread's actions through the same handlers a tap reaches.
    var start: SquaddHomeStart?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The row a thread link pointed at, marked until the next link.
    @State private var linkedRow: String?
    @State private var isLinkedThreadMissing = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    /// Made once in `.task`, not in `init`, so a pass of the parent reads no Keychain.
    @State private var model: SquaddAgentListModel?
    @State private var notifications: SquaddNotificationsModel?
    @State private var isShowingNotifications = false
    @State private var client: SquaddCompanionClient?
    @State private var finder: SquaddRouteFinder?
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
    /// The agents (by id) and channels (by `headerRowID`) showing their threads.
    @State private var expanded: Set<String> = []
    @State private var toast = ActionToastState()
    /// The agent a New Folder alert is naming a folder for.
    @State private var namingFolderFor: String?
    @State private var newFolderName = ""
    @State private var deletingFolder: SquaddFolderRef?
    @State private var renamingRoom: SquaddRoomSection?
    @State private var newRoomName = ""
    @State private var deletingRoom: SquaddRoomSection?
    @State private var hasStarted = false
    @State private var token = ""
    /// The open thread, so the keyboard's chat shortcuts know where they stand.
    @State private var path: [SquaddThreadChat] = []
    @State private var isChoosingShareAgent = false
    /// The share already offered: the agents reload while its thread opens, and it isn't asked again.
    @State private var offeredShare: String?
    /// The share the thread it opened shows in its composer.
    @State private var openedShare: (chatID: String, share: SharedImport, notice: SharedSkipsNotice?)?

    /// The home's list and chats, and the agent picker a share from another app opens (#24).
    /// Its own property, so the compiler checks `body` in reasonable time.
    private var sharing: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                AppList(rows: .plain) {
                    SessionsHeader(logoColor: HeaderLogoColor.color(for: identity.headerLogoColorHex), avatar: avatar,
                                   field: SessionsHeader.Field(isExpanded: isSearchExpanded, text: $searchText,
                                                               isFocused: $isSearchFocused, close: closeSearch),
                                   searchLabel: "Search threads", openSearch: openSearch)
                        .sessionsTopChromeListRow()
                    if let hits = model?.searchHits {
                        SquaddSearchResults(hits: hits, query: searchText)
                    } else {
                        routeRow
                        if model?.isShowingCache == true {
                            OfflineCacheBanner()
                                .padding(.top, 8)
                                .sessionsScreenListRow()
                        }
                        rows
                    }
                }
                .refreshable { await model?.load() }
                .toolbar(.hidden, for: .navigationBar)
                .onChange(of: model?.phase) { openPendingThread(proxy); offerShare() }
                .onChange(of: pendingThread) { openPendingThread(proxy) }
                // Back from a chat: a first message has titled its thread on the computer.
                .onChange(of: path.isEmpty) { _, isHome in if isHome { Task { await model?.load() } } }
                // The computer answered again after an offline copy: the route row looks again too.
                .onChange(of: model?.isShowingCache) { was, now in
                    if was == true, now == false, finder?.route == nil { Task { await finder?.find() } }
                }
            }
            .navigationDestination(for: SquaddThreadChat.self) { chat in
                let share = openedShare?.chatID == chat.id ? openedShare : nil
                ChatView(squaddThread: chat, share: share?.share, shareNotice: share?.notice).id(chat.id)
            }
        }
        .onChange(of: pendingShare?.reservationID, initial: true) { offerShare() }
        .confirmationDialog("Send to an Agent", isPresented: $isChoosingShareAgent, titleVisibility: .visible) {
            if case .loaded(let sections) = model?.phase {
                ForEach(sections) { section in
                    Button(section.name) { share(to: section.id) }
                }
            }
            Button("Cancel", role: .cancel) { if let pendingShare { didRouteShare(pendingShare) } }
        } message: {
            Text("A new thread opens with what you shared in its composer.")
        }
    }

    var body: some View {
        sharing
        .focusedSceneValue(\.hermexSceneActions, sceneActions)
        .alert("Thread Not Found", isPresented: $isLinkedThreadMissing) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This thread isn’t on the computer anymore.")
        }
        .overlay(alignment: .bottom) {
            ActionToastView(state: toast)
                .frame(maxWidth: 420)
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
        }
        .task {
            if model == nil {
                let token = authManager.squaddToken(for: server) ?? ""
                self.token = token
                let client = SquaddCompanionClient(server: server, token: token)
                self.client = client
                notifications = SquaddNotificationsModel(client: client)
                model = SquaddAgentListModel(
                    client: client, cache: modelContext,
                    onUnpaired: { [weak authManager, server] in authManager?.squaddUnpaired(server: server) }
                )
            }
            let finder = finder ?? SquaddRouteFinder(server: server, book: authManager.squaddRoutes(for: server),
                                                       relayCredential: authManager.squaddToken(for: server))
            self.finder = finder
            let model = model
            // The agents load over the route just found, then follow it while the home is on screen.
            await finder.find()
            await model?.load()
            // Siri and Shortcuts offer this server's agents once they are known (`OpenSquaddAgentIntent`).
            HermexShortcuts.updateAppShortcutParameters()
            if let start, !hasStarted {
                hasStarted = true
                begin(start)
            }
            await finder.follow { await model?.load() }
        }
        // Debounced: a new query cancels the one waiting.
        .task(id: searchText) {
            if !searchText.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled, let model else { return }
            if await !model.search(searchText) { toast.show(.failure(String(localized: "Couldn’t search the computer."))) }
        }
        // Present for Squadd while the app is in front; leaving cancels the pings (`SquaddPresence`).
        .task(id: scenePhase == .active) {
            guard scenePhase == .active, let token = authManager.squaddToken(for: server) else { return }
            let client = SquaddCompanionClient(server: server, token: token)
            await SquaddPresence.keepAlive { try await client.presenceActive() }
        }
        // The bell follows the computer's notifications while the app is in front.
        .task(id: scenePhase == .active && notifications != nil) {
            guard scenePhase == .active, let notifications else { return }
            await notifications.follow()
        }
        .sheet(isPresented: $isShowingNotifications) {
            if let notifications {
                SquaddNotificationsSheet(model: notifications) { open($0) }
            }
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
            SessionRenameSheet(title: "Rename Thread", fieldLabel: "Thread title",
                               initialTitle: SessionRowView.displayTitle(for: thread.session), isSaving: false) {
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
        .alert("New Folder", isPresented: Binding(get: { namingFolderFor != nil }, set: { if !$0 { namingFolderFor = nil } })) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let botId = namingFolderFor, !name.isEmpty else { return }
                Task { await run { await $0.createFolder(named: name, botId: botId) } }
            }
            // The companion takes 1 to 80 characters; a longer name is refused here, never cut.
            .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).count > 80)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete Folder?", isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }),
                            titleVisibility: .visible, presenting: deletingFolder) { folder in
            Button("Delete Folder", role: .destructive) {
                Task { await run { await $0.deleteFolder(folder.id, botId: folder.botId) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its threads stay, outside any folder.")
        }
        .alert("Rename Group Chat", isPresented: Binding(get: { renamingRoom != nil }, set: { if !$0 { renamingRoom = nil } })) {
            TextField("Group chat name", text: $newRoomName)
            Button("Save") {
                let name = newRoomName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let room = renamingRoom, !name.isEmpty else { return }
                Task { await run { await $0.renameRoom(room.id, to: name) } }
            }
            // The companion takes up to 100 characters; a longer name is refused here, never cut.
            .disabled(newRoomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || newRoomName.trimmingCharacters(in: .whitespacesAndNewlines).count > 100)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(Text("Delete \(deletingRoom?.name ?? "")?"),
                            isPresented: Binding(get: { deletingRoom != nil }, set: { if !$0 { deletingRoom = nil } }),
                            titleVisibility: .visible, presenting: deletingRoom) { room in
            Button("Delete Group Chat", role: .destructive) {
                Task {
                    guard let model, let failure = await model.deleteRoom(room.id) else { return }
                    toast.show(.failure(failure))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { room in
            Text("This permanently deletes the \(room.name) group chat, its messages, and every thread in it, and turns off the routines that run there. The agents in it are not deleted. This cannot be undone.")
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

    /// How the iPhone reaches the computer right now (#9): over the internet, through the tailnet, or on
    /// this Wi-Fi.
    @ViewBuilder
    private var routeRow: some View {
        if let finder {
            Label {
                switch finder.status {
                case .connected(.hosted): Text("Connected over the internet")
                case .connected(.tailnet): Text("Connected through Tailscale")
                case .connected(.lan), .connected(.bonjour): Text("Connected on this Wi-Fi")
                case .connected(.relay): Text("Connected through Squadd Multi-Agents Relay, end to end encrypted")
                case .finding: Text("Finding the computer…")
                case .unreachable: Text("Can't reach the computer.")
                }
            } icon: {
                Image(systemName: finder.route.map(Self.symbol)
                      ?? (finder.status == .unreachable ? "wifi.exclamationmark" : "antenna.radiowaves.left.and.right"))
            }
            .font(AppFont.footnote())
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) { notificationsButton }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .sessionsScreenListRow()
        }
    }

    /// The computer's notifications, with how many are unread.
    @ViewBuilder
    private var notificationsButton: some View {
        if let notifications {
            let unread = notifications.unreadCount
            Button { isShowingNotifications = true } label: {
                Image(systemName: unread > 0 ? "bell.badge" : "bell")
                    .symbolRenderingMode(unread > 0 ? .multicolor : .monochrome)
                    .font(AppFont.subheadline())
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Notifications")
            .accessibilityValue(unread > 0 ? Text("\(unread) unread") : Text(verbatim: ""))
        }
    }

    /// A tapped notification: its conversation is marked read on the computer, as opening it on the
    /// desktop does, then it opens like a thread link.
    private func open(_ notification: SquaddNotification) {
        guard notification.opensHere, let threadID = notification.threadId else { return }
        isShowingNotifications = false
        pendingThread = SquaddThreadLink(threadID: threadID, botID: notification.botId, server: server)
        Task {
            do { try await notifications?.markRead(notification) } catch {
                toast.show(.failure(String(localized: "Couldn’t mark this read on the computer.")))
            }
        }
    }

    private static func symbol(_ route: SquaddEndpoint) -> String {
        switch route.kind {
        case .hosted: "globe"
        case .tailnet: "point.3.connected.trianglepath.dotted"
        case .lan, .bonjour: "wifi"
        case .relay: "lock.shield"
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
            let rooms = model?.rooms ?? []
            if !rooms.isEmpty {
                SquaddListSectionTitle(title: "Channels")
                ForEach(rooms) { room in
                    SquaddRoomRow(room: room, isExpanded: expanded.contains(room.headerRowID),
                                  open: room.threadID.map { id in { path = [roomChat(room, threadID: id)] } }) {
                        toggle(room.headerRowID)
                    } newThread: {
                        newThread(in: room)
                    } rename: {
                        newRoomName = room.name
                        renamingRoom = room
                    } delete: {
                        deletingRoom = room
                    }
                    .id(room.headerRowID)
                    .sessionsScreenListRow()
                    let isOpen = expanded.contains(room.headerRowID)
                    if isOpen {
                        SquaddNewThreadRow { newThread(in: room) }
                    }
                    // Closed, the channel still shows its unread conversations, as the desktop sidebar does.
                    ForEach(isOpen ? room.threads : room.threads.filter { room.unreadThreadIDs.contains($0.id) }) { thread in
                        NavigationLink(value: SquaddThreadChat(room: room, thread: thread, server: server, token: token)) {
                            SessionRowView(session: thread, showsMessageCount: false, showsWorkspace: false,
                                           isUnread: room.unreadThreadIDs.contains(thread.id))
                        }
                        .buttonStyle(.plain)
                        .id(thread.id)
                        .padding(.leading, 28)
                        .padding(.trailing, 12)
                        .sessionsScreenListRow()
                    }
                }
            }
            SquaddListSectionTitle(title: "Direct Messages") {
                Button { isCreatingAgent = true } label: {
                    Image(systemName: "plus")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(client == nil)
                .accessibilityLabel("New Agent")
            }
            ForEach(sections) { section in
                SquaddAgentRow(section: section, client: client, isExpanded: expanded.contains(section.id),
                               open: section.threadID.map { id in {
                                   path = [SquaddThreadChat(server: server, token: token, botId: section.id, threadId: id,
                                                            title: section.name, botName: section.name)]
                               } }) {
                    toggle(section.id)
                } edit: {
                    editingAgent = section.bot
                } newThread: {
                    newThread(for: section)
                } newFolder: {
                    newFolderName = ""
                    namingFolderFor = section.id
                }
                .background(linkedMark(section.headerRowID))
                .id(section.headerRowID)
                .sessionsScreenListRow()
                if expanded.contains(section.id) {
                    SquaddNewThreadRow(edit: { editingAgent = section.bot }) { newThread(for: section) }
                    ForEach(section.folders) { folder in
                        folderHeader(folder, in: section)
                        ForEach(folder.threads) { thread in
                            threadRow(thread, in: section)
                        }
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
                } else {
                    // Closed, the agent still shows where to pick up, as the desktop sidebar does.
                    ForEach((section.folders.flatMap(\.threads) + section.threads).filter { section.unreadThreadIDs.contains($0.id) }) { thread in
                        threadRow(thread, in: section)
                    }
                }
            }
        }
    }

    private func toggle(_ id: String) {
        withAnimation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    private func roomChat(_ room: SquaddRoomSection, threadID: String) -> SquaddThreadChat {
        SquaddThreadChat(room: room, thread: room.threads.first { $0.id == threadID } ?? SessionSummary(sessionId: threadID, title: room.name),
                         server: server, token: token)
    }

    private func newThread(in room: SquaddRoomSection) {
        Task {
            guard let threadID = await model?.createRoomThread(room.id) else {
                toast.show(.failure(String(localized: "Couldn’t start a thread on the computer.")))
                return
            }
            path = [roomChat(room, threadID: threadID)]
        }
    }

    /// A new thread opens at once: an untitled one has no row until its first message titles it.
    private func newThread(for section: SquaddAgentSection) {
        Task {
            guard let task = await model?.createThread(botId: section.id) else {
                toast.show(.failure(String(localized: "Couldn’t start a thread on the computer.")))
                return
            }
            path = [SquaddThreadChat(server: server, token: token, botId: section.id, threadId: task.threadId,
                                     title: section.name, botName: section.name)]
        }
    }

    private func threadRow(_ thread: SessionSummary, in section: SquaddAgentSection) -> some View {
        let ref = SquaddThreadRef(botId: section.id, session: thread)
        return NavigationLink(value: SquaddThreadChat(in: section, thread: thread, server: server, token: token)) {
            SessionRowView(session: thread, showsMessageCount: false, showsWorkspace: false,
                           isUnread: section.unreadThreadIDs.contains(thread.id), labelsArchived: true)
        }
            .buttonStyle(.plain)
            .background(linkedMark(thread.id))
            .accessibilityAddTraits(linkedRow == thread.id ? .isSelected : [])
            .id(thread.id)
            .padding(.leading, 28)
            .padding(.trailing, 12)
            .contextMenu { SquaddThreadMenu(thread: ref, folders: section.folders, act: act) }
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

    private func folderHeader(_ folder: SquaddAgentSection.Folder, in section: SquaddAgentSection) -> some View {
        let ref = SquaddFolderRef(botId: section.id, id: folder.id, name: folder.name)
        return HStack(spacing: 8) {
            if let emoji = folder.emoji {
                Text(verbatim: emoji)
            } else {
                Image(systemName: "folder")
                    .foregroundStyle(.appSecondary)
            }
            Text(verbatim: folder.name)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(.appPrimary)
                .lineLimit(1)
            Spacer()
            Text(verbatim: folder.threads.count.formatted())
                .font(AppFont.caption())
                .foregroundStyle(.appSecondary)
        }
        .padding(.leading, 40)
        .padding(.trailing, 24)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button { Task { await run { await $0.moveFolder(folder.id, botId: section.id, by: -1) } } } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .disabled(!folder.canMoveUp)
            Button { Task { await run { await $0.moveFolder(folder.id, botId: section.id, by: 1) } } } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            .disabled(!folder.canMoveDown)
            Button(role: .destructive) { deletingFolder = ref } label: { Label("Delete Folder", systemImage: "trash") }
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
            .padding(.leading, 40)
            .padding(.trailing, 24)
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
        case .move(let projectId):
            Task { await run { await $0.move(threadId: thread.threadId, botId: thread.botId, toFolder: projectId) } }
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
            expanded = Set(sections.map(\.id))
        case .newFolder:
            newFolderName = ""
            namingFolderFor = sections.first?.id
        case .deleteFolder(let name):
            for section in sections {
                if let folder = section.folders.first(where: { $0.name == name }) {
                    deletingFolder = SquaddFolderRef(botId: section.id, id: folder.id, name: folder.name)
                    return
                }
            }
        case .share(let agentName):
            if let section = sections.first(where: { $0.name == agentName }) { share(to: section.id) }
        case .renameRoom:
            guard let room = model?.rooms.first else { return }
            newRoomName = room.name
            renamingRoom = room
        case .deleteRoom:
            deletingRoom = model?.rooms.first
        case .act(let action, let title):
            for section in sections {
                if let thread = (section.threads + section.folders.flatMap(\.threads) + section.archived).first(where: { $0.title == title }) {
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

    /// Opens a held thread link once this server's agents are loaded: marks the thread's row and
    /// opens its chat, or says the thread is gone. A link pinned to another server waits for its home.
    private func openPendingThread(_ proxy: ScrollViewProxy) {
        guard let link = pendingThread, link.server.map({ SquaddThreadLink.sameServer($0.absoluteString, server.absoluteString) }) ?? true,
              case .loaded(let sections) = model?.phase else { return }
        pendingThread = nil
        if let chat = link.roomChat(in: model?.rooms ?? [], server: server, token: token) {
            if let room = model?.rooms.first(where: { $0.id == chat.botId }) { expanded.insert(room.headerRowID) }
            withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(link.threadID, anchor: .center) }
            path = [chat]
            return
        }
        guard let row = link.row(in: sections) else {
            linkedRow = nil
            isLinkedThreadMissing = true
            return
        }
        linkedRow = row
        if let section = sections.first(where: { $0.archived.contains { $0.id == row } }) { expandedArchives.insert(section.id) }
        if let section = sections.first(where: { ($0.threads + $0.folders.flatMap(\.threads) + $0.archived).contains { $0.id == row } }) {
            expanded.insert(section.id)
        }
        withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(row, anchor: .center) }
        if let section = sections.first(where: { section in
            section.threadID == link.threadID || (section.threads + section.archived).contains { $0.id == link.threadID }
        }) {
            let title = (section.threads + section.archived).first { $0.id == link.threadID }?.title ?? section.name
            path = [SquaddThreadChat(server: server, token: token, botId: section.id, threadId: link.threadID, title: title,
                                     botName: section.name)]
        }
    }

    /// Asks for the agent once this server's agents are loaded.
    private func offerShare() {
        guard let pendingShare, pendingShare.reservationID != offeredShare, case .loaded = model?.phase else { return }
        offeredShare = pendingShare.reservationID
        isChoosingShareAgent = true
    }

    /// Opens a new thread of `botId` holding the pending share in its composer.
    private func share(to botId: String) {
        guard let reservation = pendingShare, let model else { return }
        offeredShare = reservation.reservationID
        isChoosingShareAgent = false
        Task {
            guard let task = await model.createThread(botId: botId) else {
                toast.show(.failure(String(localized: "Couldn’t start a thread on the computer.")))
                return didDeclineShare(reservation)
            }
            let chat = SquaddThreadChat(server: server, token: token, botId: botId, threadId: task.threadId, title: task.title)
            openedShare = (chat.id, reservation.sharedImport, SharedSkipsNotice(reservation.sharedImport.skipped))
            path = [chat]
            didRouteShare(reservation)
        }
    }

    /// The hardware-keyboard commands (`HermexCommands`): ⌘1–⌘9 and Next and Previous Chat open
    /// the home's threads; there is no New Chat here yet.
    private var sceneActions: HermexSceneActions {
        HermexSceneActions(
            canCreateNewChat: false,
            createNewChat: {},
            searchSessions: { if model != nil { openSearch() } },
            openChat: { position in
                if let chat = ChatShortcutNavigation.chat(atPosition: position, in: keyboardShortcutChats) { path = [chat] }
            },
            openAdjacentChat: { offset in
                if let chat = ChatShortcutNavigation.adjacentChat(offset: offset, from: path.last?.id, in: keyboardShortcutChats) {
                    path = [chat]
                }
            }
        )
    }

    /// Read only on a key press, never in `body`.
    private var keyboardShortcutChats: [SquaddThreadChat] {
        guard case .loaded(let sections) = model?.phase else { return [] }
        return SquaddThreadChat.all(in: sections, server: server, token: token)
            + (model?.rooms ?? []).flatMap { room in
                room.threads.map { SquaddThreadChat(room: room, thread: $0, server: server, token: token) }
            }
    }

    private func linkedMark(_ row: String) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.accentColor.opacity(linkedRow == row ? 0.15 : 0))
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

/// A list section's title, as the desktop sidebar sets Channels and Direct Messages, with an optional action.
struct SquaddListSectionTitle<Action: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack {
            Text(title)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(.appSecondary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            action().foregroundStyle(.tint)
        }
        .frame(minHeight: 44)
        .padding(.leading, 24)
        .padding(.trailing, 14)
        .padding(.top, 16)
    }
}

extension SquaddListSectionTitle where Action == EmptyView {
    init(title: LocalizedStringKey) { self.init(title: title) { EmptyView() } }
}

/// The disclosure arrow that shows or hides a row's threads.
struct SquaddThreadsToggle: View {
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "chevron.right")
                .font(AppFont.footnote(weight: .semibold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.appSecondary)
        .accessibilityLabel("Threads")
        .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
    }
}

/// One agent under Direct Messages, one line as the desktop lists it: tapping it opens the agent's own
/// chat, the arrow shows its threads, and its menu starts a thread or a folder or edits the agent.
private struct SquaddAgentRow: View {
    let section: SquaddAgentSection
    let client: SquaddCompanionClient?
    let isExpanded: Bool
    /// Opens the agent's own chat; nil shows its threads instead.
    let open: (() -> Void)?
    let toggle: () -> Void
    let edit: () -> Void
    let newThread: () -> Void
    let newFolder: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            // A button, not a NavigationLink: a link in the list draws a second arrow beside the toggle.
            Button(action: open ?? toggle) { identity }.buttonStyle(.plain)
            SquaddThreadsToggle(isExpanded: isExpanded, toggle: toggle)
        }
        .padding(.leading, 24)
        .padding(.trailing, 6)
        .contextMenu {
            Button(action: newThread) { Label("New Thread", systemImage: "square.and.pencil") }
            Button(action: newFolder) { Label("New Folder", systemImage: "folder.badge.plus") }
            Button(action: edit) { Label("Edit Agent", systemImage: "slider.horizontal.3") }
        }
        .accessibilityElement(children: .contain)
    }

    private var identity: some View {
        HStack(spacing: 10) {
            if let client {
                SquaddAgentAvatar(client: client, path: section.bot.avatarUrl, name: section.name)
            }
            SquaddRowName(name: section.name, isUnread: section.isUnread)
            if section.bot.chiefOfStaff == true {
                Image(systemName: "crown")
                    .font(AppFont.caption())
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 4)
            SquaddRowStatus(isBusy: section.isBusy, isUnread: section.isUnread)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A row's name on one line, never broken inside a word: a long name at a large text size shrinks to fit.
struct SquaddRowName: View {
    let name: String
    let isUnread: Bool

    var body: some View {
        Text(verbatim: name)
            .font(AppFont.body(weight: isUnread ? .semibold : .regular))
            .foregroundStyle(.appPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .allowsTightening(true)
    }
}

/// Working and unread marks at a row's end.
struct SquaddRowStatus: View {
    let isBusy: Bool
    let isUnread: Bool

    var body: some View {
        if isBusy {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Working")
        }
        if isUnread {
            Circle()
                .fill(.tint)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Unread")
        }
    }
}

/// A first step for `SquaddServerHome.start`.
enum SquaddHomeStart {
    case search(String)
    case showArchived
    /// The New Folder alert for the first agent.
    case newFolder
    /// The delete confirmation of the first folder with this name.
    case deleteFolder(String)
    /// The first room's rename alert, or its delete confirmation.
    case renameRoom, deleteRoom
    /// The action on the first thread with this title.
    case act(SquaddThreadAction, threadTitle: String)
    /// The pending share sent to the agent with this name, as its button in Send to an Agent does.
    case share(agentName: String)
}

/// What a thread's menu and swipes ask the home to do.
enum SquaddThreadAction {
    case pin, rename, export, archive, delete
    /// Into a folder, or out of every folder with nil.
    case move(String?)
}

/// A folder and the agent it belongs to, for its delete confirmation.
struct SquaddFolderRef: Identifiable {
    let botId: String
    let id: String
    let name: String
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
    let folders: [SquaddAgentSection.Folder]
    let act: (SquaddThreadAction, SquaddThreadRef) -> Void

    var body: some View {
        if thread.session.archived != true {
            Button { act(.pin, thread) } label: {
                Label(thread.session.pinned == true ? "Unpin" : "Pin", systemImage: "pin")
            }
        }
        Button { act(.rename, thread) } label: { Label("Rename", systemImage: "pencil") }
        if !folders.isEmpty {
            Menu {
                Button { act(.move(nil), thread) } label: {
                    Label("No Folder", systemImage: thread.session.projectId == nil ? "checkmark" : "tray")
                }
                .disabled(thread.session.projectId == nil)
                Divider()
                ForEach(folders) { folder in
                    let isHere = thread.session.projectId == folder.id
                    Button { act(.move(folder.id), thread) } label: {
                        Label { Text(verbatim: folder.name) } icon: { Image(systemName: isHere ? "checkmark" : "folder") }
                    }
                    .disabled(isHere)
                }
            } label: {
                Label("Move to Folder", systemImage: "folder")
            }
        }
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
