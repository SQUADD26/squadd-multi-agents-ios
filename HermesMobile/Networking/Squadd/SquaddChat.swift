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

    /// One of `WireMessage.attachments`: `kind` is `image`, `file` or `audio`.
    struct Attachment: Decodable, Equatable {
        let kind: String?
        let path: String
        let mime: String?
        let name: String?
        let bytes: Int?
    }

    private enum CodingKeys: String, CodingKey { case id, role, kind, text, at, itemId, sendId, parentId, reactions, reaction, attachments }

    init(id: String, role: String?, kind: String? = "text", text: String?, at: Double? = nil,
         itemId: String? = nil, sendId: String? = nil, parentId: String? = nil, reactions: [SquaddReaction] = [],
         reaction: String? = nil, attachments: [Attachment] = []) {
        self.id = id
        self.role = role
        self.kind = kind
        self.text = text
        self.at = at
        self.itemId = itemId
        self.sendId = sendId
        self.parentId = parentId
        self.reactions = reactions
        self.reaction = reaction
        self.attachments = attachments
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
        parentId = try? container.decodeIfPresent(String.self, forKey: .parentId)
        reactions = (try? container.decodeIfPresent([SquaddLossy<SquaddReaction>].self, forKey: .reactions))?
            .compactMap(\.value) ?? []
        reaction = try? container.decodeIfPresent(String.self, forKey: .reaction)
        attachments = (try? container.decodeIfPresent([SquaddLossy<Attachment>].self, forKey: .attachments))?
            .compactMap(\.value) ?? []
    }

    /// A version of a typed message: the rows an edit puts side by side.
    var isTypedUserText: Bool { role == "user" && (kind == nil || kind == "text") }

    /// The transcript row the chat draws, or nil for rows the v1 chat doesn't show: tool steps,
    /// turn digests, screens, compaction markers and the other cards their own tickets bring.
    /// `options` (a question card) shows its words until the card has its own view.
    /// A row's files show as its attachments, the tags they rode in taken out of its words.
    var chatMessage: ChatMessage? {
        guard kind == nil || kind == "text" || kind == "options", reaction == nil else { return nil }
        let parsed = SquaddAttachmentTags.parse(text ?? "")
        let files = parsed.files.map { MessageAttachment(name: $0.name, path: $0.path, isImage: $0.isImage) }
            + attachments.map { MessageAttachment(name: $0.name, path: $0.path, mime: $0.mime, size: $0.bytes,
                                                  isImage: $0.kind == "image") }
        guard !parsed.text.isEmpty || !files.isEmpty else { return nil }
        return ChatMessage(role: role == "bot" ? "assistant" : "user", content: parsed.text,
                           timestamp: at.map { $0 / 1000 }, messageId: id, attachments: files.isEmpty ? nil : files)
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

/// `POST /api/bots/:id/messages`'s 202 (and an edit's): the stored user row, or a queue slot when the bot was busy.
struct SquaddSendReceipt: Decodable {
    let threadId: String?
    let message: SquaddMessage?
    let queued: Bool?
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
    case turnStarted(threadId: String)
    /// A piece of the reply's text as it is written.
    case replyDelta(threadId: String, itemId: String?, text: String)
    case turnCompleted(threadId: String, ok: Bool)
    /// The turn failed with words for the person.
    case runtimeError(threadId: String, message: String)
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
            case "turn.started": return .turnStarted(threadId: threadId)
            case "turn.completed": return .turnCompleted(threadId: threadId, ok: event.ok ?? true)
            case "content.delta" where event.streamKind == "assistant_text":
                guard let delta = event.delta, !delta.isEmpty else { return .ignored }
                return .replyDelta(threadId: threadId, itemId: event.itemId, text: delta)
            case "runtime.error":
                guard let message = event.message, !message.isEmpty else { return .ignored }
                return .runtimeError(threadId: threadId, message: message)
            default: return .ignored
            }
        default:
            return .ignored
        }
    }

    private struct Wire: Decodable {
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
    /// over `events`, not here.
    func send(_ text: String, botId: String, threadId: String, sendId: String, mode: String? = nil) async throws -> SquaddSendReceipt {
        var body = ["text": text, "threadId": threadId, "sendId": sendId]
        if let mode { body["mode"] = mode }
        return try await post("api/bots/\(botId)/messages", body)
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
