import Foundation
import PhotosCore
import ProtonDriveSDK

/// Reads the volume-qualified SDK node. A shared photo cannot use the account's own Photos share key chain.
enum SDKPhotoMetadataReader {
    static func metadata(for uid: PhotoUID, client: any SDKPhotoCatalogClient) async throws -> PhotoMetadata {
        let node = try await SDKCancellableOperation.run { token in
            try await client.getNode(
                nodeUid: SDKNodeUid(volumeID: uid.volumeID, nodeID: uid.nodeID), cancellationToken: token)
        } cancel: { token in
            try? await client.cancelGetNode(cancellationToken: token)
        }
        try Task.checkCancellation()
        switch node {
        case .photo(let photo):
            return metadata(name: photo.name, mimeType: photo.mediaType, revision: photo.activeRevision)
        case .file(let file):
            return metadata(name: file.name, mimeType: file.mediaType, revision: file.activeRevision)
        default:
            throw CocoaError(.fileReadUnknown)
        }
    }

    static func metadata(
        name: Result<String, ProtonDriveSDKDriveError>, mimeType: String, revision: FileRevision
    ) -> PhotoMetadata {
        // Optional sections are independent. One absent or unsupported section must not discard other details.
        let additional = revision.claimedAdditionalMetadata ?? []
        func decode<T: Decodable>(_ type: T.Type, name: String) -> T? {
            guard let data = additional.first(where: { $0.name == name })?.utf8JsonValue else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
        let media = decode(Media.self, name: "Media")
        let camera = decode(Camera.self, name: "Camera")
        let location = decode(Location.self, name: "Location")
        let modificationTime = revision.claimedModificationTime.flatMap {
            $0.isFinite ? Date(timeIntervalSince1970: $0) : nil
        }
        return PhotoMetadata(
            filename: try? name.get(),
            mimeType: mimeType.isEmpty ? nil : mimeType,
            fileSize: revision.claimedSize.flatMap { $0 >= 0 ? Int(exactly: $0) : nil },
            pixelWidth: media?.width,
            pixelHeight: media?.height,
            device: camera?.device,
            durationSeconds: media?.duration,
            modificationTime: modificationTime,
            latitude: location?.latitude,
            longitude: location?.longitude
        )
    }

    // The SDK exposes decrypted sections of Proton's extended attributes, not full EXIF.
    private struct Media: Decodable {
        let width: Int?
        let height: Int?
        let duration: Double?
        enum CodingKeys: String, CodingKey {
            case width = "Width"
            case height = "Height"
            case duration = "Duration"
        }
    }
    private struct Camera: Decodable {
        let device: String?
        enum CodingKeys: String, CodingKey { case device = "Device" }
    }
    private struct Location: Decodable {
        let latitude: Double?
        let longitude: Double?
        enum CodingKeys: String, CodingKey {
            case latitude = "Latitude"
            case longitude = "Longitude"
        }
    }
}
