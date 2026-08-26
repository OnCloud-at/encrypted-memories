import Foundation
import PhotosCore
import ProtonDriveSDK

protocol SDKPhotoTagsClient: Sendable {
    func updatePhotos(
        _ updates: [PhotoTagsUpdate],
        onNodeResult: @escaping NodeResultCallback
    ) async throws
}

extension EncryptedMemoriesClient: SDKPhotoTagsClient {}

/// SDK-backed favorite mutation with strict per-node result accounting. Missing or failed SDK
/// results are failures; callers receive exact identities for selective optimistic-UI rollback.
struct SDKFavoriteWriter: Sendable {
    private let client: any SDKPhotoTagsClient

    init(client: any SDKPhotoTagsClient) {
        self.client = client
    }

    func setFavorites(_ uids: [PhotoUID], favorite: Bool) async throws {
        var seen = Set<PhotoUID>()
        let uniqueUIDs = uids.filter { seen.insert($0).inserted }
        guard !uniqueUIDs.isEmpty else { return }

        let updates = uniqueUIDs.map { uid in
            let sdkUID = SDKNodeUid(volumeID: uid.volumeID, nodeID: uid.nodeID)
            return PhotoTagsUpdate(
                nodeUid: sdkUID,
                tagsToAdd: favorite ? [.favorites] : [],
                tagsToRemove: favorite ? [] : [.favorites]
            )
        }
        let collector = SDKEnumerationCollector<NodeResult>()
        try await client.updatePhotos(updates, onNodeResult: { result in collector.receive(result) })
        let results = try collector.collected()
        let requestedBySDKID = Dictionary(
            uniqueKeysWithValues: uniqueUIDs.map {
                (SDKNodeUid(volumeID: $0.volumeID, nodeID: $0.nodeID).sdkCompatibleIdentifier, $0)
            })

        var succeeded = Set<PhotoUID>()
        var failed = Set<PhotoUID>()
        var firstFailure: String?
        for result in results {
            guard let uid = requestedBySDKID[result.nodeUid.sdkCompatibleIdentifier] else { continue }
            if let error = result.error {
                failed.insert(uid)
                if firstFailure == nil { firstFailure = error.localizedDescription }
            } else {
                succeeded.insert(uid)
            }
        }
        failed.formUnion(Set(uniqueUIDs).subtracting(succeeded).subtracting(failed))

        guard failed.isEmpty else {
            throw FavoriteMutationError(
                succeeded: succeeded,
                failed: failed,
                diagnosticMessage: firstFailure ?? "SDK omitted one or more per-photo results"
            )
        }
    }
}
