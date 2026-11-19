import SwiftUI

/// The team's shared memory on the computer: read, add, edit and delete (#28). The list only
/// changes with the computer's answer, so a refused change never shows as saved.
struct SquaddTeamMemoryPage: View {
    let model: SquaddSettingsModel
    @State private var editing: Editing?
    @State private var deleting: SquaddMemoryEntry?

    /// The editor's subject: a new memory, or an existing one.
    struct Editing: Identifiable {
        let entry: SquaddMemoryEntry?
        var id: String { entry?.id ?? "new" }
    }

    var body: some View {
        AppList {
            if let error = model.memoryError, editing == nil {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            if !model.memory.isEmpty {
                Section {
                    ForEach(model.memory) { entry in
                        Button { editing = Editing(entry: entry) } label: { row(entry) }
                            .foregroundStyle(.primary)
                            .swipeActions {
                                Button(String(localized: "Delete"), role: .destructive) { deleting = entry }
                            }
                    }
                } appFooter: {
                    Text("Every agent on the computer reads these facts.")
                }
            }
        }
        .settingsPage(String(localized: "Team Memory"))
        .overlay { SquaddPhaseOverlay(phase: model.memoryPhase, isEmpty: model.memory.isEmpty,
                                      emptyTitle: String(localized: "No Memories Yet"), retry: model.loadMemory) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = Editing(entry: nil) } label: { Label("Add Memory", systemImage: "plus") }
                    .disabled(model.memoryPhase != .loaded)
            }
        }
        .refreshable { await model.loadMemory() }
        .task { await model.loadMemory() }
        .sheet(item: $editing) { SquaddMemoryEditor(model: model, entry: $0.entry) }
        .confirmationDialog(String(localized: "Delete this memory?"), isPresented: .init(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible, presenting: deleting) { entry in
            Button(String(localized: "Delete"), role: .destructive) {
                Task { await model.changeMemory { try await $0.deleteMemory(entry) } }
            }
        } message: { _ in
            Text("The agents on the computer will no longer know it.")
        }
    }

    private func row(_ entry: SquaddMemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(entry.name)
                Spacer()
                Text(SquaddMemoryEditor.title(ofKind: entry.kind))
                    .font(AppFont.caption())
                    .foregroundStyle(.appSecondary)
            }
            if let detail = entry.detail, !detail.isEmpty {
                Text(detail)
                    .font(AppFont.footnote())
                    .foregroundStyle(.appSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edits this memory.")
    }
}

/// Adds a memory, or edits one, and closes only once the computer saved it.
struct SquaddMemoryEditor: View {
    let model: SquaddSettingsModel
    let entry: SquaddMemoryEntry?
    @Environment(\.dismiss) private var dismiss
    @State private var kind: String
    @State private var name: String
    @State private var detail: String
    @State private var isSaving = false

    init(model: SquaddSettingsModel, entry: SquaddMemoryEntry?) {
        self.model = model
        self.entry = entry
        _kind = State(initialValue: entry?.kind ?? "term")
        _name = State(initialValue: entry?.name ?? "")
        _detail = State(initialValue: entry?.detail ?? "")
    }

    static func title(ofKind kind: String) -> String {
        switch kind {
        case "person": String(localized: "Person")
        case "place": String(localized: "Place")
        case "decision": String(localized: "Decision")
        case "term": String(localized: "Term")
        default: kind
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            AppForm {
                Section {
                    Picker(String(localized: "Kind"), selection: $kind) {
                        ForEach(SquaddMemoryEntry.kinds, id: \.self) { Text(Self.title(ofKind: $0)).tag($0) }
                    }
                    TextField(String(localized: "Name"), text: $name)
                    TextField(String(localized: "Detail"), text: $detail, axis: .vertical)
                        .lineLimit(3...8)
                }
                if let error = model.memoryError {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
            }
            .navigationTitle(entry == nil ? String(localized: "New Memory") : String(localized: "Edit Memory"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(trimmedName.isEmpty)
                    }
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let (kind, name, detail) = (kind, trimmedName, detail.trimmingCharacters(in: .whitespacesAndNewlines))
        let saved = await model.changeMemory { client in
            // After a conflict the list holds the computer's latest revision: a second Save applies over it.
            if let entry { try await client.editMemory(latest(entry), kind: kind, name: name, detail: detail) }
            else { try await client.addMemory(kind: kind, name: name, detail: detail) }
        }
        if saved { dismiss() }
    }

    private func latest(_ entry: SquaddMemoryEntry) -> SquaddMemoryEntry {
        model.memory.first { $0.id == entry.id } ?? entry
    }
}
