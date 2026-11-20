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

    private enum CodingKeys: String, CodingKey { case id, role, kind, text, at, itemId, sendId, compaction }
    private struct Compaction: Decodable { let summary: String? }

    init(id: String, role: String?, kind: String? = "text", text: String?, at: Double? = nil,
         itemId: String? = nil, sendId: String? = nil) {
        self.id = id
        self.role = role
        self.kind = kind
        self.text = text
        self.at = at
        self.itemId = itemId
        self.sendId = sendId
        compactionSummary = nil
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
        compactionSummary = (try? container.decodeIfPresent(Compaction.self, forKey: .compaction))?.summary
    }

    /// The transcript row the chat draws, or nil for rows the v1 chat doesn't show: tool steps,
    /// turn digests, screens and the other cards their own tickets bring. `options` (a question
    /// card) shows its words until the card has its own view; a compaction marker shows as the
    /// "Context compaction" card `ChatMarkerMessageClassifier` knows by its first words.
    var chatMessage: ChatMessage? {
        if kind == "compaction" {
            let summary = compactionSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ChatMessage(role: "assistant", content: "[Context compaction]\n\n\(summary)",
                               timestamp: at.map { $0 / 1000 }, messageId: id)
        }
        guard kind == nil || kind == "text" || kind == "options",
              let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ChatMessage(role: role == "bot" ? "assistant" : "user", content: text,
                           timestamp: at.map { $0 / 1000 }, messageId: id)
    }
}

/// `GET /api/threads/:id/messages`: a page, oldest first; `hasMore` when older rows remain.
struct SquaddMessagePage: Decodable, Equatable {
    let messages: [SquaddMessage]
    let hasMore: Bool

    private enum CodingKeys: String, CodingKey { case messages, hasMore }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = (try? container.decodeIfPresent([SquaddLossy<SquaddMessage>].self, forKey: .messages))?
            .compactMap(\.value) ?? []
        hasMore = (try? container.decodeIfPresent(Bool.self, forKey: .hasMore)) ?? false
    }
}

/// `POST /api/bots/:id/messages`'s 202: the stored user row, or a queue slot when the bot was busy.
struct SquaddSendReceipt: Decodable {
    let threadId: String?
    let message: SquaddMessage?
    let queued: Bool?
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
        let data = try await post("api/bots/\(botId)/messages", body, reportsRefusal: false)
        return try JSONDecoder().decode(SquaddSendReceipt.self, from: data)
    }

    /// Stop: asks the computer to stop the thread's running turn. `turnId` keeps a late tap from
    /// stopping the next turn. The turn's own frames say when it has stopped.
    func interrupt(botId: String, threadId: String, turnId: String?) async throws {
        var body = ["threadId": threadId]
        body["turnId"] = turnId
        _ = try await post("api/bots/\(botId)/interrupt", body)
    }

    /// Sends a queued message into the running turn now (the thread's whole queue goes with it).
    func steerQueued(_ queueId: String, botId: String, threadId: String) async throws {
        _ = try await post("api/bots/\(botId)/queue/\(queueId)/steer", ["threadId": threadId])
    }

    /// Drops a queued message before it is sent.
    func deleteQueued(_ queueId: String, botId: String, threadId: String) async throws {
        _ = try await post("api/bots/\(botId)/queue/\(queueId)", ["threadId": threadId], method: "DELETE")
    }

    /// Folds the thread's older turns into a summary. Accepted (202) is not done: the marker
    /// row comes over `events` once the computer has written it.
    func compact(botId: String, threadId: String) async throws {
        _ = try await post("api/bots/\(botId)/compact", ["threadId": threadId])
    }

    /// A JSON request whose refusal, with `reportsRefusal`, carries the computer's own words.
    private func post(_ path: String, _ body: [String: String], method: String = "POST",
                      reportsRefusal: Bool = true) async throws -> Data {
        var request = authorized(path)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await Self.send(request, session: session, reportsRefusal: reportsRefusal)
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
