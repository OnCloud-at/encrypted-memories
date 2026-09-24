import Foundation
import Testing

@testable import MLSearchCore

@Suite struct MLIndexingCapacityProfileTests {
    @Test func platformProfilesKeepMobileConservativeAndDesktopTimeBounded() {
        #expect(MLIndexingCapacityProfile.constrained.nativeQuantumAssets == 2)
        #expect(MLIndexingCapacityProfile.constrained.semanticQuantumAssets == 2)
        #expect(MLIndexingCapacityProfile.constrained.automaticTimeSlice == nil)
        #expect(!MLIndexingCapacityProfile.constrained.rampsNativeParallelism)

        #expect(MLIndexingCapacityProfile.sustained.nativeQuantumAssets == 32)
        #expect(MLIndexingCapacityProfile.sustained.semanticQuantumAssets == 128)
        #expect(MLIndexingCapacityProfile.sustained.automaticTimeSlice == .seconds(2))
        #expect(MLIndexingCapacityProfile.sustained.rampsNativeParallelism)
    }

    @Test func nativeRampStartsAtOneAndAdvancesAfterTwoPlusTwoCleanQuanta() {
        var ramp = MLNativeParallelismRamp(ceiling: 3, profile: .sustained)
        #expect(ramp.currentParallelism == 1)

        ramp.note(.clean)
        #expect(ramp.currentParallelism == 1)
        ramp.note(.clean)
        #expect(ramp.currentParallelism == 2)
        ramp.note(.clean)
        #expect(ramp.currentParallelism == 2)
        ramp.note(.clean)
        #expect(ramp.currentParallelism == 3)

        ramp.note(.clean)
        #expect(ramp.currentParallelism == 3)
    }

    @Test func nativeRampHonorsCapabilityCeilingAndResetsOnlyForResourceYield() {
        var ramp = MLNativeParallelismRamp(ceiling: 2, profile: .sustained)
        ramp.note(.clean)
        ramp.note(.clean)
        #expect(ramp.currentParallelism == 2)

        ramp.note(.neutralFailure)
        #expect(ramp.currentParallelism == 2)

        ramp.note(.resourceYield)
        #expect(ramp.currentParallelism == 1)
        #expect(ramp.cleanQuantumCount == 0)
    }

    @Test func constrainedProfileNeverIntroducesAdaptiveParallelism() {
        var ramp = MLNativeParallelismRamp(ceiling: 3, profile: .constrained)
        #expect(ramp.currentParallelism == 2)
        for _ in 0..<6 { ramp.note(.clean) }
        #expect(ramp.currentParallelism == 2)
        ramp.note(.resourceYield)
        #expect(ramp.currentParallelism == 2)
    }
}
