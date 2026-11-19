import UIKit

/// What a bug report needs to know about this install and the active server (#1396), from
/// values the app already has: it makes no request. It holds no server address, name,
/// username, header or credential, so `text` can carry none.
struct SupportReport {
    /// Debug builds, the side-by-side Hermex Branch build, or any other Release build. App Store
    /// and TestFlight builds can't be told apart from inside the app, so both read Release.
    enum Channel: String {
        case debug = "Debug", branch = "Branch", release = "Release"
    }

    var appVersion: String?
    var build: String?
    var channel: Channel
    var iOSVersion: String
    /// iPhone or iPad.
    var device: String
    var serverKind: ServerKind?
    /// The release the server reported at its last saved sign-in; nil for webui servers.
    var serverRelease: String?
    /// The active server's latest Hermes connection attempt, while its connection is current
    /// (#1395). Only its time and each stage's outcome are reported.
    var lastAttempt: HermesAttemptRecord? = nil

    /// The report as plain text: a header line, then one "Key: value" line per field. About's
    /// preview, its Copy, and anything that later hands the report on all read this one string.
    /// English on purpose: it is read by support and by agents, not shown as UI copy.
    var text: String {
        var lines = [
            "Squadd Multi-Agents support details",
            "App version: \(appVersion ?? "unknown") (\(build ?? "unknown"))",
            "Channel: \(channel.rawValue)",
            "iOS: \(iOSVersion)",
            "Device: \(device)",
            "Server kind: \(serverKindName ?? "unknown")",
            "Server release: \(serverRelease ?? "unknown")",
        ]
        if serverKind == .hermes {
            lines.append("Tested server release: \(HermesCompatibility.testedVersion)")
        }
        if let lastAttempt {
            lines.append("Last connection attempt: \(lastAttempt.startedText)")
            lines += HermesAttemptRecord.Stage.allCases.map {
                "Attempt \($0.reportName.lowercased()): \(lastAttempt[$0].reportText)"
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The chat text Troubleshoot with Hermes queues (#1476): a request to triage, then this
    /// report. English like the report; nothing is sent until the user does.
    var troubleshootingPrompt: String {
        """
        I'm having a problem with Squadd Multi-Agents, the iPhone app I use to reach you. Help me \
        triage it from these details.

        \(text)
        """
    }

    private var serverKindName: String? {
        switch serverKind {
        case .hermes: "Squadd"
        case .webui: "webui"
        case nil: nil
        }
    }
}

extension SupportReport {
    /// This install's report for `server`, the active server.
    /// `connections` holds the active server's shared Hermes connection, whose latest attempt
    /// the report carries while it has one.
    @MainActor init(server: ServerAccount?, connections: HermesConnections = .shared) {
        let info = Bundle.main.infoDictionary
        let channel: Channel
        #if DEBUG
        channel = .debug
        #else
        channel = Bundle.main.bundleIdentifier?.hasSuffix(".branch") == true ? .branch : .release
        #endif
        self.init(
            appVersion: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String,
            channel: channel,
            iOSVersion: UIDevice.current.systemVersion,
            device: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
            serverKind: server?.kind,
            serverRelease: server?.serverVersion,
            lastAttempt: server.flatMap { URL(string: $0.id) }.flatMap { connections.lastAttempt(server: $0) }
        )
    }
}
