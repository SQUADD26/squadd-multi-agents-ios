import ActivityKit
import Foundation
import OSLog

/// The agent a Squadd Live Activity follows, and where it runs.
struct SquaddActivityBot: Equatable {
    let botId: String
    let name: String
    let threadId: String
    let server: URL
}

/// What an open Squadd chat tells the Live Activity as its stream goes (#31).
@MainActor protocol SquaddLiveActivityDriving: AnyObject {
    /// The bot works (`ask` nil) or waits on the person (`approval`, `question`, ...).
    func show(_ bot: SquaddActivityBot, ask: String?)
    func end(botId: String)
}

/// Squadd agents' Live Activities (#31). The open chat's stream starts, updates and ends one per
/// agent while the app runs; each activity's push token, and the push-to-start token, are
/// registered on the computers with push on (`PUT /api/push/activity`), whose pushes keep them
/// current once the app is closed. With nothing left to register the registration is deleted.
@MainActor final class SquaddLiveActivities: SquaddLiveActivityDriving {
    static let shared = SquaddLiveActivities()

    private static let logger = Logger(subsystem: "com.squaddcrm.multiagents", category: "squadd-live-activity")

    private let clients: @MainActor () -> [URL: SquaddCompanionClient]
    /// Each activity's push token, by bot, and the computer it started on (nil: started by a push,
    /// which names none).
    var tokens: [String: (token: String, server: URL?)] = [:]
    var startToken: String?
    private var observers: [String: Task<Void, Never>] = [:]
    private var watching: Task<Void, Never>?
    private var syncing: Task<Void, Never>?

    init(clients: @escaping @MainActor () -> [URL: SquaddCompanionClient] = SquaddPushRegistrar.pairedClients) {
        self.clients = clients
    }

    /// Launch: adopts the activities still on screen and those a push starts, and follows the
    /// push-to-start token.
    func watch() {
        guard watching == nil else { return }
        Activity<LiveActivityAttributes>.activities.forEach { observe($0) }
        watching = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor [weak self] in
                    for await token in Activity<LiveActivityAttributes>.pushToStartTokenUpdates {
                        self?.startToken = Self.hex(token)
                        self?.sync()
                    }
                }
                group.addTask { @MainActor [weak self] in
                    for await activity in Activity<LiveActivityAttributes>.activityUpdates { self?.observe(activity) }
                }
            }
        }
    }

    func show(_ bot: SquaddActivityBot, ask: String?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let current = activity(for: bot.botId)
        let previous = current.flatMap { SquaddBotActivityProps($0.content.state) }
        let link = SquaddThreadLink(threadID: bot.threadId, botID: bot.botId, server: bot.server).url?.absoluteString ?? ""
        var props = SquaddBotActivityProps(botId: bot.botId, name: bot.name, ask: ask, since: Date(), link: link)
        // A repeated frame keeps counting from when the bot entered this state.
        if let previous, previous.kind == props.kind, previous.ask == ask { props.since = previous.since }
        guard previous != props else { return }
        let content = ActivityContent(state: props.contentState, staleDate: Date().addingTimeInterval(15 * 60))
        if let current {
            Task { await current.update(content) }
            return
        }
        do {
            let started = try Activity.request(attributes: LiveActivityAttributes(url: link), content: content, pushType: .token)
            observe(started, server: bot.server)
        } catch {
            Self.logger.error("Live Activity not started: \(error.localizedDescription, privacy: .public)")
        }
    }

    func end(botId: String) {
        guard let current = activity(for: botId) else { return }
        Task { await current.end(nil, dismissalPolicy: .immediate) }
    }

    /// Records a bot's activity token (nil: the activity is gone) and registers the change.
    func record(token: String?, botId: String, server: URL?) {
        tokens[botId] = token.map { ($0, server) }
        sync()
    }

    /// Registers what is current on every computer with push on, one sync after another.
    func sync() {
        syncing = Task { [previous = syncing, weak self] in
            await previous?.value
            await self?.syncNow()
        }
    }

    /// One computer's registration: the start token and the activities it can reach (its own, and
    /// those a push started, which name no computer).
    func registration(for server: URL) -> SquaddActivityRegistration {
        let activities = tokens.filter { $0.value.server.map { SquaddThreadLink.sameServer($0.absoluteString, server.absoluteString) } ?? true }
            .sorted { $0.key < $1.key }
            .map { SquaddActivityRegistration.Activity(botId: $0.key, token: $0.value.token) }
        return SquaddActivityRegistration(startToken: startToken, activities: activities)
    }

    func syncNow() async {
        for (server, client) in clients() {
            guard (try? await client.pushDevice())?.isRegistered == true else { continue }
            let registration = registration(for: server)
            do {
                if registration.isEmpty { try await client.unregisterActivity() } else { try await client.registerActivity(registration) }
            } catch {
                Self.logger.error("Live Activity registration failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func activity(for botId: String) -> Activity<LiveActivityAttributes>? {
        Activity<LiveActivityAttributes>.activities.first {
            $0.activityState == .active && SquaddBotActivityProps($0.content.state)?.botId == botId
        }
    }

    /// Follows one activity's push token until it ends.
    private func observe(_ activity: Activity<LiveActivityAttributes>, server: URL? = nil) {
        guard observers[activity.id] == nil, let botId = SquaddBotActivityProps(activity.content.state)?.botId else { return }
        let server = server ?? URLComponents(string: activity.attributes.url)?.queryItems?
            .first { $0.name == "server" }?.value.flatMap(URL.init(string:))
        observers[activity.id] = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor [weak self] in
                    for await token in activity.pushTokenUpdates { self?.record(token: Self.hex(token), botId: botId, server: server) }
                }
                group.addTask { @MainActor [weak self] in
                    for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                        self?.observers[activity.id]?.cancel()
                        self?.observers[activity.id] = nil
                        self?.record(token: nil, botId: botId, server: server)
                        return
                    }
                }
            }
        }
    }

    private nonisolated static func hex(_ token: Data) -> String { token.map { String(format: "%02x", $0) }.joined() }
}
