import SwiftUI
import XCTest
@testable import HermesMobile

/// With the Hermes backends off (ADR 0002) the screens only webui and Hermes servers serve are
/// gone. The suite runs with them on (`TestHostStateGuard`); each test here turns them off for
/// itself. Adding and opening servers: `AuthManagerStateTests`; Thinking and Fast:
/// `HermesChatSettingsTests`.
@MainActor
final class HermesBackendsTests: XCTestCase {
    nonisolated override func tearDown() {
        HermesBackends.isEnabled = true
        super.tearDown()
    }

    func testTheHomeDropsTasksKanbanAndUsageWithTheBackendsOff() {
        HermesBackends.isEnabled = false
        let home = SidebarSectionVisibility.showAll.withoutHermesOnlyRows

        XCTAssertFalse(home.tasks)
        XCTAssertFalse(home.kanban)
        XCTAssertFalse(home.insights)
        XCTAssertTrue(home.bots && home.skills && home.memory && home.projects, "the rest stay as Settings says")
    }

    func testTheHomeKeepsEveryRowWithTheBackendsOn() {
        XCTAssertEqual(SidebarSectionVisibility.showAll.withoutHermesOnlyRows, .showAll)
    }

    /// The welcome page, the home's Settings switches and the composer's Settings page, drawn with
    /// the backends off and on. Each drops a Hermes-only entry when off (the setup prompts; Tasks,
    /// Kanban and Usage; Files and Git). The images are kept in the result bundle as evidence.
    func testTheMainScreensDropTheirHermesOnlyEntriesWithTheBackendsOff() async throws {
        let screens: [(String, AnyView)] = [
            ("welcome", AnyView(OnboardingWelcomePage(addServer: {}, setUp: {}))),
            ("settings-main-page", AnyView(NavigationStack { Form { MainPageSettingsSection(includesWebuiEntries: false) } })),
            ("settings-composer", AnyView(NavigationStack { SettingsComposerPage() })),
        ]
        for (name, screen) in screens {
            HermesBackends.isEnabled = false
            let off = try await snapshot(screen, named: "\(name)-hermes-off")
            HermesBackends.isEnabled = true
            let on = try await snapshot(screen, named: "\(name)-hermes-on")
            XCTAssertNotEqual(off, on, "\(name) draws the same with the backends off")
        }
    }

    private func snapshot(_ view: AnyView, named name: String) async throws -> Data {
        let appeared = expectation(description: "\(name) appeared")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view.onAppear { appeared.fulfill() })
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        await fulfillment(of: [appeared], timeout: 5)
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return try XCTUnwrap(image.pngData())
    }
}
