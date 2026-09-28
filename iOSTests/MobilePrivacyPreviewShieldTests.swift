import PhotosCore
import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile
@testable import TimelineUIKitFeature

final class MobilePrivacyPreviewShieldTests: XCTestCase {
    @MainActor func testInactivePreviewBlursContentWithoutTurningBlack() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        window.overrideUserInterfaceStyle = .dark
        let root = UIViewController()
        root.view.backgroundColor = .black
        let white = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 200))
        white.backgroundColor = .white
        root.view.addSubview(white)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let shield = MobilePrivacyPreviewShield()
        let uncovered = try brightnessStatistics(of: window)
        shield.update(enabled: true, isSceneActive: false, window: window)
        let cover = try XCTUnwrap(window.subviews.compactMap { $0 as? UIImageView }.first)
        XCTAssertNotNil(cover.image, "The preview must contain a rendered image, not a fallback color")
        let covered = try brightnessStatistics(of: window)

        let uncoveredEdge = abs(uncovered.profile[29] - uncovered.profile[35])
        let coveredEdge = abs(covered.profile[29] - covered.profile[35])
        let coveredBroadContrast = abs(covered.profile[8] - covered.profile[56])
        XCTAssertGreaterThan(uncoveredEdge, 0.7, "The negative control must show a sharp edge")
        XCTAssertGreaterThan(coveredBroadContrast, 0.65, "Blur must preserve broad light and dark regions")
        XCTAssertLessThan(coveredEdge, coveredBroadContrast * 0.75, "The covered edge must be softened")
        XCTAssertEqual(covered.average, uncovered.average, accuracy: 0.05, "Blur must not whiten or darken the preview")
        shield.remove()
    }

    @MainActor func testProductionMetalGridRetainsItsColorsInTheBlurredPreview() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let fixture = try await MobileSignedInFixture(itemsPerSection: 6)
        defer { fixture.removeCache() }
        // Put distinct fixture colors next to each other, starting with the brightest thumbnails.
        let items = (0..<6).reversed().flatMap { index in fixture.sections.map { $0.items[index] } }
        let state = ChromeProbeState()
        state.showsLoadingCover = false
        state.showsActivity = false
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(
            rootView: ChromeProbeShell(items: items, feed: fixture.feed, state: state))
        window.makeKeyAndVisible()
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        defer {
            descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }.forEach { $0.setActive(false) }
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        var probes: [(point: CGPoint, rgb: [Double])] = []
        var ready = false
        for _ in 0..<100 {
            if let grid = descendants(window).compactMap({ $0 as? UIKitTimelineGridHostView }).first,
                let plan = grid.accessibilityFramePlan()
            {
                probes = plan.visibleSlots.compactMap { slot in
                    let rect = grid.metalView.convert(slot.viewportRect, to: window)
                    guard rect.minY > 140, rect.maxY < window.bounds.height - 100 else { return nil }
                    let item = items[slot.index]
                    guard let section = fixture.sections.firstIndex(where: { $0.items.contains(item) }),
                        let index = fixture.sections[section].items.firstIndex(of: item)
                    else { return nil }
                    var red: CGFloat = 0
                    var green: CGFloat = 0
                    var blue: CGFloat = 0
                    var alpha: CGFloat = 0
                    UIColor(
                        hue: CGFloat(section) / 6, saturation: 0.55,
                        brightness: 0.45 + 0.5 * CGFloat(index % 6) / 6, alpha: 1
                    )
                    .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                    return (
                        CGPoint(x: rect.midX / window.bounds.width, y: rect.midY / window.bounds.height),
                        [Double(red), Double(green), Double(blue)]
                    )
                }
                if probes.count >= 3, try matchesFixtureColors(snapshot(of: window), probes: probes, tolerance: 0.12) {
                    ready = true
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(ready, "Actual pixels must show the known fixture colors before testing blur")
        guard ready else { return }
        let shield = MobilePrivacyPreviewShield()
        defer { shield.remove() }
        shield.update(enabled: true, isSceneActive: false, window: window)
        let cover = try XCTUnwrap(window.subviews.compactMap { $0 as? UIImageView }.first)
        let image = try XCTUnwrap(cover.image, "Capturing the production Metal grid must succeed")
        XCTAssertTrue(
            try matchesFixtureColors(snapshot(of: window), probes: probes, tolerance: 0.18),
            "Blur must retain the photo colors at their actual grid positions")
        // A uniform card can have the correct average brightness. It must still fail this spatial oracle.
        for color in [UIColor.gray, UIColor(white: 0.08, alpha: 1)] {
            let flat = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            }
            XCTAssertFalse(
                try matchesFixtureColors(flat, probes: probes, tolerance: 0.18),
                "Uniform and missing-grid previews must fail the same acceptance check")
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "production-metal-grid-blurred-preview"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func snapshot(of window: UIWindow) -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
    }

    private func matchesFixtureColors(
        _ image: UIImage, probes: [(point: CGPoint, rgb: [Double])], tolerance: Double
    ) throws -> Bool {
        let source = try XCTUnwrap(image.cgImage)
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(
                CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return probes.allSatisfy { probe in
            let x = min(side - 1, max(0, Int(probe.point.x * Double(side))))
            let y = min(side - 1, max(0, Int(probe.point.y * Double(side))))
            return (0..<3).allSatisfy { channel in
                abs(Double(pixels[(y * side + x) * 4 + channel]) / 255 - probe.rgb[channel]) < tolerance
            }
        }
    }

    @MainActor private func brightnessStatistics(of window: UIWindow) throws -> (average: Double, profile: [Double]) {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { context in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let values = try pixels.withUnsafeMutableBytes { buffer in
            let bitmap = try XCTUnwrap(
                CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.interpolationQuality = .high
            bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return stride(from: 0, to: buffer.count, by: 4).map { index in
                Double(Int(buffer[index]) + Int(buffer[index + 1]) + Int(buffer[index + 2])) / (3 * 255)
            }
        }
        let profile = (0..<side).map { x in
            (0..<side).reduce(0) { brightness, y in brightness + values[y * side + x] } / Double(side)
        }
        return (values.reduce(0, +) / Double(values.count), profile)
    }

    @MainActor func testInactiveSceneCoversItsWindowAndActiveSceneRestoresIt() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        let shield = MobilePrivacyPreviewShield()

        shield.update(enabled: false, isSceneActive: false, window: window)
        XCTAssertTrue(window.subviews.compactMap { $0 as? UIImageView }.isEmpty)

        shield.update(enabled: true, isSceneActive: false, window: window)
        XCTAssertEqual(window.subviews.compactMap { $0 as? UIImageView }.count, 1)

        shield.update(enabled: true, isSceneActive: true, window: window)
        XCTAssertTrue(window.subviews.compactMap { $0 as? UIImageView }.isEmpty)
    }

    @MainActor func testEachSceneOwnsItsShield() {
        let firstWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let secondWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let firstShield = MobilePrivacyPreviewShield()
        let secondShield = MobilePrivacyPreviewShield()

        firstShield.update(enabled: true, isSceneActive: false, window: firstWindow)
        secondShield.update(enabled: true, isSceneActive: true, window: secondWindow)

        XCTAssertEqual(firstWindow.subviews.compactMap { $0 as? UIImageView }.count, 1)
        XCTAssertTrue(secondWindow.subviews.compactMap { $0 as? UIImageView }.isEmpty)
    }

    @MainActor func testCenterRetainsWindowShieldAfterPresentationAnchorDetaches() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        let center = MobilePrivacyPreviewShieldCenter()

        center.register(window: window)
        center.refreshAll(enabled: true)

        XCTAssertEqual(window.subviews.compactMap { $0 as? UIImageView }.count, 1)
        // A full-screen cover can remove the SwiftUI anchor without destroying its scene window.
        center.refreshAll(enabled: true)
        XCTAssertEqual(window.subviews.compactMap { $0 as? UIImageView }.count, 1)

        center.refreshAll(enabled: false)
        XCTAssertTrue(window.subviews.compactMap { $0 as? UIImageView }.isEmpty)
    }

    @MainActor func testCenterUpdatesEveryRegisteredWindowWhenPreferenceChanges() {
        let windows = (0..<2).map { _ in UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844)) }
        let center = MobilePrivacyPreviewShieldCenter()
        for window in windows { center.register(window: window) }

        center.refreshAll(enabled: true)
        XCTAssertTrue(windows.allSatisfy { $0.subviews.compactMap { $0 as? UIImageView }.count == 1 })

        center.refreshAll(enabled: false)
        XCTAssertTrue(windows.allSatisfy { $0.subviews.compactMap { $0 as? UIImageView }.isEmpty })
    }

    @MainActor func testSceneLifecycleCoversAndRestoresTheRegisteredWindow() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        let original = UserDefaults.standard.object(forKey: AppSettingsKey.blurAppPreview)
        UserDefaults.standard.set(true, forKey: AppSettingsKey.blurAppPreview)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: AppSettingsKey.blurAppPreview)
            } else {
                UserDefaults.standard.removeObject(forKey: AppSettingsKey.blurAppPreview)
            }
            window.isHidden = true
        }

        let center = MobilePrivacyPreviewShieldCenter()
        center.register(window: window)
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        XCTAssertEqual(window.subviews.compactMap { $0 as? UIImageView }.count, 1)

        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        XCTAssertTrue(window.subviews.compactMap { $0 as? UIImageView }.isEmpty)
    }
}
