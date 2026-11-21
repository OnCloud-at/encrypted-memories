import AlbumCore
import Foundation
import MediaByteCache
import MediaCache
import PhotoViewerCore
import PhotoViewerFeature
import PhotosCore
import XCTest

final class PhotoMetadataLoadStateTests: XCTestCase {
    @MainActor
    func testUnprovenLocationShowsDateTitleBeforeMetadataCompletes() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-title-\(UUID().uuidString)", isDirectory: true)
        let item = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "no-location"),
            captureTime: Date(timeIntervalSince1970: 1),
            mediaType: "image/jpeg"
        )
        let model = PhotoViewerModel(
            items: [item],
            index: 0,
            feed: ThumbnailFeed(
                cache: ThumbnailCache(namespace: "metadata-title-\(UUID().uuidString)", rootDirectory: root),
                loader: MetadataEmptyThumbnailLoader()
            ),
            media: MetadataFailingMediaProvider(),
            metadataProvider: SuspendedMetadataProvider()
        )

        XCTAssertEqual(model.titleMetadataState, .resolving)
        XCTAssertFalse(model.isPlaceNameResolving)
        model.stop()
    }

    @MainActor
    func testKnownLocationKeepsThePlaceNameLineWhileMetadataResolvesAndFollowsTheIndex() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-known-\(UUID().uuidString)", isDirectory: true)
        let item = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "located"),
            captureTime: Date(timeIntervalSince1970: 1),
            mediaType: "image/jpeg"
        )
        var indexKnowsTheLocation = false
        let model = PhotoViewerModel(
            items: [item],
            index: 0,
            feed: ThumbnailFeed(
                cache: ThumbnailCache(namespace: "metadata-known-\(UUID().uuidString)", rootDirectory: root),
                loader: MetadataEmptyThumbnailLoader()
            ),
            media: MetadataFailingMediaProvider(),
            metadataProvider: SuspendedMetadataProvider(),
            hasKnownLocation: { $0 == item.uid && indexKnowsTheLocation }
        )

        XCTAssertEqual(model.titleMetadataState, .resolving)
        XCTAssertFalse(model.isPlaceNameResolving, "an unknown location shows the date at once")
        indexKnowsTheLocation = true
        XCTAssertTrue(model.isPlaceNameResolving, "a location that the index learns later reserves the line")
        model.stop()
    }

    /// The first failed read is repeated once without a message, so the Info never shows a failure that one new read
    /// clears.
    @MainActor
    func testInfoRepeatsAFailedReadOnceBeforeItShowsTheFailure() async {
        let provider = RetryMetadataProvider(failures: 1)
        let pauses = RecordedPauses()
        let model = makeModel(metadataProvider: provider, pauses: pauses)
        model.start()
        // The title of the photo has already read the details and cached the failure when the Info opens.
        await waitUntil { model.titleMetadataState.resolution?.metadataLoadFailed == true }
        model.toggleInfo()

        await waitUntil { model.metadataLoadState.metadata?.filename == "IMG_0001.HEIC" }
        model.stop()

        let requestCount = await provider.requestCount
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(pauses.waits, [ViewerTitleMetadataCoordinator.infoRereadDelay])
    }

    /// Only when the repeat fails too does the Info show the failure. The person's Try again then reads once.
    @MainActor
    func testFailureOfTheRepeatTooShowsTheFailureAndTryAgainReadsOnce() async {
        let provider = RetryMetadataProvider(failures: 2)
        let pauses = RecordedPauses()
        let model = makeModel(metadataProvider: provider, pauses: pauses)
        model.start()
        model.toggleInfo()
        await waitUntil { model.metadataLoadState == .failed }
        let afterFirstOpen = await provider.requestCount
        XCTAssertEqual(afterFirstOpen, 2)

        model.retryMetadata()
        await waitUntil { model.metadataLoadState.metadata?.filename == "IMG_0001.HEIC" }
        model.stop()

        XCTAssertEqual(model.metadata?.filename, "IMG_0001.HEIC")
        let requestCount = await provider.requestCount
        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(pauses.waits.count, 1, "Try again adds no second silent repeat")
    }

    /// A repeat that succeeds also gives the title of the viewer the place of the photo, like a Try again does.
    @MainActor
    func testARepeatThatSucceededGivesTheTitleItsPlaceName() async {
        let provider = RetryMetadataProvider(failures: 1, latitude: 48.2, longitude: 16.4)
        let model = makeModel(metadataProvider: provider, placeNameResolver: StaticPlaceResolver(name: "Vienna"))
        model.start()
        await waitUntil { model.titleMetadataState.resolution?.metadataLoadFailed == true }
        XCTAssertNil(model.placeName)
        model.toggleInfo()

        await waitUntil { model.metadataLoadState.metadata?.filename == "IMG_0001.HEIC" }
        await waitUntil { model.placeName == "Vienna" }
        model.stop()

        XCTAssertEqual(model.placeName, "Vienna")
    }

    /// Closing the Info while the repeat waits ends it: no second read starts. The Info that opens again repeats once.
    @MainActor
    func testClosingTheInfoDuringThePauseStartsNoReadAndTheNextOpeningRepeatsOnce() async {
        let provider = RetryMetadataProvider(failures: 1)
        let pauses = RecordedPauses()
        let model = makeModel(metadataProvider: provider, pauses: pauses)
        model.start()
        await waitUntil { model.titleMetadataState.resolution?.metadataLoadFailed == true }
        pauses.hook = { model.toggleInfo() }
        model.toggleInfo()
        await waitUntil { pauses.waits.count == 1 }
        try? await Task.sleep(for: .milliseconds(50))
        let afterClosing = await provider.requestCount
        XCTAssertEqual(afterClosing, 1, "the closed Info started no second read")
        XCTAssertNotEqual(model.metadataLoadState, .failed, "a closed Info shows no result of its own")

        pauses.hook = nil
        model.toggleInfo()
        await waitUntil { model.metadataLoadState.metadata?.filename == "IMG_0001.HEIC" }
        model.stop()

        let requestCount = await provider.requestCount
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(pauses.waits.count, 2)
    }

    /// A failure that the Info already repeated is final: the Info that opens again shows it at once, without a
    /// spinner and without another silent repeat.
    @MainActor
    func testAnInfoThatOpensAgainOnASpentFailureShowsItAtOnce() async {
        let provider = RetryMetadataProvider(failures: 3)
        let pauses = RecordedPauses()
        let model = makeModel(metadataProvider: provider, pauses: pauses)
        model.start()
        model.toggleInfo()
        await waitUntil { model.metadataLoadState == .failed }
        model.toggleInfo()

        model.toggleInfo()

        XCTAssertEqual(model.metadataLoadState, .failed, "the failure shows at once, before any await")
        XCTAssertEqual(pauses.waits.count, 1, "no second silent repeat")
        model.stop()
        let requestCount = await provider.requestCount
        XCTAssertEqual(requestCount, 2, "no read for the Info that opened again")
    }

    /// The row of the albums offers the same Try again as the details; it loads the albums again.
    @MainActor
    func testTryAgainLoadsTheAlbumMembershipsAgainAfterTheyFailed() async {
        let memberships = FlakyAlbumMembershipProvider(titles: ["Family"])
        let model = makeModel(metadataProvider: RetryMetadataProvider(failures: 0), memberships: memberships)
        model.start()
        model.toggleInfo()
        await waitUntil { model.albumMembershipsLoadFailed }

        model.retryMetadata()
        await waitUntil { model.albumTitles == ["Family"] }
        model.stop()

        XCTAssertFalse(model.albumMembershipsLoadFailed)
    }

    @MainActor
    private func makeModel(
        metadataProvider: PhotoMetadataProvider, pauses: RecordedPauses = RecordedPauses(),
        memberships: (any PhotoAlbumMembershipProviding)? = nil,
        placeNameResolver: (any PlaceNameResolving)? = nil
    ) -> PhotoViewerModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-state-\(UUID().uuidString)", isDirectory: true)
        let item = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "photo"),
            captureTime: Date(timeIntervalSince1970: 1),
            mediaType: "image/jpeg"
        )
        return PhotoViewerModel(
            items: [item],
            index: 0,
            feed: ThumbnailFeed(
                cache: ThumbnailCache(namespace: "metadata-state-\(UUID().uuidString)", rootDirectory: root),
                loader: MetadataEmptyThumbnailLoader()
            ),
            media: MetadataFailingMediaProvider(),
            metadataProvider: metadataProvider,
            albumMembershipProvider: memberships,
            placeNameResolver: placeNameResolver,
            silentRetryWait: { await pauses.record($0) }
        )
    }

    @MainActor
    func testInfoPanelLoadsAlbumMembershipTitlesForDisplayedPhoto() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-membership-state-\(UUID().uuidString)", isDirectory: true)
        let item = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "photo"),
            captureTime: Date(timeIntervalSince1970: 1),
            mediaType: "image/jpeg"
        )
        let memberships = StaticAlbumMembershipProvider(titles: ["Family", "Summer"])
        let model = PhotoViewerModel(
            items: [item],
            index: 0,
            feed: ThumbnailFeed(
                cache: ThumbnailCache(namespace: "album-membership-\(UUID().uuidString)", rootDirectory: root),
                loader: MetadataEmptyThumbnailLoader()
            ),
            media: MetadataFailingMediaProvider(),
            metadataProvider: RetryMetadataProvider(),
            albumMembershipProvider: memberships
        )

        model.toggleInfo()
        await waitUntil { model.albumTitles == ["Family", "Summer"] }
        model.stop()

        XCTAssertFalse(model.isLoadingAlbumMemberships)
        XCTAssertFalse(model.albumMembershipsLoadFailed)
        let requestedUIDs = await memberships.requestedUIDs
        XCTAssertEqual(requestedUIDs, [item.uid])
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<50 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}

private actor StaticAlbumMembershipProvider: PhotoAlbumMembershipProviding {
    let titles: [String]
    private(set) var requestedUIDs: [PhotoUID] = []

    init(titles: [String]) {
        self.titles = titles
    }

    func albumMembershipTitles(for photoUID: PhotoUID) async throws -> [String] {
        requestedUIDs.append(photoUID)
        return titles
    }
}

/// Fails its first `failures` reads, then answers.
private actor RetryMetadataProvider: PhotoMetadataProvider {
    private let failures: Int
    private let latitude: Double?
    private let longitude: Double?
    private(set) var requestCount = 0

    init(failures: Int = 1, latitude: Double? = nil, longitude: Double? = nil) {
        self.failures = failures
        self.latitude = latitude
        self.longitude = longitude
    }

    func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
        requestCount += 1
        if requestCount <= failures { throw MetadataTestError.unavailable }
        return PhotoMetadata(filename: "IMG_0001.HEIC", latitude: latitude, longitude: longitude)
    }
}

private struct StaticPlaceResolver: PlaceNameResolving {
    let name: String
    func placeName(latitude: Double, longitude: Double) async -> String? { name }
}

private actor FlakyAlbumMembershipProvider: PhotoAlbumMembershipProviding {
    let titles: [String]
    private var calls = 0

    init(titles: [String]) { self.titles = titles }

    func albumMembershipTitles(for photoUID: PhotoUID) async throws -> [String] {
        calls += 1
        if calls == 1 { throw MetadataTestError.unavailable }
        return titles
    }
}

/// The pauses that the viewer asked for, answered at once. The hook runs while a pause waits.
@MainActor
private final class RecordedPauses {
    private(set) var waits: [Duration] = []
    var hook: (@MainActor () -> Void)?

    func record(_ duration: Duration) {
        waits.append(duration)
        hook?()
    }
}

private actor SuspendedMetadataProvider: PhotoMetadataProvider {
    func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
        try await Task.sleep(for: .seconds(10))
        return PhotoMetadata()
    }
}
