import Foundation
import PhotosCore
import UploadCore

@testable import ProtonDriveBackend
@testable import ProtonDriveSDK

extension EncryptedMemoriesClient {
    /// An SDK client for tests without accounts. Its requests go through `protocols`.
    static func testClient(
        session: DriveSession, governor: ProtonRequestGovernor, protocols: [AnyClass]
    ) async throws -> EncryptedMemoriesClient {
        try await EncryptedMemoriesClient(
            configuration: ProtonDriveClientConfiguration(baseURL: "https://fixture.invalid/", clientUID: "fixture"),
            httpClient: SDKHttpClient(
                driveSession: session, requestGovernor: governor, urlProtocolClasses: protocols),
            accountClient: SDKAccountClient(addresses: [], unlockedByKeyID: [:]),
            logCallback: { _ in },
            featureFlagProviderCallback: { _, completion in completion(false) },
            recordMetricEventCallback: { _ in })
    }
}

extension DriveSDKBridge {
    /// A bridge for tests over `session`: an SDK client without accounts, the stores in `directory`, and requests
    /// sent through `protocols`. The first index build has not started unless `startsFirstBuild` is set.
    static func testBridge(
        directory: URL, session: DriveSession, governor: ProtonRequestGovernor, protocols: [AnyClass],
        crypto: DriveCrypto = DriveCrypto(addressKeys: [], signers: []),
        timelineStore: TimelineMetadataStore? = nil, startsFirstBuild: Bool = false,
        relatedFileOperations: RelatedFileOperations = .sdk,
        seriesRestoreRetry: BackupRetryPolicy = .init(baseDelay: 60, maxDelay: 900),
        checkedSeriesRestoreCandidates: [PhotoUID: [PhotoUID]]? = nil
    ) async throws -> DriveSDKBridge {
        let client = try await EncryptedMemoriesClient.testClient(
            session: session, governor: governor, protocols: protocols)
        let gate = TimelineMetadataStartGate()
        if startsFirstBuild { gate.buildStarted() }
        return DriveSDKBridge(
            prepared: PreparedSession(
                photosClient: client, uploadClientUID: "fixture", driveSession: session,
                requestGovernor: governor, expensiveUploadAccess: ExpensiveUploadAccess(),
                timelineStore: timelineStore, timelineOrderStore: nil, firstIndexBuildGate: gate,
                metadataReconciliation: TimelineMetadataReconciliation(startGate: gate), crypto: crypto,
                photosVolumeBootstrap: PhotosVolumeBootstrapService(session: session, crypto: crypto),
                recentlyDeletedStore: RecentlyDeletedListingStore(
                    directory: directory, accountUID: "fixture", keyPassword: ""),
                photoNames: nil, recentlyDeleted: RecentlyDeletedIdentities(listing: nil),
                uploadManifestURL: directory.appendingPathComponent("manifest.sqlite"),
                uploadManifestPolicy: .conservative),
            relatedFileOperations: relatedFileOperations, seriesRestoreRetry: seriesRestoreRetry,
            checkedSeriesRestoreCandidates: checkedSeriesRestoreCandidates)
    }
}
