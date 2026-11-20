import Foundation
import Observation
import OSLog
import SwiftData

/// What a `SquaddChatTurnCoordinator` asks of the chat beyond the shared stream delegate.
/// `ChatViewModel` conforms.
@MainActor protocol SquaddChatTurnDelegate: ChatStreamCoordinatorDelegate {
    /// Replaces the transcript with the thread's stored rows.
    func squaddReplaceTranscript(_ messages: [ChatMessage], hasOlder: Bool)
    /// Shows the thread's cached rows, read-only and marked offline, until the next replace (#34).
    func squaddShowCached(_ messages: [ChatMessage])
    /// Puts an older page's rows in front of the transcript.
    func squaddPrependOlder(_ messages: [ChatMessage], hasOlder: Bool)
    /// The thread couldn't be read, or the companion can't be reached; nil once it is again.
    func squaddConnectionDidChange(failure: String?)
    /// A turn began: the next reply opens a new assistant row (as a Hermes turn does).
    func hermesTurnDidStart(prompt: HermesQueuedPrompt?)
    /// A row stored mid-turn that the transcript lacks, such as a queued message steered in.
    func squaddAppendRow(_ message: ChatMessage)
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
    /// The messages the companion holds for this thread until its turn can take them.
    private(set) var queued: [SquaddQueuedMessage] = []

    @ObservationIgnored private weak var delegate: (any SquaddChatTurnDelegate)?
    @ObservationIgnored private let client: SquaddCompanionClient
    @ObservationIgnored private let reconnectDelay: ChatStreamReconnectDelay
    @ObservationIgnored private var stream: Task<Void, Never>?
    /// The last frame id seen: a reconnect resumes after it.
    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var hasLoaded = false
    /// The server's offline cache (#34): every read of the newest page is kept there, and shown
    /// when the first read fails. Set by the chat's first call that carries it.
    @ObservationIgnored var cache: ModelContext?
    /// The transcript on screen is the cached copy: the next connection reads it again.
    @ObservationIgnored private var showsCache = false
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
    /// The running turn's id, which Stop names.
    @ObservationIgnored private var runningTurnID: String?
    /// Whether the open connection asked to resume after `cursor`.
    @ObservationIgnored private var isResuming = false
    /// The running reply began before this chat saw it (opened mid-turn, or frames lost on a
    /// reconnect): it shows as working, and its stored row comes when the turn ends.
    @ObservationIgnored private var joinedMidReply = false
    /// A send's id, which makes a retry land once; tests pass the recorded one.
    @ObservationIgnored var makeSendID: () -> String = { UUID().uuidString }

    /// `reconnectDelay` waits the shared backoff's steps between reconnects; tests pass their own.
    init(_ chat: SquaddThreadChat, session: URLSession = .shared,
         reconnectDelay: @escaping ChatStreamReconnectDelay = ChatStreamReconnectBackoff.standardDelay) {
        self.chat = chat
        client = SquaddCompanionClient(server: chat.server, token: chat.token, session: session)
        self.reconnectDelay = reconnectDelay
    }

    /// Reads the transcript and opens the event stream, unless it is already open.
    func activate() async {
        guard stream == nil else { return }
        stream = Task { [weak self] in await self?.runStream() }
        await reload()
    }

    /// A staged file a send uploads ahead of its words (#23). `id` makes a retried upload land once.
    struct OutgoingFile {
        let id: UUID
        let name: String
        let mime: String
        let data: () async throws -> Data
    }

    /// A send's file the companion didn't take: the send stopped before its words went.
    struct UploadFailed: Error {
        let name: String
        let underlying: Error
    }

    /// Uploads `files`, then sends `text` with a tag for each, `/goal rest` as a goal the desktop's
    /// way; `followUp` says how it meets a running turn. Returns whether the companion queued it, so
    /// it shows in `queued` instead of the transcript. Throws when the companion didn't take a file
    /// (`UploadFailed`) or the message, so the chat puts it back.
    func send(_ text: String, files: [OutgoingFile] = [], sendId: String, localRowID: String,
              followUp: SquaddFollowUp? = nil) async throws -> Bool {
        var tags: [SquaddAttachmentTags.File] = []
        for file in files {
            do {
                let stored = try await client.upload(try await file.data(), name: file.name, mime: file.mime, uploadId: file.id)
                tags.append(.init(path: stored.path, name: stored.name ?? file.name,
                                  isImage: SquaddCompanionClient.attachmentImageTypes.contains(file.mime)))
            } catch {
                throw UploadFailed(name: file.name, underlying: error)
            }
        }
        ownSendIDs.insert(sendId)
        let receipt: SquaddSendReceipt
        do {
            let outgoing = SquaddSlashCommands.outgoing(text)
            receipt = try await client.send(SquaddAttachmentTags.compose(outgoing.text, files: tags), botId: chat.botId,
                                            threadId: chat.threadId, sendId: sendId, mode: outgoing.mode, followUp: followUp)
            if let stored = receipt.message?.id { rowIDs[stored] = localRowID; shownIDs.insert(stored) }
        } catch {
            ownSendIDs.remove(sendId)
            throw error
        }
        if stream == nil { await activate() }
        return receipt.queued == true
    }

    // MARK: Stop, queue, compaction (#13). Each only asks: the stream's frames change the state.

    /// Stop. The turn ends when its `turn.completed` comes.
    func interrupt() async throws {
        try await client.interrupt(botId: chat.botId, threadId: chat.threadId, turnId: runningTurnID)
    }

    func steerQueued(_ queueId: String) async throws {
        try await client.steerQueued(queueId, botId: chat.botId, threadId: chat.threadId)
    }

    func deleteQueued(_ queueId: String) async throws {
        try await client.deleteQueued(queueId, botId: chat.botId, threadId: chat.threadId)
    }

    /// The marker row comes as a stored message, which reloads the transcript.
    func compact() async throws {
        try await client.compact(botId: chat.botId, threadId: chat.threadId)
    }

    /// A stored file's bytes, for its thumbnail, its preview and the voice note player.
    func attachmentData(path: String) async throws -> Data {
        try await client.attachmentData(path: path)
    }

    /// What this thread's `/` panel offers: the built-ins the agent's engine and the computer allow,
    /// and the agent's skills as this thread sees them.
    func slashCatalog() async throws -> (scope: SlashCommandScope, skills: [SkillSlashSuggestion]) {
        async let skills = client.skills(botId: chat.botId, threadId: chat.threadId)
        async let bots = client.bots()
        async let instances = client.instances()
        async let authorsSkills = client.authorsSkills()
        let engine = try await bots.first { $0.id == chat.botId }?.modelSelection?.instanceId
        let runsAgents = try await instances.contains { $0.instanceId == engine && $0.runsAgents }
        return (SquaddSlashCommands.scope(runsAgents: runsAgents, authorsSkills: try await authorsSkills),
                SquaddSlashCommands.skills(try await skills))
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
            showsCache = false
            shownIDs = Set(page.messages.map(\.id))
            let rows = page.messages.compactMap { message -> ChatMessage? in
                guard let row = message.chatMessage else { return nil }
                guard let shown = rowIDs[message.id] else { return row }
                return ChatMessage(role: row.role, content: row.content, timestamp: row.timestamp, messageId: shown,
                                   attachments: row.attachments)
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
            writeCache(olderRows + rows)
        } catch is CancellationError {
        } catch {
            if !hasLoaded, let cached = readCache(), !cached.isEmpty {
                showsCache = true
                delegate?.squaddShowCached(cached)
            } else {
                delegate?.squaddConnectionDidChange(failure: Self.failureMessage(error))
            }
        }
    }

    private var cacheScope: String { CacheStore.squaddThreadScope(threadId: chat.threadId) }

    private func readCache() -> [ChatMessage]? {
        guard let cache else { return nil }
        do {
            return try CacheStore.cachedMessages(serverURL: chat.server, sessionID: cacheScope, in: cache)
        } catch {
            Self.logger.error("Squadd thread cache read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func writeCache(_ rows: [ChatMessage]) {
        guard let cache else { return }
        do {
            try CacheStore.cacheMessages(rows, serverURL: chat.server, sessionID: cacheScope, in: cache)
        } catch {
            Self.logger.error("Squadd thread cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let logger = Logger(subsystem: "com.squaddcrm.multiagents", category: "cache")

    /// Reads the page before the oldest row shown and puts it in front. Returns whether rows came.
    func loadOlder() async -> Bool {
        do {
            // A page of only hidden rows (digests, tools) shows nothing, so read on to one that does.
            while hasOlder, let before = oldestID {
                let page = try await client.messages(threadId: chat.threadId, before: before)
                guard oldestID == before else { return false }
                let rows = page.messages.compactMap(\.chatMessage)
                olderRows = rows + olderRows
                oldestID = page.messages.first?.id ?? before
                hasOlder = page.hasMore && !page.messages.isEmpty
                delegate?.squaddPrependOlder(rows, hasOlder: hasOlder)
                if !rows.isEmpty { return true }
            }
            return false
        } catch is CancellationError {
            return false
        } catch {
            delegate?.squaddConnectionDidChange(failure: Self.failureMessage(error))
            return false
        }
    }

    /// Whether a frame id (`<stream id>:<seq>`) is one already seen: same stream, seq not past
    /// the cursor's. A restarted companion has a new stream id, so its frames are never repeats.
    static func isRepeat(_ id: String, after cursor: String?) -> Bool {
        func split(_ value: String) -> (String, Int)? {
            guard let colon = value.lastIndex(of: ":"), let seq = Int(value[value.index(after: colon)...]) else { return nil }
            return (String(value[..<colon]), seq)
        }
        guard let cursor, let (stream, seq) = split(id), let (seen, last) = split(cursor) else { return false }
        return stream == seen && seq <= last
    }

    static func failureMessage(_ error: Error) -> String {
        switch error {
        case SquaddError.unpaired:
            String(localized: "This iPhone is no longer paired with the computer.")
        case SquaddError.status(let status) where status == 404:
            String(localized: "This conversation is no longer on the computer.")
        case SquaddError.status(let status) where status == 409:
            String(localized: "The computer is busy. Try again when the agents have finished.")
        case SquaddError.refused(let reason):
            reason
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
                    if let id {
                        if Self.isRepeat(id, after: cursor) { continue }
                        cursor = id
                    }
                    await apply(frame)
                }
            } catch SquaddError.unpaired {
                delegate?.squaddConnectionDidChange(failure: Self.failureMessage(SquaddError.unpaired))
                return
            } catch {}
            guard !Task.isCancelled else { return }
            let delays = ChatStreamReconnectBackoff.delays
            attempt += 1
            isReconnecting = true
            do { try await reconnectDelay(delays[min(attempt, delays.count) - 1]) } catch { return }
        }
    }

    private func apply(_ frame: SquaddFrame) async {
        switch frame {
        case .hello(let cursor, let resumed):
            // Resumed, the replay after our cursor follows (and is at most the hello's cursor).
            if !resumed { self.cursor = cursor }
            // The computer answers again while the cached copy shows: read the real transcript.
            if showsCache { await reload() }
            // A reconnect whose frames were lost: what they carried is in the stored transcript.
            else if !resumed, isResuming, hasLoaded {
                // The turn may still run or may have ended unseen: close it quietly, and a reply
                // that goes on rejoins as working.
                finish(nil)
                await reload()
            }
        case .turnStarted(let threadId, let turnId) where threadId == chat.threadId:
            beginTurn()
            runningTurnID = turnId
        case .replyDelta(let threadId, let itemId, let text) where threadId == chat.threadId:
            if activeStreamID == nil { beginTurn(); joinedMidReply = true }
            guard !joinedMidReply else { return }
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
            } else if activeStreamID != nil, message.role == "user", !shownIDs.contains(message.id),
                      !(message.sendId.map(ownSendIDs.contains) ?? false), let row = message.chatMessage {
                // A queued message steered into the running turn; the turn's end reloads the order.
                shownIDs.insert(message.id)
                delegate?.squaddAppendRow(row)
            }
        case .turnCompleted(let threadId, let ok) where threadId == chat.threadId:
            finish(ok ? .completed : .failed)
            await reload()
        case .turnStopped(let threadId) where threadId == chat.threadId:
            // The companion stores no stopped reply: the words already shown stay, marked stopped,
            // as on a Hermes chat, until the transcript next reloads.
            finish(.cancelled)
        case .queued(let queues):
            let mine = queues[chat.threadId] ?? []
            if mine != queued { queued = mine }
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
        joinedMidReply = false
        activeRunStartedAt = Date()
        activeStreamID = "squadd:\(chat.threadId):\(UUID().uuidString)"
        delegate?.hermesTurnDidStart(prompt: nil)
        delegate?.streamCoordinatorDidStartConnection(isReplay: false)
    }

    /// Ends the running turn the way the webui path ends a stream, so the chat records the
    /// same outcome, haptic and alert. A nil ending records none.
    private func finish(_ ending: TranscriptTurnRunOutcome.Ending?) {
        guard let streamID = activeStreamID else { return }
        latestRunEnding = ending.map { ChatRunEnding(startedAt: activeRunStartedAt ?? Date(), endedAt: Date(), ending: $0) }
        if ending == .completed {
            successfulResponseCompletion = .init(streamID: streamID, needsTranscriptRefresh: false)
            delegate?.streamCoordinatorApplyDone(DoneStreamEvent())
        }
        activeStreamID = nil
        activeRunStartedAt = nil
        streamingItemID = nil
        runningTurnID = nil
        joinedMidReply = false
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

    /// The chat reconnects as it appears, before its first load, so the cache is taken here too.
    func reconnectIfNeeded(modelContext: ModelContext?) async {
        if let modelContext { cache = modelContext }
        await activate()
    }

    /// A connection on the interface that went away can hang without an error, so an open
    /// stream reopens at once and resumes after the last frame seen.
    func networkPathDidChange(modelContext: ModelContext?) async {
        if let modelContext { cache = modelContext }
        guard stream != nil else { return }
        stop()
        await activate()
    }

    func recoverStaleStreamIfNeeded(now: Date, modelContext: ModelContext?) async {}
    func clearReplayConnection() {}
}
