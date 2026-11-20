import SwiftUI

/// A Squadd agent's secret, sign-in or connector card (#16), pinned above the composer in the request slot.
/// It takes layout space at its full height, scrolling once that is more than the space above the composer.
struct SquaddCardInset: View {
    let card: SquaddPendingCard
    let turn: SquaddChatTurnCoordinator
    /// Height between the chat's top safe edge and this inset's bottom edge.
    let maximumExpandedHeight: CGFloat
    let onFootprintChange: (CGFloat) -> Void

    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    /// The secret as typed. It lives only here: cleared the moment it goes out, never in a draft or a log.
    @State private var secret = ""
    @State private var contentHeight: CGFloat?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content
                if let error = turn.cardError {
                    Text(verbatim: error)
                        .font(AppFont.caption())
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: 560, alignment: .leading)
            .accessibilityElement(children: .contain)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: max(0, min(contentHeight ?? maximumExpandedHeight, maximumExpandedHeight)))
        .clipShape(shape)
        .pendingRequestCardSurface(cornerRadius: ChatComposerMetrics.cardCornerRadius)
        .frame(maxWidth: 560)
        .opacity(contentHeight == nil ? 0 : 1)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onFootprintChange($0) }
        .onDisappear { secret = "" }
    }

    @ViewBuilder private var content: some View {
        switch card.kind {
        case .secret(let request): secretCard(request)
        case .signIn(let request): signInCard(request)
        case .connector(let request): connectorCard(request)
        }
    }

    // MARK: Secret

    private func secretCard(_ request: SquaddSecretCard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(symbol: "key.fill", title: request.label)
            detail(request.description)
            if let block = turn.secretBlock {
                detail(block.explanation)
                button("Not now", symbol: "xmark", emphasis: .secondary) { await turn.dismissCard() }
            } else {
                SecureField(request.placeholder.flatMap { $0.isEmpty ? nil : $0 } ?? request.label, text: $secret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                    .padding(10)
                    .background(Color(uiColor: .appRaised), in: RoundedRectangle(cornerRadius: 8))
                    .submitLabel(.send)
                    .onSubmit(sendSecret)
                Text("Sent encrypted to your computer: only it can read it.")
                    .font(AppFont.caption())
                    .foregroundStyle(.appSecondary)
                HStack(spacing: 8) {
                    button("Not now", symbol: "xmark", emphasis: .secondary) { await turn.dismissCard() }
                    Button(action: sendSecret) {
                        Label("Send", systemImage: "lock.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.chatDecision(.primary))
                    .disabled(turn.isAnsweringCard || secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func sendSecret() {
        Self.send(&secret, to: turn)
    }

    /// Takes the typed secret out of the field before it goes: a refusal leaves the field empty, to type again.
    static func send(_ secret: inout String, to turn: SquaddChatTurnCoordinator) {
        let value = secret
        secret = ""
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { _ = await turn.provideSecret(value) }
    }

    // MARK: Sign-in

    private func signInCard(_ request: SquaddSignInCard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(symbol: "person.badge.key.fill", title: String(localized: "Sign in to \(request.site)"))
            detail(request.reason)
            detail(Self.signInPlace(request.place))
            HStack(spacing: 8) {
                button("Cancel", symbol: "xmark", emphasis: .secondary) { await turn.dismissCard() }
                button("Done", symbol: "checkmark", emphasis: .primary) { await turn.finishSignIn() }
            }
        }
    }

    /// Where the person signs in: the agent's own browser keeps its sign-ins, so one made on this iPhone
    /// would not reach it (`sign-in-request.ts`).
    static func signInPlace(_ place: String?) -> String {
        switch place {
        case "browser": String(localized: "Sign in in the agent's browser on your computer, then tap Done.")
        case "vm": String(localized: "Sign in on the agent's private desktop on your computer, then tap Done.")
        case "cloud": String(localized: "Sign in on the agent's cloud desktop, then tap Done.")
        default: String(localized: "Sign in in a browser on the computer running Squadd Multi-Agents, then tap Done.")
        }
    }

    // MARK: Connector

    private func connectorCard(_ request: SquaddConnectorCard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(symbol: "link", title: String(localized: "Connect \(request.label)"))
            detail(request.description)
            detail(request.error)
            HStack(spacing: 8) {
                button("Not now", symbol: "xmark", emphasis: .secondary) { await turn.dismissCard() }
                if request.status == "connected" {
                    button("Continue", symbol: "arrow.right", emphasis: .primary) { await turn.resumeConnector() }
                } else {
                    Button {
                        Task {
                            await turn.connect { link in
                                _ = try await webAuthenticationSession.authenticate(
                                    using: link, callback: .customScheme("squadd-multi-agents"),
                                    preferredBrowserSession: .shared, additionalHeaderFields: [:])
                            }
                        }
                    } label: {
                        Label("Connect", systemImage: "link").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.chatDecision(.primary))
                    .disabled(turn.isAnsweringCard)
                }
            }
        }
    }

    // MARK: Parts

    private func header(symbol: String, title: String) -> some View {
        Label {
            Text(verbatim: title).font(AppFont.headline())
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
    }

    @ViewBuilder private func detail(_ text: String?) -> some View {
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            Text(verbatim: text)
                .font(AppFont.subheadline())
                .foregroundStyle(.appPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func button(_ title: LocalizedStringKey, symbol: String, emphasis: ChatDecisionButtonStyle.Emphasis,
                        action: @escaping () async -> Bool) -> some View {
        Button {
            Task { _ = await action() }
        } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity)
        }
        .buttonStyle(.chatDecision(emphasis))
        .disabled(turn.isAnsweringCard)
    }
}
