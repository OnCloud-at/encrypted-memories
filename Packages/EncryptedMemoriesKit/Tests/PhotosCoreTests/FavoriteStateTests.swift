import XCTest

@testable import PhotosCore

final class FavoriteStateTests: XCTestCase {
    private let a = PhotoUID(volumeID: "v", nodeID: "a")
    private let b = PhotoUID(volumeID: "v", nodeID: "b")
    private let c = PhotoUID(volumeID: "v", nodeID: "c")

    private func loaded(_ favorites: Set<PhotoUID>) -> FavoriteState {
        var state = FavoriteState()
        let read = state.beginLoad()
        state.finishLoad(favorites, for: read)
        return state
    }

    func testAWriteDuringARunningReadWinsOverTheDelayedResponse() throws {
        var state = loaded([])
        let read = state.beginLoad()
        let request = try XCTUnwrap(state.beginWrite(selection: [a], target: true))
        state.finishWrite(request, failed: [])

        state.finishLoad([], for: read)

        XCTAssertEqual(state.favorites, [a], "the response predates the write")
    }

    func testAWriteBeforeTheFirstReadWinsOverThatRead() throws {
        var state = FavoriteState()
        let request = try XCTUnwrap(state.beginWrite(selection: [a], target: true))
        let read = state.beginLoad()
        state.finishLoad([b], for: read)

        XCTAssertEqual(state.favorites, [a, b])
        state.finishWrite(request, failed: [])
        XCTAssertEqual(state.favorites, [a, b])
    }

    func testAFailedWriteRollsBackOnlyItsFailedPhotos() throws {
        var state = loaded([])
        let request = try XCTUnwrap(state.beginWrite(selection: [a, b], target: true))
        XCTAssertEqual(state.favorites, [a, b])
        XCTAssertEqual(state.inFlight, [a, b])

        state.finishWrite(request, failed: [b])

        XCTAssertEqual(state.favorites, [a])
        XCTAssertTrue(state.inFlight.isEmpty)
    }

    func testAWriteThatOverlapsOneInFlightIsRefused() throws {
        var state = loaded([])
        _ = try XCTUnwrap(state.beginWrite(selection: [a], target: true))

        XCTAssertNil(state.beginWrite(selection: [a, b], target: true))
        XCTAssertNotNil(state.beginWrite(selection: [c], target: true))
    }

    func testAFailedFirstReadMakesFavoritesUnavailable() {
        var state = FavoriteState()
        let read = state.beginLoad()
        XCTAssertEqual(state.availability, .loading)

        state.finishLoad(nil, for: read)

        XCTAssertEqual(state.availability, .unavailable)
    }

    func testAFailedReloadKeepsKnownFavoritesAvailable() {
        var state = loaded([a])
        let read = state.beginLoad()
        XCTAssertEqual(state.availability, .available)

        state.finishLoad(nil, for: read)

        XCTAssertEqual(state.availability, .available)
        XCTAssertEqual(state.favorites, [a])
    }

    func testAResetForgetsWritesAndCanKeepTheShownFavorites() throws {
        var state = loaded([a])
        _ = try XCTUnwrap(state.beginWrite(selection: [b], target: true))

        var retry = state
        retry.reset(keepingFavorites: true)
        XCTAssertEqual(retry.favorites, [a, b])
        XCTAssertTrue(retry.inFlight.isEmpty)
        XCTAssertEqual(retry.availability, .loading)

        state.reset(keepingFavorites: false)
        XCTAssertTrue(state.favorites.isEmpty)
        XCTAssertTrue(state.inFlight.isEmpty)
        XCTAssertEqual(state.availability, .loading)
    }

    func testAReadStartedBeforeAResetChangesNothing() {
        var state = loaded([a])
        let staleRead = state.beginLoad()
        state.reset(keepingFavorites: true)
        let read = state.beginLoad()

        state.finishLoad([b], for: staleRead)
        XCTAssertEqual(state.favorites, [a])
        XCTAssertEqual(state.availability, .loading)

        state.finishLoad([c], for: read)
        XCTAssertEqual(state.favorites, [c])
    }

    func testAnOlderResponseThatArrivesLastIsStale() throws {
        var state = loaded([])
        let slow = state.beginLoad()
        let fast = state.beginLoad()
        state.finishLoad([b], for: fast)
        let request = try XCTUnwrap(state.beginWrite(selection: [a], target: true))
        state.finishWrite(request, failed: [])

        state.finishLoad([], for: slow)

        XCTAssertEqual(state.favorites, [a, b], "neither the older response nor its missing heart wins")
    }

    func testAWriteDuringTwoOverlappingReadsSurvivesBothResponses() throws {
        var state = loaded([])
        let first = state.beginLoad()
        let second = state.beginLoad()
        state.finishLoad([], for: first)
        // The second read is still open, so this write predates its response.
        let request = try XCTUnwrap(state.beginWrite(selection: [a], target: true))
        state.finishWrite(request, failed: [])

        state.finishLoad([], for: second)

        XCTAssertEqual(state.favorites, [a])
    }

    func testACancelledReadStopsTrackingWrites() throws {
        var state = loaded([a])
        let cancelled = state.beginLoad()
        state.cancelLoad(cancelled)
        // Another device removed the heart; this write of another photo must not bring it back.
        let request = try XCTUnwrap(state.beginWrite(selection: [b], target: true))
        state.finishWrite(request, failed: [])

        let read = state.beginLoad()
        state.finishLoad([b], for: read)

        XCTAssertEqual(state.favorites, [b])
        XCTAssertEqual(state.availability, .available)
    }

    func testAWriteThatFailsDuringAReadLetsTheServerStateWin() throws {
        var state = loaded([a])
        let read = state.beginLoad()
        let request = try XCTUnwrap(state.beginWrite(selection: [a], target: false))
        XCTAssertTrue(state.favorites.isEmpty)

        state.finishWrite(request, failed: [a])
        state.finishLoad([a], for: read)

        XCTAssertEqual(state.favorites, [a])
    }

    func testAReadDuringAWriteKeepsTheOptimisticState() throws {
        var state = loaded([a])
        let request = try XCTUnwrap(state.beginWrite(selection: [a], target: false))
        let read = state.beginLoad()

        state.finishLoad([a], for: read)
        XCTAssertTrue(state.favorites.isEmpty, "the unfavorite in flight wins over the older server state")

        state.finishWrite(request, failed: [])
        XCTAssertTrue(state.favorites.isEmpty)
    }

    func testAFailedUnfavoriteRestoresTheHeart() throws {
        var state = loaded([a, b])
        let request = try XCTUnwrap(state.beginWrite(selection: [a, b], target: false))

        state.finishWrite(request, failed: [b])

        XCTAssertEqual(state.favorites, [b])
    }

    func testTrashedPhotosLoseTheirHeartsWhenTheReadFails() {
        var state = loaded([a, b])

        state.removeTrashed([a])

        XCTAssertEqual(state.favorites, [b])
    }

    func testPerformReportsThePartialFailureOfTheBackend() async throws {
        var state = loaded([])
        let request = try XCTUnwrap(state.beginWrite(selection: [a, b], target: true))

        let failed = await FavoriteState.perform(request) { _, _ in
            throw FavoriteMutationError(succeeded: [a], failed: [b], diagnosticMessage: "partial")
        }

        XCTAssertEqual(failed, [b])
    }
}
