import Foundation
import Observation

/// The computer's notifications as the home's bell shows them: the list from `GET /api/notifications`,
/// kept current by the event stream's `notify` and `notifications.read` frames while the home is on
/// screen. Read marks come only from the computer, so a read on the desktop shows here too.
@MainActor @Observable
final class SquaddNotificationsModel {
    private(set) var items: [SquaddNotification] = []
    /// The last load failed; the list shows what it had.
    private(set) var loadFailed = false

    var unreadCount: Int { items.lazy.filter { !$0.read }.count }

    @ObservationIgnored private let client: SquaddCompanionClient
    @ObservationIgnored private let reconnectDelay: ChatStreamReconnectDelay

    init(client: SquaddCompanionClient,
         reconnectDelay: @escaping ChatStreamReconnectDelay = ChatStreamReconnectBackoff.standardDelay) {
        self.client = client
        self.reconnectDelay = reconnectDelay
    }

    func load() async {
        do {
            items = try await client.notifications()
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    /// Follows the computer's event stream until the calling task is cancelled. Each connection
    /// reloads the list first, so whatever was missed while away is in it.
    func follow() async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                for try await (_, frame) in client.events(since: nil) {
                    attempt = 0
                    await apply(frame)
                }
            } catch SquaddError.unpaired {
                return
            } catch {}
            guard !Task.isCancelled else { return }
            let delays = ChatStreamReconnectBackoff.delays
            attempt += 1
            do { try await reconnectDelay(delays[min(attempt, delays.count) - 1]) } catch { return }
        }
    }

    func apply(_ frame: SquaddFrame) async {
        switch frame {
        case .hello:
            await load()
        case .notify(let notification):
            items.removeAll { $0.id == notification.id }
            items.insert(notification, at: 0)
        case .notificationsRead(let ids):
            let read = Set(ids)
            for index in items.indices where read.contains(items[index].id) { items[index].read = true }
        default:
            break
        }
    }

    /// Marks the notification's conversation read on the computer, as opening it on the desktop does.
    /// The list changes only once the computer says so: the `notifications.read` frame, or this
    /// call's success for the conversation's entries.
    func markRead(_ notification: SquaddNotification) async throws {
        try await client.markRead(notification)
        for index in items.indices where items[index].threadId == notification.threadId { items[index].read = true }
    }
}
