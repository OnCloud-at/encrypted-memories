import Foundation
import PhotosCore
import ProtonDriveSDK
import Testing

@testable import ProtonDriveBackend

@Suite("SDK favorite writer")
struct SDKFavoriteWriterTests {
    @Test func favoriteBatchAddsSDKFavoriteTagOncePerUniquePhoto() async throws {
        let client = FakeSDKPhotoTagsClient()
        let one = PhotoUID(volumeID: "volume", nodeID: "one")
        let two = PhotoUID(volumeID: "volume", nodeID: "two")
        await client.setResults([
            NodeResult(nodeUid: sdkUID(one), error: nil),
            NodeResult(nodeUid: sdkUID(two), error: nil),
        ])

        try await SDKFavoriteWriter(client: client).setFavorites([one, two, one], favorite: true)

        let updates = await client.updates
        #expect(updates.count == 2)
        #expect(updates.allSatisfy { $0.tagsToAdd == [ProtonDriveSDK.PhotoTag.favorites] })
        #expect(updates.allSatisfy { $0.tagsToRemove.isEmpty })
    }

    @Test func unfavoriteBatchRemovesSDKFavoriteTag() async throws {
        let client = FakeSDKPhotoTagsClient()
        let uid = PhotoUID(volumeID: "volume", nodeID: "one")
        await client.setResults([NodeResult(nodeUid: sdkUID(uid), error: nil)])

        try await SDKFavoriteWriter(client: client).setFavorites([uid], favorite: false)

        let update = try #require(await client.updates.first)
        #expect(update.tagsToAdd.isEmpty)
        #expect(update.tagsToRemove == [ProtonDriveSDK.PhotoTag.favorites])
    }

    @Test func missingPerNodeResultReportsExactFailedIdentityAndKeepsSuccess() async throws {
        let client = FakeSDKPhotoTagsClient()
        let one = PhotoUID(volumeID: "volume", nodeID: "one")
        let two = PhotoUID(volumeID: "volume", nodeID: "two")
        await client.setResults([NodeResult(nodeUid: sdkUID(one), error: nil)])

        do {
            try await SDKFavoriteWriter(client: client).setFavorites([one, two], favorite: true)
            Issue.record("Expected partial favorite mutation")
        } catch let error as FavoriteMutationError {
            #expect(error.succeeded == [one])
            #expect(error.failed == [two])
            #expect(error.diagnosticMessage.contains("omitted"))
        }
    }

    @Test func callbackFailureStopsFavoriteMutationAndSurfacesError() async throws {
        let client = FakeSDKPhotoTagsClient()
        let uid = PhotoUID(volumeID: "volume", nodeID: "one")
        await client.setCallbackError(.failed)

        do {
            try await SDKFavoriteWriter(client: client).setFavorites([uid], favorite: true)
            Issue.record("Expected the streamed SDK callback failure")
        } catch let error as TestCallbackError {
            #expect(error == .failed)
        }
    }
}

private actor FakeSDKPhotoTagsClient: SDKPhotoTagsClient {
    private(set) var updates: [PhotoTagsUpdate] = []
    private var results: [NodeResult] = []
    private var callbackError: TestCallbackError?

    func setResults(_ results: [NodeResult]) {
        self.results = results
    }

    func setCallbackError(_ error: TestCallbackError?) {
        callbackError = error
    }

    func updatePhotos(
        _ updates: [PhotoTagsUpdate],
        onNodeResult: @escaping NodeResultCallback
    ) async throws {
        self.updates = updates
        results.forEach { onNodeResult(.success($0)) }
        if let callbackError {
            onNodeResult(.failure(callbackError))
        }
    }
}

private enum TestCallbackError: Error, Equatable {
    case failed
}

private func sdkUID(_ uid: PhotoUID) -> SDKNodeUid {
    SDKNodeUid(volumeID: uid.volumeID, nodeID: uid.nodeID)
}
