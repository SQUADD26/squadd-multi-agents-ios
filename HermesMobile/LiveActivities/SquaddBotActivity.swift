import ActivityKit
import SwiftUI

/// A Squadd agent's Live Activity (#31). The type and its content state are named and shaped as the
/// companion's pushes address them (`openmausbot/cloudflare/control-plane/src/push-activity.ts`):
/// `attributes-type` `LiveActivityAttributes` with `{url}`, and `content-state` `{name, props}` where
/// `props` is `SquaddBotActivityProps` as JSON. Shared by the app and the widget extension.
struct LiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Always `BotActivity`, the companion's name for this activity.
        var name = SquaddBotActivityProps.activityName
        var props: String
    }

    /// The thread the activity opens; one the app started also names its computer (`server=`).
    var url: String
}

/// What a bot's activity shows: names, kind and a status line, never message text. Every field the
/// companion might drop is optional; the earlier shape carries `headline` instead of `status`.
struct SquaddBotActivityProps: Codable, Equatable {
    static let activityName = "BotActivity"
    /// The companion's neutral look (`FALLBACK_VISUAL`).
    static let fallbackColor = "#7C5CFF"

    var version: Int?
    var botId: String
    var name: String
    var color: String?
    var body: String?
    /// `working` or `needsYou`.
    var kind: String
    /// `approval`, `question`, `signIn` or `other`, when the bot needs the person.
    var ask: String?
    var status: String?
    var headline: String?
    /// When the current kind began, in epoch milliseconds.
    var since: Double
    var link: String

    var needsYou: Bool { kind == "needsYou" }
    var sinceDate: Date { Date(timeIntervalSince1970: since / 1000) }

    /// The status line: the pushed words, else this iPhone's own.
    var statusLine: String { status ?? Self.status(ask: needsYou ? ask ?? "other" : nil) }

    /// This iPhone's words for each state, which it also registers with the companion.
    static func status(ask: String?) -> String {
        switch ask {
        case nil: String(localized: "Working")
        case "approval"?: String(localized: "Needs your approval")
        case "question"?: String(localized: "Has a question")
        case "signIn"?: String(localized: "Needs you to sign in")
        default: String(localized: "Needs you")
        }
    }

    init(botId: String, name: String, ask: String?, since: Date, link: String) {
        version = 1
        self.botId = botId
        self.name = name
        color = Self.fallbackColor
        body = "cursor"
        kind = ask == nil ? "working" : "needsYou"
        self.ask = ask
        status = Self.status(ask: ask)
        self.since = (since.timeIntervalSince1970 * 1000).rounded()
        self.link = link
    }

    init?(_ state: LiveActivityAttributes.ContentState) {
        guard let props = try? JSONDecoder().decode(Self.self, from: Data(state.props.utf8)) else { return nil }
        self = props
    }

    var contentState: LiveActivityAttributes.ContentState {
        LiveActivityAttributes.ContentState(props: (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}")
    }

    /// Where a tap goes: the pushed link (`openmausbot://chat/<thread>`, no computer), with the
    /// computer the activity started on, so another paired computer never opens it.
    func tapURL(startedAt attributesURL: String) -> URL? {
        guard var components = URLComponents(string: link) else { return URL(string: attributesURL) }
        if components.queryItems?.contains(where: { $0.name == "server" }) != true,
           let server = URLComponents(string: attributesURL)?.queryItems?.first(where: { $0.name == "server" }) {
            components.queryItems = (components.queryItems ?? []) + [server]
        }
        return components.url
    }

    var tint: Color { Color(squaddHex: color ?? Self.fallbackColor) ?? .purple }
}

extension Color {
    /// `#RRGGBB`, nil for anything else.
    init?(squaddHex hex: String) {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/// The lock screen and expanded Dynamic Island card: the agent's mark, name, status and how long it
/// has been in that state. Reduce Motion swaps the content transitions for none.
struct SquaddBotActivityCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let props: SquaddBotActivityProps
    let isStale: Bool

    var body: some View {
        HStack(spacing: 12) {
            SquaddBotActivityMark(props: props, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(props.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(props.statusLine)
                    .font(.subheadline)
                    .foregroundStyle(props.needsYou ? AnyShapeStyle(props.tint) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if !isStale {
                Text(props.sinceDate, style: .timer)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 64, alignment: .trailing)
            }
        }
        .contentTransition(reduceMotion ? .identity : .opacity)
        .accessibilityElement(children: .combine)
    }
}

/// The agent's mark: its color with its initial, or a raised hand when it needs the person.
struct SquaddBotActivityMark: View {
    let props: SquaddBotActivityProps
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(props.tint)
            if props.needsYou {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: size * 0.45, weight: .semibold))
            } else {
                Text(props.name.prefix(1).uppercased())
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The compact Dynamic Island's trailing side: a mark when the agent needs the person, else how
/// long it has worked.
struct SquaddBotActivityCompactTrailing: View {
    let props: SquaddBotActivityProps
    let isStale: Bool

    var body: some View {
        if props.needsYou {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(props.tint)
        } else if !isStale {
            Text(props.sinceDate, style: .timer)
                .monospacedDigit()
                .frame(maxWidth: 44)
        }
    }
}
