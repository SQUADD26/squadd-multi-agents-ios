import Foundation
import Observation

/// Screen state for making a Squadd agent or changing one: its name, title and description, its
/// model, and (once it exists) its avatar. Only the fields a paired device may set show here;
/// the rest (approval level, computer, tools, department) stays on the desktop.
/// Nothing reads as saved before the companion says so: a refused change puts back what the
/// agent had and shows the computer's reason.
@MainActor @Observable
final class SquaddAgentEditor {
    struct Profile: Equatable {
        var name = ""
        var title = ""
        var description = ""
        var instructions = ""
    }

    /// Nil while making a new agent.
    private(set) var bot: SquaddBot?
    var draft = Profile()
    private(set) var model: SquaddModelSelection?
    private(set) var modelGroups: [ModelCatalogGroup] = []
    private(set) var modelsStatus: ModelPickerLoadStatus = .loading
    /// The model being applied, for the picker's spinner.
    private(set) var pendingModel: SquaddModelSelection?
    private(set) var modelError: String?
    private(set) var isSaving = false
    var avatarPrompt = ""
    private(set) var isGeneratingAvatar = false
    private(set) var errorMessage: String?

    @ObservationIgnored let client: SquaddCompanionClient
    /// Runs after every change the companion accepted, so the agent list shows it.
    @ObservationIgnored private let onChange: () -> Void
    @ObservationIgnored private let onUnpaired: () -> Void

    init(client: SquaddCompanionClient, bot: SquaddBot? = nil, onChange: @escaping () -> Void = {},
         onUnpaired: @escaping () -> Void = {}) {
        self.client = client
        self.onChange = onChange
        self.onUnpaired = onUnpaired
        if let bot { show(bot) }
    }

    var isNew: Bool { bot == nil }

    var canSave: Bool {
        !isSaving && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (isNew || draft != Self.profile(of: bot))
    }

    /// The selected model's name as the picker lists it.
    var modelLabel: String? {
        guard let model else { return nil }
        return modelGroups.lazy.flatMap(\.allModels)
            .first { $0.id == model.model && $0.providerID == model.instanceId }?.displayName ?? model.model
    }

    func loadModels() async {
        do {
            modelGroups = try await client.instances().filter(\.isAvailable).compactMap { instance in
                let options = { (older: Bool) in
                    instance.models.filter { ($0.older == true) == older }.map {
                        ModelCatalogOption(id: $0.id, displayName: $0.label ?? $0.id, providerID: instance.instanceId)
                    }
                }
                let models = options(false), older = options(true)
                guard !(models.isEmpty && older.isEmpty) else { return nil }
                return ModelCatalogGroup(id: instance.instanceId, name: instance.displayName ?? instance.instanceId,
                                         providerID: instance.instanceId, models: models, extraModels: older)
            }
            modelsStatus = .loaded
        } catch {
            modelsStatus = .failed(message(for: error))
        }
    }

    /// Makes the agent, or saves its profile. Returns whether the companion accepted it.
    @discardableResult
    func save() async -> Bool {
        guard canSave else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let profile = Profile(name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                              title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                              description: draft.description.trimmingCharacters(in: .whitespacesAndNewlines),
                              instructions: draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            if let bot {
                show(try await client.updateProfile(botID: bot.id, name: profile.name, title: profile.title,
                                                    description: profile.description, instructions: profile.instructions))
            } else {
                show(try await client.createBot(name: profile.name, title: profile.title,
                                                description: profile.description, instructions: profile.instructions,
                                                model: model))
            }
            onChange()
            return true
        } catch {
            // A new agent keeps what was typed; an existing one goes back to what the computer holds.
            if let bot { draft = Self.profile(of: bot) }
            errorMessage = message(for: error)
            return false
        }
    }

    /// A new agent just takes the pick; an existing one keeps its model until the computer accepts it.
    func selectModel(_ option: ModelCatalogOption) async {
        guard let instanceId = option.providerID else { return }
        let selection = SquaddModelSelection(instanceId: instanceId, model: option.id)
        modelError = nil
        guard let bot else {
            model = selection
            return
        }
        guard selection != model, pendingModel == nil else { return }
        pendingModel = selection
        defer { pendingModel = nil }
        do {
            show(try await client.setModel(botID: bot.id, selection))
            onChange()
        } catch {
            modelError = message(for: error)
        }
    }

    func generateAvatar() async {
        let prompt = avatarPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bot, !prompt.isEmpty, !isGeneratingAvatar else { return }
        isGeneratingAvatar = true
        errorMessage = nil
        defer { isGeneratingAvatar = false }
        do {
            show(try await client.generateAvatar(botID: bot.id, prompt: prompt))
            avatarPrompt = ""
            onChange()
        } catch {
            errorMessage = message(for: error)
        }
    }

    private func show(_ bot: SquaddBot) {
        self.bot = bot
        draft = Self.profile(of: bot)
        model = bot.modelSelection
    }

    private static func profile(of bot: SquaddBot?) -> Profile {
        Profile(name: bot?.name ?? "", title: bot?.title ?? "", description: bot?.description ?? "",
                instructions: bot?.soul ?? "")
    }

    private func message(for error: Error) -> String {
        switch error {
        case SquaddError.refused(let reason): return reason
        case SquaddError.unpaired:
            // The route swaps this screen for the pair-again one.
            onUnpaired()
            return String(localized: "Can't Reach the Computer")
        default: return String(localized: "Can't Reach the Computer")
        }
    }
}
// misura avvio
