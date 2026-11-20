import Foundation

/// A link to one Squadd thread: `openmausbot://thread/<threadId>?bot=<botId>&server=<url>`, the
/// desktop's chat link (`openmausbot/src/lib/thread-refs.ts`) plus the computer it lives on. The
/// app's own scheme (`HermesDeepLink.scheme`) takes the same shape. A link without `server` (as the
/// desktop writes it) opens on the active Squadd server.
struct SquaddThreadLink: Hashable {
    static let scheme = "openmausbot"
    static let host = "thread"

    let threadID: String
    let botID: String?
    let server: URL?

    init(threadID: String, botID: String? = nil, server: URL? = nil) {
        self.threadID = threadID
        self.botID = botID
        self.server = server
    }

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == Self.scheme || scheme == HermesDeepLink.scheme,
              url.host?.lowercased() == Self.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let id = String(components.path.drop { $0 == "/" })
        // The desktop's own limit: up to 256 characters, no control characters; one path segment.
        guard !id.isEmpty, id.count <= 256, !id.contains("/"),
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        threadID = id
        let items = components.queryItems ?? []
        botID = items.first { $0.name == "bot" }?.value.flatMap { $0.isEmpty ? nil : $0 }
        server = items.first { $0.name == "server" }?.value.flatMap(URL.init(string:))
            .flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host() != nil ? $0 : nil }
    }

    /// The link itself, on the `openmausbot` scheme.
    var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.path = "/" + threadID
        var items: [URLQueryItem] = []
        if let botID { items.append(URLQueryItem(name: "bot", value: botID)) }
        if let server { items.append(URLQueryItem(name: "server", value: server.absoluteString)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    /// The paired Squadd server the thread opens on: the one the link names, else the active one.
    /// Nil when the link names a computer this iPhone has never paired, or names none and the active
    /// server isn't a Squadd one. A server whose pairing was revoked is still returned: it shows the
    /// pair-again screen and the link opens once it is paired.
    func account(in servers: [ServerAccount], active: URL?) -> ServerAccount? {
        guard let wanted = server ?? active else { return nil }
        return servers.first { $0.kind == .squadd && Self.sameServer($0.urlString, wanted.absoluteString) }
    }

    /// This link pinned to `server`, so only that server's home takes it.
    func pinned(to server: URL) -> SquaddThreadLink {
        SquaddThreadLink(threadID: threadID, botID: botID, server: server)
    }

    /// The home row that shows the thread: its task row, else the header of the agent whose own
    /// chat it is. Nil when the computer has no such thread (deleted, or another computer's).
    func row(in sections: [SquaddAgentSection]) -> String? {
        if sections.contains(where: { ($0.threads + $0.folders.flatMap(\.threads) + $0.archived).contains { $0.id == threadID } }) { return threadID }
        return sections.first { $0.threadID == threadID }.map(\.headerRowID)
    }

    /// Two addresses of one server, a trailing slash aside.
    static func sameServer(_ lhs: String, _ rhs: String) -> Bool {
        func trimmed(_ value: String) -> String { value.hasSuffix("/") ? String(value.dropLast()) : value }
        return trimmed(lhs).lowercased() == trimmed(rhs).lowercased()
    }
}
