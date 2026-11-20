import SwiftUI
import UIKit

struct SelectableTextPresentation: Identifiable, Equatable {
    let id: String
    let text: String

    init(id: String, text: String) {
        self.id = id
        self.text = text
    }

}

/// One entry of the message action menu. The SwiftUI menu and the UIKit
/// context-menu interaction both build from this list so they never drift.
struct ChatMessageActionItem: Identifiable {
    enum Kind: Hashable {
        case listen
        case regenerate
        case edit
        case fork
        case copy
        /// A Squadd thread's reactions (#19): a submenu of `reaction` items.
        case react
        case reaction(String)
        /// A Squadd thread's Undo Last Exchange (#20).
        case undo
    }

    let kind: Kind
    let title: String
    let systemImage: String
    let isEnabled: Bool
    /// Shown checked: a reaction this person already put on, which choosing again takes off.
    var isOn = false
    let perform: () -> Void
    /// A submenu's entries; `perform` is unused when there are any.
    var children: [ChatMessageActionItem] = []

    var id: Kind { kind }
}

extension ChatMessageActionItem {
    /// A Squadd thread's React submenu for row `rowID` (#19): each reaction the computer accepts, checked
    /// when this person put it on, so choosing it again takes it off. Nil for a row not stored yet.
    @MainActor
    static func squaddReactions(ofRow rowID: String, in squadd: SquaddChatTurnCoordinator, isEnabled: Bool) -> ChatMessageActionItem? {
        guard squadd.storedID(ofRow: rowID) != nil else { return nil }
        let mine = squadd.marks[rowID]?.mine ?? []
        return ChatMessageActionItem(
            kind: .react, title: String(localized: "React"), systemImage: "face.smiling", isEnabled: isEnabled, perform: {},
            children: SquaddReaction.all.map { emoji in
                ChatMessageActionItem(kind: .reaction(emoji), title: emoji, systemImage: "", isEnabled: true,
                                      isOn: mine.contains(emoji),
                                      perform: { Task { await squadd.toggleReaction(emoji, onRow: rowID) } })
            }
        )
    }
}

extension ChatMessageActionItem {
    /// Undo Last Exchange on a row of a Squadd thread's last exchange (#20); nil on any other row. Off
    /// when that exchange began the thread, which the computer can't undo.
    @MainActor
    static func squaddUndo(ofRow rowID: String, in squadd: SquaddChatTurnCoordinator, isEnabled: Bool) -> ChatMessageActionItem? {
        guard squadd.lastExchangeRowIDs.contains(rowID) else { return nil }
        return ChatMessageActionItem(kind: .undo, title: String(localized: "Undo the last exchange"), systemImage: "arrow.uturn.backward",
                                     isEnabled: isEnabled && squadd.canUndo,
                                     perform: { Task { await squadd.undoLastExchange() } })
    }

    /// What a Squadd thread adds to row `rowID`'s long-press menu: React, then Undo on the last exchange.
    @MainActor
    static func squaddRowItems(ofRow rowID: String, in squadd: SquaddChatTurnCoordinator,
                               isViewingCachedData: Bool, hasActiveStream: Bool) -> [ChatMessageActionItem] {
        [squaddReactions(ofRow: rowID, in: squadd, isEnabled: !isViewingCachedData),
         squaddUndo(ofRow: rowID, in: squadd, isEnabled: !isViewingCachedData && !hasActiveStream)].compactMap { $0 }
    }
}

/// The long-press menu is built from the item list alone, so any transcript
/// that can name its own actions — Sessions, a Bot chat, a group room — gets
/// the same UIKit menu without owning a chat view model.
extension Array where Element == ChatMessageActionItem {
    @MainActor
    func uiMenu() -> UIMenu {
        UIMenu(children: map { item -> UIMenuElement in
            if !item.children.isEmpty {
                return UIMenu(title: item.title, image: UIImage(systemName: item.systemImage), children: item.children.uiMenu().children)
            }
            let action = UIAction(title: item.title, image: UIImage(systemName: item.systemImage)) { _ in
                item.perform()
            }
            if !item.isEnabled {
                action.attributes = .disabled
            }
            if item.isOn { action.state = .on }
            return action
        })
    }
}

struct ChatMessageActionMenu: View {
    let context: MessageActionContext
    let listeningMessageID: String?
    let isViewingCachedData: Bool
    let hasActiveStream: Bool
    let isRegeneratingMessage: Bool
    let isEditingMessage: Bool
    let isForkingMessage: Bool
    let onToggleListening: (MessageActionContext) -> Void
    let onRegenerate: (MessageActionContext) -> Void
    let onEdit: (MessageActionContext) -> Void
    let onFork: (MessageActionContext) -> Void
    let onCopy: (MessageActionContext) -> Void
    /// Entries the chat's backend adds after the shared ones, such as a Squadd thread's reactions.
    var extraItems: [ChatMessageActionItem] = []

    var body: some View {
        ForEach(items) { item in
            if item.children.isEmpty {
                Button {
                    item.perform()
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
                .disabled(!item.isEnabled)
            } else {
                Menu {
                    ForEach(item.children) { child in
                        Button {
                            child.perform()
                        } label: {
                            if child.isOn { Label(child.title, systemImage: "checkmark") } else { Text(child.title) }
                        }
                    }
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
                .disabled(!item.isEnabled)
            }
        }
    }

    /// The actions for this message in display order. Mutating actions are
    /// disabled while the transcript is cached or a stream is active, and absent
    /// where the chat cannot rewrite its history (`MessageActionContext`).
    var items: [ChatMessageActionItem] {
        var items: [ChatMessageActionItem] = []
        let offersHistoryActions = context.offersHistoryActions

        if context.role == .assistant {
            items.append(ChatMessageActionItem(
                kind: .listen,
                title: isListening ? String(localized: "Stop Listening") : String(localized: "Listen"),
                systemImage: isListening ? "speaker.slash" : "speaker.wave.2",
                isEnabled: true,
                perform: { onToggleListening(context) }
            ))
        }

        if context.role == .assistant, offersHistoryActions {
            items.append(ChatMessageActionItem(
                kind: .regenerate,
                title: String(localized: "Regenerate Response"),
                systemImage: "arrow.clockwise",
                isEnabled: !(isViewingCachedData || hasActiveStream || isRegeneratingMessage || isEditingMessage),
                perform: { onRegenerate(context) }
            ))
        }

        if context.role == .user, offersHistoryActions {
            items.append(ChatMessageActionItem(
                kind: .edit,
                title: String(localized: "Edit Message"),
                systemImage: "pencil",
                isEnabled: !(isViewingCachedData || hasActiveStream || isRegeneratingMessage || isEditingMessage),
                perform: { onEdit(context) }
            ))
        }

        if context.offersFork {
            items.append(ChatMessageActionItem(
                kind: .fork,
                title: String(localized: "Fork From Here"),
                systemImage: "arrow.triangle.branch",
                isEnabled: !(isViewingCachedData || hasActiveStream || isForkingMessage),
                perform: { onFork(context) }
            ))
        }
        if context.role == .user {
            items.append(ChatMessageActionItem(
                kind: .copy,
                title: String(localized: "Copy"),
                systemImage: "doc.on.doc",
                isEnabled: true,
                perform: { onCopy(context) }
            ))
        }

        return items + extraItems
    }

    /// The same actions as a UIKit menu, for `ChatMessageContextMenuView`.
    func uiMenu() -> UIMenu {
        items.uiMenu()
    }

    private var isListening: Bool {
        listeningMessageID == context.messageID
    }
}

struct SelectableTextPresentationView: View {
    let selection: SelectableTextPresentation

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableTextView(text: selection.text)
                .accessibilityIdentifier("selectable-response-text")
                .background(Color(.appCanvas))
                .themedPageBackground()
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
    }
}

struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .appCanvas
        textView.font = .app(forTextStyle: .body, at: context.environment.dynamicTypeSize)
        textView.adjustsFontForContentSizeCategory = true
        // A wrapped UITextView does not inherit SwiftUI's layoutDirection; `.natural`
        // lets each paragraph align by its own writing direction so RTL message text
        // reads right-aligned while LTR stays left-aligned (issue #294).
        textView.textAlignment = .natural
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 32, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        textView.alwaysBounceVertical = true
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
    }
}

struct EditMessageSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var editDraft: String
    let onSubmit: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $editDraft)
                    .font(AppFont.body())
                    .padding()
                    .scrollContentBackground(.hidden)
                    .background(Color(.appGroupedCanvas))
            }
            .themedPageBackground()
            .navigationTitle("Edit Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        dismiss()
                        onSubmit()
                    }
                    .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .themedPageBackground()
        .presentationDetents([.medium, .large])
        .adaptiveFormPresentation()
    }
}
