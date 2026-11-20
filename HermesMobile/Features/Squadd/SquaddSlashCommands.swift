import Foundation

/// What a Squadd agent's `/` panel offers and how a picked command is sent, the desktop's way
/// (openmausbot `src/lib/composer-commands.ts`, `shared/skill-command.ts`).
///
/// The built-ins are the desktop's four (`Composer.tsx`): `/goal` always; `/setup` and `/burst` when the
/// agent's engine runs the agent tools; `/learn` when it does and the computer allows drafting skills.
/// Every other `/name` is one of the agent's enabled skills,
/// which the computer expands from the message text, as it does `/learn`, `/setup` and `/burst`.
/// Only `/goal` changes the send: its text goes without the prefix, with `mode: "goal"`.
/// `/compact` is the app's: it asks the companion to compact the thread (`ChatViewModel`).
enum SquaddSlashCommands {
    static let builtInNames = Set(["goal", "learn", "setup", "burst", "undo", "compact"]).union(forkNames)
    /// The app's own commands, which fork the thread the way Hermes chats' do (#20).
    static let forkNames: Set<String> = ["branch", "fork"]

    static func scope(runsAgents: Bool, authorsSkills: Bool) -> SlashCommandScope {
        let goal = SlashCommand(name: "goal", description: String(localized: "Keep this agent working until the goal is complete"),
                                argHint: String(localized: "goal"))
        let learn = SlashCommand(name: "learn", description: String(localized: "Draft a reusable skill from this conversation"))
        let setup = SlashCommand(name: "setup", description: String(localized: "Have this agent interview you and set itself up"))
        let burst = SlashCommand(name: "burst", description: String(localized: "Run many parts of a job at once, then merge the results"))
        let undo = SlashCommand(name: "undo", description: String(localized: "Undo the last exchange"))
        let compact = SlashCommand(name: "compact", description: String(localized: "Compress session context"))
        let branch = SlashCommand(name: "branch", description: String(localized: "Fork the conversation"))
        let fork = SlashCommand(name: "fork", description: String(localized: "Alias for \("/branch")"))
        return SlashCommandScope(builtins: [goal] + (runsAgents && authorsSkills ? [learn] : []) + (runsAgents ? [setup, burst] : [])
                                 + [branch, fork, undo, compact])
    }

    /// The agent's enabled skills the desktop offers as `/name`: a skill name
    /// (`^[a-z0-9]+(-[a-z0-9]+)*$`, up to 64 characters) that isn't a built-in, by name.
    static func skills(_ skills: [SquaddSkill]) -> [SkillSlashSuggestion] {
        skills
            .filter { $0.enabled == true && isSkillName($0.name) && !builtInNames.contains($0.name) }
            .sorted { $0.name < $1.name }
            .map { SkillSlashSuggestion(name: $0.name, category: nil, description: $0.description) }
    }

    /// The text and mode a typed message is sent with: `/goal rest` is the goal `rest` in goal
    /// mode; anything else goes as typed. `mode` is nil for a plain message.
    static func outgoing(_ text: String) -> (text: String, mode: String?) {
        guard let match = text.wholeMatch(of: /(?i)\/goal(?:\s+([\s\S]*))?/) else { return (text, nil) }
        return (String(match.1 ?? "").trimmingCharacters(in: .whitespacesAndNewlines), "goal")
    }

    private static func isSkillName(_ name: String) -> Bool {
        name.count <= 64 && name.wholeMatch(of: /[a-z0-9]+(?:-[a-z0-9]+)*/) != nil
    }
}
