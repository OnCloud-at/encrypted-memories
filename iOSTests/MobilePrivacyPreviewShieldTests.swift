import UIKit
import XCTest

@testable import EncryptedMemoriesMobile

final class MobilePrivacyPreviewShieldTests: XCTestCase {
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
}
