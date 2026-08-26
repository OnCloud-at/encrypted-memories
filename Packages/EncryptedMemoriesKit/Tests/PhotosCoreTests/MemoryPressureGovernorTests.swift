import XCTest

@testable import PhotosCore

/// Guards for the Core memory-pressure coordination mechanism: pressure and thermal conditions determine the tier policy,
/// is deterministic, the fan-out only fires on a real tier change, and registrations sync + unwind
/// cleanly. Platform event sources (DispatchSource / memory warnings) live in adapters and are not
/// exercised here - this proves the portable core the adapters feed.
@MainActor
final class MemoryPressureGovernorTests: XCTestCase {
    func testPolicyMapsConditionsToTierDeterministically() {
        func tier(
            _ p: MemoryConditions.Pressure, _ t: MemoryConditions.Thermal = .nominal, lpm: Bool = false
        ) -> MemoryBudgetTier {
            MemoryBudgetPolicy.tier(for: MemoryConditions(pressure: p, thermal: t, lowPowerMode: lpm))
        }
        // Pressure drives it.
        XCTAssertEqual(tier(.normal), .normal)
        XCTAssertEqual(tier(.warning), .reduced)
        XCTAssertEqual(tier(.critical), .minimal)
        // Thermal escalates independently.
        XCTAssertEqual(tier(.normal, .serious), .reduced)
        XCTAssertEqual(tier(.normal, .critical), .minimal)
        // Critical anywhere wins over a milder signal on the other axis.
        XCTAssertEqual(tier(.warning, .critical), .minimal)
        XCTAssertEqual(tier(.critical, .nominal), .minimal)
        // `.fair` thermal and Low Power Mode never shrink caches (documented: avoids re-decode churn).
        XCTAssertEqual(tier(.normal, .fair), .normal)
        XCTAssertEqual(tier(.normal, .nominal, lpm: true), .normal)
    }

    func testTierScaleAndPurgeSemantics() {
        XCTAssertEqual(MemoryBudgetTier.normal.budgetScale, 1.0)
        XCTAssertEqual(MemoryBudgetTier.reduced.budgetScale, 0.5)
        XCTAssertEqual(MemoryBudgetTier.minimal.budgetScale, 0.0)
        XCTAssertFalse(MemoryBudgetTier.normal.requiresImmediatePurge)
        XCTAssertFalse(MemoryBudgetTier.reduced.requiresImmediatePurge)
        XCTAssertTrue(MemoryBudgetTier.minimal.requiresImmediatePurge)
        XCTAssertTrue(MemoryBudgetTier.reduced > .normal)
        XCTAssertTrue(MemoryBudgetTier.minimal > .reduced)
    }

    func testFanOutDeliversTierChangesToAllRespondersOnlyOnChange() {
        let governor = MemoryPressureGovernor()
        var a: [MemoryBudgetTier] = []
        var b: [MemoryBudgetTier] = []
        // Registration syncs the joiner to the current tier immediately.
        governor.register { a.append($0) }
        governor.register { b.append($0) }
        XCTAssertEqual(a, [.normal])
        XCTAssertEqual(b, [.normal])
        XCTAssertEqual(governor.responderCount, 2)

        governor.update(MemoryConditions(pressure: .warning))  // normal to reduced
        XCTAssertEqual(a, [.normal, .reduced])
        XCTAssertEqual(b, [.normal, .reduced])

        // Same resolved tier from a different signal must not re-fire (thermal .serious == reduced).
        governor.update(MemoryConditions(pressure: .warning, thermal: .serious))
        XCTAssertEqual(a, [.normal, .reduced], "no redundant fan-out when the tier is unchanged")

        governor.update(MemoryConditions(pressure: .critical))  // reduced to minimal
        XCTAssertEqual(a, [.normal, .reduced, .minimal])

        governor.update(MemoryConditions())  // back to normal
        XCTAssertEqual(a, [.normal, .reduced, .minimal, .normal])
        XCTAssertEqual(b, [.normal, .reduced, .minimal, .normal])
        XCTAssertEqual(governor.tier, .normal)
    }

    func testRegistrationEndRemovesResponder() {
        let governor = MemoryPressureGovernor()
        var received: [MemoryBudgetTier] = []
        let token = governor.register { received.append($0) }
        governor.update(MemoryConditions(pressure: .warning))
        XCTAssertEqual(received, [.normal, .reduced])
        XCTAssertEqual(governor.responderCount, 1)

        token.end()
        XCTAssertEqual(governor.responderCount, 0)
        governor.update(MemoryConditions(pressure: .critical))
        XCTAssertEqual(received, [.normal, .reduced], "ended registration must stop receiving updates")
    }

    func testRegistrationEndFromDetachedTaskRunsOnMainActor() async {
        let governor = MemoryPressureGovernor()
        var received: [MemoryBudgetTier] = []
        let token = governor.register { received.append($0) }

        await Task.detached {
            await token.end()
        }.value

        XCTAssertEqual(governor.responderCount, 0)
        governor.update(MemoryConditions(pressure: .warning))
        XCTAssertEqual(received, [.normal])
    }

    func testResponderCanEndItselfDuringFanOutWithoutSkippingPeer() {
        let governor = MemoryPressureGovernor()
        var first: [MemoryBudgetTier] = []
        var second: [MemoryBudgetTier] = []
        var firstRegistration: MemoryPressureRegistration?
        firstRegistration = governor.register { tier in
            first.append(tier)
            if tier == .reduced {
                firstRegistration?.end()
            }
        }
        governor.register { second.append($0) }

        governor.update(MemoryConditions(pressure: .warning))

        XCTAssertEqual(first, [.normal, .reduced])
        XCTAssertEqual(second, [.normal, .reduced])
        XCTAssertEqual(governor.responderCount, 1)

        governor.update(MemoryConditions(pressure: .critical))
        XCTAssertEqual(first, [.normal, .reduced])
        XCTAssertEqual(second, [.normal, .reduced, .minimal])
    }

    func testResponderAddedDuringFanOutJoinsCurrentTierOnce() {
        let governor = MemoryPressureGovernor()
        var existing: [MemoryBudgetTier] = []
        var added: [MemoryBudgetTier] = []
        var addedRegistration: MemoryPressureRegistration?
        governor.register { tier in
            existing.append(tier)
            if tier == .reduced, addedRegistration == nil {
                addedRegistration = governor.register { added.append($0) }
            }
        }

        governor.update(MemoryConditions(pressure: .warning))

        XCTAssertEqual(existing, [.normal, .reduced])
        XCTAssertEqual(added, [.reduced], "the new responder receives only register()'s immediate sync")

        governor.update(MemoryConditions(pressure: .critical))
        XCTAssertEqual(existing, [.normal, .reduced, .minimal])
        XCTAssertEqual(added, [.reduced, .minimal])
    }

    func testRegisteringUnderExistingPressureSyncsToCurrentTier() {
        let governor = MemoryPressureGovernor()
        governor.update(MemoryConditions(pressure: .critical))
        var received: [MemoryBudgetTier] = []
        governor.register { received.append($0) }
        XCTAssertEqual(received, [.minimal], "a responder joining under pressure adopts the current tier")
    }

    func testTypedResponderConformanceReceivesTiers() {
        final class Spy: MemoryPressureResponder {
            var tiers: [MemoryBudgetTier] = []
            func respondToMemoryBudget(_ tier: MemoryBudgetTier) { tiers.append(tier) }
        }
        let governor = MemoryPressureGovernor()
        let spy = Spy()
        governor.register(spy)
        governor.update(MemoryConditions(pressure: .warning))
        XCTAssertEqual(spy.tiers, [.normal, .reduced])
    }

    func testSharedRuntimeStateReceivesEveryConditionEvenWithoutTierChange() {
        let runtimeState = LibraryRuntimeState()
        let governor = MemoryPressureGovernor(runtimeState: runtimeState)

        governor.update(MemoryConditions(pressure: .normal, thermal: .fair, lowPowerMode: true))

        let snapshot = runtimeState.snapshot()
        XCTAssertEqual(snapshot.thermalLevel, .fair)
        XCTAssertEqual(snapshot.memoryBudgetTier, .normal)
        XCTAssertEqual(snapshot.memoryHeadroom, .healthy)
        XCTAssertTrue(snapshot.isLowPowerMode)

        governor.update(MemoryConditions(pressure: .warning))
        XCTAssertEqual(runtimeState.snapshot().memoryHeadroom, .constrained)
        governor.update(MemoryConditions(pressure: .critical))
        XCTAssertEqual(runtimeState.snapshot().memoryHeadroom, .critical)
    }
}
