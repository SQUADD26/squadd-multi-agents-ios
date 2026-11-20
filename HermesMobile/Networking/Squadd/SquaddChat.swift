import Foundation

/// One row of a Squadd thread (`WireMessage`, `packages/phone-protocol/src/wire.ts`). Only what the
/// chat shows is read; everything but `id` is optional, so a companion that adds or retypes a field
/// never breaks the transcript.
struct SquaddMessage: Decodable, Equatable {
    let id: String
    let role: String?
    let kind: String?
    let text: String?
    /// Milliseconds since 1970.
    let at: Double?
    /// A bot reply: the item its words streamed under.
    let itemId: String?
    /// The client's own id for a send, echoed on the stored user row.
    let sendId: String?
    /// A `compaction` marker's summary of the turns it folded.
    let compactionSummary: String?
    /// A bot row's author: in a room, the member that wrote it.
    let from: Author?
    /// The message this one follows; nil at the thread's root. An edit is a second user row
    /// under the same parent: the versions of that message.
    let parentId: String?
    /// One per person: `by` is "user" on a computer one person uses.
    let reactions: [SquaddReaction]
    /// Set on the user line a 👍 or 👎 made in place of typing: shown on the message it answers, never as a bubble.
    let reaction: String?
    /// Files the computer attached to the row itself, such as a bot's voice note (#23). A person's
    /// files ride in `text` as tags (`SquaddAttachmentTags`).
    let attachments: [Attachment]
    /// An `options` row's card: an approval or a question the agent waits on (#14, #15).
    let card: SquaddCard?
    /// A `secret`, `signin` or `connector` row's card (#16).
    let secret: SquaddSecretCard?
    let signIn: SquaddSignInCard?
    let connector: SquaddConnectorCard?
    /// A bot reply that closed its turn.
    let turnTerminal: Bool?

    struct Author: Decodable, Equatable {
        let botId: String?
        let name: String?
    }

    /// One of `WireMessage.attachments`: `kind` is `image`, `file` or `audio`.
    struct Attachment: Decodable, Equatable {
        let kind: String?
        let path: String
        let mime: String?
        let name: String?
        let bytes: Int?
    }

    private enum CodingKeys: String, CodingKey { case id, role, kind, text, at, itemId, sendId, from, parentId, reactions, reaction, attachments, compaction, card,
                                              secret, signIn, connector, turnTerminal }
    private struct Compaction: Decodable { let summary: String? }

    init(id: String, role: String?, kind: String? = "text", text: String?, at: Double? = nil,
         itemId: String? = nil, sendId: String? = nil, from: Author? = nil, parentId: String? = nil,
         reactions: [SquaddReaction] = [], reaction: String? = nil, attachments: [Attachment] = [],
         card: SquaddCard? = nil, turnTerminal: Bool? = nil) {
        self.id = id
        self.role = role
        self.kind = kind
        self.text = text
        self.at = at
        self.itemId = itemId
        self.sendId = sendId
        compactionSummary = nil
        self.from = from
        self.parentId = parentId
        self.reactions = reactions
        self.reaction = reaction
        self.attachments = attachments
        self.card = card
        secret = nil
        signIn = nil
        connector = nil
        self.turnTerminal = turnTerminal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try? container.decodeIfPresent(String.self, forKey: .role)
        kind = try? container.decodeIfPresent(String.self, forKey: .kind)
        text = try? container.decodeIfPresent(String.self, forKey: .text)
        at = try? container.decodeIfPresent(Double.self, forKey: .at)
        itemId = try? container.decodeIfPresent(String.self, forKey: .itemId)
        sendId = try? container.decodeIfPresent(String.self, forKey: .sendId)
        from = try? container.decodeIfPresent(Author.self, forKey: .from)
        parentId = try? container.decodeIfPresent(String.self, forKey: .parentId)
        reactions = (try? container.decodeIfPresent([SquaddLossy<SquaddReaction>].self, forKey: .reactions))?
            .compactMap(\.value) ?? []
        reaction = try? container.decodeIfPresent(String.self, forKey: .reaction)
        attachments = (try? container.decodeIfPresent([SquaddLossy<Attachment>].self, forKey: .attachments))?
            .compactMap(\.value) ?? []
        compactionSummary = (try? container.decodeIfPresent(Compaction.self, forKey: .compaction))?.summary
        card = try? container.decodeIfPresent(SquaddCard.self, forKey: .card)
        secret = try? container.decodeIfPresent(SquaddSecretCard.self, forKey: .secret)
        signIn = try? container.decodeIfPresent(SquaddSignInCard.self, forKey: .signIn)
        connector = try? container.decodeIfPresent(SquaddConnectorCard.self, forKey: .connector)
        turnTerminal = try? container.decodeIfPresent(Bool.self, forKey: .turnTerminal)
    }

    /// A version of a typed message: the rows an edit puts side by side.
    var isTypedUserText: Bool { role == "user" && (kind == nil || kind == "text") }

    /// The transcript row the chat draws, or nil for rows the v1 chat doesn't show: tool steps,
    /// turn digests, screens and the other cards their own tickets bring. `options` (a question
    /// card) shows its words until the card has its own view; a compaction marker shows as the
    /// "Context compaction" card `ChatMarkerMessageClassifier` knows by its first words.
    /// A row's files show as its attachments, the tags they rode in taken out of its words.
    var chatMessage: ChatMessage? { chatMessage(namesAuthor: false) }

    /// `namesAuthor`: a room's reply carries the member that wrote it as its `name`, which the
    /// bubble shows over it.
    func chatMessage(namesAuthor: Bool) -> ChatMessage? {
        if kind == "compaction" {
            let summary = compactionSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ChatMessage(role: "assistant", content: "[Context compaction]\n\n\(summary)",
                               timestamp: at.map { $0 / 1000 }, messageId: id)
        }
        guard kind == nil || kind == "text" || kind == "options", reaction == nil else { return nil }
        let parsed = SquaddAttachmentTags.parse(text ?? "")
        let files = parsed.files.map { MessageAttachment(name: $0.name, path: $0.path, isImage: $0.isImage) }
            + attachments.map { MessageAttachment(name: $0.name, path: $0.path, mime: $0.mime, size: $0.bytes,
                                                  isImage: $0.kind == "image") }
        guard !parsed.text.isEmpty || !files.isEmpty else { return nil }
        let isBot = role == "bot"
        return ChatMessage(role: isBot ? "assistant" : "user", content: parsed.text,
                           timestamp: at.map { $0 / 1000 }, messageId: id, name: namesAuthor && isBot ? from?.name : nil,
                           attachments: files.isEmpty ? nil : files)
    }
}

/// The card of an `options` row (`OptionCardData`, `phone-protocol/src/wire.ts`): what the chat needs to
/// show and answer a live approval or question. Unknown fields are ignored; a field that doesn't decode is nil.
struct SquaddCard: Decodable, Equatable {
    let title: String?
    let subtitle: String?
    let options: [String]
    /// The id `respond` answers; nil on a card that isn't a live ask.
    let requestId: String?
    /// `permission` (an approval) or `question`.
    let requestType: String?
    let tool: String?
    /// A grant "always allow" remembers for this bot (`POST /api/bots/:id/always-allow`).
    let allowKey: String?
    /// The engine can remember an allow for the rest of its session (`always: true`).
    let allowSession: Bool?
    /// The verdict, once someone answered: here, on the desktop or another phone.
    let answered: String?
    let dismissed: Bool?
    let expired: Bool?
    let stopped: Bool?
    /// A question's structured set, as the engine asked it (`QuestionRequestCardData`).
    let questionRequest: SquaddQuestionRequest?
    /// Only the card's own options answer it: no typed reply.
    let fixedOptions: Bool?

    private enum CodingKeys: String, CodingKey {
        case title, subtitle, options, requestId, requestType, tool, allowKey, allowSession, answered, dismissed, expired, stopped,
             questionRequest, fixedOptions
    }

    init(title: String? = nil, subtitle: String? = nil, options: [String] = [], requestId: String?, requestType: String?,
         tool: String? = nil, allowKey: String? = nil, allowSession: Bool? = nil, answered: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.options = options
        self.requestId = requestId
        self.requestType = requestType
        self.tool = tool
        self.allowKey = allowKey
        self.allowSession = allowSession
        self.answered = answered
        dismissed = nil
        expired = nil
        stopped = nil
        questionRequest = nil
        fixedOptions = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        subtitle = try? container.decodeIfPresent(String.self, forKey: .subtitle)
        options = (try? container.decodeIfPresent([String].self, forKey: .options)) ?? []
        requestId = try? container.decodeIfPresent(String.self, forKey: .requestId)
        requestType = try? container.decodeIfPresent(String.self, forKey: .requestType)
        tool = try? container.decodeIfPresent(String.self, forKey: .tool)
        allowKey = try? container.decodeIfPresent(String.self, forKey: .allowKey)
        allowSession = try? container.decodeIfPresent(Bool.self, forKey: .allowSession)
        answered = try? container.decodeIfPresent(String.self, forKey: .answered)
        dismissed = try? container.decodeIfPresent(Bool.self, forKey: .dismissed)
        expired = try? container.decodeIfPresent(Bool.self, forKey: .expired)
        stopped = try? container.decodeIfPresent(Bool.self, forKey: .stopped)
        questionRequest = try? container.decodeIfPresent(SquaddQuestionRequest.self, forKey: .questionRequest)
        fixedOptions = try? container.decodeIfPresent(Bool.self, forKey: .fixedOptions)
    }

    /// Still waiting for an answer: a live ask nobody answered, dismissed, let expire or stopped.
    var isOpen: Bool {
        requestId != nil && answered == nil && dismissed != true && expired != true && stopped != true
    }
}

/// The questions an agent asks in one card (`phone-protocol/src/ask-question.ts`).
struct SquaddQuestionRequest: Decodable, Equatable {
    let questions: [SquaddQuestion]
}

struct SquaddQuestion: Decodable, Equatable {
    let question: String
    let options: [Option]
    /// `false`: only an option answers it.
    let custom: Bool?

    struct Option: Decodable, Equatable {
        let label: String
    }

    init(question: String, options: [String], custom: Bool? = nil) {
        self.question = question
        self.options = options.map(Option.init)
        self.custom = custom
    }

    private enum CodingKeys: String, CodingKey { case question, options, custom }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        question = try container.decode(String.self, forKey: .question)
        options = (try? container.decodeIfPresent([Option].self, forKey: .options)) ?? []
        custom = try? container.decodeIfPresent(Bool.self, forKey: .custom)
    }
}

/// One person's reaction on a message (`REACTIONS` in `phone-protocol/src/reactions.ts`).
struct SquaddReaction: Decodable, Equatable {
    let emoji: String
    let by: String

    /// Every reaction the computer accepts, in the order its clients offer them.
    static let all = ["👍", "👎", "❤️", "😂", "🎉", "👀"]
}

/// `GET /api/threads/:id/messages`: a page, oldest first; `hasMore` when older rows remain. The page
/// holds every version an edit made; `activeLeafId` is the newest row of the one the thread shows.
struct SquaddMessagePage: Decodable, Equatable {
    let messages: [SquaddMessage]
    let hasMore: Bool
    let activeLeafId: String?

    private enum CodingKeys: String, CodingKey { case messages, hasMore, activeLeafId }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = (try? container.decodeIfPresent([SquaddLossy<SquaddMessage>].self, forKey: .messages))?
            .compactMap(\.value) ?? []
        hasMore = (try? container.decodeIfPresent(Bool.self, forKey: .hasMore)) ?? false
        activeLeafId = try? container.decodeIfPresent(String.self, forKey: .activeLeafId)
    }
}

/// `POST /api/bots/:id/messages`'s 202 (and an edit's): the stored user row, or a queue slot when the
/// bot was busy. A room's send (`POST /api/groups/:id/messages`) answers the same way.
struct SquaddSendReceipt: Decodable {
    let threadId: String?
    let message: SquaddMessage?
    let queued: Bool?
    let queueId: String?
}

/// A message the companion holds until the busy thread can take it (`bot.queued`), which Steer
/// sends into the running turn at once and Delete drops.
struct SquaddQueuedMessage: Decodable, Equatable {
    let queueId: String
    let text: String?
}

/// How a message sent to a working agent meets its running turn (`followUp`): steered into it,
/// queued behind it, or sent after stopping it.
enum SquaddFollowUp: String {
    case steer, queue, restart
}

/// The frames of `/api/events` the chat acts on (`ServerFrame` in `wire.ts`). Every other kind,
/// and any frame that doesn't decode, is `.ignored`: the stream carries far more than a chat reads.
enum SquaddFrame: Equatable {
    /// Always first. `resumed` false: frames were missed, so the transcript reloads.
    case hello(cursor: String, resumed: Bool)
    /// A row was stored or changed.
    case message(threadId: String, message: SquaddMessage)
    /// The thread now shows another version: an edit, or a version picked on any device.
    case activeBranch(threadId: String)
    /// `turnId` names the turn a Stop is for.
    case turnStarted(threadId: String, turnId: String?)
    /// A piece of the reply's text as it is written.
    case replyDelta(threadId: String, itemId: String?, text: String)
    case turnCompleted(threadId: String, ok: Bool)
    /// The turn ended because someone stopped it (`stopReason` interrupted or cancelled).
    case turnStopped(threadId: String)
    /// The messages each thread holds (keyed by thread id), all of them: a thread not named holds none.
    case queued([String: [SquaddQueuedMessage]])
    /// The turn failed with words for the person.
    case runtimeError(threadId: String, message: String)
    /// The agent waits on the person: `question` for a question, else an approval.
    case requestOpened(threadId: String, isQuestion: Bool)
    case requestResolved(threadId: String)
    /// A new entry for the computer's notification list.
    case notify(SquaddNotification)
    /// These notifications were read, here or on another app.
    case notificationsRead(ids: [String])
    case ignored

    static func decode(_ data: String) -> SquaddFrame {
        guard let frame = try? JSONDecoder().decode(Wire.self, from: Data(data.utf8)) else { return .ignored }
        switch frame.kind {
        case "hello":
            guard let cursor = frame.cursor else { return .ignored }
            return .hello(cursor: cursor, resumed: frame.resumed ?? false)
        case "message", "message.patch":
            guard let threadId = frame.threadId, let message = frame.message?.value else { return .ignored }
            return .message(threadId: threadId, message: message)
        case "notify":
            return frame.notification?.value.map { .notify($0) } ?? .ignored
        case "notifications.read":
            return .notificationsRead(ids: frame.ids ?? [])
        case "thread":
            guard let threadId = frame.threadId else { return .ignored }
            return .activeBranch(threadId: threadId)
        case "runtime":
            guard let event = frame.event, let threadId = event.threadId else { return .ignored }
            switch event.type {
            case "turn.started": return .turnStarted(threadId: threadId, turnId: event.turnId)
            // Claude reports a stop as `ok:false, interrupted`, Pi as `ok:true, cancelled`.
            case "turn.completed" where ["interrupted", "cancelled"].contains(event.stopReason):
                return .turnStopped(threadId: threadId)
            case "turn.completed": return .turnCompleted(threadId: threadId, ok: event.ok ?? true)
            case "content.delta" where event.streamKind == "assistant_text":
                guard let delta = event.delta, !delta.isEmpty else { return .ignored }
                return .replyDelta(threadId: threadId, itemId: event.itemId, text: delta)
            case "runtime.error":
                guard let message = event.message, !message.isEmpty else { return .ignored }
                return .runtimeError(threadId: threadId, message: message)
            case "request.opened": return .requestOpened(threadId: threadId, isQuestion: event.requestType == "question")
            case "request.resolved": return .requestResolved(threadId: threadId)
            default: return .ignored
            }
        case "bot.queued":
            guard let queues = frame.queues else { return .ignored }
            return .queued(queues.mapValues { $0.compactMap(\.value) })
        default:
            return .ignored
        }
    }

    private struct Wire: Decodable {
        let queues: [String: [SquaddLossy<SquaddQueuedMessage>]]?
        let kind: String
        let cursor: String?
        let resumed: Bool?
        let threadId: String?
        let message: SquaddLossy<SquaddMessage>?
        let event: Event?
        let notification: SquaddLossy<SquaddNotification>?
        let ids: [String]?
    }

    private struct Event: Decodable {
        let type: String
        let threadId: String?
        let turnId: String?
        let stopReason: String?
        let itemId: String?
        let streamKind: String?
        let delta: String?
        let ok: Bool?
        let message: String?
        let requestType: String?
    }
}

/// Splits a Server-Sent Events byte stream into its events' `data` (`text/event-stream`): lines
/// gathered until a blank one, comments (`: keepalive`) skipped. The companion sends no `event:` lines.
struct SquaddSSEParser {
    private var data: [String] = []
    private var id: String?
    /// The `id:` of the event `feed` last returned; an event without one keeps none.
    private(set) var lastEventID: String?

    /// Feeds one line, without its line break. Returns the event's data when the line ends one.
    mutating func feed(_ line: String) -> String? {
        if line.isEmpty {
            defer { data = []; id = nil }
            guard !data.isEmpty else { return nil }
            lastEventID = id
            return data.joined(separator: "\n")
        }
        if line.hasPrefix(":") { return nil }
        let field = line.prefix { $0 != ":" }
        var value = line.dropFirst(field.count)
        if value.hasPrefix(":") { value = value.dropFirst() }
        if value.hasPrefix(" ") { value = value.dropFirst() }
        switch field {
        case "data": data.append(String(value))
        case "id": id = String(value)
        default: break
        }
        return nil
    }
}

extension SquaddCompanionClient {
    /// A thread's newest page of messages, or with `before` (a stored message id) the page just
    /// older than that message.
    func messages(threadId: String, before: String? = nil) async throws -> SquaddMessagePage {
        var request = authorized("api/threads/\(threadId)/messages")
        if let before, var parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) {
            parts.queryItems = [URLQueryItem(name: "before", value: before)]
            request.url = parts.url
        }
        let data = try await Self.send(request, session: session)
        return try JSONDecoder().decode(SquaddMessagePage.self, from: data)
    }

    /// Sends a typed message into one of the bot's threads. `sendId` makes a retry land once;
    /// `mode` "goal" starts a goal with `text` (`SquaddSlashCommands.outgoing`). The reply comes
    /// over `events`, not here. `followUp` says how it meets a running turn; nil leaves it to the
    /// computer's setting.
    func send(_ text: String, botId: String, threadId: String, sendId: String, mode: String? = nil,
              followUp: SquaddFollowUp? = nil) async throws -> SquaddSendReceipt {
        var body = ["text": text, "threadId": threadId, "sendId": sendId]
        body["mode"] = mode
        body["followUp"] = followUp?.rawValue
        let data = try await call("api/bots/\(botId)/messages", body, reportsRefusal: false)
        return try JSONDecoder().decode(SquaddSendReceipt.self, from: data)
    }

    /// Stop: asks the computer to stop the thread's running turn. `turnId` keeps a late tap from
    /// stopping the next turn. The turn's own frames say when it has stopped.
    func interrupt(botId: String, threadId: String, turnId: String?) async throws {
        var body = ["threadId": threadId]
        body["turnId"] = turnId
        _ = try await call("api/bots/\(botId)/interrupt", body)
    }

    /// Sends a queued message into the running turn now (the thread's whole queue goes with it).
    func steerQueued(_ queueId: String, botId: String, threadId: String) async throws {
        _ = try await call("api/bots/\(botId)/queue/\(queueId)/steer", ["threadId": threadId])
    }

    /// Drops a queued message before it is sent.
    func deleteQueued(_ queueId: String, botId: String, threadId: String) async throws {
        _ = try await call("api/bots/\(botId)/queue/\(queueId)", ["threadId": threadId], method: "DELETE")
    }

    /// Folds the thread's older turns into a summary. Accepted (202) is not done: the marker
    /// row comes over `events` once the computer has written it.
    func compact(botId: String, threadId: String) async throws {
        _ = try await call("api/bots/\(botId)/compact", ["threadId": threadId])
    }

    /// A JSON request whose refusal, with `reportsRefusal`, carries the computer's own words.
    private func call(_ path: String, _ body: [String: String], method: String = "POST",
                      reportsRefusal: Bool = true) async throws -> Data {
        var request = authorized(path)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await Self.send(request, session: session, reportsRefusal: reportsRefusal)
    }

    /// Sends `text` as a new version of the stored user message `messageId`: the thread moves to it
    /// and the agent answers it, while the old version stays one swipe of the version picker away.
    func edit(messageId: String, to text: String, botId: String, threadId: String, sendId: String) async throws -> SquaddSendReceipt {
        try await post("api/bots/\(botId)/messages/\(messageId)/edit", ["text": text, "threadId": threadId, "sendId": sendId])
    }

    /// Shows the version of the conversation through `messageId`, down to its newest row.
    func showBranch(through messageId: String, botId: String, threadId: String) async throws {
        let _: SquaddActiveBranch = try await post("api/bots/\(botId)/active-branch", ["messageId": messageId, "threadId": threadId])
    }

    /// A new thread of the agent holding this one up to the stored text message `messageId`, as the
    /// desktop's Fork does. Returns the new thread.
    func fork(threadId: String, through messageId: String, botId: String) async throws -> SquaddTask {
        let reply: SquaddTaskResponse = try await post("api/bots/\(botId)/tasks/\(threadId)/forks", ["messageId": messageId])
        return reply.task
    }

    /// Puts the thread back to before this person's last typed message (`undo-exchange`, openmausbot
    /// #113), which stays a version away. The companion refuses (409 `nothing_to_undo`) when that
    /// message is the thread's first.
    func undoExchange(botId: String, threadId: String) async throws {
        let _: SquaddActiveBranch = try await post("api/bots/\(botId)/undo-exchange", ["threadId": threadId])
    }

    /// Puts this person's `emoji` on a message (`on`) or takes it off. Returns the message as saved.
    func react(_ emoji: String, on: Bool, messageId: String, threadId: String) async throws -> SquaddMessage {
        var request = authorized("api/threads/\(threadId)/messages/\(messageId)/reactions")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["emoji": emoji, "on": on])
        return try JSONDecoder().decode(SquaddReactionReply.self, from: await Self.send(request, session: session)).message
    }

    private func post<Reply: Decodable>(_ path: String, _ body: [String: String]) async throws -> Reply {
        var request = authorized(path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try JSONDecoder().decode(Reply.self, from: await Self.send(request, session: session))
    }

    /// The computer's live event stream, one frame per element with its `id:` (the cursor a
    /// reconnect resumes from), until it closes or fails. `since` is the last cursor seen: the
    /// companion replays what was missed, or says in `hello` that it couldn't.
    func events(since: String?) -> AsyncThrowingStream<(id: String?, frame: SquaddFrame), Error> {
        var request = authorized("api/events")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(nil, forHTTPHeaderField: "Origin")
        if let since { request.setValue(since, forHTTPHeaderField: "Last-Event-ID") }
        request.timeoutInterval = .infinity
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw SquaddError.invalidResponse }
                    guard http.statusCode != 401 else { throw SquaddError.unpaired }
                    guard (200..<300).contains(http.statusCode) else { throw SquaddError.status(http.statusCode) }
                    var parser = SquaddSSEParser()
                    var line = Data()
                    for try await byte in bytes {
                        // `bytes.lines` drops the blank lines that end events, so lines are split here.
                        guard byte == UInt8(ascii: "\n") else { line.append(byte); continue }
                        if line.last == UInt8(ascii: "\r") { line.removeLast() }
                        if let data = parser.feed(String(decoding: line, as: UTF8.self)) {
                            continuation.yield((parser.lastEventID, SquaddFrame.decode(data)))
                        }
                        line.removeAll(keepingCapacity: true)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func authorized(_ path: String) -> URLRequest {
        var request = URLRequest(url: server.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}

// MARK: - Approvals and questions (#14, #15)

extension SquaddCompanionClient {
    /// Answers a card's live ask: `behavior` is `allow`, `deny` or `answer` (with `message`). `always`
    /// asks the engine to remember an allow for its session, on a card with `allowSession`. The card's
    /// own `message.patch` follows on the event stream.
    func respond(threadId: String, requestId: String, behavior: String, always: Bool = false,
                 message: String? = nil) async throws {
        var body: [String: Any] = ["requestId": requestId, "behavior": behavior]
        if always { body["always"] = true }
        body["message"] = message
        _ = try await call("POST", "api/threads/\(threadId)/respond", body: body)
    }

    /// Remembers `allowKey` as a standing grant for the bot. Only for a card still waiting with that
    /// key: it answers nothing by itself, so an `allow` follows.
    func alwaysAllow(botId: String, threadId: String, allowKey: String) async throws {
        _ = try await call("POST", "api/bots/\(botId)/always-allow", body: ["threadId": threadId, "allowKey": allowKey])
    }
}

private struct SquaddActiveBranch: Decodable { let activeLeafId: String? }
private struct SquaddReactionReply: Decodable { let message: SquaddMessage }

// MARK: - Attachments (#23)

/// `POST /api/attachments` or `/api/files`'s 201: where the computer stored the bytes. `path` is
/// what the message's tag names; `name` (files only) is the cleaned file name.
struct SquaddUpload: Decodable, Equatable {
    let path: String
    let mime: String?
    let name: String?
}

extension SquaddCompanionClient {
    /// The images `POST /api/attachments` takes; every other file goes to `/api/files`.
    static let attachmentImageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]
    /// Bytes one ranged read of an attachment asks for.
    static let attachmentChunkBytes = 1 << 20

    /// Uploads one file's raw bytes. `uploadId` (a UUID) makes a retry store it once.
    func upload(_ data: Data, name: String, mime: String, uploadId: UUID) async throws -> SquaddUpload {
        // iOS names WAV `audio/vnd.wave`, a type the computer stores as `.bin`, which no player opens.
        let mime = name.lowercased().hasSuffix(".wav") ? "audio/wav" : mime
        let image = Self.attachmentImageTypes.contains(mime)
        var parts = URLComponents(url: base.appendingPathComponent(image ? "api/attachments" : "api/files"),
                                  resolvingAgainstBaseURL: false)!
        parts.queryItems = (image ? [] : [URLQueryItem(name: "name", value: name)])
            + [URLQueryItem(name: "uploadId", value: uploadId.uuidString.lowercased())]
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return try JSONDecoder().decode(SquaddUpload.self, from: await Self.send(request, session: session))
    }

    /// A stored image's or voice note's bytes (`GET /api/attachments/<name>`, the stored file's own
    /// name), read in ranged pieces as the desktop's player reads them. A computer that answers a
    /// range with the whole file (200) is read in one go.
    func attachmentData(path: String) async throws -> Data {
        let name = URL(fileURLWithPath: path).lastPathComponent
        var data = Data()
        while true {
            var request = URLRequest(url: base.appendingPathComponent("api/attachments/\(name)"))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("bytes=\(data.count)-\(data.count + Self.attachmentChunkBytes - 1)", forHTTPHeaderField: "Range")
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SquaddError.invalidResponse }
            switch http.statusCode {
            case 200: return body
            case 206:
                // `Content-Range: bytes 0-1048575/2400000`: the total follows the slash.
                guard let total = http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap({ Int($0) }),
                      !body.isEmpty else { throw SquaddError.invalidResponse }
                data.append(body)
                if data.count >= total { return data }
            case 401: throw SquaddError.unpaired
            default: throw SquaddError.status(http.statusCode)
            }
        }
    }
}

// MARK: - Listen (#25)

extension SquaddCompanionClient {
    private struct Prepared: Decodable {
        let ready: Bool
        let utterances: [String]
    }

    /// A reply read aloud in the computer's own voice, one clip per utterance, each with a file
    /// name its type opens by: `POST /api/tts/prepare` cleans the text (secrets redacted, markdown
    /// dropped) and splits it into utterances of 500 characters at most, `POST /api/tts/speak`
    /// voices each. Nil when the computer has no voice set up.
    func speech(for text: String) async throws -> [(data: Data, filename: String)]? {
        var prepare = authorized("api/tts/prepare")
        prepare.httpMethod = "POST"
        prepare.setValue("application/json", forHTTPHeaderField: "Content-Type")
        prepare.httpBody = try JSONEncoder().encode(["text": text])
        let prepared = try JSONDecoder().decode(Prepared.self, from: await Self.send(prepare, session: session))
        guard prepared.ready, !prepared.utterances.isEmpty else { return nil }
        var clips: [(data: Data, filename: String)] = []
        for utterance in prepared.utterances {
            try Task.checkCancellation()
            var speak = authorized("api/tts/speak")
            speak.httpMethod = "POST"
            speak.setValue("application/json", forHTTPHeaderField: "Content-Type")
            speak.setValue(nil, forHTTPHeaderField: "Origin")
            speak.httpBody = try JSONEncoder().encode(["text": utterance])
            let (data, response) = try await session.data(for: speak)
            guard let http = response as? HTTPURLResponse else { throw SquaddError.invalidResponse }
            guard http.statusCode != 401 else { throw SquaddError.unpaired }
            guard http.statusCode == 200 else { throw SquaddError.status(http.statusCode) }
            let mp3 = http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("audio/mp") == true
            clips.append((data, "clip\(clips.count).\(mp3 ? "mp3" : "wav")"))
        }
        return clips
    }
}

/// The tags a Squadd message carries its files in, as the desktop's composer writes them
/// (`composeMessage`, `src/lib/composer-attachments.ts`): one per file after the text, each in its
/// own paragraph, the path and name quoted with `&`, `"`, `<`, `>`, tab and line breaks escaped.
enum SquaddAttachmentTags {
    struct File: Equatable {
        let path: String
        let name: String
        let isImage: Bool
    }

    static func compose(_ text: String, files: [File]) -> String {
        let tags = files.map { "<attached-\($0.isImage ? "image" : "file") path=\"\(escape($0.path))\" name=\"\(escape($0.name))\" />" }
        return ([text.trimmingCharacters(in: .whitespacesAndNewlines)] + tags).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The text without its tags, and the files they name.
    static func parse(_ text: String) -> (text: String, files: [File]) {
        var files: [File] = []
        let pattern = #/<attached-(image|file) path="([^"]*)" name="([^"]*)" />/#
        let stripped = text.replacing(pattern) { match in
            files.append(File(path: unescape(String(match.2)), name: unescape(String(match.3)), isImage: match.1 == "image"))
            return ""
        }
        return (stripped.trimmingCharacters(in: .whitespacesAndNewlines), files)
    }

    private static let escapes = [("&", "&amp;"), ("\"", "&quot;"), ("<", "&lt;"), (">", "&gt;"),
                                  ("\t", "&#9;"), ("\r", "&#13;"), ("\n", "&#10;")]

    private static func escape(_ value: String) -> String {
        escapes.reduce(value) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    private static func unescape(_ value: String) -> String {
        escapes.reversed().reduce(value) { $0.replacingOccurrences(of: $1.1, with: $1.0) }
    }
}
