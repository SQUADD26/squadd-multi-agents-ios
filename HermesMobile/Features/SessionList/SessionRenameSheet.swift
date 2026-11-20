import SwiftUI

struct SessionRenameSheet: View {
    let title: LocalizedStringKey
    let fieldLabel: LocalizedStringKey
    let isSaving: Bool
    /// Why the server refused the last title, shown under the field so the sheet stays open
    /// with it; a Hermes host's own message (#1048).
    let errorMessage: String?
    let onCancel: () -> Void
    let onSave: (String) -> Void

    @State private var sessionTitle: String
    @FocusState private var titleIsFocused: Bool

    init(
        title: LocalizedStringKey = "Rename Session",
        fieldLabel: LocalizedStringKey = "Session title",
        initialTitle: String,
        isSaving: Bool,
        errorMessage: String? = nil,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) -> Void
    ) {
        self.title = title
        self.fieldLabel = fieldLabel
        self.isSaving = isSaving
        self.errorMessage = errorMessage
        self.onCancel = onCancel
        self.onSave = onSave
        _sessionTitle = State(initialValue: initialTitle)
    }

    var body: some View {
        NavigationStack {
            AppForm {
                Section {
                    TextField(fieldLabel, text: $sessionTitle)
                        .textInputAutocapitalization(.sentences)
                        .focused($titleIsFocused)
                        .disabled(isSaving)
                } appFooter: {
                    if let errorMessage {
                        Text(verbatim: errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .themedPageBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isSaving)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSave(trimmedSessionTitle)
                    } label: {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(trimmedSessionTitle.isEmpty || isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .onAppear {
                titleIsFocused = true
            }
            .onChange(of: errorMessage) {
                if let errorMessage { AccessibilityNotification.Announcement(errorMessage).post() }
            }
        }
        .adaptiveFormPresentation()
    }

    private var trimmedSessionTitle: String {
        sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
