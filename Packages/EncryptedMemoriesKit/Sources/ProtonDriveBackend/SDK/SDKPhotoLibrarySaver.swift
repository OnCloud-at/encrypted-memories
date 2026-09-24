import Foundation
import PhotosCore
import ProtonDriveSDK

protocol SDKPhotoTimelineSaveClient: Sendable {
    func savePhotosToTimeline(
        photoUids: [SDKNodeUid],
        cancellationToken: UUID,
        onNodeResult: @escaping NodeResultCallback
    ) async throws

    func cancelSavePhotosToTimeline(cancellationToken: UUID) async throws
}

extension EncryptedMemoriesClient: SDKPhotoTimelineSaveClient {}

/// Copies shared photos into the account's own photo timeline through SDK `savePhotosToTimeline`.
///
/// The SDK copies Live Photo and burst companions itself and reports one result per requested main photo.
/// A missing or failed result is a failure, so callers always learn the exact identities that were not saved.
struct SDKPhotoLibrarySaver: Sendable {
    private let client: any SDKPhotoTimelineSaveClient

    init(client: any SDKPhotoTimelineSaveClient) {
        self.client = client
    }

    func save(_ uids: [PhotoUID]) async throws -> PhotoLibrarySaveResult {
        var seen = Set<PhotoUID>()
        let uniqueUIDs = uids.filter { seen.insert($0).inserted }
        guard !uniqueUIDs.isEmpty else { return PhotoLibrarySaveResult(saved: [], failed: []) }

        let requestedBySDKID = Dictionary(
            uniqueKeysWithValues: uniqueUIDs.map {
                (SDKNodeUid(volumeID: $0.volumeID, nodeID: $0.nodeID).sdkCompatibleIdentifier, $0)
            })
        let sdkUIDs = uniqueUIDs.map { SDKNodeUid(volumeID: $0.volumeID, nodeID: $0.nodeID) }
        let collector = SDKEnumerationCollector<NodeResult>()
        var terminalFailure: (any Error)?
        do {
            try await SDKCancellableOperation.run { [client] cancellationToken in
                try await client.savePhotosToTimeline(
                    photoUids: sdkUIDs,
                    cancellationToken: cancellationToken,
                    onNodeResult: { result in collector.receive(result) }
                )
            } cancel: { [client] cancellationToken in
                try? await client.cancelSavePhotosToTimeline(cancellationToken: cancellationToken)
            }
        } catch {
            terminalFailure = error
        }

        let received = collector.snapshot()
        let outcomes = received.elements.map {
            (sdkIdentifier: $0.nodeUid.sdkCompatibleIdentifier, succeeded: $0.error == nil)
        }
        let result = Self.result(requested: uniqueUIDs, requestedBySDKID: requestedBySDKID, outcomes: outcomes)
        // The SDK streams one result per finished photo. Copies reported before a failure already exist, so a
        // partial result replaces the error; the caller then refreshes the library and names the failed photos.
        if let failure = terminalFailure ?? received.failure, result.saved.isEmpty {
            throw failure
        }
        return result
    }

    /// Maps per-node SDK outcomes to the requested identities. Results for unrequested nodes are ignored. A
    /// photo with any successful result counts as saved; a photo without a successful result failed.
    static func result(
        requested: [PhotoUID],
        requestedBySDKID: [String: PhotoUID],
        outcomes: [(sdkIdentifier: String, succeeded: Bool)]
    ) -> PhotoLibrarySaveResult {
        var saved = Set<PhotoUID>()
        for outcome in outcomes where outcome.succeeded {
            if let uid = requestedBySDKID[outcome.sdkIdentifier] { saved.insert(uid) }
        }
        return PhotoLibrarySaveResult(saved: saved, failed: Set(requested).subtracting(saved))
    }
}
