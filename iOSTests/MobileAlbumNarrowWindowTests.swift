import AlbumCore
import AlbumsFeature
import PhotosCore
import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile

/// Measures the native picker in a resized test window; this does not simulate Split View or a fold.
final class MobileAlbumNarrowWindowTests: XCTestCase {
    func testRegularSizingRequiresBothRegularSizeClasses() {
        XCTAssertTrue(AlbumPresentationTraits.usesRegularSizing(horizontal: .regular, vertical: .regular))
        XCTAssertFalse(AlbumPresentationTraits.usesRegularSizing(horizontal: .regular, vertical: .compact))
        XCTAssertFalse(AlbumPresentationTraits.usesRegularSizing(horizontal: .compact, vertical: .regular))
        XCTAssertFalse(AlbumPresentationTraits.usesRegularSizing(horizontal: nil, vertical: .regular))
    }

    @MainActor func testCompactWindowKeepsAlbumPickerInsideAvailableWidth() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let albums = MobileFixtureAlbums()
        let repository = AlbumsRepository(
            catalogBackend: albums, writeBackend: albums, capabilities: MobileFixtureAlbums.capabilities)
        let coordinator = AlbumActionCoordinator(repository: repository)
        let photo = PhotoUID(volumeID: "fixture", nodeID: "narrow-window")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 700)
        window.traitOverrides.horizontalSizeClass = .compact
        let root = UIHostingController(
            rootView: AlbumAddButton(coordinator: coordinator, photoUIDs: [photo], isPresented: .constant(true)))
        root.traitOverrides.horizontalSizeClass = .compact
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        await fulfillment(
            of: [
                XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "presentedViewController != nil"), object: root)
            ],
            timeout: 10)
        let presented = try XCTUnwrap(root.presentedViewController, "The album picker must be presented")
        let frame = presented.view.convert(presented.view.bounds, to: window)
        print("[Album narrow window] window=\(window.bounds) presented=\(frame)")
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertGreaterThanOrEqual(frame.minX, window.bounds.minX - 1)
        XCTAssertLessThanOrEqual(frame.maxX, window.bounds.maxX + 1)

        root.presentedViewController?.dismiss(animated: false)
        window.isHidden = true
        let regularWindow = UIWindow(windowScene: scene)
        regularWindow.frame = CGRect(x: 0, y: 0, width: 400, height: 700)
        regularWindow.traitOverrides.horizontalSizeClass = .regular
        let regularRoot = UIHostingController(
            rootView: AlbumAddButton(coordinator: coordinator, photoUIDs: [photo], isPresented: .constant(true)))
        regularRoot.traitOverrides.horizontalSizeClass = .regular
        regularWindow.rootViewController = regularRoot
        regularWindow.makeKeyAndVisible()
        defer {
            regularRoot.presentedViewController?.dismiss(animated: false)
            regularWindow.isHidden = true
            regularWindow.rootViewController = nil
        }
        await fulfillment(
            of: [
                XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "presentedViewController != nil"), object: regularRoot)
            ], timeout: 10)
        let regularPicker = try XCTUnwrap(regularRoot.presentedViewController, "The regular album picker must open")
        let regularFrame = regularPicker.view.convert(regularPicker.view.bounds, to: regularWindow)
        print("[Album narrow window] regular window=\(regularWindow.bounds) presented=\(regularFrame)")
        XCTAssertGreaterThanOrEqual(regularFrame.width, 300, "The regular picker must have usable width")
        XCTAssertGreaterThan(regularFrame.height, 0)
        XCTAssertGreaterThanOrEqual(regularFrame.minX, regularWindow.bounds.minX - 1)
        XCTAssertLessThanOrEqual(regularFrame.maxX, regularWindow.bounds.maxX + 1)
    }
}
