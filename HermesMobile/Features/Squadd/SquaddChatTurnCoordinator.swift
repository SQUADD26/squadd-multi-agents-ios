import Foundation
import Observation
import SwiftData

/// What a `SquaddChatTurnCoordinator` asks of the chat beyond the shared stream delegate.
/// `ChatViewModel` conforms.
@MainActor protocol SquaddChatTurnDelegate: ChatStreamCoordinatorDelegate {
    /// Replaces the transcript with the thread's stored rows.
    func squaddReplaceTranscript(_ messages: [ChatMessage], hasOlder: Bool)
    /// Puts an older page's rows in front of the transcript.
    func squaddPrependOlder(_ messages: [ChatMessage], hasOlder: Bool)
    /// The thread couldn't be read, or the companion can't be reached; nil once it is again.
    func squaddConnectionDidChange(failure: String?)
    /// A turn began: the next reply opens a new assistant row (as a Hermes turn does).
    func hermesTurnDidStart(prompt: HermesQueuedPrompt?)
}

/// A Squadd agent thread the main chat opens: the companion, the device token, the agent and
/// the thread. Each value is its own chat.
struct SquaddThreadChat: Hashable, Identifiable {
    let server: URL
    let token: String
    let botId: String
    let threadId: String
    let title: String?

    var id: String { threadId }

    /// The session the chat view keys the thread's draft and cache on.
    var session: SessionSummary { SessionSummary(sessionId: threadId, title: title) }
}

extension SquaddThreadChat {
    /// Every thread under the agent headers, in the home's on-screen order: the rows the
    /// home links and the hardware-keyboard chat shortcuts step through.
    static func all(in sections: [SquaddAgentSection], server: URL, token: String) -> [SquaddThreadChat] {
        sections.flatMap { section in
            section.threads.map { SquaddThreadChat(in: section, thread: $0, server: server, token: token) }
        }
    }

    init(in section: SquaddAgentSection, thread: SessionSummary, server: URL, token: String) {
        self.init(server: server, token: token, botId: section.id, threadId: thread.id, title: thread.title)
    }
}

/// Runs a Squadd thread's turns for `ChatViewModel` (#11): the transcript from
/// `GET /api/threads/:id/messages`, sends through `POST /api/bots/:id/messages`, and the reply from
/// the companion's `/api/events` frames, fed to the same delegate the webui and Hermes paths feed,
/// so transcript building, pacing and run endings stay shared.
@MainActor @Observable
final class SquaddChatTurnCoordinator {
    let chat: SquaddThreadChat
    private(set) var activeStreamID: String?
    private(set) var activeRunStartedAt: Date?
    private(set) var latestRunEnding: ChatRunEnding?
    private(set) var successfulResponseCompletion: ChatStreamCoordinator.SuccessfulResponseCompletion?
    private(set) var isReconnecting = false

    @ObservationIgnored private weak var delegate: (any SquaddChatTurnDelegate)?
    @ObservationIgnored private let client: SquaddCompanionClient
    @ObservationIgnored private let retryDelay: @Sendable (Int) async throws -> Void
    @ObservationIgnored private var stream: Task<Void, Never>?
    /// The last frame id seen: a reconnect resumes after it.
    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var hasLoaded = false
    /// Rows of the older pages read so far, oldest first, kept across reloads of the newest page.
    @ObservationIgnored private var olderRows: [ChatMessage] = []
    /// The oldest stored message read (its id is the next `before`), and whether more remain.
    @ObservationIgnored private var oldestID: String?
    @ObservationIgnored private var hasOlder = false
    /// The first stored message of the newest page last read.
    @ObservationIgnored private var newestPageStart: String?
    /// Stored rows the transcript already shows, so a frame about one doesn't reload it.
    @ObservationIgnored private var shownIDs: Set<String> = []
    /// This chat's own sends, whose echo is already on screen.
    @ObservationIgnored private var ownSendIDs: Set<String> = []
    /// Stored row id → the id its row already has on screen (the sent prompt's local row, the
    /// streamed reply's row), so the stored copy replaces it in place instead of redrawing.
    @ObservationIgnored private var rowIDs: [String: String] = [:]
    @ObservationIgnored private var streamingItemID: String?
    /// Whether the open connection asked to resume after `cursor`.
    @ObservationIgnored private var isResuming = false
    /// A send's id, which makes a retry land once; tests pass the recorded one.
    @ObservationIgnored var makeSendID: () -> String = { UUID().uuidString }

    /// `retryDelay` waits before reconnect `attempt` (1, 2, …); tests pass their own.
    init(_ chat: SquaddThreadChat, session: URLSession = .shared,
         retryDelay: @escaping @Sendable (Int) async throws -> Void = { attempt in
             try await Task.sleep(for: .seconds(min(1 << min(attempt - 1, 4), 15)))
         }) {
        self.chat = chat
        client = SquaddCompanionClient(server: chat.server, token: chat.token, session: session)
        self.retryDelay = retryDelay
    }

    /// Reads the transcript and opens the event stream, unless it is already open.
    func activate() async {
        guard stream == nil else { return }
        stream = Task { [weak self] in await self?.runStream() }
        await reload()
    }

    /// Sends a typed message. Throws when the companion didn't take it, so the chat puts it back.
    func send(_ text: String, sendId: String, localRowID: String) async throws {
        ownSendIDs.insert(sendId)
        do {
            let receipt = try await client.send(text, botId: chat.botId, threadId: chat.threadId, sendId: sendId)
            if let stored = receipt.message?.id { rowIDs[stored] = localRowID; shownIDs.insert(stored) }
        } catch {
            ownSendIDs.remove(sendId)
            throw error
        }
        if stream == nil { await activate() }
    }

    func stop() {
        stream?.cancel()
        stream = nil
    }

    // MARK: Transcript

    private func reload() async {
        do {
            let page = try await client.messages(threadId: chat.threadId)
            // A turn that began meanwhile keeps its streaming row; its end reloads again.
            guard activeStreamID == nil else { return }
            hasLoaded = true
            shownIDs = Set(page.messages.map(\.id))
            let rows = page.messages.compactMap { message -> ChatMessage? in
                guard let row = message.chatMessage else { return nil }
                guard let shown = rowIDs[message.id] else { return row }
                return ChatMessage(role: row.role, content: row.content, timestamp: row.timestamp, messageId: shown)
            }
            // Older pages stay while the new page still reaches back to where the last one began;
            // past a gap they'd sit out of order, so paging starts again from this page.
            if olderRows.isEmpty || !page.messages.contains(where: { $0.id == newestPageStart }) {
                olderRows = []
                oldestID = page.messages.first?.id
                hasOlder = page.hasMore
            }
            newestPageStart = page.messages.first?.id
            delegate?.squaddConnectionDidChange(failure: nil)
            delegate?.squaddReplaceTranscript(olderRows + rows, hasOlder: hasOlder)
        } catch is CancellationError {
        } catch {
            delegate?.squaddConnectionDidChange(failure: Self.failureMessage(error))
        }
    }

    /// Reads the page before the oldest row shown and puts it in front. Returns whether rows came.
    func loadOlder() async -> Bool {
        guard hasOlder, let before = oldestID else { return false }
        do {
            let page = try await client.messages(threadId: chat.threadId, before: before)
            guard oldestID == before else { return false }
            let rows = page.messages.compactMap(\.chatMessage)
            olderRows = rows + olderRows
            oldestID = page.messages.first?.id ?? before
            hasOlder = page.hasMore && !page.messages.isEmpty
            delegate?.squaddPrependOlder(rows, hasOlder: hasOlder)
            return !rows.isEmpty
        } catch is CancellationError {
            return false
        } catch {
            delegate?.squaddConnectionDidChange(failure: Self.failureMessage(error))
            return false
        }
    }

    static func failureMessage(_ error: Error) -> String {
        switch error {
        case SquaddError.unpaired:
            String(localized: "This iPhone is no longer paired with the computer.")
        case SquaddError.status(let status) where status == 404:
            String(localized: "This conversation is no longer on the computer.")
        case SquaddError.status(let status) where status == 409:
            String(localized: "The computer is busy. Try again when the agents have finished.")
        default:
            String(localized: "Can't reach the computer.")
        }
    }

    // MARK: Stream

    private func runStream() async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                isResuming = cursor != nil
                for try await (id, frame) in client.events(since: cursor) {
                    attempt = 0
                    isReconnecting = false
                    if let id { cursor = id }
                    await apply(frame)
                }
            } catch SquaddError.unpaired {
                delegate?.squaddConnectionDidChange(failure: Self.failureMessage(SquaddError.unpaired))
                return
            } catch {}
            guard !Task.isCancelled else { return }
            attempt += 1
            isReconnecting = true
            do { try await retryDelay(attempt) } catch { return }
        }
    }

    private func apply(_ frame: SquaddFrame) async {
        switch frame {
        case .hello(let cursor, let resumed):
            self.cursor = cursor
            // A reconnect whose frames were lost: what they carried is in the stored transcript.
            if !resumed, isResuming, hasLoaded {
                if activeStreamID != nil { finish(.failed) }
                await reload()
            }
        case .turnStarted(let threadId) where threadId == chat.threadId:
            beginTurn()
        case .replyDelta(let threadId, let itemId, let text) where threadId == chat.threadId:
            if activeStreamID == nil { beginTurn() }
            streamingItemID = itemId ?? streamingItemID
            delegate?.streamCoordinatorAppendToken(text)
        case .message(let threadId, let message) where threadId == chat.threadId:
            if message.role == "bot", message.itemId != nil, message.itemId == streamingItemID,
               let row = delegate?.streamCoordinatorStreamingAssistantMessageID {
                rowIDs[message.id] = row
                shownIDs.insert(message.id)
            } else if activeStreamID == nil, !shownIDs.contains(message.id),
                      !(message.sendId.map(ownSendIDs.contains) ?? false), message.chatMessage != nil {
                // A row written elsewhere, such as on the desktop, while no turn runs here.
                await reload()
            }
        case .turnCompleted(let threadId, let ok) where threadId == chat.threadId:
            finish(ok ? .completed : .failed)
            await reload()
        case .runtimeError(let threadId, let message) where threadId == chat.threadId:
            delegate?.streamCoordinatorDidReceiveErrorMessage(message)
        default:
            break
        }
    }

    private func beginTurn() {
        guard activeStreamID == nil else { return }
        latestRunEnding = nil
        successfulResponseCompletion = nil
        streamingItemID = nil
        activeRunStartedAt = Date()
        activeStreamID = "squadd:\(chat.threadId):\(UUID().uuidString)"
        delegate?.hermesTurnDidStart(prompt: nil)
        delegate?.streamCoordinatorDidStartConnection(isReplay: false)
    }

    /// Ends the running turn the way the webui path ends a stream, so the chat records the
    /// same outcome, haptic and alert.
    private func finish(_ ending: TranscriptTurnRunOutcome.Ending) {
        guard let streamID = activeStreamID else { return }
        latestRunEnding = ChatRunEnding(startedAt: activeRunStartedAt ?? Date(), endedAt: Date(), ending: ending)
        if ending == .completed {
            successfulResponseCompletion = .init(streamID: streamID, needsTranscriptRefresh: false)
            delegate?.streamCoordinatorApplyDone(DoneStreamEvent())
        }
        activeStreamID = nil
        activeRunStartedAt = nil
        streamingItemID = nil
        delegate?.streamCoordinatorStreamingAssistantMessageID = nil
        if ending == .completed { delegate?.streamCoordinatorDidCompleteCurrentResponse(needsTranscriptRefresh: false) }
        delegate?.streamCoordinatorFlushPinnedLocalNoticesToTranscript()
        delegate?.streamCoordinatorDidFinishStream()
        delegate?.streamCoordinatorDidResetRecoveryState()
    }
}

extension SquaddChatTurnCoordinator: ChatTurnCoordinating {
    var recoveryState: ActiveStreamRecoveryState {
        activeStreamID != nil && isReconnecting ? .reconnecting : .idle
    }
    var liveTokensPerSecond: Double? { nil }
    var hasCompletedCurrentResponse: Bool { false }
    var isConnectionSuspended: Bool { stream == nil }
    /// Never: a reconnect resumes after the last frame id, so no text repeats.
    var isReplayConnection: Bool { false }

    func attach(delegate: any ChatStreamCoordinatorDelegate) {
        self.delegate = delegate as? any SquaddChatTurnDelegate
    }

    func setShowsLiveActivityResponseExcerpts(_ shows: Bool) {}
    func prepareForNewResponse() {}

    /// Leaving or backgrounding closes the stream; the turn keeps running on the computer, and
    /// the reconnect resumes after the last frame seen.
    func suspendActiveStreamConnection() { stop() }

    func reconnectIfNeeded(modelContext: ModelContext?) async { await activate() }

    func networkPathDidChange(modelContext: ModelContext?) async {
        guard isReconnecting else { return }
        stop()
        await activate()
    }

    func recoverStaleStreamIfNeeded(now: Date, modelContext: ModelContext?) async {}
    func clearReplayConnection() {}
}
