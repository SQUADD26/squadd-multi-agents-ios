import SwiftUI

/// Settings → Notifications on a Squadd server: turns this iPhone's push on or off on that computer
/// (`/api/push/device`), then the alerts every server shares. The computer is the record of whether it is on.
@MainActor struct SquaddPushSettingsPage<SharedSections: View>: View {
    let server: URL
    @ViewBuilder let sharedSections: () -> SharedSections

    @State private var state: LoadState = .loading
    @State private var isWorking = false
    @State private var failure: String?

    private enum LoadState: Equatable {
        case loading, unreachable
        case loaded(SquaddPushAnswer)
    }

    var body: some View {
        AppList {
            Section {
                pushRow
            } header: {
                Text("Push · Current server")
            } appFooter: {
                if let footer { Text(footer) }
            }

            sharedSections()
        }
        .settingsPage(String(localized: "Notifications"))
        .task { await load() }
    }

    @ViewBuilder private var pushRow: some View {
        switch state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity)
        case .unreachable:
            Button(String(localized: "Try again")) { Task { await load() } }
        case .loaded(let answer) where answer.isRegistered:
            Button(isWorking ? String(localized: "Turning off…") : String(localized: "Turn off notifications…"),
                   role: .destructive) { run { try await SquaddPushRegistrar.shared.disable(for: server) } }
                .disabled(isWorking)
        case .loaded:
            Button(isWorking ? String(localized: "Setting up…") : String(localized: "Turn on notifications…")) {
                run { try await SquaddPushRegistrar.shared.enable(for: server) }
            }
            .disabled(isWorking)
        }
    }

    private var footer: String? {
        if let failure { return failure }
        switch state {
        case .unreachable: return String(localized: "Can't Reach the Computer")
        case .loaded(let answer) where answer.push != nil && answer.push != "on":
            return String(localized: "This computer isn't sending notifications yet. Turn them on in Squadd on the computer.")
        default: return nil
        }
    }

    private func load() async {
        if let answer = await SquaddPushRegistrar.shared.isEnabled(for: server) {
            state = .loaded(answer)
        } else {
            state = .unreachable
        }
    }

    private func run(_ change: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        failure = nil
        Task {
            do { try await change() } catch SquaddPushRegistrar.Failure.permissionDenied {
                failure = String(localized: "Allow them in iOS Settings, then try again.")
            } catch {
                failure = String(localized: "Can't Reach the Computer")
            }
            await load()
            isWorking = false
        }
    }
}
