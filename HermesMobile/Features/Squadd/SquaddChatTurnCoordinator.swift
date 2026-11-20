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
    /// A queued send went in: its prompt joins the transcript as a sent row.
    func squaddAppendPrompt(_ message: ChatMessage)
    /// A version pick or a reaction the computer didn't take, in words for the person.
    func squaddActionDidFail(_ message: String)
}

/// What a transcript row of a Squadd thread carries beyond its text (#19): the versions an edit
/// made of a typed message, and the reactions on it.
struct SquaddRowMarks: Equatable {
    struct Versions: Equatable {
        /// Every version's stored id, oldest first.
        let ids: [String]
        /// The one the thread shows, from 0.
        let index: Int

        /// The version `step` away (-1 the one before, 1 the one after), if there is one.
        func id(_ step: Int) -> String? { ids.indices.contains(index + step) ? ids[index + step] : nil }
    }

    struct Reaction: Equatable {
        let emoji: String
        let count: Int
    }

    var versions: Versions?
    /// In the order the computer offers them.
    var reactions: [Reaction] = []
    /// The reactions this person put on, which the menu takes off again.
    var mine: Set<String> = []

    var isEmpty: Bool { versions == nil && reactions.isEmpty }
}

/// A Squadd agent thread the main chat opens: the companion, the device token, the agent and
/// the thread. Each value is its own chat.
struct SquaddThreadChat: Hashable, Identifiable {
    let server: URL
    let token: String
    let botId: String
    let threadId: String
    let title: String?
    /// The room the thread is a conversation of; nil for an agent's own thread.
    var room: SquaddRoomChat?

    var id: String { threadId }

    /// The session the chat view keys the thread's draft and cache on.
    var session: SessionSummary { SessionSummary(sessionId: threadId, title: title) }
}

/// A room as its chat needs it: where sends go and who `@` reaches.
struct SquaddRoomChat: Hashable {
    struct Member: Hashable {
        let id: String
        let name: String
    }

    let id: String
    let members: [Member]

    /// The members the text names as the companion reads it (`room-mentions.ts`): `@` and the
    /// whole name, in any case.
    func mentionedIDs(in text: String) -> [String] {
        members.filter { text.range(of: "@" + $0.name, options: .caseInsensitive) != nil }.map(\.id)
    }

    /// The members for the composer's `@` panel, which inserts each one's whole name.
    var mentions: BotMentions {
        BotMentions(roomMembers: members.compactMap {
            BotProfile(.object(["name": .string($0.id), "display_name": .string($0.name)]))
        })
    }
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
    /// Sends the busy room holds for the turns after this one, in order; each leaves once it goes in.
    private(set) var queuedPrompts: [QueuedSend] = []
    /// The room's members for the composer's `@` panel; nil for an agent's thread.
    @ObservationIgnored let mentions: BotMentions?

    struct QueuedSend: Equatable {
        let sendId: String
        let text: String
        let queueId: String?
    }
    /// Versions and reactions by on-screen row id; rows with neither are absent.
    private(set) var marks: [String: SquaddRowMarks] = [:]
    /// The rows of the last exchange on screen, from this person's last typed message on, which offer
    /// Undo; and whether it can go: not when that message is the thread's first (#20).
    private(set) var lastExchangeRowIDs: Set<String> = []
    private(set) var canUndo = false

    @ObservationIgnored private weak var delegate: (any SquaddChatTurnDelegate)?
    @ObservationIgnored private let client: SquaddCompanionClient
    @ObservationIgnored private let reconnectDelay: ChatStreamReconnectDelay
    @ObservationIgnored private var stream: Task<Void, Never>?
    /// The last frame id seen: a reconnect resumes after it.
    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var hasLoaded = false
    /// The stored rows of the older pages read so far, oldest first, kept across reloads of the newest page.
    @ObservationIgnored private var olderMessages: [SquaddMessage] = []
    /// The newest page's stored rows, every version included.
    @ObservationIgnored private var pageMessages: [SquaddMessage] = []
    /// The newest row of the version the thread shows; nil from a companion that doesn't say.
    @ObservationIgnored private var activeLeafID: String?
    /// The rows last handed to the transcript.
    @ObservationIgnored private var shownRows: [ChatMessage] = []
    /// On-screen row id → its stored message id, for the actions a row offers.
    @ObservationIgnored private var storedIDs: [String: String] = [:]
    /// The stored text messages of the version on screen, which a fork can start from, and the newest.
    @ObservationIgnored private var forkableIDs: Set<String> = []
    @ObservationIgnored private var newestForkableID: String?
    /// The server's offline cache (#34): every read of the newest page is kept there, and shown
    /// when the first read fails. Set by the chat's first call that carries it.
    @ObservationIgnored var cache: ModelContext?
    /// The transcript on screen is the cached copy: the next connection reads it again.
    @ObservationIgnored private var showsCache = false
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
    /// The running reply began before this chat saw it (opened mid-turn, or frames lost on a
    /// reconnect): it shows as working, and its stored row comes when the turn ends.
    @ObservationIgnored private var joinedMidReply = false
    /// A send's id, which makes a retry land once; tests pass the recorded one.
    @ObservationIgnored var makeSendID: () -> String = { UUID().uuidString }

    /// `reconnectDelay` waits the shared backoff's steps between reconnects; tests pass their own.
    init(_ chat: SquaddThreadChat, session: URLSession = .shared,
         reconnectDelay: @escaping ChatStreamReconnectDelay = ChatStreamReconnectBackoff.standardDelay) {
        self.chat = chat
        mentions = chat.room?.mentions
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

    /// Uploads `files`, then sends `text` with a tag for each; in an agent's thread `/goal rest` goes
    /// as a goal the desktop's way. Throws when the companion didn't take a file (`UploadFailed`) or
    /// the message, so the chat puts it back. Returns true when the agents were busy and the
    /// companion queued it: it is in `queuedPrompts`, not yet in the transcript.
    func send(_ text: String, files: [OutgoingFile] = [], sendId: String, localRowID: String) async throws -> Bool {
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
            if let room = chat.room {
                receipt = try await client.send(SquaddAttachmentTags.compose(text, files: tags), roomId: room.id,
                                                threadId: chat.threadId, sendId: sendId, mentions: room.mentionedIDs(in: text))
            } else {
                let outgoing = SquaddSlashCommands.outgoing(text)
                receipt = try await client.send(SquaddAttachmentTags.compose(outgoing.text, files: tags), botId: chat.botId,
                                                threadId: chat.threadId, sendId: sendId, mode: outgoing.mode)
            }
        } catch {
            ownSendIDs.remove(sendId)
            throw error
        }
        if let stored = receipt.message?.id { rowIDs[stored] = localRowID; shownIDs.insert(stored) }
        let queued = receipt.queued == true && receipt.message == nil
        if queued { queuedPrompts.append(QueuedSend(sendId: sendId, text: text, queueId: receipt.queueId)) }
        if stream == nil { await activate() }
        return queued
    }

    /// Stops the room's running turn; its `turn.completed` ends the reply here. Only a room
    /// has Stop: an agent thread's is its own ticket.
    func interrupt() async throws {
        guard let room = chat.room else { return }
        try await client.interrupt(roomId: room.id, threadId: chat.threadId, stopId: makeSendID())
    }

    /// A stored file's bytes, for its thumbnail, its preview and the voice note player.
    func attachmentData(path: String) async throws -> Data {
        try await client.attachmentData(path: path)
    }

    /// A reply in the computer's voice for Listen (#25), its utterances joined into one track.
    /// Nil when the computer has no voice set up, so Listen speaks on the phone.
    func speech(for text: String) async throws -> Data? {
        guard let clips = try await client.speech(for: text) else { return nil }
        if clips.count == 1 { return clips[0].data }
        return try await Task.detached { try ComposerVoiceNoteRecorder.wav(joining: clips) }.value
    }

    /// What this thread's `/` panel offers: the built-ins the agent's engine and the computer allow,
    /// and the agent's skills as this thread sees them.
    func slashCatalog() async throws -> (scope: SlashCommandScope, skills: [SkillSlashSuggestion]) {
        // A room's messages go out as typed: no agent's commands or skills to offer.
        guard chat.room == nil else { return (SlashCommandScope(builtins: []), []) }
        async let skills = client.skills(botId: chat.botId, threadId: chat.threadId)
        async let bots = client.bots()
        async let instances = client.instances()
        async let authorsSkills = client.authorsSkills()
        let engine = try await bots.first { $0.id == chat.botId }?.modelSelection?.instanceId
        let runsAgents = try await instances.contains { $0.instanceId == engine && $0.runsAgents }
        return (SquaddSlashCommands.scope(runsAgents: runsAgents, authorsSkills: try await authorsSkills),
                SquaddSlashCommands.skills(try await skills))
    }

    /// Takes the queued send out of the room's line; it leaves `queuedPrompts` once the companion
    /// confirms. Throws when it has already gone in or the companion refused.
    func cancelQueued(sendId: String) async throws {
        guard let room = chat.room, let queueId = queuedPrompts.first(where: { $0.sendId == sendId })?.queueId else { return }
        try await client.cancelQueued(roomId: room.id, queueId: queueId)
        queuedPrompts.removeAll { $0.sendId == sendId }
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
            let stored = Set(page.messages.compactMap(\.sendId))
            queuedPrompts.removeAll { stored.contains($0.sendId) }
            // Older pages stay while the new page still reaches back to where the last one began;
            // past a gap they'd sit out of order, so paging starts again from this page.
            if olderMessages.isEmpty || !page.messages.contains(where: { $0.id == newestPageStart }) {
                olderMessages = []
                oldestID = page.messages.first?.id
                hasOlder = page.hasMore
            }
            newestPageStart = page.messages.first?.id
            pageMessages = page.messages
            activeLeafID = page.activeLeafId
            delegate?.squaddConnectionDidChange(failure: nil)
            let rows = transcriptRows(of: olderMessages + pageMessages)
            shownRows = rows
            delegate?.squaddReplaceTranscript(rows, hasOlder: hasOlder)
            writeCache(rows)
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

    /// The rows the transcript shows of `messages`: the version the thread is on, without the rows
    /// the v1 chat doesn't draw. Also sets each row's marks.
    private func transcriptRows(of messages: [SquaddMessage]) -> [ChatMessage] {
        let all = olderMessages + pageMessages
        let path = Self.activePath(all, leaf: activeLeafID)
        updateMarks(all, path: path)
        return messages.compactMap { message -> ChatMessage? in
            guard path?.contains(message.id) ?? true, let row = message.chatMessage(namesAuthor: chat.room != nil) else { return nil }
            guard let shown = rowIDs[message.id] else { return row }
            return ChatMessage(role: row.role, content: row.content, timestamp: row.timestamp, messageId: shown,
                               name: row.name, attachments: row.attachments)
        }
    }

    /// The ids from `leaf` up through its parents: the version the thread shows. Nil shows every row,
    /// for a companion that names no leaf.
    // shortcut: a leaf outside the rows read so far (a long thread switched to an old version) also
    // shows every row read; page back to the leaf if threads that long switch versions.
    nonisolated static func activePath(_ messages: [SquaddMessage], leaf: String?) -> Set<String>? {
        let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        guard let leaf, var current = byID[leaf] else { return nil }
        var path: Set<String> = [current.id]
        while let parent = current.parentId, let next = byID[parent], path.insert(parent).inserted {
            current = next
        }
        return path
    }

    private func updateMarks(_ all: [SquaddMessage], path: Set<String>?) {
        // The versions of a typed message are the typed rows under its parent (`transcript-derivations.ts`).
        let versions = Dictionary(grouping: all.filter(\.isTypedUserText), by: { $0.parentId ?? "" })
            .mapValues { $0.sorted { ($0.at ?? 0) < ($1.at ?? 0) }.map(\.id) }
        var marks: [String: SquaddRowMarks] = [:]
        storedIDs = [:]
        forkableIDs = []
        newestForkableID = nil
        var exchange: [String] = []
        var lastTyped: SquaddMessage?
        for message in all where path?.contains(message.id) ?? true {
            let rowID = rowIDs[message.id] ?? message.id
            storedIDs[rowID] = message.id
            // The companion undoes back to before the last typed message (`undo-exchange`).
            if message.role == "user", message.kind == "text" { lastTyped = message; exchange = [] }
            if lastTyped != nil { exchange.append(rowID) }
            // The companion forks from a typed message or a reply (`forkHistory` in `store-forks.ts`).
            if message.kind == "text", message.role == "user" || message.role == "bot" {
                forkableIDs.insert(message.id)
                newestForkableID = message.id
            }
            var mark = SquaddRowMarks()
            if message.isTypedUserText, let ids = versions[message.parentId ?? ""], ids.count > 1,
               let index = ids.firstIndex(of: message.id) {
                mark.versions = .init(ids: ids, index: index)
            }
            mark.reactions = SquaddReaction.all.compactMap { emoji -> SquaddRowMarks.Reaction? in
                let count = message.reactions.filter { $0.emoji == emoji }.count
                return count > 0 ? .init(emoji: emoji, count: count) : nil
            }
            mark.mine = Set(message.reactions.filter { $0.by == "user" }.map(\.emoji))
            if !mark.isEmpty { marks[rowID] = mark }
        }
        if marks != self.marks { self.marks = marks }
        if Set(exchange) != lastExchangeRowIDs { lastExchangeRowIDs = Set(exchange) }
        let undoable = lastTyped?.parentId != nil
        if undoable != canUndo { canUndo = undoable }
    }

    /// The stored message behind an on-screen row, for the actions it offers.
    func storedID(ofRow rowID: String) -> String? { storedIDs[rowID] }

    // MARK: Fork (#20)

    /// Whether Fork From Here starts a thread from row `rowID`.
    func canFork(row rowID: String) -> Bool { storedIDs[rowID].map(forkableIDs.contains) ?? false }

    /// A new thread holding this one up to row `rowID`, or up to its newest message when nil (`/branch`).
    func fork(fromRow rowID: String?) async throws -> SquaddThreadChat {
        guard let messageID = rowID.map({ storedIDs[$0] }) ?? newestForkableID, forkableIDs.contains(messageID) else {
            throw SquaddError.status(404)
        }
        let task = try await client.fork(threadId: chat.threadId, through: messageID, botId: chat.botId)
        return SquaddThreadChat(server: chat.server, token: chat.token, botId: chat.botId, threadId: task.threadId, title: task.title)
    }

    // MARK: Undo (#20)

    /// Undo Last Exchange and `/undo`: the thread goes back to before this person's last typed message
    /// and shows the companion's version. Says why in the chat when the computer didn't take it.
    func undoLastExchange() async {
        guard activeStreamID == nil, canUndo else { return }
        do {
            try await client.undoExchange(botId: chat.botId, threadId: chat.threadId)
            await reload()
        } catch {
            delegate?.squaddActionDidFail(Self.failureMessage(error))
        }
    }

    // MARK: Versions and reactions (#19)

    /// Sends `text` as a new version of the typed message on row `rowID`. Like a send, the new version
    /// shows at once in place of the old one and what followed it; the old one stays a version away.
    /// Throws when the computer didn't take it, after putting the transcript back.
    func edit(rowID: String, to text: String) async throws {
        guard let messageID = storedIDs[rowID] else { throw SquaddError.status(404) }
        let sendId = makeSendID()
        let localRowID = "local-\(sendId)"
        ownSendIDs.insert(sendId)
        let kept = Array(shownRows.prefix { $0.id != rowID })
        let prompt = ChatMessage(role: "user", content: text, timestamp: Date().timeIntervalSince1970, messageId: localRowID)
        delegate?.squaddReplaceTranscript(kept + [prompt], hasOlder: hasOlder)
        do {
            let receipt = try await client.edit(messageId: messageID, to: text, botId: chat.botId,
                                                threadId: chat.threadId, sendId: sendId)
            if let stored = receipt.message?.id { rowIDs[stored] = localRowID; shownIDs.insert(stored) }
        } catch {
            ownSendIDs.remove(sendId)
            delegate?.squaddReplaceTranscript(shownRows, hasOlder: hasOlder)
            throw error
        }
        if stream == nil { await activate() }
    }

    /// Shows the version `step` away from the one on row `rowID` (-1 before, 1 after).
    func showVersion(_ step: Int, ofRow rowID: String) async {
        guard activeStreamID == nil, let target = marks[rowID]?.versions?.id(step) else { return }
        do {
            try await client.showBranch(through: target, botId: chat.botId, threadId: chat.threadId)
            await reload()
        } catch {
            delegate?.squaddActionDidFail(Self.failureMessage(error))
        }
    }

    /// Puts `emoji` on the message on row `rowID`, or takes it off when this person already put it on.
    func toggleReaction(_ emoji: String, onRow rowID: String) async {
        guard let messageID = storedIDs[rowID] else { return }
        let on = marks[rowID]?.mine.contains(emoji) != true
        do {
            store(try await client.react(emoji, on: on, messageId: messageID, threadId: chat.threadId))
        } catch {
            delegate?.squaddActionDidFail(Self.failureMessage(error))
        }
    }

    /// Takes a changed copy of a row already read; only its marks can differ on screen.
    private func store(_ message: SquaddMessage) {
        if let index = pageMessages.firstIndex(where: { $0.id == message.id }) {
            pageMessages[index] = message
        } else if let index = olderMessages.firstIndex(where: { $0.id == message.id }) {
            olderMessages[index] = message
        } else {
            return
        }
        let all = olderMessages + pageMessages
        updateMarks(all, path: Self.activePath(all, leaf: activeLeafID))
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
                olderMessages = page.messages + olderMessages
                let rows = transcriptRows(of: page.messages)
                shownRows = rows + shownRows
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
        case .turnStarted(let threadId) where threadId == chat.threadId:
            beginTurn()
        case .replyDelta(let threadId, let itemId, let text) where threadId == chat.threadId:
            if activeStreamID == nil { beginTurn(); joinedMidReply = true }
            guard !joinedMidReply else { return }
            streamingItemID = itemId ?? streamingItemID
            delegate?.streamCoordinatorAppendToken(text)
        case .message(let threadId, let message) where threadId == chat.threadId:
            store(message)
            if let sendId = message.sendId, let index = queuedPrompts.firstIndex(where: { $0.sendId == sendId }) {
                // A queued send went in: it shows as sent, and the stored copy replaces it in place.
                let queued = queuedPrompts.remove(at: index)
                let rowID = "local-\(sendId)"
                rowIDs[message.id] = rowID
                shownIDs.insert(message.id)
                delegate?.squaddAppendPrompt(ChatMessage(role: "user", content: queued.text,
                                                         timestamp: message.at.map { $0 / 1000 }, messageId: rowID))
            } else if message.role == "bot", message.itemId != nil, message.itemId == streamingItemID,
               let row = delegate?.streamCoordinatorStreamingAssistantMessageID {
                rowIDs[message.id] = row
                shownIDs.insert(message.id)
            } else if activeStreamID == nil, !shownIDs.contains(message.id),
                      !(message.sendId.map(ownSendIDs.contains) ?? false), message.chatMessage != nil {
                // A row written elsewhere, such as on the desktop, while no turn runs here.
                await reload()
            }
        case .activeBranch(let threadId) where threadId == chat.threadId:
            if activeStreamID == nil { await reload() }
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
