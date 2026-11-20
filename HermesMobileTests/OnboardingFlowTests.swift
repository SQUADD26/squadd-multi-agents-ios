import SwiftUI
import XCTest
@testable import HermesMobile

final class OnboardingFlowTests: XCTestCase {
    func testCopyReminderOnlyAppliesToAgentPromptPageWithoutCopy() {
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex,
                shownPrompt: .hermes,
                copiedPrompts: []
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex,
                shownPrompt: .hermes,
                copiedPrompts: [.hermes]
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex,
                shownPrompt: .hermes,
                copiedPrompts: [],
                bypassedPrompts: [.hermes]
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex + 1,
                shownPrompt: .hermes,
                copiedPrompts: []
            )
        )
    }

    /// "I don't have one yet" shows the setup prompt, then the private-network page, and its
    /// last Continue opens the Add Server sheet (#1540).
    func testSetupEndsOnTheAddServerSheet() {
        let next = OnboardingFlowPolicy.page(after: OnboardingFlowPolicy.agentPromptPageIndex)
        XCTAssertEqual(next, 1)
        XCTAssertNil(OnboardingFlowPolicy.page(after: 1))
    }

    func testCopyReminderFollowsThePromptShown() {
        // Copying one prompt and then swapping to the other still needs a copy.
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex,
                shownPrompt: .hermes,
                copiedPrompts: [.webUI]
            )
        )
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex,
                shownPrompt: .webUI,
                copiedPrompts: [.hermes]
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex,
                shownPrompt: .webUI,
                copiedPrompts: [.hermes, .webUI]
            )
        )
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: OnboardingFlowPolicy.agentPromptPageIndex + 1,
                shownPrompt: .webUI,
                copiedPrompts: [.hermes]
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: OnboardingFlowPolicy.agentPromptPageIndex + 1,
                shownPrompt: .webUI,
                copiedPrompts: [.webUI]
            )
        )
    }

    func testForwardSwipeFromAgentPromptRequiresCopyOrBypass() {
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: OnboardingFlowPolicy.agentPromptPageIndex + 1,
                shownPrompt: .hermes,
                copiedPrompts: []
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: OnboardingFlowPolicy.agentPromptPageIndex + 1,
                shownPrompt: .hermes,
                copiedPrompts: [.hermes]
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: OnboardingFlowPolicy.agentPromptPageIndex + 1,
                shownPrompt: .hermes,
                copiedPrompts: [],
                bypassedPrompts: [.hermes]
            )
        )
    }

    func testSkippingOnePromptsReminderStillRemindsForTheOther() {
        // Continue Anyway on Hermes, then back to step 1 and over to Web UI: its reminder still shows.
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex,
                shownPrompt: .webUI,
                copiedPrompts: [],
                bypassedPrompts: [.hermes]
            )
        )
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: OnboardingFlowPolicy.agentPromptPageIndex + 1,
                shownPrompt: .webUI,
                copiedPrompts: [],
                bypassedPrompts: [.hermes]
            )
        )
    }

    /// The prompts an agent runs on the user's machine keep the rules that stop it exposing the
    /// server, killing someone else's process or losing the user's secrets.
    func testWebUISetupPromptKeepsItsSafetyRules() {
        let prompt = OnboardingFlowPolicy.webUISetupPrompt

        for rule in [
            "Never enable Funnel",
            "Do not kill an unknown process",
            "Do not run tailscale serve reset",
            "never truncate or replace the file",
            "Do not print the full .env",
            "Do not automate it"
        ] {
            XCTAssertTrue(prompt.contains(rule), "Missing safety rule: \(rule)")
        }
        XCTAssertFalse(prompt.contains("fall back: bind the server to 0.0.0.0"))
    }

    func testHermesSetupPromptKeepsItsSafetyRules() {
        let prompt = OnboardingFlowPolicy.hermesSetupPrompt

        for rule in ["Do not kill an unknown process", "Never run the dashboard without its sign-in gate"] {
            XCTAssertTrue(prompt.contains(rule), "Missing safety rule: \(rule)")
        }
        XCTAssertFalse(prompt.contains("--insecure"))
    }
}

/// The Squadd build's first launch (#10): install on the computer, then its button opens the
/// pairing screen in the same stack. Runs only for photos, from pr-ios.yml's FOTO_DIR.
@MainActor
final class SquaddOnboardingPhotoTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        HermesBackends.isEnabled = true
        window?.isHidden = true
        super.tearDown()
    }

    func testPhotoInstallThenScan() async throws {
        let path = ProcessInfo.processInfo.environment["FOTO_DIR"]
        try XCTSkipIf(path == nil, "Only for photo runs")
        let dir = URL(fileURLWithPath: path!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        HermesBackends.isEnabled = false
        let keychain = InMemoryKeychainStore()
        let manager = AuthManager(keychain: keychain, headerStore: CustomHeaderStore(),
                                  serverRegistry: ServerRegistry.inMemory(keychain: keychain),
                                  hermesConnections: HermesConnections(), preferences: .ephemeral(), forgetPush: { _ in })

        try await shoot("10-a-install", OnboardingView(authManager: manager), dir: dir)
        try await shoot("10-b-install-largest-text", OnboardingView(authManager: manager)
            .environment(\.dynamicTypeSize, .accessibility3), dir: dir)

        // The button a person taps, reached the way VoiceOver reaches it.
        let window = try XCTUnwrap(window)
        _ = try await readyPhoto(of: window) { Self.element(labeled: "Scan the QR Code", in: window) != nil }
        XCTAssertTrue(try XCTUnwrap(Self.element(labeled: "Scan the QR Code", in: window)).accessibilityActivate())
        let scan = try await readyPhoto(of: window) { Self.element(labeled: "Pair with Your Computer", in: window) != nil }
        XCTAssertNotNil(Self.element(labeled: "Pair with Your Computer", in: window), "the button opens the pairing screen")
        try scan.write(to: dir.appendingPathComponent("10-c-scan.png"))
    }

    /// The first accessibility element under `root` whose label is `label`.
    private static func element(labeled label: String, in root: NSObject) -> NSObject? {
        if root.accessibilityLabel == label { return root }
        let children = (root as? UIView)?.subviews ?? []
        let elements = (root.accessibilityElements as? [NSObject])
            ?? (0..<max(root.accessibilityElementCount(), 0)).compactMap { root.accessibilityElement(at: $0) as? NSObject }
        for child in elements + children {
            if let found = element(labeled: label, in: child) { return found }
        }
        return nil
    }

    private func shoot(_ name: String, _ view: some View, dir: URL) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window?.isHidden = true
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        self.window = window
        try await readyPhoto(of: window).write(to: dir.appendingPathComponent("\(name).png"))
    }
}
