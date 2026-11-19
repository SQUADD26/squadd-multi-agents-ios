import Foundation

/// The one switch for the Hermes and hermes-webui backends (ADR 0002). Set by the build setting
/// `HERMES_BACKENDS` in `Config/Shared.xcconfig`: `NO` builds the Squadd v1, where no webui or
/// Hermes server can be added or opened and every screen that only those servers serve (Kanban,
/// Workspace, Git, Move to Hermes, Thinking and Fast, rollback, delegated work, custom headers,
/// Tasks, Usage, Screen) is hidden; `YES` builds the app as Hermex ships it. The hidden code stays
/// compiled. Read here only: every gate asks `isEnabled`, never a server's name or kind.
enum HermesBackends {
    /// The build's value.
    static let built: Bool = {
        #if HERMES_BACKENDS
        true
        #else
        false
        #endif
    }()

    /// `built`, except that the test bundle turns it on (`TestHostStateGuard`) so the Hermex
    /// suite runs as before, and a flag-off test sets it off for its own duration.
    nonisolated(unsafe) static var isEnabled = built
}
