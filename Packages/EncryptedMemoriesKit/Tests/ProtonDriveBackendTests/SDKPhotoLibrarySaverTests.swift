import Foundation
import PhotosCore
import ProtonDriveSDK
import Testing

@testable import ProtonDriveBackend

@Suite("SDK photo library saver")
struct SDKPhotoLibrarySaverTests {
    private let one = PhotoUID(volumeID: "shared-volume", nodeID: "one")
    private let two = PhotoUID(volumeID: "shared-volume", nodeID: "two")

    @Test func savesEveryUniquePhotoOnceWithItsVolumeQualifiedIdentity() async throws {
        let client = FakeSDKPhotoTimelineSaveClient()
        await client.setResults([
            NodeResult(nodeUid: sdkUID(one), error: nil),
            NodeResult(nodeUid: sdkUID(two), error: nil),
        ])

        let result = try await SDKPhotoLibrarySaver(client: client).save([one, two, one])

        #expect(result == PhotoLibrarySaveResult(saved: [one, two], failed: []))
        let requested = await client.requested
        #expect(requested.map(\.sdkCompatibleIdentifier) == [sdkUID(one), sdkUID(two)].map(\.sdkCompatibleIdentifier))
    }

    @Test func aPhotoWithoutAResultIsReportedAsFailed() async throws {
        let client = FakeSDKPhotoTimelineSaveClient()
        await client.setResults([NodeResult(nodeUid: sdkUID(one), error: nil)])

        let result = try await SDKPhotoLibrarySaver(client: client).save([one, two])

        #expect(result == PhotoLibrarySaveResult(saved: [one], failed: [two]))
    }

    @Test func anEmptyRequestNeverCallsTheSDK() async throws {
        let client = FakeSDKPhotoTimelineSaveClient()

        let result = try await SDKPhotoLibrarySaver(client: client).save([])

        #expect(result == PhotoLibrarySaveResult(saved: [], failed: []))
        #expect(await client.callCount == 0)
    }

    @Test func aStreamedCallbackFailureFailsTheRequest() async throws {
        let client = FakeSDKPhotoTimelineSaveClient()
        await client.setCallbackError(true)

        await #expect(throws: FakeSDKPhotoTimelineSaveClient.CallbackFailure.self) {
            _ = try await SDKPhotoLibrarySaver(client: client).save([one])
        }
    }

    @Test func copiesReportedBeforeAFailureAreKeptAsAPartialResult() async throws {
        let client = FakeSDKPhotoTimelineSaveClient()
        await client.setResults([NodeResult(nodeUid: sdkUID(one), error: nil)])
        await client.setCallbackError(true)

        let result = try await SDKPhotoLibrarySaver(client: client).save([one, two])

        #expect(result == PhotoLibrarySaveResult(saved: [one], failed: [two]))
    }

    @Test func aTerminalSDKFailureAfterACopyKeepsThatCopy() async throws {
        let client = FakeSDKPhotoTimelineSaveClient()
        await client.setResults([NodeResult(nodeUid: sdkUID(one), error: nil)])
        await client.setThrowAfterResults(true)

        let result = try await SDKPhotoLibrarySaver(client: client).save([one, two])

        #expect(result == PhotoLibrarySaveResult(saved: [one], failed: [two]))
    }

    @Test func aTerminalSDKFailureWithoutACopyFailsTheRequest() async throws {
        let client = FakeSDKPhotoTimelineSaveClient()
        await client.setThrowAfterResults(true)

        await #expect(throws: FakeSDKPhotoTimelineSaveClient.CallbackFailure.self) {
            _ = try await SDKPhotoLibrarySaver(client: client).save([one])
        }
    }

    @Test func failedAndUnrequestedOutcomesNeverCountAsSaved() {
        let requestedBySDKID = [
            sdkUID(one).sdkCompatibleIdentifier: one,
            sdkUID(two).sdkCompatibleIdentifier: two,
        ]

        let result = SDKPhotoLibrarySaver.result(
            requested: [one, two],
            requestedBySDKID: requestedBySDKID,
            outcomes: [
                (sdkIdentifier: sdkUID(one).sdkCompatibleIdentifier, succeeded: false),
                (sdkIdentifier: sdkUID(two).sdkCompatibleIdentifier, succeeded: true),
                (sdkIdentifier: "shared-volume~unrequested", succeeded: true),
            ]
        )

        #expect(result == PhotoLibrarySaveResult(saved: [two], failed: [one]))
    }

    @Test func aLaterSuccessForTheSamePhotoWins() {
        let requestedBySDKID = [sdkUID(one).sdkCompatibleIdentifier: one]

        let result = SDKPhotoLibrarySaver.result(
            requested: [one],
            requestedBySDKID: requestedBySDKID,
            outcomes: [
                (sdkIdentifier: sdkUID(one).sdkCompatibleIdentifier, succeeded: false),
                (sdkIdentifier: sdkUID(one).sdkCompatibleIdentifier, succeeded: true),
            ]
        )

        #expect(result == PhotoLibrarySaveResult(saved: [one], failed: []))
    }
}

private actor FakeSDKPhotoTimelineSaveClient: SDKPhotoTimelineSaveClient {
    struct CallbackFailure: Error {}

    private(set) var requested: [SDKNodeUid] = []
    private(set) var callCount = 0
    private var results: [NodeResult] = []
    private var failCallback = false
    private var throwAfterResults = false

    func setResults(_ results: [NodeResult]) { self.results = results }
    func setCallbackError(_ fail: Bool) { failCallback = fail }
    func setThrowAfterResults(_ fail: Bool) { throwAfterResults = fail }

    func savePhotosToTimeline(
        photoUids: [SDKNodeUid],
        cancellationToken: UUID,
        onNodeResult: @escaping NodeResultCallback
    ) async throws {
        callCount += 1
        requested = photoUids
        results.forEach { onNodeResult(.success($0)) }
        if failCallback { onNodeResult(.failure(CallbackFailure())) }
        if throwAfterResults { throw CallbackFailure() }
    }

    func cancelSavePhotosToTimeline(cancellationToken: UUID) async throws {}
}

private func sdkUID(_ uid: PhotoUID) -> SDKNodeUid {
    SDKNodeUid(volumeID: uid.volumeID, nodeID: uid.nodeID)
}
