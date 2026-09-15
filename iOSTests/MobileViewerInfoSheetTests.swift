import PhotoViewerCore
import PhotosCore
import XCTest

@testable import EncryptedMemoriesMobile

final class MobileViewerInfoSheetTests: XCTestCase {
    func testMetadataStatesKeepUnavailableQuietAndFailuresRetryable() {
        let item = PhotoItem(
            uid: PhotoUID(volumeID: "shared", nodeID: "photo"),
            captureTime: Date(timeIntervalSince1970: 1_374_306_540), mediaType: "")
        let states: [(PhotoMetadataLoadState, Bool)] = [
            (.unavailable, false), (.loaded(PhotoMetadata()), true),
            (.loaded(PhotoMetadata(filename: "Shared photo.jpg", mimeType: "image/jpeg")), true),
            (.failed, false),
        ]
        for (state, hasMetadata) in states {
            _ = MobileViewerInfoSheet(
                item: item, metadataLoadState: state, albumTitles: ["Shared family"],
                canLoadAlbumMemberships: true, isLoadingAlbumMemberships: false,
                albumMembershipsLoadFailed: false, placeName: nil, onRetry: {}, onClose: {})

            XCTAssertEqual(state.metadata != nil, hasMetadata)
            XCTAssertEqual(state == .failed, !hasMetadata && state != .unavailable)
        }
    }
}
