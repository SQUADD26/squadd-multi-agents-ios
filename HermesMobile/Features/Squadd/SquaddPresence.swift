import Foundation

/// Keeps the person "present" for Squadd while the app is in the foreground: one presence ping on
/// arrival, then one a minute, the desktop's own pace (`PRESENCE_MIN_INTERVAL_MS`). It runs inside
/// a task the Squadd home starts only while the scene is active and cancels when it leaves, so
/// nothing is scheduled in the background and nothing wakes the app.
enum SquaddPresence {
    static let interval: Duration = .seconds(60)

    /// Pings until the calling task is cancelled. A failed ping (offline, computer asleep) waits for
    /// the next one; a revoked token is the agent list's to handle.
    static func keepAlive(ping: () async throws -> Void,
                          sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async {
        while !Task.isCancelled {
            try? await ping()
            do { try await sleep(interval) } catch { return }
        }
    }
}
