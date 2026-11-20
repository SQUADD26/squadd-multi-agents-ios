import SwiftUI
import UIKit

/// Makes a Squadd agent (`bot` nil) or changes one: name, title, description, instructions, model
/// and an avatar drawn from a description. The avatar route needs the agent's id, so a new agent
/// stays open here once made, with its avatar section. Mirrors the desktop's bot card, limited
/// to what the companion lets a paired iPhone change.
struct SquaddAgentEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var editor: SquaddAgentEditor
    @State private var isPickingModel = false

    init(client: SquaddCompanionClient, bot: SquaddBot?, onChange: @escaping () -> Void, onUnpaired: @escaping () -> Void) {
        self.init(editor: SquaddAgentEditor(client: client, bot: bot, onChange: onChange, onUnpaired: onUnpaired))
    }

    init(editor: SquaddAgentEditor) {
        _editor = State(initialValue: editor)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let bot = editor.bot {
                    avatarSection(bot)
                }
                Section {
                    TextField("Name", text: $editor.draft.name)
                        .textInputAutocapitalization(.words)
                    TextField("Title", text: $editor.draft.title)
                    TextField("Description", text: $editor.draft.description, axis: .vertical)
                        .lineLimit(2...6)
                }
                Section {
                    TextField("Instructions", text: $editor.draft.instructions, axis: .vertical)
                        .lineLimit(3...10)
                } footer: {
                    if let errorMessage = editor.errorMessage {
                        Text(verbatim: errorMessage)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button { isPickingModel = true } label: {
                        LabeledContent("Model") {
                            Text(verbatim: editor.modelLabel ?? String(localized: "Default"))
                        }
                    }
                    .foregroundStyle(.appPrimary)
                } footer: {
                    if let modelError = editor.modelError {
                        Text(verbatim: modelError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(editor.isSaving)
            .navigationTitle(editor.isNew ? Text("New Agent") : Text("Edit Agent"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(editor.isNew ? LocalizedStringKey("Cancel") : "Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if editor.isSaving {
                        ProgressView()
                    } else {
                        Button(editor.isNew ? LocalizedStringKey("Create") : "Save") {
                            Task { await editor.save() }
                        }
                        .disabled(!editor.canSave)
                    }
                }
            }
            .sheet(isPresented: $isPickingModel) {
                ModelPickerSheet(
                    configuration: .squaddAgent,
                    modelGroups: editor.modelGroups,
                    selectedModelID: editor.model?.model,
                    selectedModelProviderID: editor.model?.instanceId,
                    isSelected: { $0.id == editor.model?.model && $0.providerID == editor.model?.instanceId },
                    loadStatus: editor.modelsStatus,
                    inFlightKey: editor.pendingModel.map { ModelFavoriteKey(modelID: $0.model, providerID: $0.instanceId) },
                    isSelectionDisabled: editor.pendingModel != nil,
                    errorMessage: editor.modelError,
                    onSelect: { option in
                        Task {
                            await editor.selectModel(option)
                            if editor.modelError == nil { isPickingModel = false }
                        }
                    }
                )
            }
            .task { await editor.loadModels() }
        }
    }

    private func avatarSection(_ bot: SquaddBot) -> some View {
        Section {
            HStack {
                Spacer()
                SquaddAgentAvatar(client: editor.client, path: bot.avatarUrl, name: bot.name ?? "", size: 88)
                Spacer()
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            TextField("A tiny orange cat holding a wrench", text: $editor.avatarPrompt, axis: .vertical)
                .lineLimit(1...3)
            if editor.isGeneratingAvatar {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Generating. This can take a few minutes.").font(AppFont.subheadline())
                }
            } else {
                Button("Generate") { Task { await editor.generateAvatar() } }
                    .disabled(editor.avatarPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Avatar")
        }
    }
}

/// An agent's avatar from the companion, read with the device token, or its initial while there
/// is none. Images are cached per server and path: a new avatar always gets a new path.
struct SquaddAgentAvatar: View {
    let client: SquaddCompanionClient
    let path: String?
    let name: String
    var size: CGFloat = 28
    /// The agent's mascot color (`SquaddBot.color`): without a picture it is drawn as the desktop's
    /// colored cursor instead of an initial.
    var color: String?
    @State private var image: UIImage?

    /// The desktop's mascot palette (`openmausbot/src/lib/mascot.ts`, `MAUS_COLORS`).
    static let mascotColors: [String: String] = [
        "green": "#009957", "blue": "#377FE6", "red": "#D94B52", "orange": "#E78531", "purple": "#8057C8",
        "cyan": "#0EA5C6", "pink": "#D84F8B", "yellow": "#D8A729", "teal": "#01A492", "coral": "#E5634E",
        "silver": "#A8ADB4", "chrome": "#B3BAC4",
    ]

    @MainActor private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let hex = color.flatMap({ Self.mascotColors[$0] }) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: size * 0.72, weight: .semibold))
                    .foregroundStyle(HeaderLogoColor.color(for: hex))
            } else {
                Circle().fill(Color.accentColor.opacity(0.18))
                Text(verbatim: name.first.map { String($0).uppercased() } ?? "")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: path) {
            guard let path else {
                image = nil
                return
            }
            let key = (client.server.absoluteString + path) as NSString
            if let cached = Self.cache.object(forKey: key) {
                image = cached
                return
            }
            guard let data = try? await client.avatarData(path: path), let loaded = UIImage(data: data) else { return }
            Self.cache.setObject(loaded, forKey: key)
            image = loaded
        }
    }
}
