import ActivityKit
import SwiftUI
import WidgetKit

/// A Squadd agent's Live Activity (#31) on the Lock Screen and in the Dynamic Island. Every tap opens
/// the agent's thread; the content is the companion's or the app's `SquaddBotActivityProps`.
struct SquaddBotLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveActivityAttributes.self) { context in
            let props = SquaddBotActivityProps(context.state)
            Group {
                if let props {
                    SquaddBotActivityCard(props: props, isStale: context.isStale)
                } else {
                    Text(verbatim: "Squadd").font(.headline)
                }
            }
            .padding(16)
            .widgetURL(props?.tapURL(startedAt: context.attributes.url) ?? URL(string: context.attributes.url))
        } dynamicIsland: { context in
            let props = SquaddBotActivityProps(context.state)
            let url = props?.tapURL(startedAt: context.attributes.url) ?? URL(string: context.attributes.url)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    if let props { SquaddBotActivityCard(props: props, isStale: context.isStale) }
                }
            } compactLeading: {
                if let props { SquaddBotActivityMark(props: props, size: 22) }
            } compactTrailing: {
                if let props {
                    if props.needsYou {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(props.tint)
                    } else if !context.isStale {
                        Text(props.sinceDate, style: .timer)
                            .monospacedDigit()
                            .frame(maxWidth: 44)
                    }
                }
            } minimal: {
                if let props { SquaddBotActivityMark(props: props, size: 22) }
            }
            .widgetURL(url)
        }
    }
}
