import PhotosCore
import Testing

@testable import MediaCacheUIKitAdapter

@MainActor
@Suite("UIKit memory-pressure ownership in the iOS test host")
struct UIKitMemoryPressureCoordinatorAppTests {
    private final class Owner {
        var tiers: [MemoryBudgetTier] = []
    }

    @Test func separateOwnersSharingRoleStayIndependent() {
        let governor = MemoryPressureGovernor()
        let coordinator = UIKitMemoryPressureCoordinator(testGovernor: governor)
        let first = Owner()
        let second = Owner()

        coordinator.attach(first, key: "gridTextureCache") { [weak first] tier in
            first?.tiers.append(tier)
        }
        coordinator.attach(second, key: "gridTextureCache") { [weak second] tier in
            second?.tiers.append(tier)
        }

        governor.update(MemoryConditions(pressure: .warning))
        #expect(first.tiers == [.normal, .reduced])
        #expect(second.tiers == [.normal, .reduced])

        coordinator.detach(first)
        governor.update(MemoryConditions(pressure: .critical))
        #expect(first.tiers == [.normal, .reduced])
        #expect(second.tiers == [.normal, .reduced, .minimal])
    }

    @Test func coordinatorDeinitEndsEveryLiveOwnerRegistration() async {
        let governor = MemoryPressureGovernor()
        let owner = Owner()
        var coordinator: UIKitMemoryPressureCoordinator? = UIKitMemoryPressureCoordinator(testGovernor: governor)

        coordinator?.attach(owner, key: "gridTextureCache") { [weak owner] tier in
            owner?.tiers.append(tier)
        }
        #expect(owner.tiers == [.normal])

        coordinator = nil
        for _ in 0..<100 where governor.responderCount != 0 {
            await Task.yield()
        }
        #expect(governor.responderCount == 0)

        governor.update(MemoryConditions(pressure: .warning))
        #expect(owner.tiers == [.normal])
    }
}
