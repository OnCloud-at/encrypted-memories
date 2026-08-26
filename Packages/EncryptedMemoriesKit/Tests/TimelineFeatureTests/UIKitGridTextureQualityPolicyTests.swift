import CoreGraphics
import Testing

@testable import GridCore
@testable import MetalGridTextureUIKitAdapter

/// Keeps dense uploads small, allows sparse tiles to reach native display resolution, and preserves byte budgets.
@Suite("UIKitGridTextureQualityPolicy")
struct UIKitGridTextureQualityPolicyTests {
    @Test func denseLevelUploadsStaySmallUnderTheRaisedCaps() {
        // A dense-overview tile (~31 pt on a 3× iPhone) must resolve far below the absolute cap -
        // the cap raise may not touch dense-scroll upload cost.
        let dense = GridTextureUploadSizing.uploadPixels(
            slotSidePoints: 31, backingScale: 3, headroom: 1.15, floor: 64,
            cap: UIKitMetalGridTexturePolicies.compact.maxTexturePixels
        )
        #expect(dense == 107)
        #expect(dense < 128)
    }

    @Test func largestCompactTilesCanRequestSharpPixels() {
        // The largest compact tile must reach its native supersampled size within the cap.
        let sparse = GridTextureUploadSizing.uploadPixels(
            slotSidePoints: 133, backingScale: 3, headroom: 1.15, floor: 64,
            cap: UIKitMetalGridTexturePolicies.compact.maxTexturePixels
        )
        #expect(sparse == 459)
        #expect(sparse > 288)  // above the previous ceiling
    }

    @Test func absolutePixelCapsMatchTheSurfaceCalibration() {
        #expect(UIKitMetalGridTexturePolicies.compact.maxTexturePixels == 480)
        #expect(UIKitMetalGridTexturePolicies.regular.maxTexturePixels == 512)
        #expect(UIKitMetalGridTexturePolicies.expanded.maxTexturePixels == 512)
    }

    @Test func jetsamCalibratedByteBudgetsAreUnchangedByTheCapRaise() {
        #expect(UIKitMetalGridTexturePolicies.compact.budget.maxResidentBytes == 67_108_864)  // 64 MiB
        #expect(UIKitMetalGridTexturePolicies.regular.budget.maxResidentBytes == 100_663_296)  // 96 MiB
        #expect(UIKitMetalGridTexturePolicies.expanded.budget.maxResidentBytes == 201_326_592)  // 192 MiB
        #expect(UIKitMetalGridTexturePolicies.compact.budget.maxUploadBytesPerFrame == 2_097_152)
        #expect(UIKitMetalGridTexturePolicies.regular.budget.maxUploadBytesPerFrame == 3_145_728)
        #expect(UIKitMetalGridTexturePolicies.expanded.budget.maxUploadBytesPerFrame == 4_194_304)
    }
}
