import Testing

@testable import DesignSystemAppKitAdapter

@Suite("Tip jar celebration window overlay")
@MainActor
struct TipJarCelebrationWindowOverlayTests {
    @Test("Uses a foreground, click-through native window policy")
    func usesForegroundClickThroughPolicy() {
        #expect(TipJarCelebrationWindowPolicy.orderingMode == .above)
        #expect(TipJarCelebrationWindowPolicy.ignoresMouseEvents)
        #expect(!TipJarCelebrationWindowPolicy.isOpaque)
        #expect(TipJarCelebrationWindowPolicy.styleMask.contains(.nonactivatingPanel))
        #expect(!TipJarCelebrationWindowPolicy.styleMask.contains(.titled))
    }
}
