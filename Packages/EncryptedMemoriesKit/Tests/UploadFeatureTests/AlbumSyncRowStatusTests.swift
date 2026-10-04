import PhotosCore
import UploadCore
import XCTest

@testable import PhotoLibraryBackupAdapter

final class AlbumSyncRowStatusTests: XCTestCase {
    func testAttentionOverridesRecentSyncedStateInAlbumRows() {
        let album = AlbumSyncController.SelectedAlbum(
            id: "album-1",
            title: "FaceApp",
            assetCount: 2,
            state: .synced(Date(timeIntervalSince1970: 1_720_000_000)),
            needsAttentionCount: 1
        )

        XCTAssertTrue(album.hasNeedsAttention)
        XCTAssertNotEqual(
            album.localizedRowStatusDescription,
            album.localizedStateDescription,
            "a row with failed photos must not present itself as cleanly synced"
        )
        XCTAssertEqual(album.localizedRowStatusDescription, L10n.string("albumsync.detail_not_in_album \(1)"))
    }

    func testRowOpensTheProblemListOnlyWhenTheLastRunListedPhotos() {
        var album = AlbumSyncController.SelectedAlbum(
            id: "album-1", title: "FaceApp", assetCount: 2,
            state: .synced(Date(timeIntervalSince1970: 1_720_000_000)), needsAttentionCount: 1)
        // A run of an earlier build counted the photos but left no list: the row only states the count.
        XCTAssertFalse(album.showsProblemList)

        album.problems = [
            BackupFailedItem(id: "album/a", filename: "a.heic", reason: "attach reason", isPermanent: false)
        ]
        XCTAssertTrue(album.showsProblemList)

        album.needsAttentionCount = 0
        XCTAssertFalse(album.showsProblemList, "a clean run must not offer a stale list")
    }
}
