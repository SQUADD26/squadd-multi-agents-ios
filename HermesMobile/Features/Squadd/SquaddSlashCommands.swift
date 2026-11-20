import Foundation

/// What a Squadd agent's `/` panel offers and how a picked command is sent, the desktop's way
/// (openmausbot `src/lib/composer-commands.ts`, `shared/skill-command.ts`).
///
/// The built-ins are the desktop's four. Every other `/name` is one of the agent's enabled skills,
/// which the computer expands from the message text, as it does `/learn`, `/setup` and `/burst`.
/// Only `/goal` changes the send: its text goes without the prefix, with `mode: "goal"`.
enum SquaddSlashCommands {
    static let builtInNames: Set<String> = ["goal", "learn", "setup", "burst"]

    static let scope = SlashCommandScope(builtins: [
        SlashCommand(name: "goal", description: String(localized: "Keep this agent working until the goal is complete"),
                     argHint: String(localized: "goal")),
        SlashCommand(name: "learn", description: String(localized: "Draft a reusable skill from this conversation")),
        SlashCommand(name: "setup", description: String(localized: "Have this agent interview you and set itself up")),
        SlashCommand(name: "burst", description: String(localized: "Run many parts of a job at once, then merge the results")),
    ])

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
