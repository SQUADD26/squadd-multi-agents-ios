import Foundation
import OSLog
import UserNotifications

/// This iPhone's APNs registration on its Squadd computers (ADR 0004). Each computer keeps its own
/// registration (`/api/push/device`), so the companion is the only record of whether push is on: nothing is
/// stored here. Once notifications are allowed, every launch mints a token and re-registers it on each
/// computer that already holds one, since APNs may have rotated it.
@MainActor final class SquaddPushRegistrar {
    static let shared = SquaddPushRegistrar()

    enum Failure: Error, Equatable {
        /// No `HermesAPSEnvironment` in Info.plist: the build can't say which APNs environment its token is for.
        case unsupportedBuild
        case permissionDenied
        case tokenUnavailable
    }

    private static let logger = Logger(subsystem: "com.squaddcrm.multiagents", category: "squadd-push")

    private let remoteNotifications: any RemoteNotificationRegistering
    private let requestAuthorization: @MainActor () async -> Bool
    private let isAuthorized: @MainActor () async -> Bool
    /// The configured Squadd servers that are paired, each with a client holding its device token.
    private let clients: @MainActor () -> [URL: SquaddCompanionClient]
    private let environment: PushEnvironment?
    private var currentToken: String?
    private var tokenWaiters: [CheckedContinuation<String, any Error>] = []

    init(
        remoteNotifications: any RemoteNotificationRegistering = UIApplicationRemoteNotificationRegistrar(),
        requestAuthorization: @escaping @MainActor () async -> Bool = {
            (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        },
        isAuthorized: @escaping @MainActor () async -> Bool = {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized
        },
        clients: @escaping @MainActor () -> [URL: SquaddCompanionClient] = SquaddPushRegistrar.pairedClients,
        environment: PushEnvironment? = PushEnvironment.current()
    ) {
        self.remoteNotifications = remoteNotifications
        self.requestAuthorization = requestAuthorization
        self.isAuthorized = isAuthorized
        self.clients = clients
        self.environment = environment
    }

    /// Asks for permission (once; iOS never asks again after a denial), gets a token and registers it on `server`.
    func enable(for server: URL) async throws {
        guard let environment else { throw Failure.unsupportedBuild }
        guard let client = clients()[server] else { throw SquaddError.unpaired }
        guard await requestAuthorization() else { throw Failure.permissionDenied }
        let token = try await deviceToken()
        try await client.registerPush(token: token, environment: environment, pairing: SquaddPush.pairingTag(for: server))
    }

    func disable(for server: URL) async throws {
        guard let client = clients()[server] else { return }
        try await client.unregisterPush()
    }

    /// Removing or signing out of a server: best effort, since the user already threw the server away. Runs
    /// before its device token is deleted, which it needs.
    func forget(server: URL) async {
        guard let client = clients()[server] else { return }
        do { try await client.unregisterPush() } catch {
            Self.logger.error("Push unregister failed: \(String(describing: error), privacy: .public)")
        }
    }

    func isEnabled(for server: URL) async -> SquaddPushAnswer? {
        try? await clients()[server]?.pushDevice()
    }

    /// Launch: with notifications allowed and a Squadd server paired, ask APNs for the token; its delivery
    /// re-registers it everywhere it is on.
    func refreshOnLaunch() async {
        guard !clients().isEmpty, await isAuthorized() else { return }
        remoteNotifications.registerForRemoteNotifications()
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) async {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        currentToken = token
        let waiters = tokenWaiters
        tokenWaiters = []
        waiters.forEach { $0.resume(returning: token) }
        guard let environment else { return }
        for (server, client) in clients() {
            guard (try? await client.pushDevice())?.isRegistered == true else { continue }
            try? await client.registerPush(token: token, environment: environment, pairing: SquaddPush.pairingTag(for: server))
        }
    }

    func didFailToRegisterForRemoteNotifications(error: any Error) {
        Self.logger.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
        let waiters = tokenWaiters
        tokenWaiters = []
        waiters.forEach { $0.resume(throwing: Failure.tokenUnavailable) }
    }

    private func deviceToken() async throws -> String {
        if let currentToken { return currentToken }
        // APNs may never answer (no network): give up rather than leave a spinner turning.
        let timeout = Task { [weak self] in
            try await Task.sleep(for: .seconds(20))
            self?.didFailToRegisterForRemoteNotifications(error: Failure.tokenUnavailable)
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            tokenWaiters.append(continuation)
            remoteNotifications.registerForRemoteNotifications()
        }
    }

    static func pairedClients() -> [URL: SquaddCompanionClient] {
        let keychain = KeychainStore()
        var clients: [URL: SquaddCompanionClient] = [:]
        for account in ServerRegistry.shared.servers where account.kind == .squadd {
            guard let url = URL(string: account.urlString),
                  let token = (try? keychain.load(.squaddDeviceToken, scope: url.absoluteString)) ?? nil else { continue }
            clients[url] = SquaddCompanionClient(server: url, token: token)
        }
        return clients
    }
}
