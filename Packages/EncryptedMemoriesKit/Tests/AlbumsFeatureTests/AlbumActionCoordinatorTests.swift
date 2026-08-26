import PhotosCore
import XCTest

@testable import AlbumCore
@testable import AlbumsFeature

private func coordinatorUID(_ nodeID: String) -> PhotoUID {
    PhotoUID(volumeID: "volume", nodeID: nodeID)
}

final class AlbumActionCoordinatorTests: XCTestCase {
    private func sharedAlbum(_ nodeID: String) -> SharedAlbumSummary {
        SharedAlbumSummary(
            node: AlbumNodeIdentifier(volumeID: "shared-volume", nodeID: nodeID),
            title: "Shared \(nodeID)",
            photoCount: 4,
            coverPhotoID: nil,
            owner: "Owner",
            lastActivityTime: nil,
            isSharedByURL: false,
            isMetadataDegraded: false
        )
    }

    @MainActor
    func testAlbumLoadingPlaceholdersDisappearPermanentlyAfterInitialRefresh() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        let coordinator = AlbumActionCoordinator(repository: repository(backend))

        XCTAssertTrue(coordinator.showsInitialAlbumLoadingPlaceholder)
        XCTAssertTrue(coordinator.showsInitialSharedAlbumLoadingPlaceholder)

        await coordinator.refresh()
        await coordinator.refreshSharedAlbums()

        XCTAssertTrue(coordinator.hasCompletedInitialAlbumLoad)
        XCTAssertTrue(coordinator.hasCompletedInitialSharedAlbumLoad)
        XCTAssertFalse(coordinator.showsInitialAlbumLoadingPlaceholder)
        XCTAssertFalse(coordinator.showsInitialSharedAlbumLoadingPlaceholder)

        await coordinator.refresh()
        await coordinator.refreshSharedAlbums()

        XCTAssertFalse(coordinator.showsInitialAlbumLoadingPlaceholder)
        XCTAssertFalse(coordinator.showsInitialSharedAlbumLoadingPlaceholder)
    }

    @MainActor
    func testCreateAndAddRefreshesSharedAlbumState() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        let coordinator = AlbumActionCoordinator(repository: repository(backend))

        let outcome = await coordinator.createAlbum(
            name: "  Summer  ",
            adding: [coordinatorUID("one"), coordinatorUID("two")]
        )

        XCTAssertEqual(outcome, .completed(albumID: "album-0"))
        XCTAssertEqual(coordinator.albums.map(\.title), ["Summer"])
        XCTAssertEqual(backend.added.first?.uids.count, 2)
        XCTAssertNil(coordinator.actionFailure)
        XCTAssertFalse(coordinator.isWorking)
    }

    @MainActor
    func testCreatedAlbumMembershipFailureKeepsAlbumAndReportsRetryOutcome() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        backend.addError = AlbumError.partialAdd(succeeded: 1, total: 2, message: "retry later")
        let coordinator = AlbumActionCoordinator(repository: repository(backend))

        let outcome = await coordinator.createAlbum(
            name: "Summer",
            adding: [coordinatorUID("one"), coordinatorUID("two")]
        )

        XCTAssertEqual(outcome, .albumCreatedNeedsMembershipRetry(albumID: "album-0"))
        XCTAssertEqual(coordinator.albums.map(\.id), ["album-0"])
        XCTAssertNotNil(coordinator.actionFailure)
        XCTAssertTrue(coordinator.actionFailure?.message.contains("Summer") == true)
        XCTAssertFalse(coordinator.actionFailure?.message.contains("retry later") == true)
    }

    @MainActor
    func testExistingAlbumAddFailurePreservesSelectionForRetry() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        backend.addError = NSError(
            domain: "ProtonAlbumAPI",
            code: 2_000,
            userInfo: [NSLocalizedDescriptionKey: "service unavailable"]
        )
        let coordinator = AlbumActionCoordinator(repository: repository(backend))

        let succeeded = await coordinator.add([coordinatorUID("one")], to: "album-existing")

        XCTAssertFalse(succeeded)
        XCTAssertEqual(coordinator.actionFailure?.message, L10n.string("error.album_backend"))
        XCTAssertFalse(coordinator.actionFailure?.message.contains("service unavailable") == true)
        XCTAssertFalse(coordinator.isWorking)
    }

    @MainActor
    func testSharedCatalogRefreshAndLeaveUpdateOneSharedStateMachine() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        backend.sharedAlbums = [sharedAlbum("one"), sharedAlbum("two")]
        let coordinator = AlbumActionCoordinator(repository: repository(backend))

        await coordinator.refreshSharedAlbums()
        XCTAssertEqual(coordinator.sharedAlbums.map(\.node.nodeID), ["one", "two"])

        let left = await coordinator.leaveSharedAlbum(coordinator.sharedAlbums[0])

        XCTAssertTrue(left)
        XCTAssertEqual(backend.leftSharedAlbums.map(\.nodeID), ["one"])
        XCTAssertEqual(coordinator.sharedAlbums.map(\.node.nodeID), ["two"])
    }

    @MainActor
    func testMembershipHintsAvoidRedundantAddAndOnlySubmitMissingPhotos() async {
        let first = coordinatorUID("one")
        let second = coordinatorUID("two")
        let albumID = "album-existing"
        let backend = FakeAlbumBackend(
            capabilities: .sdkCatalogWithHTTPWrites,
            albums: [AlbumSummary(id: albumID, title: "Existing", photoCount: 1, coverPhotoID: nil)]
        )
        backend.memberships[first] = [AlbumNodeIdentifier(volumeID: "volume", nodeID: albumID)]
        let coordinator = AlbumActionCoordinator(repository: repository(backend))

        await coordinator.loadMemberships(for: [first, second])
        XCTAssertEqual(coordinator.membershipState(for: albumID), .some)
        XCTAssertEqual(coordinator.membershipState(for: "another-album"), AlbumMembershipState.none)

        let added = await coordinator.add([first, second], to: albumID)

        XCTAssertTrue(added)
        XCTAssertEqual(backend.added.count, 1)
        XCTAssertEqual(Set(backend.added[0].uids), Set([second]))
        XCTAssertEqual(coordinator.membershipState(for: albumID), .all)

        let redundantAdd = await coordinator.add([first, second], to: albumID)
        XCTAssertTrue(redundantAdd)
        XCTAssertEqual(backend.added.count, 1)
    }

    @MainActor
    func testLargeSelectionDoesNotSchedulePerPhotoMembershipReads() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        let coordinator = AlbumActionCoordinator(repository: repository(backend))
        let selection = (0...AlbumActionCoordinator.membershipSelectionLimit)
            .map { coordinatorUID("\($0)") }

        await coordinator.loadMemberships(for: selection)

        XCTAssertTrue(backend.membershipRequests.isEmpty)
        XCTAssertNil(coordinator.membershipState(for: "album"))
    }
}
