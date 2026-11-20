import Foundation
import Observation
import OSLog
import SwiftData

/// One agent in the Squadd home as the desktop sidebar shows it: its folders with their open
/// threads, then the open threads in no folder, and its archived threads apart, as session rows.
struct SquaddAgentSection: Identifiable, Equatable {
    /// A folder and its open threads.
    struct Folder: Identifiable, Equatable {
        let id: String
        let name: String
        let emoji: String?
        let threads: [SessionSummary]
        let canMoveUp: Bool
        let canMoveDown: Bool
    }

    let id: String
    let name: String
    /// The agent's own chat.
    let threadID: String?
    let subtitle: String?
    let isBusy: Bool
    let folders: [Folder]
    /// Open threads in no folder.
    let threads: [SessionSummary]
    let archived: [SessionSummary]
    /// The threads the companion marks unread, by `SessionSummary.id` (the thread id).
    let unreadThreadIDs: Set<String>
    /// The agent as the companion sent it, for its avatar and its editor.
    let bot: SquaddBot

    init(bot: SquaddBot) {
        self.bot = bot
        id = bot.id
        threadID = bot.threadId
        unreadThreadIDs = Set(bot.tasks.filter { $0.unread == true }.map(\.threadId))
        name = Self.nonEmpty(bot.name) ?? String(localized: "Unnamed Agent")
        subtitle = Self.nonEmpty(bot.title)
        isBusy = bot.busy == true
        let layout = bot.desktopLayout
        threads = layout.loose.map(Self.row)
        folders = layout.folders.map { folder in
            Folder(id: folder.project.id, name: folder.project.name, emoji: folder.project.emoji, threads: folder.tasks.map(Self.row),
                   canMoveUp: bot.projects(movingFolder: folder.project.id, by: -1) != nil,
                   canMoveDown: bot.projects(movingFolder: folder.project.id, by: 1) != nil)
        }
        archived = SquaddTask.desktopOrder(bot.tasks).filter(\.isArchived).map(Self.row)
    }

    private static func row(_ task: SquaddTask) -> SessionSummary {
        // The companion counts milliseconds; session rows read seconds.
        SessionSummary(sessionId: task.threadId, title: nonEmpty(task.title), updatedAt: task.updatedAt.map { $0 / 1000 },
                       pinned: task.pinned, archived: task.isArchived, projectId: task.projectId, isStreaming: task.busy)
    }

    /// The scroll identity of the agent's header row in the home.
    var headerRowID: String { "agent-\(id)" }

    private static func nonEmpty(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A room in the Squadd home (#21): its name and its conversations as session rows, newest
/// first as the desktop lists them, with the members `@` reaches in each.
struct SquaddRoomSection: Identifiable, Equatable {
    let id: String
    let name: String
    let isBusy: Bool
    let threads: [SessionSummary]
    let unreadThreadIDs: Set<String>
    let members: [SquaddRoomChat.Member]

    init(room: SquaddRoom, bots: [SquaddBot]) {
        id = room.id
        let name = room.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = name.isEmpty ? String(localized: "Unnamed Group Chat") : name
        isBusy = room.working == true
        let tasks = SquaddTask.desktopOrder(room.tasks).filter { !$0.isArchived }
        threads = tasks.map {
            SessionSummary(sessionId: $0.threadId, title: $0.title, updatedAt: $0.updatedAt.map { $0 / 1000 },
                           pinned: $0.pinned, isStreaming: $0.busy)
        }
        unreadThreadIDs = Set(tasks.filter { $0.unread == true }.map(\.threadId))
        let names = Dictionary(bots.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        members = room.memberIds.compactMap { id in
            guard let name = names[id] ?? nil, !name.isEmpty else { return nil }
            return SquaddRoomChat.Member(id: id, name: name)
        }
    }

    var headerRowID: String { "room-\(id)" }
}

/// The Squadd home's screen state for one server. Built per server (the logged-in tree is keyed
/// by it), so one companion's agents never show under another.
///
/// Rename, pin, archive and delete change the row at once and put it back as it was when the
/// companion refuses; creating a thread waits for the companion's answer.
///
/// What the home shows is saved in the server's offline cache (#34); a load that fails before
/// anything showed puts the saved copy on screen, marked offline, and reads again on the chat
/// stream's backoff until the computer answers.
@MainActor @Observable
final class SquaddAgentListModel {
    enum Phase: Equatable {
        case loading
        case loaded([SquaddAgentSection])
        case failed
    }

    private(set) var phase: Phase = .loading
    /// Matches for the last query; nil while no query is active.
    private(set) var searchHits: [SquaddSearchHit]?
    /// The rooms, below the agents; set with `phase`.
    private(set) var rooms: [SquaddRoomSection] = []
    /// The agents on screen are the cached copy, not the computer's answer.
    private(set) var isShowingCache = false
    @ObservationIgnored private var bots: [SquaddBot] = []
    @ObservationIgnored private var roomList: [SquaddRoom] = []
    @ObservationIgnored private let client: SquaddCompanionClient
    @ObservationIgnored private let onUnpaired: () -> Void
    @ObservationIgnored private let cache: ModelContext?
    @ObservationIgnored private let retryDelay: ChatStreamReconnectDelay
    /// Reads again while the cached copy shows; ends with the first answer.
    @ObservationIgnored private(set) var retrying: Task<Void, Never>?

    /// `onUnpaired` runs when the companion refused the token. `cache` keeps the home under
    /// `client.server`; nil keeps nothing. `retryDelay` waits between reads of an offline home.
    init(client: SquaddCompanionClient, cache: ModelContext? = nil,
         retryDelay: @escaping ChatStreamReconnectDelay = ChatStreamReconnectBackoff.standardDelay,
         onUnpaired: @escaping () -> Void) {
        self.client = client
        self.cache = cache
        self.retryDelay = retryDelay
        self.onUnpaired = onUnpaired
    }

    func load() async {
        do {
            let list = try await client.botList()
            bots = list.bots
            roomList = list.rooms
            isShowingCache = false
            publish()
        } catch {
            guard handled(error) else { return }
            // Keep what is on screen through a failed refresh; only an empty screen says it failed.
            if case .loaded = phase { return }
            if let cache, let cached = try? CacheStore.cachedSquaddBots(serverURL: client.server, in: cache) {
                bots = cached
                isShowingCache = true
                publish()
                retryWhileOffline()
                return
            }
            phase = .failed
        }
    }

    private func retryWhileOffline() {
        guard retrying == nil else { return }
        retrying = Task { [weak self, retryDelay] in
            let delays = ChatStreamReconnectBackoff.delays
            var attempt = 0
            while self?.isShowingCache == true {
                attempt += 1
                do { try await retryDelay(delays[min(attempt, delays.count) - 1]) } catch { break }
                await self?.load()
            }
            self?.retrying = nil
        }
    }

    /// A new, untitled thread at the top of `botId`'s list.
    func createThread(botId: String) async -> Bool {
        do {
            let task = try await client.createTask(botId: botId)
            edit(botId) { $0.insert(task, at: 0) }
            return true
        } catch {
            _ = handled(error)
            return false
        }
    }

    func rename(threadId: String, botId: String, to title: String) async -> Bool {
        await change(threadId, botId, ["title": title]) { $0.title = title }
    }

    func setPinned(_ pinned: Bool, threadId: String, botId: String) async -> Bool {
        await change(threadId, botId, ["pinned": pinned]) { $0.pinned = pinned ? true : nil }
    }

    /// Archive hides the thread from the open list on every device; restore brings it back.
    func setArchived(_ archived: Bool, threadId: String, botId: String, now: Date = .now) async -> Bool {
        let at = (now.timeIntervalSince1970 * 1000).rounded()
        return await change(threadId, botId, ["archivedAt": archived ? at as Any : NSNull()]) { $0.archivedAt = archived ? at : nil }
    }

    func delete(threadId: String, botId: String) async -> Bool {
        guard let index = bots.firstIndex(where: { $0.id == botId }),
              let position = bots[index].tasks.firstIndex(where: { $0.threadId == threadId }) else { return false }
        let removed = bots[index].tasks[position]
        edit(botId) { $0.remove(at: position) }
        do {
            try await client.deleteTask(botId: botId, threadId: threadId)
            return true
        } catch {
            edit(botId) { $0.insert(removed, at: min(position, $0.count)) }
            _ = handled(error)
            return false
        }
    }

    /// A new folder at the end of `botId`'s folders; waits for the companion like a new thread.
    func createFolder(named name: String, botId: String) async -> Bool {
        do {
            let project = try await client.createProject(botId: botId, name: name)
            editBot(botId) { $0.projects.append(project) }
            return true
        } catch {
            _ = handled(error)
            return false
        }
    }

    /// Puts a thread in a folder, or in none with nil.
    func move(threadId: String, botId: String, toFolder projectId: String?) async -> Bool {
        await change(threadId, botId, ["projectId": projectId.map { $0 as Any } ?? NSNull()]) { $0.projectId = projectId }
    }

    /// Moves a folder one place in the shown order (`offset` -1 up, +1 down) and saves the whole
    /// order, as the desktop's drag does.
    func moveFolder(_ projectId: String, botId: String, by offset: Int) async -> Bool {
        guard let bot = bots.first(where: { $0.id == botId }),
              let after = bot.projects(movingFolder: projectId, by: offset) else { return false }
        let before = bot.projects
        editBot(botId) { $0.projects = after }
        do {
            try await client.reorderProjects(botId: botId, projectIds: after.map(\.id))
            return true
        } catch {
            editBot(botId) { $0.projects = before }
            _ = handled(error)
            return false
        }
    }

    /// Deletes a folder; its threads stay, in no folder, as the companion does.
    func deleteFolder(_ projectId: String, botId: String) async -> Bool {
        guard let bot = bots.first(where: { $0.id == botId }) else { return false }
        let before = bot
        editBot(botId) { bot in
            bot.projects.removeAll { $0.id == projectId }
            for index in bot.tasks.indices where bot.tasks[index].projectId == projectId { bot.tasks[index].projectId = nil }
        }
        do {
            try await client.deleteProject(botId: botId, projectId: projectId)
            return true
        } catch {
            editBot(botId) { bot in
                bot.projects = before.projects
                for task in before.tasks where task.projectId == projectId {
                    if let index = bot.tasks.firstIndex(where: { $0.threadId == task.threadId }) { bot.tasks[index].projectId = projectId }
                }
            }
            _ = handled(error)
            return false
        }
    }

    // MARK: Rooms

    /// Renames the room at once and puts the old name back when the computer refuses.
    func renameRoom(_ roomId: String, to name: String) async -> Bool {
        guard let index = roomList.firstIndex(where: { $0.id == roomId }) else { return false }
        let before = roomList[index].name
        editRoom(roomId) { $0.name = name }
        do {
            _ = try await client.renameRoom(roomId, to: name)
            return true
        } catch {
            editRoom(roomId) { $0.name = before }
            _ = handled(error)
            return false
        }
    }

    /// Deletes the room on the computer; the row leaves at once and comes back if refused.
    /// Returns nil when deleted, else what to tell the person (a working room is refused).
    func deleteRoom(_ roomId: String) async -> String? {
        guard let index = roomList.firstIndex(where: { $0.id == roomId }) else { return nil }
        let removed = roomList.remove(at: index)
        publish()
        do {
            try await client.deleteRoom(roomId)
            return nil
        } catch {
            roomList.insert(removed, at: min(index, roomList.count))
            publish()
            guard handled(error) else { return nil }
            return SquaddChatTurnCoordinator.failureMessage(error)
        }
    }

    /// A new, empty conversation at the top of the room; waits for the computer's answer.
    func createRoomThread(_ roomId: String) async -> Bool {
        do {
            let room = try await client.createRoomTask(roomId)
            editRoom(roomId) { $0.tasks = room.tasks }
            return true
        } catch {
            _ = handled(error)
            return false
        }
    }

    private func editRoom(_ roomId: String, _ update: (inout SquaddRoom) -> Void) {
        guard let index = roomList.firstIndex(where: { $0.id == roomId }) else { return }
        update(&roomList[index])
        publish()
    }

    /// Searches every conversation's messages; an empty query ends the search. False when the
    /// search failed: the last results stay, since an empty list would say nothing matched.
    func search(_ query: String) async -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { searchHits = nil; return true }
        do {
            searchHits = try await client.search(query)
            return true
        } catch {
            return !handled(error)
        }
    }

    /// The thread as a Markdown file in its own temporary folder, for the share sheet.
    func export(threadId: String, title: String) async -> URL? {
        do {
            let data = try await client.exportMarkdown(threadId: threadId)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // A slash or colon in a title would name a folder or fail the write.
            let name = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            let file = folder.appendingPathComponent((name.isEmpty ? "Thread" : name) + ".md")
            try data.write(to: file)
            return file
        } catch {
            _ = handled(error)
            return nil
        }
    }

    /// Applies `apply` to the thread now and sends `changes`; puts the thread back if refused.
    private func change(_ threadId: String, _ botId: String, _ changes: [String: Any],
                        apply: (inout SquaddTask) -> Void) async -> Bool {
        guard let before = task(threadId, botId) else { return false }
        var after = before
        apply(&after)
        replace(after, botId)
        do {
            _ = try await client.patchTask(botId: botId, threadId: threadId, changes)
            return true
        } catch {
            // Put back only this thread, so a change to another thread in flight stays.
            replace(before, botId)
            _ = handled(error)
            return false
        }
    }

    private func replace(_ task: SquaddTask, _ botId: String) {
        edit(botId) { tasks in
            if let index = tasks.firstIndex(where: { $0.threadId == task.threadId }) { tasks[index] = task }
        }
    }

    private func task(_ threadId: String, _ botId: String) -> SquaddTask? {
        bots.first { $0.id == botId }?.tasks.first { $0.threadId == threadId }
    }

    private func edit(_ botId: String, _ update: (inout [SquaddTask]) -> Void) {
        editBot(botId) { update(&$0.tasks) }
    }

    private func editBot(_ botId: String, _ update: (inout SquaddBot) -> Void) {
        guard let index = bots.firstIndex(where: { $0.id == botId }) else { return }
        update(&bots[index])
        publish()
    }

    private func publish() {
        rooms = roomList.map { SquaddRoomSection(room: $0, bots: bots) }
        let sections = bots.map(SquaddAgentSection.init(bot:))
        phase = .loaded(sections)
        guard !isShowingCache else { return }
        BotWidgetPublisher.shared.publish(sections, squaddServer: client.server)
        guard let cache else { return }
        do {
            try CacheStore.cacheSquaddBots(bots, serverURL: client.server, in: cache)
        } catch {
            Logger(subsystem: "com.squaddcrm.multiagents", category: "cache").error("Squadd home cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// False for a cancelled request, which says nothing about the companion.
    private func handled(_ error: Error) -> Bool {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return false }
        if case SquaddError.unpaired = error { onUnpaired() }
        return true
    }
}
