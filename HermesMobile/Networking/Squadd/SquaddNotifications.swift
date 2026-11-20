import Foundation

/// One entry of the computer's notification list (`NotificationLogEntry`, `shared/notification.ts`):
/// what the desktop's bell shows. Only `id` is required, so a companion that adds a kind or a field
/// never empties the list.
struct SquaddNotification: Decodable, Equatable, Identifiable {
    let id: String
    /// Milliseconds since 1970.
    let at: Double?
    var read: Bool
    let kind: String?
    let botId: String?
    let botName: String?
    let threadId: String?
    let title: String?
    let body: String?
    /// Set when the conversation is a room's.
    let groupId: String?

    /// A conversation a tap opens and reads: an agent's thread, or a room's.
    var opensHere: Bool { threadId != nil && (botId != nil || groupId != nil) }

    private enum CodingKeys: String, CodingKey { case id, at, read, kind, botId, botName, threadId, title, body, groupId }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        at = try? container.decodeIfPresent(Double.self, forKey: .at)
        read = (try? container.decodeIfPresent(Bool.self, forKey: .read)) ?? false
        kind = try? container.decodeIfPresent(String.self, forKey: .kind)
        botId = try? container.decodeIfPresent(String.self, forKey: .botId)
        botName = try? container.decodeIfPresent(String.self, forKey: .botName)
        threadId = try? container.decodeIfPresent(String.self, forKey: .threadId)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        body = try? container.decodeIfPresent(String.self, forKey: .body)
        groupId = try? container.decodeIfPresent(String.self, forKey: .groupId)
    }
}

private struct SquaddNotificationList: Decodable {
    let notifications: [SquaddLossy<SquaddNotification>]?
}

extension SquaddCompanionClient {
    /// `GET /api/notifications`: the computer's recent notifications, newest first.
    func notifications() async throws -> [SquaddNotification] {
        try JSONDecoder().decode(SquaddNotificationList.self, from: await call("GET", "api/notifications")).notifications?
            .compactMap(\.value) ?? []
    }

    /// Marks a conversation read the way opening it on the desktop does: the computer marks its
    /// notifications read and tells every open app with a `notifications.read` frame.
    func markRead(_ notification: SquaddNotification) async throws {
        guard let threadId = notification.threadId else { return }
        if let roomId = notification.groupId {
            _ = try await call("POST", "api/groups/\(Self.segment(roomId))/read", body: ["threadId": threadId])
        } else if let botId = notification.botId {
            _ = try await call("POST", "api/bots/\(Self.segment(botId))/read", body: ["threadId": threadId])
        }
    }
}
