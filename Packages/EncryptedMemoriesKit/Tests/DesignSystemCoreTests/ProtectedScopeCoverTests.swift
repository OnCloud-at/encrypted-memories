import SwiftUI
import Testing

@testable import DesignSystemCore

@Suite struct ProtectedScopeCoverTests {
    /// Any red tint counts, so a partly transparent cover fails too.
    private static func isRed(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Bool {
        Int(red) - Int(green) > 40 && Int(red) - Int(blue) > 40
    }

    /// A material would let the colors of the photos behind it show through; the cover must hide them completely.
    @MainActor @Test func noContentShowsThroughTheCover() throws {
        let content = Color(red: 1, green: 0, blue: 0)
        #expect(try RenderedInk.pixels(content, matching: Self.isRed) > 0)
        let covered = ZStack {
            content
            ProtectedScopeCover(unlockTitle: "Unlock", accessibilityLabel: "Locked", isAuthenticating: false) {}
        }
        #expect(try RenderedInk.pixels(covered, matching: Self.isRed) == 0)
    }

    /// The host passes bounds that keep the symbol and the button clear of a fold; without them they are centered.
    @MainActor @Test func theCoverPlacesItsContentInTheGivenBounds() throws {
        func leadingInk(_ bounds: CGRect?) throws -> Int {
            let cover = ProtectedScopeCover(
                unlockTitle: "Unlock", accessibilityLabel: "Locked", isAuthenticating: false, contentBounds: bounds
            ) {}
            return try RenderedInk.pixels(
                cover.frame(width: 480, height: 360).mask(alignment: .leading) { Rectangle().frame(width: 160) })
        }
        #expect(try leadingInk(CGRect(x: 0, y: 0, width: 160, height: 360)) > 0)
        #expect(try leadingInk(nil) == 0)
    }

    /// The cover also hides content under a safe-area inset, such as a status bar or a camera housing.
    @MainActor @Test func theCoverFillsTheSafeArea() throws {
        let covered = ZStack {
            Color(red: 1, green: 0, blue: 0)
            ProtectedScopeCover(unlockTitle: "Unlock", accessibilityLabel: "Locked", isAuthenticating: false) {}
                .safeAreaPadding(.top, 120)
        }
        #expect(try RenderedInk.pixels(covered, matching: Self.isRed) == 0)
    }

    /// Bounds measured over the whole window keep their place when the window has a safe-area inset.
    @MainActor @Test func theBoundsIncludeTheSafeArea() throws {
        let cover = ProtectedScopeCover(
            unlockTitle: "Unlock", accessibilityLabel: "Locked", isAuthenticating: false,
            contentBounds: CGRect(x: 0, y: 0, width: 160, height: 80)
        ) {}
        let topLeadingInk = try RenderedInk.pixels(
            cover.safeAreaPadding(.top, 120).frame(width: 480, height: 360).mask(alignment: .topLeading) {
                Rectangle().frame(width: 160, height: 80)
            })
        #expect(topLeadingInk > 0)
    }

    @Test func theCoverUsesStableMetrics() {
        #expect(ProtectedScopeCoverMetrics.symbolSize == 44)
        #expect(ProtectedScopeCoverMetrics.spacing == 24)
    }
}
