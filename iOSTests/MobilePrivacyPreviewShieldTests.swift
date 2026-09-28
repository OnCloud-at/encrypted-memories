import PhotosCore
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile

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
        try await Task.sleep(for: .milliseconds(100))
        let covered = try brightnessStatistics(of: window)

        let uncoveredEdge = abs(uncovered.profile[29] - uncovered.profile[35])
        let coveredEdge = abs(covered.profile[29] - covered.profile[35])
        let coveredBroadContrast = abs(covered.profile[8] - covered.profile[56])
        XCTAssertGreaterThan(uncoveredEdge, 0.7, "The negative control must show a sharp edge")
        XCTAssertGreaterThan(coveredBroadContrast, 0.05, "A solid cover must not pass as blur")
        XCTAssertLessThan(coveredEdge, coveredBroadContrast * 0.75, "The covered edge must be softened")
        XCTAssertGreaterThan(covered.average, 0.35, "The app-switcher cover must not render black")
        shield.remove()
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
        XCTAssertTrue(window.subviews.compactMap { $0 as? UIVisualEffectView }.isEmpty)

        shield.update(enabled: true, isSceneActive: false, window: window)
        XCTAssertEqual(window.subviews.compactMap { $0 as? UIVisualEffectView }.count, 1)

        shield.update(enabled: true, isSceneActive: true, window: window)
        XCTAssertTrue(window.subviews.compactMap { $0 as? UIVisualEffectView }.isEmpty)
    }

    @MainActor func testEachSceneOwnsItsShield() {
        let firstWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let secondWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let firstShield = MobilePrivacyPreviewShield()
        let secondShield = MobilePrivacyPreviewShield()

        firstShield.update(enabled: true, isSceneActive: false, window: firstWindow)
        secondShield.update(enabled: true, isSceneActive: true, window: secondWindow)

        XCTAssertEqual(firstWindow.subviews.compactMap { $0 as? UIVisualEffectView }.count, 1)
        XCTAssertTrue(secondWindow.subviews.compactMap { $0 as? UIVisualEffectView }.isEmpty)
    }

    @MainActor func testCenterRetainsWindowShieldAfterPresentationAnchorDetaches() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        let center = MobilePrivacyPreviewShieldCenter()

        center.register(window: window)
        center.refreshAll(enabled: true)

        XCTAssertEqual(window.subviews.compactMap { $0 as? UIVisualEffectView }.count, 1)
        // A full-screen cover can remove the SwiftUI anchor without destroying its scene window.
        center.refreshAll(enabled: true)
        XCTAssertEqual(window.subviews.compactMap { $0 as? UIVisualEffectView }.count, 1)

        center.refreshAll(enabled: false)
        XCTAssertTrue(window.subviews.compactMap { $0 as? UIVisualEffectView }.isEmpty)
    }

    @MainActor func testCenterUpdatesEveryRegisteredWindowWhenPreferenceChanges() {
        let windows = (0..<2).map { _ in UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844)) }
        let center = MobilePrivacyPreviewShieldCenter()
        for window in windows { center.register(window: window) }

        center.refreshAll(enabled: true)
        XCTAssertTrue(windows.allSatisfy { $0.subviews.compactMap { $0 as? UIVisualEffectView }.count == 1 })

        center.refreshAll(enabled: false)
        XCTAssertTrue(windows.allSatisfy { $0.subviews.compactMap { $0 as? UIVisualEffectView }.isEmpty })
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
        XCTAssertEqual(window.subviews.compactMap { $0 as? UIVisualEffectView }.count, 1)

        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        XCTAssertTrue(window.subviews.compactMap { $0 as? UIVisualEffectView }.isEmpty)
    }
}
