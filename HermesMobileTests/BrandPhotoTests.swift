import SwiftUI
import XCTest
@testable import HermesMobile

/// Photos of the branded screens a simulator can't reach without a signed-in server: the home
/// header's wordmark, Settings → About and Settings → Acknowledgements, rendered from the real
/// views in the app host. Runs only from `.github/workflows/pr-ios.yml`, which sets
/// `BRAND_PHOTOS_DIR` (through `TEST_RUNNER_BRAND_PHOTOS_DIR`) and uploads what lands there.
@MainActor
final class BrandPhotoTests: XCTestCase {
    func testPhotographTheBrandedScreens() throws {
        guard let directory = ProcessInfo.processInfo.environment["BRAND_PHOTOS_DIR"] else {
            throw XCTSkip("Photos only: pr-ios.yml sets BRAND_PHOTOS_DIR.")
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try photograph(
            VStack(alignment: .leading) {
                HermesHeaderLogo(selectedColor: HeaderLogoColor.color(for: HeaderLogoColor.defaultHex))
                    .frame(width: 160, alignment: .leading)
                Spacer()
            }
            .padding(),
            named: "4-home-header", in: folder
        )
        try photograph(NavigationStack { SettingsAboutPage(server: nil) }, named: "5-settings-about", in: folder)
        try photograph(NavigationStack { SettingsAcknowledgementsPage() }, named: "6-acknowledgements", in: folder)
    }

    private func photograph(_ view: some View, named name: String, in folder: URL) throws {
        // On the host app's scene, or the window never draws.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        try steadyPhoto(of: window).write(to: folder.appendingPathComponent("\(name).png"))
        window.isHidden = true
    }
}

/// The window's PNG once its picture holds still: three equal frames 0.1 s apart, at most `limit`
/// seconds (a never-ending animation gets its photo at the limit). For photos, never an assertion.
@MainActor
func steadyPhoto(of window: UIWindow, limit: TimeInterval = 3) throws -> Data {
    let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
    let frame = { renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) } }
    let pixels = { (image: UIImage) in image.cgImage?.dataProvider?.data as Data? }
    var last = frame(), same = 0
    let end = Date().addingTimeInterval(limit)
    while same < 3, Date() < end {
        // test-wait: a photo, not a check; lets the next frame draw before comparing it with the last one
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let now = frame()
        same = pixels(now) == pixels(last) ? same + 1 : 0
        last = now
    }
    return try XCTUnwrap(last.pngData())
}
