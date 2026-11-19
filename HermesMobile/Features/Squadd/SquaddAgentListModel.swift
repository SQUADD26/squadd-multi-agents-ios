import Foundation
import Observation

/// One agent in the Squadd home: its open threads in the desktop sidebar's order, and its
/// archived ones apart, as session rows.
struct SquaddAgentSection: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String?
    let isBusy: Bool
    let threads: [SessionSummary]
    let archived: [SessionSummary]
    /// The threads the companion marks unread, by `SessionSummary.id` (the thread id).
    let unreadThreadIDs: Set<String>

    init(bot: SquaddBot) {
        id = bot.id
        unreadThreadIDs = Set(bot.tasks.filter { $0.unread == true }.map(\.threadId))
        name = Self.nonEmpty(bot.name) ?? String(localized: "Unnamed Agent")
        subtitle = Self.nonEmpty(bot.title)
        isBusy = bot.busy == true
        let ordered = SquaddTask.desktopOrder(bot.tasks)
        threads = ordered.filter { !$0.isArchived }.map(Self.row)
        archived = ordered.filter(\.isArchived).map(Self.row)
    }

    private static func row(_ task: SquaddTask) -> SessionSummary {
        // The companion counts milliseconds; session rows read seconds.
        SessionSummary(sessionId: task.threadId, title: nonEmpty(task.title), updatedAt: task.updatedAt.map { $0 / 1000 },
                       pinned: task.pinned, archived: task.isArchived, projectId: task.projectId, isStreaming: task.busy)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The Squadd home's screen state for one server. Built per server (the logged-in tree is keyed
/// by it), so one companion's agents never show under another.
///
/// Rename, pin, archive and delete change the row at once and put it back as it was when the
/// companion refuses; creating a thread waits for the companion's answer.
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
    @ObservationIgnored private var bots: [SquaddBot] = []
    @ObservationIgnored private let client: SquaddCompanionClient
    @ObservationIgnored private let onUnpaired: () -> Void

    /// `onUnpaired` runs when the companion refused the token.
    init(client: SquaddCompanionClient, onUnpaired: @escaping () -> Void) {
        self.client = client
        self.onUnpaired = onUnpaired
    }

    func load() async {
        do {
            bots = try await client.bots()
            publish()
        } catch {
            guard handled(error) else { return }
            // Keep what is on screen through a failed refresh; only an empty screen says it failed.
            if case .loaded = phase { return }
            phase = .failed
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

    /// Searches every conversation's messages; an empty query ends the search.
    func search(_ query: String) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { searchHits = nil; return }
        do {
            searchHits = try await client.search(query)
        } catch {
            if handled(error) { searchHits = [] }
        }
    }

    /// The thread as a Markdown file in its own temporary folder, for the share sheet.
    func export(threadId: String, title: String) async -> URL? {
        do {
            let data = try await client.exportMarkdown(threadId: threadId)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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
            // Put back only this thread's fields, so a change to another thread in flight stays.
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
        guard let index = bots.firstIndex(where: { $0.id == botId }) else { return }
        update(&bots[index].tasks)
        publish()
    }

    private func publish() {
        phase = .loaded(bots.map(SquaddAgentSection.init(bot:)))
    }

    /// False for a cancelled request, which says nothing about the companion.
    private func handled(_ error: Error) -> Bool {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return false }
        if case SquaddError.unpaired = error { onUnpaired() }
        return true
    }
}
