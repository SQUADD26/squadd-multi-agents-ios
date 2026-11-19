import Foundation
import Observation

/// One agent in the Squadd home: its name and its task threads as session rows, newest first.
struct SquaddAgentSection: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String?
    let isBusy: Bool
    let threads: [SessionSummary]
    /// The threads the companion marks unread, by `SessionSummary.id` (the thread id).
    let unreadThreadIDs: Set<String>
    /// The agent as the companion sent it, for its avatar and its editor.
    let bot: SquaddBot

    init(bot: SquaddBot) {
        self.bot = bot
        id = bot.id
        unreadThreadIDs = Set(bot.tasks.filter { $0.unread == true }.map(\.threadId))
        name = Self.nonEmpty(bot.name) ?? String(localized: "Unnamed Agent")
        subtitle = Self.nonEmpty(bot.title)
        isBusy = bot.busy == true
        threads = bot.tasks
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
            .map { task in
                // The companion counts milliseconds; session rows read seconds.
                SessionSummary(sessionId: task.threadId, title: Self.nonEmpty(task.title),
                               updatedAt: task.updatedAt.map { $0 / 1000 }, isStreaming: task.busy)
            }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The Squadd home's screen state for one server. Built per server (the logged-in tree is keyed
/// by it), so one companion's agents never show under another.
@MainActor @Observable
final class SquaddAgentListModel {
    enum Phase: Equatable {
        case loading
        case loaded([SquaddAgentSection])
        case failed
    }

    private(set) var phase: Phase = .loading
    @ObservationIgnored private let fetch: () async throws -> [SquaddBot]
    @ObservationIgnored private let onUnpaired: () -> Void

    /// `fetch` reads `GET /api/bots`; `onUnpaired` runs when the companion refused the token.
    init(fetch: @escaping () async throws -> [SquaddBot], onUnpaired: @escaping () -> Void) {
        self.fetch = fetch
        self.onUnpaired = onUnpaired
    }

    func load() async {
        do {
            phase = .loaded(try await fetch().map(SquaddAgentSection.init(bot:)))
        } catch SquaddError.unpaired {
            onUnpaired()
        } catch is CancellationError {
            return
        } catch {
            // Keep what is on screen through a failed refresh; only an empty screen says it failed.
            if case .loaded = phase { return }
            phase = .failed
        }
    }
}
