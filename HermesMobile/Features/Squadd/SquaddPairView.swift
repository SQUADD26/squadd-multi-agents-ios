import AVFoundation
import SwiftUI
import UIKit

/// Pairs this iPhone with a computer running Squadd Multi-Agents (ADR 0003): the camera reads the QR
/// code from the computer's Remote access screen, or the person types the address and six-digit
/// code shown beside it. Without the camera (refused, restricted, or none) the code is the way in.
struct SquaddPairView: View {
    @Bindable var authManager: AuthManager
    /// From an `openmausbot://pair` link: paired as soon as the screen appears.
    var invite: SquaddPairingInvite?
    var onPaired: () -> Void
    /// Read from the system; a photo test sets `.denied` to show the way to Settings.
    @State var camera = AVCaptureDevice.authorizationStatus(for: .video)
    /// None in the simulator: then nothing asks for the camera and the code is the way in.
    private static let hasCamera = AVCaptureDevice.default(for: .video) != nil
    @State private var address = ""
    @State private var code = ""
    @State private var isPairing = false
    @State private var errorMessage: String?
    /// The last typed invite, so a second tap on Pair after a lost reply sends the same `pairRequestId`.
    @State private var typedInvite: SquaddPairingInvite?

    var body: some View {
        Form {
            Section {
                scanner
                    .frame(height: 260)
                    // Over the camera, not in its place: a new scanner would read the failed code again.
                    .overlay {
                        if isPairing { ProgressView("Pairing…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) }
                    }
                    .listRowInsets(EdgeInsets())
            } footer: {
                Text("Open Remote access on your computer, start pairing, and point the camera at the QR code.")
            }
            Section {
                TextField("Address", text: $address, prompt: Text(verbatim: "192.168.1.10:8810"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Pairing code", text: $code, prompt: Text(verbatim: "123456"))
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                Button("Pair") { pairTyped() }
                    .disabled(SquaddPairingInvite(typedAddress: address, code: code) == nil || isPairing)
            } header: {
                Text("Or Enter the Code")
            } footer: {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                } else {
                    Text("The computer shows the address and the six-digit code under the QR code.")
                }
            }
            #if DEBUG
            NavigationLink { SquaddDebugAddServerView(authManager: authManager) } label: { Text(verbatim: "Address and token (Debug)") }
            #endif
        }
        .navigationTitle("Pair with Your Computer")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let invite { pair(invite) }
            if Self.hasCamera, camera == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                camera = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    @ViewBuilder private var scanner: some View {
        if Self.hasCamera, camera == .authorized {
            SquaddQRScanner { scanned in
                guard !isPairing else { return }
                guard let url = URL(string: scanned), let invite = SquaddPairingInvite(url: url) else {
                    errorMessage = String(localized: "That QR code isn’t a Squadd Multi-Agents pairing code.")
                    return
                }
                pair(invite)
            }
            .accessibilityLabel("QR code scanner")
        } else if Self.hasCamera, camera == .notDetermined {
            Color.black
        } else {
            VStack(spacing: 12) {
                Image(systemName: "camera.fill").font(.title).foregroundStyle(.secondary)
                Text("The camera is off or unavailable. Enter the address and code the computer shows instead.")
                    .multilineTextAlignment(.center)
                if camera == .denied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func pairTyped() {
        guard let fresh = SquaddPairingInvite(typedAddress: address, code: code) else { return }
        if typedInvite?.server != fresh.server || typedInvite?.credential != fresh.credential { typedInvite = fresh }
        pair(typedInvite)
    }

    private func pair(_ invite: SquaddPairingInvite?) {
        guard let invite, !isPairing else { return }
        isPairing = true
        errorMessage = nil
        Task {
            defer { isPairing = false }
            do {
                try await squaddPair(invite, authManager: authManager)
                onPaired()
            } catch {
                errorMessage = squaddPairingFailure(error)
                // A QR or link that failed leaves its address, so a typed code can follow.
                if address.isEmpty { address = invite.server.absoluteString }
            }
        }
    }
}

/// The back camera reading QR codes (`AVCaptureMetadataOutput`). Hands each new code to `onCode`
/// on the main actor; the session runs while the view is on screen.
private struct SquaddQRScanner: UIViewRepresentable {
    var onCode: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        let session = context.coordinator.session
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let device = AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
                output.metadataObjectTypes = [.qr]
            }
        }
        // startRunning blocks; never on the main thread.
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: Coordinator) {
        let session = coordinator.session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        let session = AVCaptureSession()
        var onCode: @MainActor (String) -> Void
        /// The camera reports the same code many times a second; it goes on once.
        private var lastCode: String?

        init(onCode: @escaping @MainActor (String) -> Void) { self.onCode = onCode }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
                  code != lastCode else { return }
            lastCode = code
            MainActor.assumeIsolated { onCode(code) }
        }
    }
}
