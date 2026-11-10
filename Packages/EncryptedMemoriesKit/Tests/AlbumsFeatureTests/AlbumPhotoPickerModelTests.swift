import PhotosCore
import XCTest

@testable import AlbumCore
@testable import AlbumsFeature

private func pickerUID(_ nodeID: String, volume: String = "volume") -> PhotoUID {
    PhotoUID(volumeID: volume, nodeID: nodeID)
}

private func pickerItem(_ uid: PhotoUID) -> PhotoItem {
    PhotoItem(uid: uid, captureTime: Date(timeIntervalSince1970: 0), mediaType: "image/jpeg")
}

private func loaded(
    _ uids: [PhotoUID], authority: SourceInventoryAuthority = .authoritative
) -> AlbumPhotoPickerLibrary {
    .loaded(uids.map(pickerItem), authority: authority)
}

@MainActor
final class AlbumPhotoPickerModelTests: XCTestCase {
    private let pending = PhotoUID(localPending: .photoLibrary, identifier: "asset-1")

    private func makeModel(_ backend: FakeAlbumBackend) -> AlbumPhotoPickerModel {
        AlbumPhotoPickerModel(albumID: "album", coordinator: AlbumActionCoordinator(repository: repository(backend)))
    }

    private func readyModel(
        _ backend: FakeAlbumBackend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites),
        library: [PhotoUID],
        members: Set<String> = []
    ) async -> AlbumPhotoPickerModel {
        let model = makeModel(backend)
        await model.update(library: loaded(library), albumNodeIDs: members)
        return model
    }

    // MARK: Candidates

    func testCandidatesLeaveOutPhotosOfTheAlbumAndPhotosThatAreNotUploaded() async {
        let model = await readyModel(
            library: [pickerUID("a"), pickerUID("b"), pending, pickerUID("c")], members: ["b"])

        XCTAssertEqual(model.candidates.map(\.uid), [pickerUID("a"), pickerUID("c")])
        XCTAssertEqual(model.content, .choose)
    }

    func testAlbumMembershipComparesNodesNotVolumes() {
        let candidates = AlbumPhotoPickerModel.candidates(
            from: [pickerItem(pickerUID("a", volume: "own")), pickerItem(pickerUID("b", volume: "own"))],
            excludingAlbumNodeIDs: AlbumPhotoPickerModel.albumNodeIDs(of: [pickerItem(pickerUID("a", volume: "route"))])
        )

        XCTAssertEqual(candidates.map(\.uid), [pickerUID("b", volume: "own")])
    }

    func testAlbumMembershipCoversLivePhotoAndBurstGrouping() {
        let livePhoto = PhotoItem(
            uid: pickerUID("live"), captureTime: .distantPast, mediaType: "image/heic", isLivePhoto: true,
            relatedVideoID: "live-video")
        let libraryBurst = PhotoItem(
            uid: pickerUID("burst-2"), captureTime: .distantPast, mediaType: "image/jpeg",
            burstMemberIDs: ["burst-1", "burst-2", "burst-3"])
        let routeBurst = PhotoItem(
            uid: pickerUID("burst-1"), captureTime: .distantPast, mediaType: "image/jpeg",
            burstMemberIDs: ["burst-1", "burst-2", "burst-3"])
        let other = pickerItem(pickerUID("other"))

        let candidates = AlbumPhotoPickerModel.candidates(
            from: [livePhoto, libraryBurst, other],
            excludingAlbumNodeIDs: AlbumPhotoPickerModel.albumNodeIDs(of: [livePhoto, routeBurst])
        )

        XCTAssertEqual(
            candidates.map(\.uid), [pickerUID("other")], "a burst grouped under another main is in the album")
    }

    func testCandidatesForALargeLibraryTakeOnePass() {
        let library = (0..<100_000).map { pickerItem(pickerUID("p\($0)")) }
        let members = Set((0..<50_000).map { "p\($0 * 2)" })
        let start = ContinuousClock.now

        let candidates = AlbumPhotoPickerModel.candidates(from: library, excludingAlbumNodeIDs: members)

        let elapsed = ContinuousClock.now - start
        XCTAssertEqual(candidates.count, 50_000)
        XCTAssertEqual(candidates.first?.uid, pickerUID("p1"))
        print("[AlbumPhotoPicker] 100k candidates in \(elapsed)")
        XCTAssertLessThan(elapsed, .seconds(2), "the filter must stay one linear pass")
    }

    // MARK: Content states

    func testContentStaysLoadingUntilTheLibraryAndTheAlbumAreLoaded() async {
        let model = makeModel(FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites))
        XCTAssertEqual(model.content, .loading)

        await model.update(library: .loading, albumNodeIDs: [])
        XCTAssertEqual(model.content, .loading)

        await model.update(library: loaded([pickerUID("a")]), albumNodeIDs: nil)
        XCTAssertEqual(model.content, .loading, "the album route is still loading")
        XCTAssertTrue(model.candidates.isEmpty)
    }

    func testAnAlbumThatHoldsEveryPhotoSaysSoOnlyWithAnAuthoritativeLibrary() async {
        let model = makeModel(FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites))

        await model.update(library: loaded([pickerUID("a")], authority: .cached), albumNodeIDs: ["a"])
        XCTAssertEqual(model.content, .loading, "a saved library can be stale")
        await model.update(library: loaded([pickerUID("a")], authority: .hydrating), albumNodeIDs: ["a"])
        XCTAssertEqual(model.content, .loading)

        await model.update(library: loaded([pickerUID("a")]), albumNodeIDs: ["a"])
        XCTAssertEqual(model.content, .nothingToAdd)
    }

    func testAnEmptyLibraryIsReportedOnlyWithAuthority() async {
        let model = makeModel(FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites))

        await model.update(library: loaded([], authority: .cached), albumNodeIDs: [])
        XCTAssertEqual(model.content, .loading)

        await model.update(library: loaded([]), albumNodeIDs: [])
        XCTAssertEqual(model.content, .emptyLibrary)
    }

    func testAnEmptyAlbumOffersTheWholeLibrary() async {
        let model = await readyModel(library: [pickerUID("a"), pickerUID("b")], members: [])

        XCTAssertEqual(model.candidates.count, 2)
        XCTAssertEqual(model.content, .choose)
    }

    func testASavedLibraryWithPhotosToAddShowsTheGrid() async {
        let model = makeModel(FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites))

        await model.update(library: loaded([pickerUID("a"), pickerUID("b")], authority: .cached), albumNodeIDs: ["a"])

        XCTAssertEqual(model.content, .choose)
        XCTAssertEqual(model.candidates.map(\.uid), [pickerUID("b")])
    }

    func testOnlyPhotosThatAreNotUploadedLeaveNothingToAdd() async {
        let model = await readyModel(library: [pending], members: [])

        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertNotEqual(model.content, .choose)
    }

    func testALoadFailureThenARetryShowsTheGrid() async {
        let model = makeModel(FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites))

        await model.update(library: .failed(message: "offline"), albumNodeIDs: [])
        XCTAssertEqual(model.content, .failed(message: "offline"))

        await model.update(library: .loading, albumNodeIDs: [])
        XCTAssertEqual(model.content, .loading)

        await model.update(library: loaded([pickerUID("a")]), albumNodeIDs: [])
        XCTAssertEqual(model.content, .choose)
    }

    func testTheCandidatesStayFixedOnceTheGridShows() async {
        let model = await readyModel(library: [pickerUID("a"), pickerUID("b")])
        model.replaceSelection(with: [pickerUID("a")])

        await model.update(library: loaded([pickerUID("b"), pickerUID("c")]), albumNodeIDs: [])
        await model.update(library: .failed(message: "offline"), albumNodeIDs: [])

        XCTAssertEqual(model.candidates.map(\.uid), [pickerUID("a"), pickerUID("b")])
        XCTAssertEqual(model.selection, [pickerUID("a")])
        XCTAssertEqual(model.content, .choose)
    }

    // MARK: Selection and submit

    func testSelectionAcceptsOnlyCandidates() async {
        let model = await readyModel(library: [pickerUID("a"), pickerUID("b"), pending], members: ["b"])

        model.replaceSelection(with: [pickerUID("a"), pickerUID("b"), pending, pickerUID("unknown")])
        XCTAssertEqual(model.selection, [pickerUID("a")])

        model.toggle(pickerUID("a"))
        model.toggle(pickerUID("b"))
        model.toggle(pending)
        XCTAssertEqual(model.selection, [])

        model.toggle(pickerUID("a"))
        XCTAssertEqual(model.selection, [pickerUID("a")])
    }

    func testAnEmptySelectionCannotBeSubmittedAndSendsNoRequest() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        let model = await readyModel(backend, library: [pickerUID("a")])

        XCTAssertFalse(model.canSubmit)
        let outcome = await model.submit()

        XCTAssertEqual(outcome, .notStarted)
        XCTAssertTrue(backend.added.isEmpty)
    }

    func testSubmitAddsTheSelectionOnceInLibraryOrder() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        let model = await readyModel(backend, library: [pickerUID("c"), pickerUID("a"), pickerUID("b")])
        model.toggle(pickerUID("b"))
        model.toggle(pickerUID("c"))

        XCTAssertTrue(model.canSubmit)
        let outcome = await model.submit()

        XCTAssertEqual(outcome, .added)
        XCTAssertEqual(backend.added.count, 1)
        XCTAssertEqual(backend.added.first?.uids, [pickerUID("c"), pickerUID("b")])
        XCTAssertEqual(backend.added.first?.album, "album")
        XCTAssertNil(model.coordinator.actionFailure)
    }

    func testAnAddWhileAnotherAlbumChangeRunsDoesNotStart() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        let gate = AsyncStream<Void>.makeStream()
        backend.listHold = { for await _ in gate.stream { break } }
        let coordinator = AlbumActionCoordinator(repository: repository(backend))
        let model = AlbumPhotoPickerModel(albumID: "album", coordinator: coordinator)
        await model.update(library: loaded([pickerUID("a")]), albumNodeIDs: [])
        model.toggle(pickerUID("a"))
        let running = Task { await coordinator.createAlbum(name: "Other") }
        while !coordinator.isWorking { await Task.yield() }

        XCTAssertFalse(model.canSubmit)
        let outcome = await model.submit()

        XCTAssertEqual(outcome, .notStarted)
        XCTAssertEqual(model.selection, [pickerUID("a")])
        XCTAssertNil(coordinator.actionFailure)
        gate.continuation.finish()
        _ = await running.value
        XCTAssertTrue(backend.added.isEmpty)
    }

    func testAFailedAddKeepsTheSelectionAndCanBeRetried() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        backend.addError = AlbumError.partialAdd(succeeded: 1, total: 2, message: "one photo failed")
        let model = await readyModel(backend, library: [pickerUID("a"), pickerUID("b")])
        model.replaceSelection(with: [pickerUID("a"), pickerUID("b")])

        let failed = await model.submit()

        XCTAssertEqual(failed, .failed)
        XCTAssertEqual(model.selection, [pickerUID("a"), pickerUID("b")])
        XCTAssertNotNil(model.coordinator.actionFailure)
        XCTAssertTrue(model.canSubmit, "the person can retry the same selection")

        backend.addError = nil
        model.coordinator.clearActionFailure()
        let retried = await model.submit()

        XCTAssertEqual(retried, .added)
        XCTAssertEqual(backend.added.last?.uids, [pickerUID("a"), pickerUID("b")])
    }

    // MARK: Availability and the shared-album guard

    func testTheActionIsOfferedOnlyForAnOwnedAlbumThatAcceptsPhotos() {
        let writable = AlbumsRepository(
            catalogBackend: FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites),
            writeBackend: FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites),
            capabilities: .sdkCatalogWithHTTPWrites
        )
        let readOnly = AlbumsRepository(
            catalogBackend: FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites),
            writeBackend: FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites),
            capabilities: AlbumCapabilities(
                canList: true, canCreate: true, canAddPhotos: false, canSetCover: false, canReadMemberships: true)
        )
        let owned = PhotoFilter.album(id: "album", title: "Album")
        let shared = PhotoFilter.sharedAlbum(volumeID: "shared-volume", nodeID: "album", title: "Shared")
        let writableActions = AlbumActionCoordinator(repository: writable)
        let readOnlyActions = AlbumActionCoordinator(repository: readOnly)

        XCTAssertTrue(AlbumPhotoPickerModel.isOffered(for: owned, coordinator: writableActions))
        XCTAssertFalse(AlbumPhotoPickerModel.isOffered(for: shared, coordinator: writableActions))
        XCTAssertFalse(AlbumPhotoPickerModel.isOffered(for: .all, coordinator: writableActions))
        XCTAssertFalse(AlbumPhotoPickerModel.isOffered(for: owned, coordinator: readOnlyActions))
    }

    func testAKnownSharedAlbumIsRejectedBeforeAnyRequest() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        backend.sharedAlbums = [
            SharedAlbumSummary(
                node: AlbumNodeIdentifier(volumeID: "shared-volume", nodeID: "album"),
                title: "Shared",
                photoCount: 1,
                coverPhotoID: nil,
                owner: "Owner",
                lastActivityTime: nil,
                isSharedByURL: false,
                isMetadataDegraded: false
            )
        ]
        let coordinator = AlbumActionCoordinator(repository: repository(backend))
        await coordinator.refreshSharedAlbums()
        let model = AlbumPhotoPickerModel(albumID: "album", coordinator: coordinator)
        await model.update(library: loaded([pickerUID("a")]), albumNodeIDs: [])
        model.toggle(pickerUID("a"))

        let outcome = await model.submit()

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(backend.added.isEmpty)
        XCTAssertNotNil(coordinator.actionFailure)
    }
}
