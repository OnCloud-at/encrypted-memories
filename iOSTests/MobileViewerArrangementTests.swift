import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile

/// The viewer arrangement keeps the Photos-app layout while the display is whole: the filmstrip shortens the media,
/// and without the filmstrip the media fills the area. iOS 27.1 lays both out with an overlay arrangement view
/// (on iPhone Duo), earlier systems with a bottom safe-area inset; both paths must agree.
final class MobileViewerArrangementTests: XCTestCase {
    @MainActor func testTheFilmstripShortensTheMediaWhileTheDisplayIsWhole() async throws {
        let withFilmstrip = try await layout(showsAccessory: true)
        XCTAssertEqual(withFilmstrip.accessory.height, 60, accuracy: 0.5)
        XCTAssertEqual(withFilmstrip.media.maxY, withFilmstrip.accessory.minY, accuracy: 1)

        let withoutFilmstrip = try await layout(showsAccessory: false)
        XCTAssertEqual(withoutFilmstrip.media.maxY, withFilmstrip.accessory.maxY, accuracy: 1)
    }

    @MainActor private func layout(showsAccessory: Bool) async throws -> (media: CGRect, accessory: CGRect) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        let frames = ArrangementFrames()
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(
            rootView: MobileViewerArrangement(showsAccessory: showsAccessory) {
                Color.red.onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    frames.media = $0
                }
            } accessory: {
                Color.blue.frame(height: 60)
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        frames.accessory = $0
                    }
            })
        window.isHidden = false
        defer { window.isHidden = true }
        // The arrangement measures the filmstrip first and shortens the media in the next layout pass.
        try await Task.sleep(for: .milliseconds(600))
        return (frames.media, frames.accessory)
    }
}

@MainActor private final class ArrangementFrames {
    var media = CGRect.null
    var accessory = CGRect.null
}
