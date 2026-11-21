import AlbumCore
import Foundation
import PhotosCore
import ProtonAuth
import ProtonDriveSDK

/// The album write calls of the SDK that `SDKAlbumWriteBackend` uses. The protocol keeps SDK types out of
/// AlbumCore and lets tests run the adapter without a signed-in client.
protocol SDKAlbumWriteClient: Sendable {
    func createAlbum(name: String, cancellationToken: UUID) async throws -> DriveNode
    func cancelCreateAlbum(cancellationToken: UUID) async throws
    func updateAlbum(
        albumUid: SDKNodeUid, name: String?, coverPhotoUid: SDKNodeUid?, cancellationToken: UUID
    ) async throws -> DriveNode
    func cancelUpdateAlbum(cancellationToken: UUID) async throws
    func deleteAlbum(albumUid: SDKNodeUid, config: AlbumDeletionConfig, cancellationToken: UUID) async throws
    func cancelDeleteAlbum(cancellationToken: UUID) async throws
    func addPhotosToAlbum(
        albumUid: SDKNodeUid, photoUids: [SDKNodeUid], cancellationToken: UUID,
        onNodeResult: @escaping NodeResultCallback
    ) async throws
    func cancelAddPhotosToAlbum(cancellationToken: UUID) async throws
    func removePhotosFromAlbum(
        albumUid: SDKNodeUid, photoUids: [SDKNodeUid], cancellationToken: UUID,
        onNodeResult: @escaping NodeResultCallback
    ) async throws
    func cancelRemovePhotosFromAlbum(cancellationToken: UUID) async throws
}

extension EncryptedMemoriesClient: SDKAlbumWriteClient {}

enum SDKAlbumWriteError: Error, Equatable {
    /// `createAlbum` answered with a node that is not an album.
    case unexpectedNode
    /// The SDK finished a membership write without a result for a requested photo. The outcome is unknown.
    case missingResult(PhotoUID)
}

/// `AlbumWriteBackend` over the album calls of SDK 0.33.1. The SDK runs the album cryptography.
///
/// An album identifier is a bare node identifier of an album in the account's own Photos volume, so every
/// call addresses `ownVolumeID()`. Shared albums stay read-only (`AlbumsRepository.rejectSharedAlbumTarget`).
struct SDKAlbumWriteBackend: AlbumWriteBackend {
    /// The Proton answer for a photo that is already in the album.
    static let alreadyInAlbumCode = 2_500
    /// The SDK refuses a photo whose parent already is the album before it sends a request. The SDK sends the
    /// simple name of the exception type (`Type.Name`, no namespace) as the error type, with the undefined
    /// domain and no code (upstream `ExceptionExtensions.ToProtoError`, `InteropErrorConverter`, tag cs/v0.33.1).
    static let alreadyInAlbumErrorType = "PhotoAlreadyInTargetException"

    private let client: any SDKAlbumWriteClient
    private let ownVolumeID: @Sendable () async throws -> String
    private let admission: RequestAdmission

    init(
        client: any SDKAlbumWriteClient,
        ownVolumeID: @escaping @Sendable () async throws -> String,
        admission: RequestAdmission = RequestAdmission(gate: nil, requestCause: nil)
    ) {
        self.client = client
        self.ownVolumeID = ownVolumeID
        self.admission = admission
    }

    func createAlbum(name: String) async throws -> AlbumID {
        try await write {
            let node = try await SDKCancellableOperation.run { [client] token in
                try await client.createAlbum(name: name, cancellationToken: token)
            } cancel: { [client] token in
                try? await client.cancelCreateAlbum(cancellationToken: token)
            }
            guard case .album(let album) = node else { throw SDKAlbumWriteError.unexpectedNode }
            return album.uid.nodeID
        }
    }

    func setAlbumCover(albumID: AlbumID, photoUID: PhotoUID) async throws {
        try await write {
            let album = SDKNodeUid(volumeID: try await ownVolumeID(), nodeID: albumID)
            let cover = SDKNodeUid(volumeID: photoUID.volumeID, nodeID: photoUID.nodeID)
            _ = try await SDKCancellableOperation.run { [client] token in
                try await client.updateAlbum(albumUid: album, name: nil, coverPhotoUid: cover, cancellationToken: token)
            } cancel: { [client] token in
                try? await client.cancelUpdateAlbum(cancellationToken: token)
            }
        }
    }

    /// Deletes only the album container. The SDK refuses with code 200302 when the album holds photos that exist
    /// only in it. This adapter never passes `.force`, which would delete those photos for good, and never
    /// `.saveToTimeline`, which would move them without the user's consent.
    func deleteAlbum(albumID: AlbumID) async throws {
        try await write {
            let album = SDKNodeUid(volumeID: try await ownVolumeID(), nodeID: albumID)
            try await SDKCancellableOperation.run { [client] token in
                try await client.deleteAlbum(
                    albumUid: album, config: .failIfContainsPhotosNotInTimeline, cancellationToken: token)
            } cancel: { [client] token in
                try? await client.cancelDeleteAlbum(cancellationToken: token)
            }
        }
    }

    /// All or nothing for the caller: a photo without a confirmed result, or with a failed one, throws
    /// `AlbumError.partialAddWithCauses`. A photo that is already in the album counts as added, as before.
    func addPhotos(_ photoUIDs: [PhotoUID], to albumID: AlbumID) async throws {
        guard !photoUIDs.isEmpty else { return }
        try await write {
            let album = SDKNodeUid(volumeID: try await ownVolumeID(), nodeID: albumID)
            let sdkUIDs = photoUIDs.map { SDKNodeUid(volumeID: $0.volumeID, nodeID: $0.nodeID) }
            let collector = SDKEnumerationCollector<NodeResult>()
            try await SDKCancellableOperation.run { [client] token in
                try await client.addPhotosToAlbum(
                    albumUid: album, photoUids: sdkUIDs, cancellationToken: token,
                    onNodeResult: { collector.receive($0) })
            } cancel: { [client] token in
                try? await client.cancelAddPhotosToAlbum(cancellationToken: token)
            }
            let (result, checked) = Self.attachResult(requested: photoUIDs, results: try collector.collected())
            let confirmed = result.attachedCount + result.alreadyMemberCount
            if confirmed < checked.count {
                DebugLog.log(
                    "[AlbumWrite] membership incomplete selected=\(photoUIDs.count) ok=\(confirmed) "
                        + "failed=\(result.failedCount) unanswered=\(checked.count - confirmed - result.failedCount)")
            }
            try result.requireComplete(for: checked)
        }
    }

    /// The same rule as `addPhotos`: the first failed or missing result throws, so the caller never reads a
    /// partial removal as a success.
    func removePhotos(_ photoUIDs: [PhotoUID], from albumID: AlbumID) async throws {
        guard !photoUIDs.isEmpty else { return }
        try await write {
            let album = SDKNodeUid(volumeID: try await ownVolumeID(), nodeID: albumID)
            let sdkUIDs = photoUIDs.map { SDKNodeUid(volumeID: $0.volumeID, nodeID: $0.nodeID) }
            let collector = SDKEnumerationCollector<NodeResult>()
            try await SDKCancellableOperation.run { [client] token in
                try await client.removePhotosFromAlbum(
                    albumUid: album, photoUids: sdkUIDs, cancellationToken: token,
                    onNodeResult: { collector.receive($0) })
            } cancel: { [client] token in
                try? await client.cancelRemovePhotosFromAlbum(cancellationToken: token)
            }
            let results = try collector.collected()
            if let failure = results.lazy.compactMap(\.error).first { throw failure }
            let confirmed = Set(results.map(\.nodeUid.sdkCompatibleIdentifier))
            if let missing = photoUIDs.first(where: {
                !confirmed.contains(SDKNodeUid(volumeID: $0.volumeID, nodeID: $0.nodeID).sdkCompatibleIdentifier)
            }) {
                throw SDKAlbumWriteError.missingResult(missing)
            }
        }
    }

    // MARK: - Results

    /// Per-photo outcomes of an add, keyed by link identifier. A failure is never replaced by a later success
    /// of the same photo, and a failed result for a photo that nobody requested (a Live Photo companion that
    /// the SDK added with the main photo) counts as a failure of the whole add.
    static func attachResult(
        requested: [PhotoUID], results: [NodeResult]
    ) -> (result: AlbumAttachResult, checked: [PhotoUID]) {
        var result = AlbumAttachResult()
        var checked = requested
        let requestedIDs = Set(requested.map(\.nodeID))
        for item in results {
            let outcome = outcome(of: item)
            let linkID = item.nodeUid.nodeID
            if case .failed? = result.outcomes[linkID] { continue }
            result.outcomes[linkID] = outcome
            if case .failed = outcome, !requestedIDs.contains(linkID) {
                checked.append(PhotoUID(volumeID: item.nodeUid.volumeID, nodeID: linkID))
            }
        }
        return (result, checked)
    }

    private static func outcome(of result: NodeResult) -> AlbumAttachItemOutcome {
        guard let error = result.error else { return .attached }
        let code = error.underlyingAPINetworkError?.domainCode
        if code == alreadyInAlbumCode || error.type == alreadyInAlbumErrorType { return .alreadyMember }
        // The SDK message can carry server text, which must not reach the diagnostics.
        return .failed(code: code, message: "SDK album write failed: \(error.type)")
    }

    // MARK: - Errors

    private func write<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        do {
            return try await admission.run(operation)
        } catch {
            throw Self.albumError(from: error)
        }
    }

    /// Keeps the classification that callers read from `AlbumError.requestFailed`: cancellation stays
    /// cancellation, URL and socket failures become network causes, and an API answer keeps its HTTP status.
    /// The refusal 200302 keeps its SDK error as the underlying error; it is never transient and never retried.
    /// The Drive web API answer of the volume lookup keeps its status the same way.
    static func albumError(from error: any Error) -> any Error {
        if error is CancellationError || error is AlbumError { return error }
        if case .apiError(let status, _)? = error as? ProtonAuthError {
            return AlbumError.requestFailed(AlbumWriteCause(error, httpStatus: status))
        }
        if let signal = ProtonFailureClassifier.relatedTransferSignal(error) {
            guard let urlError = signal as? URLError, urlError.code != .cancelled else { return CancellationError() }
            return AlbumError.requestFailed(AlbumWriteCause(urlError))
        }
        guard let sdkError = error as? ProtonDriveSDKError else { return error }
        if sdkError.underlyingSocketNetworkError != nil {
            return AlbumError.requestFailed(AlbumWriteCause(URLError(.networkConnectionLost)))
        }
        if let transport = sdkError.underlyingHTTPNetworkError {
            if let status = transport.httpCode {
                return AlbumError.requestFailed(AlbumWriteCause(sdkError, httpStatus: status))
            }
            switch transport.errorType {
            case .userAuthenticationError, .configurationLimitExceeded:
                return AlbumError.requestFailed(AlbumWriteCause(sdkError))
            default:
                return AlbumError.requestFailed(AlbumWriteCause(URLError(.networkConnectionLost)))
            }
        }
        return AlbumError.requestFailed(
            AlbumWriteCause(sdkError, httpStatus: sdkError.underlyingAPINetworkError?.httpCode))
    }
}
