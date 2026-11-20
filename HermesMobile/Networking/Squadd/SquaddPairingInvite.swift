import Foundation

/// A pairing the computer handed over: its QR code or link (`openmausbot://pair`, or a server's
/// `https://…/pair#code=…`), or the address and code typed from its pairing screen. Redeemed by
/// `AuthManager.pairSquadd`.
struct SquaddPairingInvite: Equatable, Identifiable {
    let server: URL
    /// The QR's one-time `omb_pair_` credential, or a typed code: a computer's six digits or a server's twelve symbols.
    let credential: String
    /// The computer's name as the link carries it; the pairing reply's `serverName` wins.
    var name: String?
    /// The computer's public HPKE key for secrets (`secretKey`): a 65-byte uncompressed P-256 point. Only a QR has it.
    var secretKey: Data?
    /// Sent as `pairRequestId` on every try of this invite: a retry after a lost reply gets the same
    /// device back instead of `pairing_not_open`, as the code works once. Random, so knowing the code
    /// is not enough to replay someone else's pairing.
    let requestID = "ios-" + UUID().uuidString

    var id: String { server.absoluteString + credential }

    /// Reads a link as `openmausbot/packages/phone-protocol/src/pairing-link.ts` writes it: `address` is
    /// `host:port` (IPv6 bracketed) or an http(s) origin, `token` the one-time credential. Nil for anything
    /// else, as the desktop never prints a link a phone would refuse. The fallback routes (`hosts`,
    /// `endpoints`, `e2e`) are left to choosing the route (#9).
    init?(url: URL) {
        if let page = Self.pairPage(url) {
            self.init(server: page.server, credential: page.code)
            return
        }
        guard !Self.isRelayOnly(url), url.scheme?.lowercased() == "openmausbot", url.host?.lowercased() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ key: String) -> String? {
            items.first { $0.name == key }?.value?.trimmingCharacters(in: .whitespaces)
        }
        guard let server = value("address").flatMap(Self.server(fromLinkAddress:)),
              let token = value("token").flatMap(Self.credential) ?? value("code").flatMap(Self.pairingCode)
        else { return nil }
        let name = value("name")
        self.init(server: server, credential: token, name: name?.isEmpty == false ? name : nil)
        // A malformed key leaves only the secret card without it, as the rest of the link still pairs.
        secretKey = value("secretKey").flatMap { $0.count == 87 ? Data(base64URL: $0) : nil }
            .flatMap { $0.count == 65 && $0.first == 0x04 ? $0 : nil }
    }

    /// What someone typed: the address the computer shows (`192.168.1.10:8810`, or a full http(s) address)
    /// and its code. Nil until both are usable.
    init?(typedAddress: String, code: String) {
        let address = typedAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, let code = Self.pairingCode(code),
              let server = try? AuthManager.normalizedServerURL(from: Self.schemed(address))
        else { return nil }
        self.init(server: server, credential: code)
    }

    /// The companion listens on plain HTTP on the LAN and the tailnet, always with a port
    /// (`192.168.1.10:8810`); a server's or Cloud's name without one (`bots.example.com`) is https.
    static func schemed(_ address: String) -> String {
        if address.contains("://") { return address }
        let hasPort = address.range(of: #":\d+$"#, options: .regularExpression) != nil
        return (hasPort ? "http://" : "https://") + address
    }

    init(server: URL, credential: String, name: String? = nil) {
        self.server = server
        self.credential = credential
        self.name = name
    }

    /// A link from a computer reachable only through Squadd Multi-Agents Relay: its address is
    /// `relay-only.invalid` (`openmausbot/server/phone-relay.ts`), and this app has no relay route yet (#9).
    static func isRelayOnly(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "address" }?.value?.lowercased().hasPrefix("relay-only.invalid") == true
    }

    /// A desktop companion's six digits (`companion/src/devices.ts`, `newWindow`), or a server's or
    /// Cloud's twelve symbols (`packages/phone-protocol/src/pairing-code.ts`), sent as `XXXX-XXXX-XXXX`.
    /// Spaces, dashes and case never matter; 0 and 1 read as O and I, as the server reads them.
    static func pairingCode(_ raw: String) -> String? {
        let code = raw.filter { !$0.isWhitespace && $0 != "-" }
        if code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) { return code }
        let symbols = code.uppercased().replacingOccurrences(of: "0", with: "O").replacingOccurrences(of: "1", with: "I")
        guard symbols.count == 12, symbols.allSatisfy({ "23456789ABCDEFGHJKLMNPQRSTUVWXYZ".contains($0) }) else { return nil }
        return stride(from: 0, to: 12, by: 4).map { String(Array(symbols)[$0..<$0 + 4]) }.joined(separator: "-")
    }

    private static func credential(_ raw: String) -> String? {
        raw.range(of: #"^omb_pair_[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil ? raw : nil
    }

    /// A server's own pairing page, `https://host/pair#code=…` (`ServerPairingCard` on the desktop): its
    /// origin and the code it carries.
    private static func pairPage(_ url: URL) -> (server: URL, code: String)? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.percentEncodedHost, !host.isEmpty,
              components.path == "/pair" || components.path == "/pair/",
              let raw = URLComponents(string: "?" + (components.fragment ?? ""))?.queryItems?.first(where: { $0.name == "code" })?.value
                ?? components.queryItems?.first(where: { $0.name == "code" })?.value,
              let code = pairingCode(raw)
        else { return nil }
        let origin = "\(scheme)://\(host)" + (components.port.map { ":\($0)" } ?? "")
        return server(fromLinkAddress: origin).map { ($0, code) }
    }

    /// `host:port` becomes `http://host:port`; an http(s) origin stays. Credentials, a path, a query or a
    /// fragment refuse the link, as both phone protocols do.
    private static func server(fromLinkAddress address: String) -> URL? {
        let isOrigin = address.lowercased().hasPrefix("http://") || address.lowercased().hasPrefix("https://")
        let value = isOrigin ? address : "http://\(address)"
        guard let components = URLComponents(string: value), components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              components.path.isEmpty || components.path == "/",
              components.query == nil, components.fragment == nil,
              isOrigin || components.port != nil
        else { return nil }
        // The same normalization as a typed address, so both reach the same server in the list.
        return try? AuthManager.normalizedServerURL(from: value)
    }
}
