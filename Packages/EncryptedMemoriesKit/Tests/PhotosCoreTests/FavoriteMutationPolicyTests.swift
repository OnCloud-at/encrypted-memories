import XCTest

@testable import PhotosCore

final class FavoriteMutationPolicyTests: XCTestCase {
    private let a = PhotoUID(volumeID: "v", nodeID: "a")
    private let b = PhotoUID(volumeID: "v", nodeID: "b")
    private let c = PhotoUID(volumeID: "v", nodeID: "c")

    func testSingleSelectionTogglesFromAuthoritativeState() {
        XCTAssertEqual(
            FavoriteMutationPolicy.target(for: [a], current: []),
            true
        )
        XCTAssertEqual(
            FavoriteMutationPolicy.target(for: [a], current: [a]),
            false
        )
        XCTAssertNil(FavoriteMutationPolicy.target(for: [], current: [a]))
    }

    func testMixedSelectionFavoritesOnlyItemsThatNeedChanging() {
        let selection: Set<PhotoUID> = [a, b, c]
        let current: Set<PhotoUID> = [a]
        let target = FavoriteMutationPolicy.target(for: selection, current: current)

        XCTAssertEqual(target, true)
        XCTAssertEqual(
            FavoriteMutationPolicy.requestedUIDs(
                selection: selection,
                current: current,
                target: true
            ),
            [b, c]
        )
    }

    func testPartialFailureRollsBackOnlyFailedIdentities() {
        let optimistic = FavoriteMutationPolicy.optimisticState(
            current: [a],
            requested: [b, c],
            target: true
        )
        XCTAssertEqual(optimistic, [a, b, c])

        let reconciled = FavoriteMutationPolicy.rollbackState(
            current: optimistic,
            failed: [c],
            target: true
        )
        XCTAssertEqual(reconciled, [a, b])
    }

    func testUnfavoriteRollbackRestoresOnlyFailedIdentities() {
        let optimistic = FavoriteMutationPolicy.optimisticState(
            current: [a, b, c],
            requested: [a, b],
            target: false
        )
        XCTAssertEqual(optimistic, [c])

        let reconciled = FavoriteMutationPolicy.rollbackState(
            current: optimistic,
            failed: [b],
            target: false
        )
        XCTAssertEqual(reconciled, [b, c])
    }

    func testDelayedAuthoritativeReadPreservesNewerMutationTargets() {
        let reconciled = FavoriteMutationPolicy.reconciling(
            authoritative: [a, c],
            newerTargets: [a: false, b: true]
        )

        XCTAssertEqual(reconciled, [b, c])
    }
}
