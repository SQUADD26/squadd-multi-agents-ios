import SwiftUI
import UIKit

/// Redeems a pairing code shown on the computer for this iPhone's device token.
@MainActor
private func squaddPair(server: URL, code: String) async throws -> String {
    let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
    return try await SquaddCompanionClient.pair(server: server, code: code, deviceName: UIDevice.current.name).token
}

private func squaddPairingFailure(_ error: Error) -> String {
    switch error {
    case SquaddError.unpaired, SquaddError.status(400), SquaddError.status(403), SquaddError.status(404):
        return String(localized: "The computer refused the code. Codes last two minutes and work once.")
    case AuthManager.SquaddAddError.alreadyConfigured:
        return String(localized: "This server is already configured.")
    case AuthManager.SquaddAddError.keychain:
        return String(localized: "Could not save sign-in details on this iPhone.")
    default:
        return String(localized: "Could not reach the computer at this address.")
    }
}

/// What a Squadd server shows once the companion refused its token (revoked from the desktop):
/// it says to pair again, and takes a new code. Settings stays reachable to switch or remove it.
struct SquaddPairAgainView: View {
    @Bindable var authManager: AuthManager
    let server: URL
    @State private var code = ""
    @State private var isPairing = false
    @State private var errorMessage: String?
    @State private var isShowingSettings = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Pair This iPhone Again", systemImage: "iphone.slash")
                        .font(.headline)
                    Text("The computer no longer accepts this iPhone, so it was probably removed from the desktop. Open Remote access on the computer, start a new pairing, and enter the code.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    TextField("Pairing code", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                    Button("Pair") { pair() }
                        .disabled(code.isEmpty || isPairing)
                } footer: {
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(authManager.activeServer?.displayName ?? server.host() ?? "")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isShowingSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            NavigationStack {
                SettingsView(authManager: authManager, server: server)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingSettings = false }
                        }
                    }
            }
        }
    }

    private func pair() {
        isPairing = true
        errorMessage = nil
        Task {
            defer { isPairing = false }
            do {
                try authManager.repairSquaddServer(server, token: try await squaddPair(server: server, code: code))
            } catch {
                errorMessage = squaddPairingFailure(error)
            }
        }
    }
}

#if DEBUG
/// Debug only (#2): adds a Squadd server from its address and a pairing code, so work on the
/// Squadd screens can start before QR pairing exists. Release builds have no such entry.
struct SquaddDebugAddServerView: View {
    @Bindable var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var code = ""
    @State private var isPairing = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField(text: $address, prompt: Text(verbatim: "http://192.168.1.10:8810")) { Text(verbatim: "Address") }
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(text: $code) { Text(verbatim: "Pairing code or device token") }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            Button { pair() } label: { Text(verbatim: "Pair") }
                .disabled(address.isEmpty || code.isEmpty || isPairing)
        }
        .navigationTitle(Text(verbatim: "Add Squadd Server (Debug)"))
    }

    private func pair() {
        isPairing = true
        errorMessage = nil
        Task {
            defer { isPairing = false }
            do {
                let server = try AuthManager.normalizedServerURL(from: address)
                // Digits are a pairing code to redeem; anything else is a device token `POST /api/pair` already returned.
                let entry = code.trimmingCharacters(in: .whitespacesAndNewlines)
                let isCode = !entry.isEmpty && entry.allSatisfy(\.isNumber)
                try authManager.addSquaddServer(address: server, token: isCode ? try await squaddPair(server: server, code: entry) : entry)
                dismiss()
            } catch {
                errorMessage = squaddPairingFailure(error)
            }
        }
    }
}

/// Debug only: what the Squadd home's Add Server opens, so a second companion can be added.
struct SquaddAddServerSheet: View {
    @Bindable var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SquaddDebugAddServerView(authManager: authManager)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
        }
    }
}

/// Debug only: a corner button on first launch that opens `SquaddDebugAddServerView`.
struct SquaddDebugAddServerButton: View {
    @Bindable var authManager: AuthManager
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: { Text(verbatim: "Squadd (Debug)") }
            .buttonStyle(.bordered)
            .padding()
            .sheet(isPresented: $isPresented) {
                NavigationStack { SquaddDebugAddServerView(authManager: authManager) }
            }
    }
}
#else
/// Release: the Squadd home's Add Server is the app's usual one.
struct SquaddAddServerSheet: View {
    @Bindable var authManager: AuthManager

    var body: some View { AddServerView(authManager: authManager) }
}
#endif
