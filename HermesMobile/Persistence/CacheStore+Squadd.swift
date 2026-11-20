import Foundation
import SwiftData

/// The offline cache of a Squadd computer (#34), in the message table under its server's URL, so
/// sign-out, server removal and Clear Offline Cache (`clearCache(for:)`) take it with the server's
/// other rows, and the TTL ages it out like a Hermes transcript.
///
/// The home is one row under the scope `squadd|home`: the agents with their threads and folders, as
/// the companion's `GET /api/bots` JSON. A thread's transcript is its shown rows under
/// `squadd|thread|<thread id>`. No scope here is a session id, so no Hermes or webui read finds them.
extension CacheStore {
    static let squaddHomeScope = "squadd|home"

    static func squaddThreadScope(threadId: String) -> String { "squadd|thread|\(threadId)" }

    /// The agents last read from `serverURL`, or nil when none are cached.
    @MainActor
    static func cachedSquaddBots(serverURL: URL, in context: ModelContext) throws -> [SquaddBot]? {
        guard let json = try cachedMessages(serverURL: serverURL, sessionID: squaddHomeScope, in: context).first?.content
        else { return nil }
        // A row an older build wrote in another shape reads as none; the next load replaces it.
        return try? JSONDecoder().decode(SquaddBotList.self, from: Data(json.utf8)).bots
    }

    @MainActor
    static func cacheSquaddBots(_ bots: [SquaddBot], serverURL: URL, in context: ModelContext) throws {
        let json = String(decoding: try JSONEncoder().encode(SquaddBotList(bots: bots)), as: UTF8.self)
        try cacheMessages([ChatMessage(role: "squadd-home", content: json, timestamp: nil, messageId: squaddHomeScope)],
                          serverURL: serverURL, sessionID: squaddHomeScope, in: context)
    }
}
