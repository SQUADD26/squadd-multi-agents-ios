import Foundation
import Observation

/// The paired computer's connected apps on the phone (#29): the catalog, the apps with an active
/// account, a new connection through the service's own sign-in, and removing an account. The
/// computer's answer is the only truth: every action ends in a fresh read, however it ended.
@MainActor @Observable
final class SquaddConnectorsModel {
    enum State: Equatable {
        case loading
        case loaded([SquaddConnectorApp])
        /// Connecting apps isn't set up on the computer.
        case notSetUp
        case failed(String)
    }

    private(set) var state = State.loading
    /// The app whose connect or disconnect is in flight. One at a time: each ends in a fresh read.
    private(set) var busyApp: String?
    /// The last action's refusal, for the page's alert.
    var actionError: String?

    private let client: SquaddCompanionClient
    private let onUnpaired: () -> Void

    init(client: SquaddCompanionClient, onUnpaired: @escaping () -> Void) {
        self.client = client
        self.onUnpaired = onUnpaired
    }

    var apps: [SquaddConnectorApp] {
        if case .loaded(let apps) = state { return apps }
        return []
    }

    func load() async {
        do {
            async let catalog = client.connectorCatalog()
            async let connected = client.connectedServices()
            let (read, services) = try await (catalog, connected)
            state = read.setup == "ready" ? .loaded(SquaddConnectorApp.join(read, services)) : .notSetUp
        } catch {
            if !Task.isCancelled { state = .failed(message(for: error)) }
        }
    }

    /// Asks the computer for `app`'s sign-in link, shows it through `browse`, and reads the list
    /// again once the browser closes. A sign-in the person cancels or that fails leaves the app
    /// as the computer reports it: not connected.
    func connect(_ app: SquaddConnectorApp, browse: (URL) async -> Void) async {
        await act(on: app) {
            let link = try await self.client.authorizeConnector(slug: app.slug)
            await browse(link)
        }
    }

    func disconnect(_ account: SquaddConnectedServices.Account, of app: SquaddConnectorApp) async {
        await act(on: app) { try await self.client.removeConnectorAccount(slug: app.slug, accountId: account.id) }
    }

    private func act(on app: SquaddConnectorApp, _ work: () async throws -> Void) async {
        guard busyApp == nil else { return }
        busyApp = app.id
        defer { busyApp = nil }
        do {
            try await work()
        } catch {
            if !Task.isCancelled { actionError = message(for: error) }
        }
        await load()
    }

    private func message(for error: Error) -> String {
        switch error {
        case SquaddError.unpaired:
            onUnpaired()
            return String(localized: "This iPhone is no longer paired with the computer.")
        case SquaddError.status(403):
            return String(localized: "This can only be changed on the computer.")
        case SquaddError.status(let code):
            return String(localized: "The computer answered with an error (\(code)).")
        default:
            return String(localized: "Can't reach the computer.")
        }
    }
}
