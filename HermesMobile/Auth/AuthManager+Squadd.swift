import Foundation

/// Squadd companion servers (ADR 0001, 0003): signed in with a device token from `POST /api/pair`,
/// kept in the Keychain under the server's own scope so two companions never share one.
extension AuthManager {
    enum SquaddAddError: Error, Equatable {
        case alreadyConfigured
        case keychain
    }

    /// Adds a Squadd companion at `address` with the token its pairing returned and makes it the
    /// active server. Refuses an address already configured, leaving the active server alone.
    func addSquaddServer(address: URL, token: String) throws {
        guard !serverRegistry.servers.contains(where: { $0.id == address.absoluteString }) else {
            throw SquaddAddError.alreadyConfigured
        }
        do {
            try keychain.save(token, forKey: .squaddDeviceToken, scope: address.absoluteString)
            try keychain.save(address.absoluteString, forKey: .serverURL)
        } catch {
            try? keychain.delete(.squaddDeviceToken, scope: address.absoluteString)
            throw SquaddAddError.keychain
        }
        handBackScreens(leavingFor: address)
        serverRegistry.activate(url: address, kind: .squadd)
        refreshServers()
        // The Shortcuts Profile list belonged to the server this replaces as active (#339).
        ProfileEntityCache.shared.save([])
        enterActiveServer(address)
    }

    /// Redeems `invite` and makes its computer the active server: a new server in the list, or, for
    /// a computer already there, its new token. That one goes with the token it replaces
    /// (`replacesToken`), so the computer swaps this iPhone instead of counting it twice. A webui or
    /// Hermes server at the same address is refused before the code is spent.
    func pairSquadd(_ invite: SquaddPairingInvite, deviceName: String, session: URLSession = .shared) async throws {
        let existing = servers.first { $0.id == invite.server.absoluteString }
        if let existing, existing.kind != .squadd { throw SquaddAddError.alreadyConfigured }
        let reply = try await SquaddCompanionClient.pair(
            server: invite.server, credential: invite.credential, deviceName: deviceName, requestID: invite.requestID,
            // No token after a revocation: the computer already dropped that device, so nothing to replace.
            replacesToken: existing == nil ? nil : squaddToken(for: invite.server), session: session)
        guard let existing else {
            try addSquaddServer(address: invite.server, token: reply.token)
            // A new server is named after its host; the computer's own name reads better.
            if let name = (reply.serverName ?? invite.name)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
               let account = servers.first(where: { $0.id == invite.server.absoluteString }) {
                updateServerIdentity(account, displayName: name,
                                     initials: SessionIdentitySettings.displayInitials(displayName: name, storedInitials: "", fallbackFullName: name),
                                     headerLogoColorHex: account.headerLogoColorHex)
            }
            return
        }
        try repairSquaddServer(invite.server, token: reply.token)
        switchActiveServer(to: existing)
    }

    /// Pairs the saved Squadd server at `server` again with a new token: the pair-again screen's way
    /// back in after the desktop revoked the old one.
    func repairSquaddServer(_ server: URL, token: String) throws {
        guard kind(of: server) == .squadd else { return }
        do { try keychain.save(token, forKey: .squaddDeviceToken, scope: server.absoluteString) } catch {
            throw SquaddAddError.keychain
        }
        if state.server == server { enterActiveServer(server) }
    }

    /// The device token saved for a Squadd server; nil once it is unpaired or signed out.
    func squaddToken(for server: URL) -> String? {
        (try? keychain.load(.squaddDeviceToken, scope: server.absoluteString)) ?? nil
    }

    /// The companion answered 401: the desktop revoked this iPhone. The token goes, and the server,
    /// if still active, shows the pair-again screen. A late reply for another server changes nothing
    /// on screen.
    func squaddUnpaired(server: URL) {
        guard kind(of: server) == .squadd else { return }
        try? keychain.delete(.squaddDeviceToken, scope: server.absoluteString)
        if state.server == server { enterActiveServer(server) }
    }

    /// Everything that signs `server` in on this iPhone: a Hermes server's Bot connection
    /// (`removeBotConnection`) and a Squadd server's device token.
    func removeSignIn(for server: URL) {
        removeBotConnection(for: server)
        try? keychain.delete(.squaddDeviceToken, scope: server.absoluteString)
    }
}
