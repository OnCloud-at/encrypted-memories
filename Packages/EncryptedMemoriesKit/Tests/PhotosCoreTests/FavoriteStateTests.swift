import XCTest

@testable import PhotosCore

final class FavoriteStateTests: XCTestCase {
    private let a = PhotoUID(volumeID: "v", nodeID: "a")
    private let b = PhotoUID(volumeID: "v", nodeID: "b")
    private let c = PhotoUID(volumeID: "v", nodeID: "c")

    private func loaded(_ favorites: Set<PhotoUID>) -> FavoriteState {
        var state = FavoriteState()
        state.beginLoad()
        state.finishLoad(favorites)
        return state
    }

    func testAWriteDuringARunningReadWinsOverTheDelayedResponse() throws {
        var state = loaded([])
        state.beginLoad()
        let request = try XCTUnwrap(state.beginWrite(selection: [a], target: true))
        state.finishWrite(request, failed: [])

        state.finishLoad([])

        XCTAssertEqual(state.favorites, [a], "the response predates the write")
    }

    func testAWriteBeforeTheFirstReadWinsOverThatRead() throws {
        var state = FavoriteState()
        let request = try XCTUnwrap(state.beginWrite(selection: [a], target: true))
        state.beginLoad()
        state.finishLoad([b])

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
        state.beginLoad()
        XCTAssertEqual(state.availability, .loading)

        state.finishLoad(nil)

        XCTAssertEqual(state.availability, .unavailable)
    }

    func testAFailedReloadKeepsKnownFavoritesAvailable() {
        var state = loaded([a])
        state.beginLoad()
        XCTAssertEqual(state.availability, .available)

        state.finishLoad(nil)

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
        XCTAssertEqual(state, FavoriteState())
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
