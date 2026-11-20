import Foundation

/// A pairing the computer handed over: its QR code or `openmausbot://pair` link, or the address and
/// six-digit code typed from its Remote access screen. Redeemed by `AuthManager.pairSquadd`.
struct SquaddPairingInvite: Equatable, Identifiable {
    let server: URL
    /// The QR's one-time `omb_pair_` credential, or the typed six digits.
    let credential: String
    /// The computer's name as the link carries it; the pairing reply's `serverName` wins.
    var name: String?
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
        guard url.scheme?.lowercased() == "openmausbot", url.host?.lowercased() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ key: String) -> String? {
            items.first { $0.name == key }?.value?.trimmingCharacters(in: .whitespaces)
        }
        guard let server = value("address").flatMap(Self.server(fromLinkAddress:)),
              let token = value("token"),
              token.range(of: #"^omb_pair_[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil
        else { return nil }
        let name = value("name")
        self.init(server: server, credential: token, name: name?.isEmpty == false ? name : nil)
    }

    /// What someone typed: the address the computer shows (`192.168.1.10:8810`, or a full http(s) address)
    /// and its six-digit code. Nil until both are usable.
    init?(typedAddress: String, code: String) {
        let address = typedAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, let code = Self.pairingCode(code),
              // The companion listens on plain HTTP on the LAN and the tailnet; only a hosted address is https.
              let server = try? AuthManager.normalizedServerURL(from: address.contains("://") ? address : "http://\(address)")
        else { return nil }
        self.init(server: server, credential: code)
    }

    init(server: URL, credential: String, name: String? = nil) {
        self.server = server
        self.credential = credential
        self.name = name
    }

    /// The desktop companion's code: six digits (`companion/src/devices.ts`, `newWindow`), shown with
    /// spaces or a dash at times. The twelve-symbol code of `pairing-code.ts` is a server's or Cloud's,
    /// which this app does not pair with.
    static func pairingCode(_ raw: String) -> String? {
        let code = raw.filter { !$0.isWhitespace && $0 != "-" }
        return code.count == 6 && code.allSatisfy({ $0.isASCII && $0.isNumber }) ? code : nil
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
