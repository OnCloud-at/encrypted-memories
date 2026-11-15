import CoreLocation
import Foundation
import Photos
import UploadCore
import XCTest

@testable import PhotoLibraryBackupAdapter

final class PhotoUploadPlaybackStyleTests: XCTestCase {
    func testLoopingMarkerSurvivesMetadataEncoding() throws {
        let source = Data(
            #"{"ICloudID":"cloud-id","ModificationTime":"2026-01-01T00:00:00.000Z","PlaybackStyle":"videoLooping"}"#
                .utf8)
        let encoded = try roundTrip(source)
        XCTAssertEqual(encoded["PlaybackStyle"] as? String, "videoLooping")
        XCTAssertEqual(encoded["ICloudID"] as? String, "cloud-id")
        XCTAssertEqual(encoded["ModificationTime"] as? String, "2026-01-01T00:00:00.000Z")
    }

    func testLoopingMarkerDoesNotRequireCloudIdentity() throws {
        let encoded = try roundTrip(Data(#"{"PlaybackStyle":"videoLooping"}"#.utf8))
        XCTAssertEqual(encoded["PlaybackStyle"] as? String, "videoLooping")
        XCTAssertNil(encoded["ICloudID"])
    }

    func testLegacyMetadataKeepsItsExistingFieldsWithoutAMarker() throws {
        let source = Data(#"{"ICloudID":"cloud-id","ModificationTime":"2026-01-01T00:00:00.000Z"}"#.utf8)
        XCTAssertEqual(
            try NSDictionary(dictionary: roundTrip(source)),
            try JSONSerialization.jsonObject(with: source) as? NSDictionary
        )
    }

    func testBuilderWritesMarkerForLoopingPlayback() throws {
        let metadata = try PhotoLibraryUploadMetadataBuilder.metadata(
            for: PlaybackStyleAsset(style: .videoLooping), cloudIdentifier: "cloud-id"
        )
        let source = try sourceSection(metadata)
        XCTAssertEqual(source["PlaybackStyle"] as? String, "videoLooping")
        XCTAssertEqual(source["ICloudID"] as? String, "cloud-id")
        XCTAssertEqual(metadata.map(\.name), ["Camera", "Media", "iOS.photos"])
    }

    func testBuilderOmitsMarkerForOtherPlaybackStyles() throws {
        for style in [PHAsset.PlaybackStyle.image, .livePhoto, .video] {
            let metadata = try PhotoLibraryUploadMetadataBuilder.metadata(
                for: PlaybackStyleAsset(style: style), cloudIdentifier: "cloud-id"
            )
            let source = try sourceSection(metadata)
            XCTAssertNil(source["PlaybackStyle"])
            XCTAssertEqual(source["ICloudID"] as? String, "cloud-id")
        }
    }

    func testBuilderSourceKeepsTheMarkerWithoutCloudIdentity() throws {
        let source = try XCTUnwrap(
            PhotoLibraryUploadMetadataBuilder.photosSource(
                cloudIdentifier: nil, modificationDate: nil, playbackStyle: .videoLooping))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        XCTAssertEqual(object["PlaybackStyle"] as? String, "videoLooping")
        XCTAssertNil(object["ICloudID"])
        XCTAssertNil(object["ModificationTime"])
    }

    func testBuilderKeepsTheAbsentSourceForOrdinaryPhotosWithoutCloudIdentity() {
        XCTAssertNil(
            PhotoLibraryUploadMetadataBuilder.photosSource(
                cloudIdentifier: nil, modificationDate: nil, playbackStyle: .livePhoto))
    }

    func testLoopingPlaybackKeepsBackupIdentityRevisionsAndEveryResource() throws {
        let resources: [PhotoBackupAssetInfo.Resource] = [
            .init(role: .originalPhoto, originalFilename: "IMG.HEIC"),
            .init(role: .pairedVideo, originalFilename: "IMG.MOV"),
            .init(role: .fullSizePhoto, originalFilename: "FullSizeRender.heic"),
            .init(role: .fullSizePairedVideo, originalFilename: "FullSizeRender.mov"),
            .init(role: .adjustmentData, originalFilename: "Adjustments.plist"),
        ]
        for cloudID in [nil, "cloud-id"] as [String?] {
            var ordinary = PhotoBackupAssetInfo(
                localIdentifier: "asset", creationDate: Date(timeIntervalSince1970: 0),
                modificationDate: Date(timeIntervalSince1970: 1), pixelWidth: 100, pixelHeight: 100,
                durationSeconds: 0, isLivePhoto: true, isVideo: false, resources: resources,
                cloudIdentifier: cloudID, hasAdjustments: true,
                adjustmentTimestamp: Date(timeIntervalSince1970: 1))
            ordinary.livePlaybackOff = PhotoKitAssetMapper.livePlaybackOff(
                isVideo: false, resources: resources, playbackStyle: .livePhoto)
            var loop = ordinary
            loop.livePlaybackOff = PhotoKitAssetMapper.livePlaybackOff(
                isVideo: false, resources: resources, playbackStyle: .videoLooping)
            let before = try XCTUnwrap(PhotoBackupAssetPlanner.candidate(for: ordinary))
            let after = try XCTUnwrap(PhotoBackupAssetPlanner.candidate(for: loop))
            XCTAssertEqual(
                after, before, "source identity, metadata/edit revisions, resource count and external identity")
            XCTAssertEqual(after.snapshot.resourceCount, resources.count)
            XCTAssertEqual(
                PhotoBackupAssetPlanner.exportPlan(for: loop), PhotoBackupAssetPlanner.exportPlan(for: ordinary))
            let source = try XCTUnwrap(
                PhotoLibraryUploadMetadataBuilder.photosSource(
                    cloudIdentifier: cloudID, modificationDate: ordinary.modificationDate, playbackStyle: .videoLooping)
            )
            XCTAssertEqual(source.playbackStyle, PhotoUploadMetadataEncoder.IOSPhotos.loopingPlaybackStyle)
        }
    }

    private func roundTrip(_ source: Data) throws -> [String: Any] {
        let photos = try JSONDecoder().decode(PhotoUploadMetadataEncoder.IOSPhotos.self, from: source)
        let metadata = try PhotoUploadMetadataEncoder.metadata(
            location: nil, camera: .init(captureTime: nil),
            media: .init(width: nil, height: nil, duration: nil), iOSPhotos: photos
        )
        return try sourceSection(metadata)
    }

    private func sourceSection(_ metadata: [PhotoUploadAdditionalMetadata]) throws -> [String: Any] {
        let source = try XCTUnwrap(metadata.first { $0.name == "iOS.photos" })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: source.utf8JsonValue) as? [String: Any])
    }
}

private final class PlaybackStyleAsset: PHAsset, @unchecked Sendable {
    private let style: PHAsset.PlaybackStyle

    init(style: PHAsset.PlaybackStyle) {
        self.style = style
        super.init()
    }

    override var playbackStyle: PHAsset.PlaybackStyle { style }
    override var creationDate: Date? { Date(timeIntervalSince1970: 0) }
    override var modificationDate: Date? { Date(timeIntervalSince1970: 1) }
    override var location: CLLocation? { nil }
    override var mediaType: PHAssetMediaType { .image }
    override var pixelWidth: Int { 100 }
    override var pixelHeight: Int { 100 }
    override var duration: TimeInterval { 0 }
}
