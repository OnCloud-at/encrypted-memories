import Foundation
import Photos
import PhotosCore
import UploadCore

/// Resolves a PhotoKit queue entry in two stages. It first streams each original only to compute its
/// identity (O(chunk) memory, no temp file). Core materializes verbatim bytes into the bounded temp
/// store only if dedupe returns `.upload`. HEIC stays HEIC and MOV stays MOV; `PHImageManager` is
/// never used.
public struct PhotoLibraryResourceResolver: BackupResourceResolving {
    private let tempStore: BackupTempFileStore
    private let cloudIdentifierProvider: @Sendable (String) -> String?

    public init(
        tempStore: BackupTempFileStore,
        cloudIdentifierProvider: @Sendable @escaping (String) -> String? = { _ in nil }
    ) {
        self.tempStore = tempStore
        self.cloudIdentifierProvider = cloudIdentifierProvider
    }

    public func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
        try await resolve(entry, onPreparationProgress: { _ in })
    }

    public func resolve(
        _ entry: UploadBackupSyncQueueEntry,
        onPreparationProgress: @escaping BackupResourcePreparationHandler
    ) async throws -> BackupResolvedResource? {
        guard entry.source.kind == .photoLibraryAsset else {
            throw UploadError.backend("photo resolver received source kind \(entry.source.kind.rawValue)")
        }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [entry.source.identifier], options: nil)
        guard let asset = fetch.firstObject else {
            return nil  // A deleted or unselected asset has no queue work.
        }

        let info = PhotoKitAssetMapper.info(for: asset)
        guard let plan = PhotoBackupAssetPlanner.exportPlan(for: info),
            let candidate = PhotoBackupAssetPlanner.candidate(for: info),
            let primaryResource = PhotoKitAssetMapper.resource(for: plan.primary.role, of: asset)
        else {
            return nil
        }

        // Stable descriptor dates: capture time drives the remote timeline; the descriptor's
        // modification date must not be the temp file's mtime (that would defeat manifest hash
        // reuse across re-exports), so it uses the asset's stable creation date.
        let captureDate = asset.creationDate ?? asset.modificationDate ?? Date()
        let additionalMetadata = try PhotoLibraryUploadMetadataBuilder.metadata(
            for: asset,
            cloudIdentifier: cloudIdentifierProvider(entry.source.identifier)
        )
        // Track deferred exports so the runner can release them as soon as the entry settles.
        let exportedURLs = ExportedURLBox()
        var didResolve = false
        defer {
            if !didResolve {
                for url in exportedURLs.urls { tempStore.discard(url) }
            }
        }
        let resourceCount = max(1, 1 + plan.secondaries.count)
        let identityProgress: @Sendable (Int, Double) -> Void = { completedResources, fraction in
            let aggregate = (Double(completedResources) + min(1, max(0, fraction))) / Double(resourceCount)
            onPreparationProgress(.init(phase: .identity, fraction: aggregate))
        }
        let primaryIdentity = try await readIdentity(
            primaryResource,
            filename: plan.primary.uploadFilename
        ) { fraction in
            identityProgress(0, fraction)
        }
        let primaryDescriptor = Self.identityDescriptor(
            source: candidate.snapshot.source,
            identity: primaryIdentity,
            filename: plan.primary.uploadFilename,
            stableDate: captureDate,
            tempStore: tempStore
        )
        let primaryRole = plan.primary.role
        let primaryByteCount = primaryIdentity.byteCount
        let localIdentifier = entry.source.identifier
        let tempStore = self.tempStore
        let primaryMaterializer:
            @Sendable (BackupResourcePreparationReporter) async throws -> UploadResourceDescriptor = {
                progress in
                guard
                    let currentAsset = PHAsset.fetchAssets(
                        withLocalIdentifiers: [localIdentifier], options: nil
                    ).firstObject,
                    let resource = PhotoKitAssetMapper.resource(for: primaryRole, of: currentAsset)
                else {
                    throw UploadError.fileMissing(plan.primary.uploadFilename)
                }
                let export = try await Self.export(
                    resource,
                    uploadFilename: plan.primary.uploadFilename,
                    expectedBytes: primaryByteCount,
                    tempStore: tempStore,
                    tracking: exportedURLs,
                    onProgress: {
                        progress(
                            .init(
                                phase: .materializing,
                                fraction: $0,
                                resourceIndex: 0,
                                resourceCount: resourceCount
                            ))
                    }
                )
                return Self.materializedDescriptor(
                    source: candidate.snapshot.source,
                    export: export,
                    filename: plan.primary.uploadFilename,
                    stableDate: captureDate
                )
            }

        var secondaries: [BackupSecondaryResource] = []
        for (secondaryIndex, item) in plan.secondaries.enumerated() {
            guard let resource = PhotoKitAssetMapper.resource(for: item.role, ordinal: item.ordinal, of: asset) else {
                throw UploadError.fileMissing(item.uploadFilename)
            }
            let identity = try await readIdentity(resource, filename: item.uploadFilename) { fraction in
                identityProgress(secondaryIndex + 1, fraction)
            }
            let source = UploadSourceIdentity(
                kind: .photoLibraryAsset,
                identifier: entry.source.identifier,
                resource: item.sourceResource
            )
            let role = item.role
            let ordinal = item.ordinal
            let filename = item.uploadFilename
            let expectedByteCount = identity.byteCount
            let materializer: @Sendable (BackupResourcePreparationReporter) async throws -> UploadResourceDescriptor = {
                progress in
                guard
                    let currentAsset = PHAsset.fetchAssets(
                        withLocalIdentifiers: [localIdentifier], options: nil
                    ).firstObject,
                    let currentResource = PhotoKitAssetMapper.resource(
                        for: role, ordinal: ordinal, of: currentAsset
                    )
                else {
                    throw UploadError.fileMissing(filename)
                }
                let export = try await Self.export(
                    currentResource,
                    uploadFilename: filename,
                    expectedBytes: expectedByteCount,
                    tempStore: tempStore,
                    tracking: exportedURLs,
                    onProgress: {
                        progress(
                            .init(
                                phase: .materializing,
                                fraction: $0,
                                resourceIndex: secondaryIndex + 1,
                                resourceCount: resourceCount
                            ))
                    }
                )
                return Self.materializedDescriptor(
                    source: source,
                    export: export,
                    filename: filename,
                    stableDate: captureDate
                )
            }
            secondaries.append(
                BackupSecondaryResource(
                    descriptor: Self.identityDescriptor(
                        source: source,
                        identity: identity,
                        filename: item.uploadFilename,
                        stableDate: captureDate,
                        tempStore: tempStore
                    ),
                    mediaType: item.mimeType
                        ?? SupportedMedia.mimeType(for: URL(fileURLWithPath: item.uploadFilename))
                        ?? "application/octet-stream",
                    additionalMetadata: additionalMetadata,
                    materializeWithProgress: materializer
                ))
        }

        didResolve = true
        return BackupResolvedResource(
            candidate: candidate,
            descriptor: primaryDescriptor,
            mediaType: plan.primary.mimeType
                ?? SupportedMedia.mimeType(for: URL(fileURLWithPath: plan.primary.uploadFilename))
                ?? "application/octet-stream",
            additionalMetadata: additionalMetadata,
            captureDate: captureDate,
            secondaries: secondaries,
            materializeWithProgress: primaryMaterializer,
            cleanup: { for url in exportedURLs.urls { tempStore.discard(url) } }
        )
    }

    /// Collects committed export URLs so the whole compound can be discarded in one cleanup call.
    /// A reference box (not an inout array) so it survives the async export hops and is captured
    /// by the `cleanup` closure.
    private final class ExportedURLBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URL] = []
        func append(_ url: URL) { lock.withLock { stored.append(url) } }
        var urls: [URL] { lock.withLock { stored } }
    }

    private struct IdentityResult {
        let byteCount: Int64
        let sha1Digest: Data
    }

    private static func identityDescriptor(
        source: UploadSourceIdentity,
        identity: IdentityResult,
        filename: String,
        stableDate: Date,
        tempStore: BackupTempFileStore
    ) -> UploadResourceDescriptor {
        return UploadResourceDescriptor(
            source: source,
            fileURL: tempStore.directory.appendingPathComponent(".not-materialized"),
            filename: filename,
            fileSize: identity.byteCount,
            modificationDate: stableDate,
            precomputedSHA1Digest: identity.sha1Digest
        )
    }

    private static func materializedDescriptor(
        source: UploadSourceIdentity,
        export: ExportResult,
        filename: String,
        stableDate: Date
    ) -> UploadResourceDescriptor {
        UploadResourceDescriptor(
            source: source,
            fileURL: export.url,
            filename: filename,
            fileSize: export.byteCount,
            modificationDate: stableDate,
            precomputedSHA1Digest: export.sha1Digest
        )
    }

    private struct ExportResult {
        let url: URL
        let byteCount: Int64
        let sha1Digest: Data
    }

    /// PhotoKit may report very fine-grained iCloud progress. One-percent buckets cap cross-actor/UI churn
    /// while still updating often enough that iOS can observe continued-processing liveness.
    private final class FractionProgressGate: @unchecked Sendable {
        private let lock = NSLock()
        private var lastBucket = -1
        private let handler: @Sendable (Double) -> Void

        init(_ handler: @escaping @Sendable (Double) -> Void) { self.handler = handler }

        func publish(_ fraction: Double) {
            let clamped = min(1, max(0, fraction))
            let bucket = Int((clamped * 100).rounded(.down))
            let shouldPublish = lock.withLock {
                guard bucket > lastBucket else { return false }
                lastBucket = bucket
                return true
            }
            if shouldPublish { handler(Double(bucket) / 100) }
        }
    }

    /// Hashes one PhotoKit resource without materializing it. This is the common path for a library
    /// that is already backed up: original bytes are read once, but no temp I/O is paid.
    private func readIdentity(
        _ resource: PHAssetResource,
        filename: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> IdentityResult {
        let sha1 = UploadSHA1Accumulator()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let progressGate = FractionProgressGate(onProgress)
        let manager = PHAssetResourceManager.default()
        let liveness = PhotoKitResourceRequestLivenessGuard<PHAssetResourceDataRequestID>(
            cancelRequest: { manager.cancelDataRequest($0) }
        )
        options.progressHandler = {
            liveness.markActivity()
            progressGate.publish($0)
        }
        final class ReadBox: @unchecked Sendable {
            var bytes: Int64 = 0
        }
        let box = ReadBox()
        try await liveness.waitForCompletion {
            manager.requestData(for: resource, options: options) { data in
                liveness.receiveData {
                    sha1.update(data)
                    box.bytes += Int64(data.count)
                }
            } completionHandler: { error in
                liveness.complete(
                    error: error.map {
                        Self.normalizedPhotoKitError($0, filename: filename)
                    }
                )
            }
        }
        progressGate.publish(1)
        return IdentityResult(byteCount: box.bytes, sha1Digest: sha1.finalizeDigest())
    }

    /// Materializes one resource only after Core selected it for upload. Chunks go straight to the
    /// temp file and are hashed again so the runner can reject a source that changed after preflight.
    private static func export(
        _ resource: PHAssetResource,
        uploadFilename: String,
        expectedBytes: Int64,
        tempStore: BackupTempFileStore,
        tracking exported: ExportedURLBox,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExportResult {
        let partialURL = try tempStore.reserve(filename: uploadFilename, expectedBytes: expectedBytes)
        do {
            guard FileManager.default.createFile(atPath: partialURL.path, contents: nil) else {
                throw UploadError.backend("PhotoKit export file could not be created")
            }
            let handle = try FileHandle(forWritingTo: partialURL)
            defer { try? handle.close() }
            let sha1 = UploadSHA1Accumulator()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            let progressGate = FractionProgressGate(onProgress)
            let manager = PHAssetResourceManager.default()
            let liveness = PhotoKitResourceRequestLivenessGuard<PHAssetResourceDataRequestID>(
                cancelRequest: { manager.cancelDataRequest($0) }
            )
            options.progressHandler = {
                liveness.markActivity()
                progressGate.publish($0)
            }

            final class WriteBox: @unchecked Sendable {
                var bytes: Int64 = 0
            }
            let box = WriteBox()
            try await liveness.waitForCompletion {
                manager.requestData(for: resource, options: options) { data in
                    liveness.receiveData {
                        try tempStore.recordWrite(to: partialURL, byteCount: data.count)
                        try handle.write(contentsOf: data)
                        sha1.update(data)
                        box.bytes += Int64(data.count)
                        if expectedBytes > 0 {
                            progressGate.publish(Double(box.bytes) / Double(expectedBytes))
                        }
                    }
                } completionHandler: { error in
                    liveness.complete(
                        error: error.map {
                            normalizedPhotoKitError($0, filename: uploadFilename)
                        }
                    )
                }
            }
            progressGate.publish(1)

            let finalURL = try tempStore.commit(partialURL)
            exported.append(finalURL)
            let digest = sha1.finalizeDigest()
            return ExportResult(url: finalURL, byteCount: box.bytes, sha1Digest: digest)
        } catch {
            tempStore.discard(partialURL)
            throw error
        }
    }

    /// Converts stable PhotoKit failure codes into Core upload categories. Network and storage conditions stay
    /// retryable; errors that prove the resource is gone remove it from backup work.
    static func normalizedPhotoKitError(_ error: Error, filename: String) -> Error {
        let nsError = error as NSError
        guard nsError.domain == PHPhotosErrorDomain,
            let code = PHPhotosError.Code(rawValue: nsError.code)
        else { return error }

        switch code {
        case .missingResource, .identifierNotFound, .invalidResource:
            return UploadError.fileMissing(filename)
        case .accessRestricted, .accessUserDenied:
            return UploadError.permissionDenied(filename)
        case .networkAccessRequired, .networkError, .libraryVolumeOffline, .operationInterrupted:
            return UploadError.transport(code: nsError.code, message: nsError.localizedDescription)
        case .notEnoughSpace:
            return BackupTempFileStore.BackupTempFileError.diskBudgetExceeded
        default:
            return error
        }
    }
}
