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
    private let offline = "offline"

    private func makeModel(_ backend: FakeAlbumBackend) -> AlbumPhotoPickerModel {
        AlbumPhotoPickerModel(albumID: "album", coordinator: AlbumActionCoordinator(repository: repository(backend)))
    }

    private func readyModel(
        _ backend: FakeAlbumBackend = FakeAlbumBackend(capabilities: .sdkCatalogAndWrites),
        library: [PhotoUID],
        members: Set<String> = []
    ) async -> AlbumPhotoPickerModel {
        let model = makeModel(backend)
        await model.update(library: loaded(library), albumNodeIDs: members)
        return model
    }

    // MARK: Candidates

    func testCandidatesLeaveOutPhotosOfTheAlbumAndKeepPhotosThatAreBackingUp() async {
        let model = await readyModel(
            library: [pickerUID("a"), pickerUID("b"), pending, pickerUID("c")], members: ["b", "asset-1"])

        XCTAssertEqual(model.candidates.map(\.uid), [pickerUID("a"), pending, pickerUID("c")])
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

    /// A library of 100,000 photos with half of them in the album keeps the other half in library order. The time goes
    /// to the log only: a time limit would fail on a loaded runner.
    func testCandidatesOfALargeLibraryKeepLibraryOrder() {
        let library = (0..<100_000).map { pickerItem(pickerUID("p\($0)")) }
        let members = Set((0..<50_000).map { "p\($0 * 2)" })
        let start = ContinuousClock.now

        let candidates = AlbumPhotoPickerModel.candidates(from: library, excludingAlbumNodeIDs: members)

        print("[AlbumPhotoPicker] 100k candidates in \(ContinuousClock.now - start)")
        XCTAssertEqual(candidates.count, 50_000)
        XCTAssertEqual(candidates.first?.uid, pickerUID("p1"))
        XCTAssertEqual(candidates.last?.uid, pickerUID("p99999"))
    }

    // MARK: Content states

    func testContentStaysLoadingUntilTheLibraryAndTheAlbumAreLoaded() async {
        let model = makeModel(FakeAlbumBackend(capabilities: .sdkCatalogAndWrites))
        XCTAssertEqual(model.content, .loading)

        await model.update(library: .loading, albumNodeIDs: [])
        XCTAssertEqual(model.content, .loading)

        await model.update(library: loaded([pickerUID("a")]), albumNodeIDs: nil)
        XCTAssertEqual(model.content, .loading, "the album route is still loading")
        XCTAssertTrue(model.candidates.isEmpty)
    }

    func testAnAlbumThatHoldsEveryPhotoSaysSoOnlyWithAnAuthoritativeLibrary() async {
        let model = makeModel(FakeAlbumBackend(capabilities: .sdkCatalogAndWrites))

        await model.update(library: loaded([pickerUID("a")], authority: .cached), albumNodeIDs: ["a"])
        XCTAssertEqual(model.content, .loading, "a saved library can be stale")
        await model.update(library: loaded([pickerUID("a")], authority: .hydrating), albumNodeIDs: ["a"])
        XCTAssertEqual(model.content, .loading)

        await model.update(library: loaded([pickerUID("a")]), albumNodeIDs: ["a"])
        XCTAssertEqual(model.content, .nothingToAdd)
    }

    func testAnEmptyLibraryIsReportedOnlyWithAuthority() async {
        let model = makeModel(FakeAlbumBackend(capabilities: .sdkCatalogAndWrites))

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
        let model = makeModel(FakeAlbumBackend(capabilities: .sdkCatalogAndWrites))

        await model.update(library: loaded([pickerUID("a"), pickerUID("b")], authority: .cached), albumNodeIDs: ["a"])

        XCTAssertEqual(model.content, .choose)
        XCTAssertEqual(model.candidates.map(\.uid), [pickerUID("b")])
    }

    func testPhotosThatAreBackingUpAreHandedToTheBackupForTheAlbum() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogAndWrites)
        let albums = repository(backend)
        let recorded = RecordedPendingAlbumAdds()
        await albums.setPendingAlbumAdds { uids, albumID in
            await recorded.append(uids, albumID)
            return true
        }
        let model = AlbumPhotoPickerModel(albumID: "album", coordinator: AlbumActionCoordinator(repository: albums))
        await model.update(library: loaded([pickerUID("a"), pending]), albumNodeIDs: [])
        XCTAssertEqual(model.content, .choose)
        model.replaceSelection(with: [pickerUID("a"), pending])

        let outcome = await model.submit()

        XCTAssertEqual(outcome, .added)
        XCTAssertEqual(backend.added.first?.uids, [pickerUID("a")], "only the uploaded photo reaches Proton now")
        let handedToBackup = await recorded.adds
        XCTAssertEqual(handedToBackup.map(\.uids), [[pending]])
        XCTAssertEqual(handedToBackup.map(\.album), ["album"])
    }

    func testALoadFailureThenARetryShowsTheGrid() async {
        let model = makeModel(FakeAlbumBackend(capabilities: .sdkCatalogAndWrites))

        await model.update(library: .loaded([], authority: .hydrating, failure: offline), albumNodeIDs: nil)
        XCTAssertEqual(model.content, .failed(message: "offline"), "no album load can help")

        await model.update(library: .loading, albumNodeIDs: [])
        XCTAssertEqual(model.content, .loading)

        await model.update(library: loaded([pickerUID("a")]), albumNodeIDs: [])
        XCTAssertEqual(model.content, .choose)
    }

    func testASavedLibraryWithoutPhotosToAddShowsAFailedServerLoad() async {
        let model = makeModel(FakeAlbumBackend(capabilities: .sdkCatalogAndWrites))

        await model.update(library: loaded([pickerUID("a")], authority: .cached), albumNodeIDs: ["a"])
        XCTAssertEqual(model.content, .loading, "the server listing may still bring photos")

        await model.update(
            library: .loaded([pickerItem(pickerUID("a"))], authority: .cached, failure: offline), albumNodeIDs: ["a"])
        XCTAssertEqual(model.content, .failed(message: "offline"), "a failed listing never ends")

        await model.update(library: loaded([pickerUID("a"), pickerUID("b")]), albumNodeIDs: ["a"])
        XCTAssertEqual(model.content, .choose, "a retry that brings photos shows them")
        XCTAssertEqual(model.candidates.map(\.uid), [pickerUID("b")])
    }

    func testTheCandidatesStayFixedOnceTheGridShows() async {
        let model = await readyModel(library: [pickerUID("a"), pickerUID("b")])
        model.replaceSelection(with: [pickerUID("a")])

        await model.update(library: loaded([pickerUID("b"), pickerUID("c")]), albumNodeIDs: [])
        await model.update(library: .loaded([], authority: .hydrating, failure: offline), albumNodeIDs: [])

        XCTAssertEqual(model.candidates.map(\.uid), [pickerUID("a"), pickerUID("b")])
        XCTAssertEqual(model.selection, [pickerUID("a")])
        XCTAssertEqual(model.content, .choose)
    }

    // MARK: Library source

    func testALoadFailureShowsWithRetryAndTheNextLoadClearsIt() async {
        let model = makeModel(FakeAlbumBackend(capabilities: .sdkCatalogAndWrites))
        let source = FakePickerLibrary(loadResults: ["offline", nil])

        await model.loadLibrary(from: source)
        await model.update(from: source, albumItems: [])
        XCTAssertEqual(model.libraryLoadFailure, "offline")
        XCTAssertEqual(model.content, .failed(message: "offline"))

        await model.loadLibrary(from: source)
        XCTAssertNil(model.libraryLoadFailure, "a new load ends the failure")
        source.items = [pickerItem(pickerUID("a"))]
        source.authority = .authoritative
        await model.update(from: source, albumItems: [])
        XCTAssertEqual(model.content, .choose)
        XCTAssertEqual(source.loads, 2)
    }

    func testTheAlbumsOwnPhotosLeaveTheCandidates() async {
        let model = makeModel(FakeAlbumBackend(capabilities: .sdkCatalogAndWrites))
        let source = FakePickerLibrary(
            items: [pickerItem(pickerUID("a")), pickerItem(pickerUID("b"))], authority: .authoritative)

        await model.update(from: source, albumItems: nil)
        XCTAssertEqual(model.content, .loading, "the album still loads")

        await model.update(from: source, albumItems: [pickerItem(pickerUID("a", volume: "route"))])
        XCTAssertEqual(model.candidates.map(\.uid), [pickerUID("b")])
    }

    func testTheInputsChangeWithEverythingThePickerReads() {
        let model = makeModel(FakeAlbumBackend(capabilities: .sdkCatalogAndWrites))
        let source = FakePickerLibrary()
        let base = model.inputs(from: source, albumRevision: 1, albumLoaded: true)
        XCTAssertEqual(model.inputs(from: source, albumRevision: 1, albumLoaded: true), base)

        XCTAssertNotEqual(model.inputs(from: source, albumRevision: 2, albumLoaded: true), base)
        XCTAssertNotEqual(model.inputs(from: source, albumRevision: 1, albumLoaded: false), base)
        source.contentRevision = 1
        XCTAssertNotEqual(model.inputs(from: source, albumRevision: 1, albumLoaded: true), base)
        source.contentRevision = 0
        source.authorityRevision = 1
        XCTAssertNotEqual(model.inputs(from: source, albumRevision: 1, albumLoaded: true), base)
        source.authorityRevision = 0
        source.pendingRevision = 1
        XCTAssertNotEqual(model.inputs(from: source, albumRevision: 1, albumLoaded: true), base)
        source.pendingRevision = 0
        model.libraryLoadFailure = "offline"
        XCTAssertNotEqual(model.inputs(from: source, albumRevision: 1, albumLoaded: true), base)
    }

    // MARK: Selection and submit

    func testSelectionAcceptsOnlyCandidates() async {
        let model = await readyModel(library: [pickerUID("a"), pickerUID("b"), pending], members: ["b"])

        model.replaceSelection(with: [pickerUID("a"), pickerUID("b"), pending, pickerUID("unknown")])
        XCTAssertEqual(model.selection, [pickerUID("a"), pending])

        model.toggle(pickerUID("a"))
        model.toggle(pickerUID("b"))
        model.toggle(pending)
        XCTAssertEqual(model.selection, [])

        model.toggle(pickerUID("a"))
        XCTAssertEqual(model.selection, [pickerUID("a")])
    }

    func testAnEmptySelectionCannotBeSubmittedAndSendsNoRequest() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogAndWrites)
        let model = await readyModel(backend, library: [pickerUID("a")])

        XCTAssertFalse(model.canSubmit)
        let outcome = await model.submit()

        XCTAssertEqual(outcome, .notStarted)
        XCTAssertTrue(backend.added.isEmpty)
    }

    func testSubmitAddsTheSelectionOnceInLibraryOrder() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogAndWrites)
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
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogAndWrites)
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
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogAndWrites)
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
            catalogBackend: FakeAlbumBackend(capabilities: .sdkCatalogAndWrites),
            writeBackend: FakeAlbumBackend(capabilities: .sdkCatalogAndWrites),
            capabilities: .sdkCatalogAndWrites
        )
        let readOnly = AlbumsRepository(
            catalogBackend: FakeAlbumBackend(capabilities: .sdkCatalogAndWrites),
            writeBackend: FakeAlbumBackend(capabilities: .sdkCatalogAndWrites),
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
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogAndWrites)
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

/// A whole library that a test sets directly; each load returns the next of `loadResults`.
@MainActor
private final class FakePickerLibrary: AlbumPhotoPickerLibrarySource {
    var items: [PhotoItem]
    var authority: SourceInventoryAuthority
    var contentRevision: UInt64 = 0
    var authorityRevision: UInt64 = 0
    var pendingRevision: UInt64 = 0
    private var loadResults: [String?]
    private(set) var loads = 0

    init(items: [PhotoItem] = [], authority: SourceInventoryAuthority = .hydrating, loadResults: [String?] = []) {
        self.items = items
        self.authority = authority
        self.loadResults = loadResults
    }

    var wholeLibraryGridItems: [PhotoItem] { items }
    var wholeLibraryInventoryAuthority: SourceInventoryAuthority { authority }
    var wholeLibraryContentRevision: UInt64 { contentRevision }
    var wholeLibraryInventoryAuthorityRevision: UInt64 { authorityRevision }
    var pendingMembershipRevision: UInt64 { pendingRevision }

    func loadWholeLibraryIfNeeded() async -> String? {
        loads += 1
        return loadResults.isEmpty ? nil : loadResults.removeFirst()
    }
}
