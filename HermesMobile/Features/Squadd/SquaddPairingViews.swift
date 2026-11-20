import SwiftUI
import UIKit

/// What a scanned QR code that doesn't pair tells the person.
func squaddScanRefusal(_ refusal: SquaddPairingInvite.ScanRefusal) -> String {
    switch refusal {
    case .relayOnly:
        return String(localized: "This QR code has no way through Squadd Multi-Agents Relay. Sign the computer in to the relay, then create a new code.")
    case .updateApp:
        return String(localized: "Update the Squadd Multi-Agents app to pair with this computer.")
    case .notAPairingCode:
        return String(localized: "That QR code isn’t a Squadd Multi-Agents pairing code.")
    }
}

/// Redeems `invite` with this iPhone's name and saves its computer (`AuthManager.pairSquadd`).
@MainActor
func squaddPair(_ invite: SquaddPairingInvite, authManager: AuthManager) async throws {
    try await authManager.pairSquadd(invite, deviceName: UIDevice.current.name)
}

/// What a failed pairing tells the person, in the words of what to do next. The companion's refusals
/// are `companion/src/devices.ts`'s: an expired or used code finds no pairing open.
func squaddPairingFailure(_ error: Error) -> String {
    switch error {
    case SquaddError.pairing("pairing_not_open"):
        return String(localized: "This code has expired or was already used. Create a new one on the computer and scan it again.")
    case SquaddError.pairing("pairing_code_wrong"):
        return String(localized: "That code isn’t right, or it has expired. Create a new one on the computer and try again.")
    case SquaddError.pairing("pairing_too_many"):
        return String(localized: "Too many wrong codes. Create a new one on the computer and try again.")
    case SquaddError.pairing("pairing_qr_only"):
        return String(localized: "This computer takes only its QR code. Scan the QR code on the computer instead of typing the code.")
    case SquaddError.pairing("pairing_device_limit"):
        return String(localized: "This computer already has 20 paired devices. Remove an old phone in Remote access on the computer, then pair again.")
    case SquaddError.pairing, SquaddError.unpaired, SquaddError.status(400), SquaddError.status(403), SquaddError.status(404):
        return String(localized: "The computer refused the code. Codes work once and only for a few minutes: create a new one on the computer.")
    case SquaddE2ETunnel.Failure.offline:
        return String(localized: "Your computer is asleep or offline.")
    case SquaddE2ETunnel.Failure.relayUnreachable:
        return String(localized: "Can’t reach Squadd Multi-Agents Relay right now. Try again in a moment.")
    case SquaddE2ETunnel.Failure.unverified:
        return String(localized: "Couldn’t verify your computer. Pair again from your computer’s Settings.")
    case AuthManager.SquaddAddError.alreadyConfigured:
        return String(localized: "This server is already configured.")
    case AuthManager.SquaddAddError.keychain:
        return String(localized: "Could not save sign-in details on this iPhone.")
    default:
        return String(localized: "Could not reach the computer at this address. If it works only on its own Wi-Fi, connect this iPhone to that Wi-Fi.")
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
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
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
                try await squaddPair(SquaddPairingInvite(server: server, credential: SquaddPairingInvite.pairingCode(code) ?? code), authManager: authManager)
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
                if let digits = SquaddPairingInvite.pairingCode(entry) {
                    try await squaddPair(SquaddPairingInvite(server: server, credential: digits), authManager: authManager)
                } else {
                    try authManager.addSquaddServer(address: server, token: entry)
                }
                dismiss()
            } catch {
                errorMessage = squaddPairingFailure(error)
            }
        }
    }
}

#endif

/// The Squadd home's Add Server and an `openmausbot://pair` link:
/// the pairing screen, which pairs `invite` at once when there is one.
struct SquaddAddServerSheet: View {
    @Bindable var authManager: AuthManager
    var invite: SquaddPairingInvite?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SquaddPairView(authManager: authManager, invite: invite, onPaired: { dismiss() })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
        }
    }
}
