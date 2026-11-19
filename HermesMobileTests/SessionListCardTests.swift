import SwiftUI
import XCTest
@testable import HermesMobile

final class SessionListCardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func makeDefaults() throws -> UserDefaults {
        let name = "SessionListCardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    @MainActor
    func testEachCardReachesItsThresholdOnTheSharedCounterAndImportTemporarilySuppressesIt() throws {
        for (card, threshold) in [(SessionListCard.tip, 25), (.star, 15)] {
            let defaults = try makeDefaults()
            let rating = RatingPromptState(defaults: defaults, now: now)
            let state = SessionListCardState(card: card, defaults: defaults)
            for _ in 0..<(threshold - 1) { rating.recordCompletedResponse() }
            XCTAssertFalse(eligible(state, rating: rating), "\(card)")
            rating.recordCompletedResponse()
            XCTAssertTrue(eligible(state, rating: rating), "\(card)")
            XCTAssertFalse(state.isEligible(completedResponses: threshold, hasSharedImport: true, ratingPolicy: rating.policy, now: now))
            XCTAssertTrue(eligible(SessionListCardState(card: card, defaults: defaults), rating: RatingPromptState(defaults: defaults, now: now)))
        }
    }

    @MainActor
    func testDismissalLastsUntilTheNextFeatureReleaseAndHidesOnlyThatCard() throws {
        for card in [SessionListCard.tip, .star] {
            let other: SessionListCard = card == .tip ? .star : .tip
            let defaults = try makeDefaults()
            defaults.set(25, forKey: TipJar.completedResponseCountKey)
            let rating = RatingPromptState(defaults: defaults, now: now)
            SessionListCardState(card: card, defaults: defaults, appVersion: "1.8").dismiss()
            XCTAssertFalse(eligible(SessionListCardState(card: card, defaults: defaults, appVersion: "1.8"), rating: rating))
            XCTAssertFalse(eligible(SessionListCardState(card: card, defaults: defaults, appVersion: "1.8.1"), rating: rating),
                           "A patch update keeps the dismissal")
            XCTAssertTrue(eligible(SessionListCardState(card: card, defaults: defaults, appVersion: "1.9"), rating: rating))
            XCTAssertTrue(eligible(SessionListCardState(card: other, defaults: defaults, appVersion: "1.8"), rating: rating))
        }
    }

    @MainActor
    func testOpeningALinkHidesOnlyThatCardForGood() throws {
        for card in [SessionListCard.tip, .star] {
            let other: SessionListCard = card == .tip ? .star : .tip
            let defaults = try makeDefaults()
            defaults.set(25, forKey: TipJar.completedResponseCountKey)
            let rating = RatingPromptState(defaults: defaults, now: now)
            SessionListCardState(card: card, defaults: defaults, appVersion: "1.8").recordLinkOpened()
            XCTAssertFalse(eligible(SessionListCardState(card: card, defaults: defaults, appVersion: "2.0"), rating: rating),
                           "Opening a link hides the card on every later release")
            XCTAssertTrue(eligible(SessionListCardState(card: other, defaults: defaults, appVersion: "1.8"), rating: rating))
        }
    }

    @MainActor
    func testBothCardsWaitSevenDaysAfterARatingRequest() throws {
        let defaults = try makeDefaults()
        defaults.set(now, forKey: RatingPromptSettings.lastRequestDateKey)
        let rating = RatingPromptState(defaults: defaults, now: now)
        for card in [SessionListCard.tip, .star] {
            let state = SessionListCardState(card: card, defaults: defaults)
            XCTAssertFalse(state.isEligible(completedResponses: 25, hasSharedImport: false, ratingPolicy: rating.policy, now: now.addingTimeInterval(7 * RatingPromptPolicy.day - 1)))
            XCTAssertTrue(state.isEligible(completedResponses: 25, hasSharedImport: false, ratingPolicy: rating.policy, now: now.addingTimeInterval(7 * RatingPromptPolicy.day)))
        }
    }

    func testTipWinsAndOnlyOneCardShowsPerLaunch() {
        XCTAssertEqual(SessionListCard.choose(eligible: [.tip, .star], shownThisLaunch: nil), .tip)
        // Dismissing the tip card leaves the slot empty until a later launch.
        XCTAssertNil(SessionListCard.choose(eligible: [.star], shownThisLaunch: .tip))
        // A star card already showing keeps the slot when another card becomes eligible mid-launch.
        XCTAssertEqual(SessionListCard.choose(eligible: [.tip, .star], shownThisLaunch: .star), .star)
    }

    @MainActor
    func testReducedMotionSchedulesNothingAndConsumesWelcome() async {
        let greeting = SessionListCardGreeting()
        var frames: [SessionListCardGreeting.Phase] = []
        await greeting.play(reduceMotion: true, wait: { _ in XCTFail("No motion should be scheduled") }, display: { frames.append($0) })
        XCTAssertEqual(frames, [.neutral])
        frames = []
        await greeting.play(reduceMotion: false, wait: { duration in
            XCTAssertEqual(duration, .milliseconds(3500), "Enabling motion resumes idle, not the welcome")
            throw CancellationError()
        }, display: { frames.append($0) })
        XCTAssertEqual(frames, [.neutral])
    }

    @MainActor
    func testCancellationDuringWelcomeOrIdleCannotDisplayAnotherFrame() async {
        // Covers pre-blink, airborne, neutral waiting, and holding the downward glance.
        for cancellationPause in [1, 4, 7, 10] {
            let greeting = SessionListCardGreeting()
            var frames: [SessionListCardGreeting.Phase] = []
            var snapshot: [SessionListCardGreeting.Phase] = []
            var pauseCount = 0
            let task = Task {
                await greeting.play(reduceMotion: false, wait: { _ in
                    pauseCount += 1
                    if pauseCount == cancellationPause {
                        snapshot = frames
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }, display: { frames.append($0) })
            }
            await task.value
            XCTAssertEqual(pauseCount, cancellationPause)
            XCTAssertEqual(frames, snapshot)
        }
    }

    @MainActor
    private func eligible(_ state: SessionListCardState, rating: RatingPromptState) -> Bool {
        state.isEligible(completedResponses: rating.policy.completedResponses, hasSharedImport: false, ratingPolicy: rating.policy, now: now)
    }
}

/// Photographs real SwiftUI screens into `FOTO_DIR` (passed as `TEST_RUNNER_FOTO_DIR`) for a PR's
/// evidence; skipped everywhere else. Add a `shoot` call per screen; `pr-ios.yml` runs it when the PR touches its screens.
@MainActor
final class ScreenPhotoTests: XCTestCase {
    private func shoot<V: View>(_ name: String, _ view: V) throws {
        let dir = try XCTUnwrap(ProcessInfo.processInfo.environment["FOTO_DIR"], "FOTO_DIR not set")
        let controller = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.backgroundColor = .systemBackground
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        // test-wait: photo runs only (skipped without FOTO_DIR); lets SwiftUI lay out before the capture
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    func testPhotoSettingsAboutAndSessionListCardSlot() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["FOTO_DIR"] == nil, "Only for photo runs")
        let defaults = UserDefaults.standard
        // A device that said yes to usage reports in the old version, with enough replies for any card.
        defaults.set(2, forKey: "usageReports.acceptedVersion")
        defaults.set(30, forKey: TipJar.completedResponseCountKey)
        addTeardownBlock {
            defaults.removeObject(forKey: "usageReports.acceptedVersion")
            defaults.removeObject(forKey: TipJar.completedResponseCountKey)
        }
        try shoot("1-settings-about", NavigationStack { SettingsAboutPage(server: nil) })
        try shoot("2-session-list-card-slot", List { SessionListCardSlot(hasSharedImport: false) })
    }
}
