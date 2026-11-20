import AuthenticationServices
import SwiftUI

/// The paired computer's Connected Apps (#29): connected apps on top, then the catalog. Connect
/// opens the service's sign-in in a browser sheet; when it closes, the list is read again.
struct SquaddConnectorsPage: View {
    @State private var model: SquaddConnectorsModel
    @State private var disconnecting: (account: SquaddConnectedServices.Account, app: SquaddConnectorApp)?
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    init(client: SquaddCompanionClient, onUnpaired: @escaping () -> Void) {
        _model = State(initialValue: SquaddConnectorsModel(client: client, onUnpaired: onUnpaired))
    }

    var body: some View {
        AppList { content }
            .settingsPage(String(localized: "Connected Apps"))
            .task { await model.load() }
            .refreshable { await model.load() }
            .alert("Couldn't Update Connected Apps", isPresented: Binding(
                get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(verbatim: model.actionError ?? "")
            }
            .confirmationDialog(String(localized: "Disconnect this account?"), isPresented: Binding(
                get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }
            ), titleVisibility: .visible) {
                if let disconnecting {
                    Button(String(localized: "Disconnect"), role: .destructive) {
                        Task { await model.disconnect(disconnecting.account, of: disconnecting.app) }
                    }
                }
            } message: {
                Text("The agents on the computer lose access to this account.")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
        case .notSetUp:
            ContentUnavailableView("Connected Apps Aren't Set Up", systemImage: "app.connected.to.app.below.fill",
                                   description: Text("Set them up in Squadd Multi-Agents on the computer."))
                .listRowBackground(Color.clear)
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't Reach the Computer", systemImage: "wifi.exclamationmark")
            } description: {
                Text(verbatim: message)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
            }
            .listRowBackground(Color.clear)
        case .loaded(let apps):
            let connected = apps.filter(\.isConnected)
            if !connected.isEmpty {
                Section(String(localized: "Connected")) {
                    ForEach(connected) { app in
                        ForEach(app.accounts) { account in
                            row(app, detail: account.alias ?? String(localized: "Connected"))
                                .swipeActions {
                                    Button(String(localized: "Disconnect"), role: .destructive) { disconnecting = (account, app) }
                                }
                                .contextMenu {
                                    Button(String(localized: "Disconnect"), systemImage: "minus.circle", role: .destructive) {
                                        disconnecting = (account, app)
                                    }
                                }
                        }
                    }
                }
            }
            Section {
                ForEach(apps) { app in
                    row(app, detail: app.blurb) {
                        Button {
                            Task { await model.connect(app, browse: browse) }
                        } label: {
                            if model.busyApp == app.id { ProgressView() } else { Text(app.isConnected ? "Add Account" : "Connect") }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.busyApp != nil)
                    }
                }
            } header: {
                Text("Apps")
            } appFooter: {
                Text("You sign in on the app's own page. The computer keeps the connection; this iPhone never holds it.")
            }
        }
    }

    private func row(_ app: SquaddConnectorApp, detail: String?) -> some View {
        row(app, detail: detail) { EmptyView() }
    }

    private func row<Action: View>(_ app: SquaddConnectorApp, detail: String?,
                                   @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: String(app.name.prefix(1)).uppercased())
                .font(AppFont.body(weight: .semibold))
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.15)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: app.name)
                if let detail {
                    Text(verbatim: detail).font(AppFont.footnote()).foregroundStyle(.appSecondary)
                }
            }
            Spacer(minLength: 8)
            action()
        }
    }

    /// Shows the service's sign-in and returns when the sheet closes, however it closed. Not
    /// ephemeral, so sign-ins already in Safari carry over. The computer's accounts, read next,
    /// say whether it worked.
    private func browse(_ link: URL) async {
        _ = try? await webAuthenticationSession.authenticate(
            using: link, callback: .customScheme("squadd-multi-agents"),
            preferredBrowserSession: .shared, additionalHeaderFields: [:])
    }
}
