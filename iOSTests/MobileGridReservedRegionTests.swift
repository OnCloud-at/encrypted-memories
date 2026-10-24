import GridCore
import UIKit
import XCTest

@testable import TimelineUIKitFeature

/// The UIKit grid host hands the device's reserved regions to the shared layout policy. The iPhone Duo simulator
/// starts closed, and there the outer camera and the status area occlude the display; the fold (a division) needs
/// the partially open pose, which a test cannot set.
final class MobileGridReservedRegionTests: XCTestCase {
    @MainActor func testGridHostReadsTheActiveReservedRegionsOfItsWindow() throws {
        #if canImport(UIKit, _version: 9127.0.85)
            guard #available(iOS 27.1, *) else { throw XCTSkip("reserved regions need iOS 27.1") }
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            let host = UIKitTimelineGridHostView(frame: window.bounds)
            window.addSubview(host)
            window.isHidden = false
            defer { window.isHidden = true }
            host.layoutIfNeeded()

            let reported = [UIView.ReservedRegion.Kind.division, .occlusion].flatMap { kind in
                host.reservedRegions(kind: kind).filter { $0.isActive && !$0.frame.isEmpty }.map(\.frame)
            }
            try XCTSkipIf(reported.isEmpty, "this display reports no active reserved region")
            let exclusions = host.reservedRegionLayout.exclusions
            XCTAssertEqual(exclusions.count, reported.count)
            for frame in reported {
                XCTAssertTrue(exclusions.contains(frame), "the grid misses the reserved region \(frame)")
            }
        #else
            throw XCTSkip("the SDK has no reserved regions")
        #endif
    }
}
