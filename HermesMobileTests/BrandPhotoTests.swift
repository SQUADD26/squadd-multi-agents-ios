import SwiftUI
import XCTest
@testable import HermesMobile

/// Photos of the branded screens a simulator can't reach without a signed-in server: the home
/// header's wordmark, Settings → About and Settings → Acknowledgements, rendered from the real
/// views in the app host. Runs only from `.github/workflows/pr-ios.yml`, which sets
/// `BRAND_PHOTOS_DIR` (through `TEST_RUNNER_BRAND_PHOTOS_DIR`) and uploads what lands there.
@MainActor
final class BrandPhotoTests: XCTestCase {
    func testPhotographTheBrandedScreens() async throws {
        guard let directory = ProcessInfo.processInfo.environment["BRAND_PHOTOS_DIR"] else {
            throw XCTSkip("Photos only: pr-ios.yml sets BRAND_PHOTOS_DIR.")
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try await photograph(
            VStack(alignment: .leading) {
                HermesHeaderLogo(selectedColor: HeaderLogoColor.color(for: HeaderLogoColor.defaultHex))
                    .frame(width: 160, alignment: .leading)
                Spacer()
            }
            .padding(),
            named: "4-home-header", in: folder
        )
        try await photograph(NavigationStack { SettingsAboutPage(server: nil) }, named: "5-settings-about", in: folder)
        try await photograph(NavigationStack { SettingsAcknowledgementsPage() }, named: "6-acknowledgements", in: folder)
    }

    private func photograph(_ view: some View, named name: String, in folder: URL) async throws {
        // On the host app's scene, or the window never draws.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        try await readyPhoto(of: window).write(to: folder.appendingPathComponent("\(name).png"))
        window.isHidden = true
    }
}


/// The window's PNG once `ready` holds and two renders 33 ms apart are the same picture, at most
/// `limit` seconds (a never-ending animation gets its photo at the limit). A screen still loading
/// can sit still too, so a shot that waits on a reply passes `ready`. Waits with `Task.sleep`,
/// which lets the screen's own async work run. Photos only, never an assertion.
/// The frames it compares are drawn at 1x, about a sixth of the cost; the photo at the screen's scale.
@MainActor
func readyPhoto(of window: UIWindow, until ready: () -> Bool = { true }, limit: Duration = .seconds(3)) async throws -> Data {
    let small = UIGraphicsImageRendererFormat.preferred()
    small.scale = 1
    let draw = { (renderer: UIGraphicsImageRenderer) in
        renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
    }
    let preview = UIGraphicsImageRenderer(bounds: window.bounds, format: small)
    let pixels = { (image: UIImage) in image.cgImage?.dataProvider?.data as Data? }
    // Liquid Glass settles in steps the frames don't show: wait until no layer is animating.
    func animating(_ layer: CALayer) -> Bool {
        !(layer.animationKeys() ?? []).isEmpty || (layer.sublayers ?? []).contains(where: animating)
    }
    var last = draw(preview), still = false
    let end = ContinuousClock.now + limit
    while !still, ContinuousClock.now < end {
        // test-wait: a photo, not a check; two display frames for the next one to draw before comparing
        try await Task.sleep(for: .milliseconds(33))
        let now = draw(preview)
        still = ready() && !animating(window.layer) && pixels(now) == pixels(last)
        last = now
    }
    return try XCTUnwrap(draw(UIGraphicsImageRenderer(bounds: window.bounds)).pngData())
}
