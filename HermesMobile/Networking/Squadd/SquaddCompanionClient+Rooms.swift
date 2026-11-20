import Foundation

/// A room's routes (`/api/groups/:id`, `openmausbot/companion/src/proxy.ts`). The list of rooms comes
/// with the agents (`botList()`); `GET /api/groups/:id` is not open to a phone.
extension SquaddCompanionClient {
    /// Sends a typed message into one of the room's conversations. `mentions` names the members the
    /// text addresses with `@Name`; the companion reads the same names from the text. A busy room
    /// queues the message (`queued`, `queueId`) and runs it once the turn before ends.
    func send(_ text: String, roomId: String, threadId: String, sendId: String,
              mentions: [String]) async throws -> SquaddSendReceipt {
        var body: [String: Any] = ["text": text, "threadId": threadId, "sendId": sendId]
        if !mentions.isEmpty { body["mentions"] = mentions }
        let data = try await call("POST", "api/groups/\(Self.segment(roomId))/messages", body: body)
        return try JSONDecoder().decode(SquaddSendReceipt.self, from: data)
    }

    /// Stops the turn running in one of the room's conversations. `stopId` makes a retry land once.
    func interrupt(roomId: String, threadId: String, stopId: String) async throws {
        _ = try await call("POST", "api/groups/\(Self.segment(roomId))/interrupt",
                           body: ["threadId": threadId, "stopId": stopId])
    }

    /// Renames the room; the computer refuses a name over 100 characters.
    func renameRoom(_ roomId: String, to name: String) async throws -> SquaddRoom {
        let data = try await call("PATCH", "api/groups/\(Self.segment(roomId))", body: ["name": name])
        return try JSONDecoder().decode(SquaddRoomEnvelope.self, from: data).group
    }

    /// Deletes the room, its messages and every conversation in it; its agents stay. The computer
    /// refuses while the room is working (409).
    func deleteRoom(_ roomId: String) async throws {
        _ = try await call("DELETE", "api/groups/\(Self.segment(roomId))")
    }

    /// A new, empty conversation in the room. Returns the room as it now stands.
    func createRoomTask(_ roomId: String) async throws -> SquaddRoom {
        let data = try await call("POST", "api/groups/\(Self.segment(roomId))/tasks", body: [:])
        return try JSONDecoder().decode(SquaddRoomEnvelope.self, from: data).group
    }
}
