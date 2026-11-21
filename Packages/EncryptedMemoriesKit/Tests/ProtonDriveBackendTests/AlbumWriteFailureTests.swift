import AlbumCore
import PhotosCore
import ProtonAuth
import XCTest

@testable import ProtonDriveBackend
@testable import UploadCore

private struct FailingAlbumBackend: AlbumCatalogBackend, AlbumWriteBackend {
    let failure: any Error
    func listAlbums() async throws -> [AlbumSummary] { [] }
    func listSharedWithMeAlbums() async throws -> [SharedAlbumSummary] { [] }
    func leaveSharedAlbum(_ album: AlbumNodeIdentifier) async throws {}
    func albumMemberships(for photoUIDs: [PhotoUID]) async throws -> [PhotoUID: Set<AlbumNodeIdentifier>] { [:] }
    func createAlbum(name: String) async throws -> AlbumID { "a" }
    func deleteAlbum(albumID: AlbumID) async throws {}
    func addPhotos(_ photoUIDs: [PhotoUID], to albumID: AlbumID) async throws { throw failure }
    func removePhotos(_ photoUIDs: [PhotoUID], from albumID: AlbumID) async throws {}
    func setAlbumCover(albumID: AlbumID, photoUID: PhotoUID) async throws {}
}

final class AlbumWriteFailureTests: XCTestCase {
    func testMixedAndMissingItemOutcomesNeverBecomeSuccess() {
        let photos = [
            PhotoUID(volumeID: "v", nodeID: "a"), PhotoUID(volumeID: "v", nodeID: "b"),
            PhotoUID(volumeID: "v", nodeID: "c"),
        ]
        let result = AlbumAttachResult(outcomes: ["a": .attached, "b": .failed(code: 429, message: "later")])
        do {
            try result.requireComplete(for: photos)
            XCTFail("one failure and one missing answer must stop the write")
        } catch let AlbumError.partialAddWithCauses(succeeded, total, _, failures) {
            XCTAssertEqual(succeeded, 1)
            XCTAssertEqual(total, 3)
            XCTAssertEqual(failures.map(\.linkID), ["b", "c"])
            XCTAssertEqual(failures.map(\.code), [429, nil])
        } catch {
            XCTFail("the item causes must remain available: \(error)")
        }
    }

    func testConfirmedAndAlreadyPresentItemsBothSucceed() throws {
        let photos = [PhotoUID(volumeID: "v", nodeID: "a"), PhotoUID(volumeID: "v", nodeID: "b")]
        let result = AlbumAttachResult(outcomes: ["a": .attached, "b": .alreadyMember])
        XCTAssertNoThrow(try result.requireComplete(for: photos))
    }

    func testCarryOverAdapterRetainsNetworkAndServerRetrySignals() async {
        let errors: [AlbumError] = [
            .requestFailed(AlbumWriteCause(URLError(.notConnectedToInternet))),
            .requestFailed(AlbumWriteCause(URLError(.timedOut))),
            .requestFailed(AlbumWriteCause(ProtonAuthError.apiError(code: 429, message: "later"), httpStatus: 429)),
            .requestFailed(AlbumWriteCause(ProtonAuthError.apiError(code: 503, message: "later"), httpStatus: 503)),
        ]
        for original in errors {
            let backend = FailingAlbumBackend(failure: original)
            let repo = AlbumsRepository(catalogBackend: backend, writeBackend: backend)
            let carryOver = AlbumRepositorySeriesCarryOver(repository: repo)
            do {
                try await carryOver.addPhotos([PhotoUID(volumeID: "v", nodeID: "p")], toOwnAlbum: "a")
                XCTFail("the album add must stop")
            } catch {
                if original.writeCause?.kind == .network(code: URLError.notConnectedToInternet.rawValue)
                    || original.writeCause?.kind == .network(code: URLError.timedOut.rawValue)
                {
                    XCTAssertTrue(BackupSyncRunner.isTransientNetwork(error))
                } else if case UploadError.retryableBackend(let code, _) = error {
                    XCTAssertTrue(code == 429 || code == 503)
                } else {
                    XCTFail("the runner must see a retryable service failure: \(error)")
                }
            }
        }
    }

    func testCarryOverAdapterKeepsCancellationAndUnknownFailures() async {
        let unknown = AlbumError.partialAddWithCauses(
            succeeded: 1, total: 2, message: "unknown",
            failures: [AlbumWriteItemFailure(linkID: "p", code: nil, message: "unknown")])
        let forbidden = AlbumError.requestFailed(
            AlbumWriteCause(ProtonAuthError.apiError(code: 403, message: "forbidden"), httpStatus: 403))
        for failure in [CancellationError() as any Error, unknown, forbidden] {
            let backend = FailingAlbumBackend(failure: failure)
            let carryOver = AlbumRepositorySeriesCarryOver(
                repository: AlbumsRepository(catalogBackend: backend, writeBackend: backend))
            do {
                try await carryOver.addPhotos([PhotoUID(volumeID: "v", nodeID: "p")], toOwnAlbum: "a")
                XCTFail("the add must stop")
            } catch {
                if failure is CancellationError {
                    XCTAssertTrue(error is CancellationError)
                } else {
                    XCTAssertEqual(error as? AlbumError, failure as? AlbumError)
                }
            }
        }
    }
}
