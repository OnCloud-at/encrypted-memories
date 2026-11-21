import AlbumCore
import Foundation
import PhotosCore
import ProtonAuth
import Testing

@testable import ProtonDriveBackend
@testable import ProtonDriveSDK

@Suite("SDK album write backend")
struct SDKAlbumWriteBackendTests {
    private let ownVolume = "own-volume"
    private let one = PhotoUID(volumeID: "own-volume", nodeID: "one")
    private let two = PhotoUID(volumeID: "own-volume", nodeID: "two")

    private func backend(_ client: FakeSDKAlbumWriteClient) -> SDKAlbumWriteBackend {
        SDKAlbumWriteBackend(client: client, ownVolumeID: { "own-volume" })
    }

    // MARK: - Create, cover, delete

    @Test func createAlbumReturnsTheNodeIdentifierOfTheNewAlbum() async throws {
        let client = FakeSDKAlbumWriteClient()
        await client.setNode(.album(albumNode(id: "album-1")))

        let id = try await backend(client).createAlbum(name: "Trip")

        #expect(id == "album-1")
        #expect(await client.calls == [.create(name: "Trip")])
    }

    @Test func createAlbumRejectsANodeThatIsNotAnAlbum() async throws {
        let client = FakeSDKAlbumWriteClient()
        await client.setNode(.folder(folderNode(id: "folder-1")))

        await #expect(throws: SDKAlbumWriteError.unexpectedNode) {
            _ = try await backend(client).createAlbum(name: "Trip")
        }
    }

    @Test func setAlbumCoverChangesOnlyTheCoverOfTheOwnedAlbum() async throws {
        let client = FakeSDKAlbumWriteClient()
        await client.setNode(.album(albumNode(id: "album-1")))

        try await backend(client).setAlbumCover(albumID: "album-1", photoUID: one)

        #expect(
            await client.calls == [.update(album: "own-volume~album-1", name: nil, cover: "own-volume~one")])
    }

    @Test func deleteAlbumNeverAllowsTheSDKToRemovePhotosThatExistOnlyInTheAlbum() async throws {
        let client = FakeSDKAlbumWriteClient()

        try await backend(client).deleteAlbum(albumID: "album-1")

        #expect(
            await client.calls == [.delete(album: "own-volume~album-1", config: .failIfContainsPhotosNotInTimeline)])
    }

    @Test func theRefusalForPhotosThatExistOnlyInTheAlbumIsPermanentAndNotRetried() async throws {
        let client = FakeSDKAlbumWriteClient()
        // The SDK reports the refusal as a business-logic error with code 200302 and no HTTP status.
        await client.setFailure(sdkError(domain: .businessLogic, primary: 200_302))

        do {
            try await backend(client).deleteAlbum(albumID: "album-1")
            Issue.record("the delete must be refused")
        } catch let AlbumError.requestFailed(cause) {
            #expect(cause.kind == .unknown)
            #expect(!cause.isTransient)
            #expect((cause.underlyingError as? ProtonDriveSDKError)?.primaryCode == 200_302)
        }
        // One attempt with the safe configuration: no retry with force or save-to-timeline.
        #expect(
            await client.calls == [.delete(album: "own-volume~album-1", config: .failIfContainsPhotosNotInTimeline)])
    }

    // MARK: - Add: all or nothing

    @Test func addSendsEveryPhotoToTheOwnedAlbumAndAcceptsConfirmedResults() async throws {
        let client = FakeSDKAlbumWriteClient()
        await client.setResults([result(one), result(two)])

        try await backend(client).addPhotos([one, two], to: "album-1")

        #expect(
            await client.calls == [.add(album: "own-volume~album-1", photos: ["own-volume~one", "own-volume~two"])])
    }

    @Test func addWithoutPhotosNeverCallsTheSDK() async throws {
        let client = FakeSDKAlbumWriteClient()

        try await backend(client).addPhotos([], to: "album-1")

        #expect(await client.calls.isEmpty)
    }

    @Test func oneFailedPhotoFailsTheWholeAddAndKeepsItsServerCode() async throws {
        let client = FakeSDKAlbumWriteClient()
        await client.setResults([
            result(one), result(two, error: sdkError(domain: .api, primary: 2_501, secondary: 422)),
        ])

        do {
            try await backend(client).addPhotos([one, two], to: "album-1")
            Issue.record("a partial add must throw")
        } catch let AlbumError.partialAddWithCauses(succeeded, total, _, failures) {
            #expect(succeeded == 1)
            #expect(total == 2)
            #expect(failures.map(\.linkID) == ["two"])
            #expect(failures.map(\.code) == [2_501])
        }
    }

    @Test func aPhotoWithoutAResultFailsTheWholeAdd() async throws {
        let client = FakeSDKAlbumWriteClient()
        await client.setResults([result(one)])

        do {
            try await backend(client).addPhotos([one, two], to: "album-1")
            Issue.record("a missing result must throw")
        } catch let AlbumError.partialAddWithCauses(succeeded, total, _, failures) {
            #expect(succeeded == 1)
            #expect(total == 2)
            #expect(failures.map(\.linkID) == ["two"])
            #expect(failures.map(\.code) == [nil])
        }
    }

    @Test func aPhotoThatIsAlreadyInTheAlbumCountsAsAdded() async throws {
        let client = FakeSDKAlbumWriteClient()
        await client.setResults([
            result(one), result(two, error: sdkError(domain: .api, primary: 2_500, secondary: 422)),
        ])

        try await backend(client).addPhotos([one, two], to: "album-1")
    }

    @Test func aPhotoWhoseParentIsAlreadyTheAlbumCountsAsAdded() async throws {
        let client = FakeSDKAlbumWriteClient()
        // The SDK refuses the photo before any request: type is the exception name, undefined domain, no code.
        await client.setResults([
            result(one), result(two, error: sdkError(domain: .undefined, type: "PhotoAlreadyInTargetException")),
        ])

        try await backend(client).addPhotos([one, two], to: "album-1")
    }

    @Test func anUndefinedErrorOfAnotherTypeStaysAFailure() async throws {
        let client = FakeSDKAlbumWriteClient()
        await client.setResults([
            result(one), result(two, error: sdkError(domain: .undefined, type: "InvalidOperationException")),
        ])

        await #expect(throws: AlbumError.self) {
            try await backend(client).addPhotos([one, two], to: "album-1")
        }
    }

    @Test func aPhotoThatIsAlreadyInTheAlbumNeverHidesAnotherFailure() async throws {
        let client = FakeSDKAlbumWriteClient()
        await client.setResults([
            result(one, error: sdkError(domain: .api, primary: 2_500, secondary: 422)),
            result(two, error: sdkError(domain: .api, primary: 2_501, secondary: 422)),
        ])

        await #expect(throws: AlbumError.self) {
            try await backend(client).addPhotos([one, two], to: "album-1")
        }
    }

    @Test func aLaterSuccessNeverReplacesAnEarlierFailureOfTheSamePhoto() async throws {
        let client = FakeSDKAlbumWriteClient()
        await client.setResults([
            result(one, error: sdkError(domain: .api, primary: 2_501, secondary: 422)), result(one),
        ])

        await #expect(throws: AlbumError.self) {
            try await backend(client).addPhotos([one], to: "album-1")
        }
    }

    @Test func aFailedCompanionOfARequestedPhotoFailsTheAdd() async throws {
        let client = FakeSDKAlbumWriteClient()
        let companion = PhotoUID(volumeID: ownVolume, nodeID: "live-video")
        await client.setResults([
            result(one), result(companion, error: sdkError(domain: .api, primary: 2_501, secondary: 422)),
        ])

        do {
            try await backend(client).addPhotos([one], to: "album-1")
            Issue.record("a failed companion must throw")
        } catch let AlbumError.partialAddWithCauses(succeeded, total, _, failures) {
            #expect(succeeded == 1)
            #expect(total == 2)
            #expect(failures.map(\.linkID) == ["live-video"])
        }
    }

    @Test func aTerminalFailureAfterConfirmedResultsStillFailsTheAdd() async throws {
        let client = FakeSDKAlbumWriteClient()
        await client.setResults([result(one), result(two)])
        await client.setFailureAfterResults(sdkError(domain: .api, primary: 2_000, secondary: 503))

        do {
            try await backend(client).addPhotos([one, two], to: "album-1")
            Issue.record("the unknown tail of the add must throw")
        } catch let AlbumError.requestFailed(cause) {
            #expect(cause.kind == .http(status: 503))
            #expect(cause.isTransient)
        }
    }

    @Test func aStreamedCallbackFailureFailsTheAdd() async throws {
        let client = FakeSDKAlbumWriteClient()
        await client.setResults([result(one), result(two)])
        await client.setCallbackFailure(URLError(.networkConnectionLost))

        do {
            try await backend(client).addPhotos([one, two], to: "album-1")
            Issue.record("a callback failure must throw")
        } catch {
            #expect((error as? URLError)?.code == .networkConnectionLost)
        }
    }

    // MARK: - Remove

    @Test func removeSendsEveryPhotoAndAcceptsConfirmedResults() async throws {
        let client = FakeSDKAlbumWriteClient()
        await client.setResults([result(one), result(two)])

        try await backend(client).removePhotos([one, two], from: "album-1")

        #expect(
            await client.calls == [.remove(album: "own-volume~album-1", photos: ["own-volume~one", "own-volume~two"])])
    }

    @Test func aFailedResultFailsTheRemoveWithItsHTTPCause() async throws {
        let client = FakeSDKAlbumWriteClient()
        await client.setResults([
            result(one), result(two, error: sdkError(domain: .api, primary: 2_000, secondary: 429)),
        ])

        do {
            try await backend(client).removePhotos([one, two], from: "album-1")
            Issue.record("a failed removal must throw")
        } catch let AlbumError.requestFailed(cause) {
            #expect(cause.kind == .http(status: 429))
            #expect(cause.isTransient)
        }
    }

    @Test func aPhotoWithoutAResultFailsTheRemove() async throws {
        let client = FakeSDKAlbumWriteClient()
        await client.setResults([result(one)])

        await #expect(throws: SDKAlbumWriteError.missingResult(two)) {
            try await backend(client).removePhotos([one, two], from: "album-1")
        }
    }

    @Test func removeWithoutPhotosNeverCallsTheSDK() async throws {
        let client = FakeSDKAlbumWriteClient()

        try await backend(client).removePhotos([], from: "album-1")

        #expect(await client.calls.isEmpty)
    }

    // MARK: - Errors

    @Test func anAPIAnswerKeepsItsHTTPStatusAndTransientClassification() {
        for status in [408, 429, 500, 503, 403, 404] {
            let mapped = SDKAlbumWriteBackend.albumError(
                from: sdkError(domain: .api, primary: 2_000, secondary: status))
            guard case AlbumError.requestFailed(let cause) = mapped else {
                Issue.record("the API answer must stay typed: \(mapped)")
                continue
            }
            #expect(cause.kind == .http(status: status))
            #expect(cause.isTransient == (status == 408 || status == 429 || status >= 500))
        }
    }

    @Test func anAPIAnswerWithoutAStatusStaysUnknownAndIsNotTransient() {
        let mapped = SDKAlbumWriteBackend.albumError(from: sdkError(domain: .api, primary: 2_000))

        guard case AlbumError.requestFailed(let cause) = mapped else {
            Issue.record("the API answer must stay typed: \(mapped)")
            return
        }
        #expect(cause.kind == .unknown)
        #expect(!cause.isTransient)
    }

    @Test func aTransportFailureWithAStatusKeepsTheStatusAndOneWithoutAStatusIsANetworkCause() {
        let withStatus = SDKAlbumWriteBackend.albumError(
            from: sdkError(
                domain: .transport, primary: ProtonDriveSDKHTTPNetworkError.HttpErrorType.unknown.rawValue,
                secondary: 502))
        let without = SDKAlbumWriteBackend.albumError(
            from: sdkError(
                domain: .transport, primary: ProtonDriveSDKHTTPNetworkError.HttpErrorType.connectionError.rawValue))

        guard case AlbumError.requestFailed(let statusCause) = withStatus,
            case AlbumError.requestFailed(let networkCause) = without
        else {
            Issue.record("transport failures must stay typed")
            return
        }
        #expect(statusCause.kind == .http(status: 502))
        #expect(networkCause.kind == .network(code: URLError.networkConnectionLost.rawValue))
        #expect(networkCause.isTransient)
    }

    @Test func aURLFailureInsideTheSDKErrorBecomesANetworkCause() {
        let mapped = SDKAlbumWriteBackend.albumError(
            from: sdkError(
                domain: .network, type: NSURLErrorDomain, primary: URLError.notConnectedToInternet.rawValue))

        guard case AlbumError.requestFailed(let cause) = mapped else {
            Issue.record("the network failure must stay typed: \(mapped)")
            return
        }
        #expect(cause.kind == .network(code: URLError.notConnectedToInternet.rawValue))
        #expect(cause.isTransient)
    }

    @Test func aSocketFailureBecomesANetworkCause() {
        let mapped = SDKAlbumWriteBackend.albumError(
            from: sdkError(
                domain: .network, primary: 54,
                secondary: ProtonDriveSDKSocketNetworkError.SocketErrorType.socketError.rawValue))

        guard case AlbumError.requestFailed(let cause) = mapped else {
            Issue.record("the socket failure must stay typed: \(mapped)")
            return
        }
        #expect(cause.isTransient)
    }

    @Test func cancellationStaysCancellationInEveryShape() {
        let successful = SDKAlbumWriteBackend.albumError(from: sdkError(domain: .successfulCancellation))
        let urlCancelled = SDKAlbumWriteBackend.albumError(
            from: sdkError(domain: .network, type: NSURLErrorDomain, primary: URLError.cancelled.rawValue))

        #expect(successful is CancellationError)
        #expect(urlCancelled is CancellationError)
        #expect(SDKAlbumWriteBackend.albumError(from: CancellationError()) is CancellationError)
    }

    @Test func aFailedVolumeLookupKeepsItsHTTPStatus() async throws {
        let client = FakeSDKAlbumWriteClient()
        let failing = SDKAlbumWriteBackend(
            client: client, ownVolumeID: { throw ProtonAuthError.apiError(code: 503, message: "later") })

        do {
            try await failing.deleteAlbum(albumID: "album-1")
            Issue.record("the lookup failure must stop the delete")
        } catch let AlbumError.requestFailed(cause) {
            #expect(cause.kind == .http(status: 503))
            #expect(cause.isTransient)
        }
        #expect(await client.calls.isEmpty)
    }

    @Test func albumErrorsAndForeignErrorsPassThroughUnchanged() {
        let album = AlbumError.partialAdd(succeeded: 1, total: 2, message: "m")
        let foreign = URLError(.badServerResponse)

        #expect(SDKAlbumWriteBackend.albumError(from: album) as? AlbumError == album)
        #expect((SDKAlbumWriteBackend.albumError(from: foreign) as? URLError)?.code == .badServerResponse)
    }

    // MARK: - Cancellation and admission

    @Test func cancellingTheTaskCancelsTheNativeAddWithTheSameToken() async throws {
        let client = FakeSDKAlbumWriteClient()
        await client.blockUntilCancelled()
        let backend = backend(client)
        let (one, albumID) = (one, "album-1")

        let task = Task { try await backend.addPhotos([one], to: albumID) }
        while await client.calls.isEmpty { await Task.yield() }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        let used = await client.usedTokens
        let cancelled = await client.cancelledTokens
        #expect(used.count == 1)
        #expect(cancelled == used)
    }

    @Test func cancellingTheTaskCancelsEveryOtherNativeWriteWithTheSameToken() async throws {
        let operations: [(String, @Sendable (SDKAlbumWriteBackend) async throws -> Void)] = [
            ("create", { _ = try await $0.createAlbum(name: "Trip") }),
            (
                "cover",
                { try await $0.setAlbumCover(albumID: "album-1", photoUID: PhotoUID(volumeID: "v", nodeID: "p")) }
            ),
            ("delete", { try await $0.deleteAlbum(albumID: "album-1") }),
            ("remove", { try await $0.removePhotos([PhotoUID(volumeID: "v", nodeID: "p")], from: "album-1") }),
        ]
        for (name, operation) in operations {
            let client = FakeSDKAlbumWriteClient()
            await client.blockUntilCancelled()
            let backend = backend(client)

            let task = Task { try await operation(backend) }
            while await client.calls.isEmpty { await Task.yield() }
            task.cancel()

            await #expect(throws: CancellationError.self, "\(name)") { try await task.value }
            let used = await client.usedTokens
            let cancelled = await client.cancelledTokens
            #expect(used.count == 1, "\(name)")
            #expect(cancelled == used, "\(name)")
        }
    }

    @Test func aClosedSessionNeverReachesTheSDK() async throws {
        let client = FakeSDKAlbumWriteClient()
        let gate = JoinedShutdownGate()
        gate.closeAdmission()
        let closed = SDKAlbumWriteBackend(
            client: client, ownVolumeID: { "own-volume" },
            admission: RequestAdmission(gate: gate, requestCause: nil))

        await #expect(throws: CancellationError.self) { try await closed.deleteAlbum(albumID: "album-1") }
        #expect(await client.calls.isEmpty)
    }
}

// MARK: - Fixtures

private func result(_ uid: PhotoUID, error: ProtonDriveSDKError? = nil) -> NodeResult {
    NodeResult(nodeUid: SDKNodeUid(volumeID: uid.volumeID, nodeID: uid.nodeID), error: error)
}

private func sdkError(
    domain: Proton_Drive_Sdk_ErrorDomain, type: String = "fixture", primary: Int? = nil, secondary: Int? = nil
) -> ProtonDriveSDKError {
    ProtonDriveSDKError(
        protoError: Proton_Drive_Sdk_Error.with {
            $0.type = type
            $0.domain = domain
            $0.message = "PRIVATE SERVER TEXT"
            if let primary { $0.primaryCode = Int64(primary) }
            if let secondary { $0.secondaryCode = Int64(secondary) }
        })
}

private func albumNode(id: String) -> AlbumNode {
    AlbumNode(
        uid: SDKNodeUid(volumeID: "own-volume", nodeID: id), parentUid: nil, name: .success("Trip"), creationTime: 1,
        trashTime: nil, nameAuthor: Author(emailAddress: nil, signatureVerificationError: nil),
        keyAuthor: Author(emailAddress: nil, signatureVerificationError: nil),
        ownedBy: OwnedBy(email: nil, organization: nil), isShared: false, isSharedByUrl: false,
        directRole: .inherited, membership: nil, errors: [], photoCount: 0, coverPhotoNodeUid: nil,
        lastActivityTime: nil)
}

private func folderNode(id: String) -> FolderNode {
    FolderNode(
        uid: SDKNodeUid(volumeID: "own-volume", nodeID: id), parentUid: nil, name: .success("Folder"),
        creationTime: 1, trashTime: nil, nameAuthor: Author(emailAddress: nil, signatureVerificationError: nil),
        keyAuthor: Author(emailAddress: nil, signatureVerificationError: nil),
        ownedBy: OwnedBy(email: nil, organization: nil), isShared: false, isSharedByUrl: false,
        directRole: .inherited, membership: nil, errors: [])
}

private actor FakeSDKAlbumWriteClient: SDKAlbumWriteClient {
    enum Call: Equatable {
        case create(name: String)
        case update(album: String, name: String?, cover: String?)
        case delete(album: String, config: AlbumDeletionConfig)
        case add(album: String, photos: [String])
        case remove(album: String, photos: [String])
    }

    enum FakeError: Error { case noNode }

    private(set) var calls: [Call] = []
    private(set) var usedTokens: [UUID] = []
    private(set) var cancelledTokens: [UUID] = []
    private var node: DriveNode?
    private var results: [NodeResult] = []
    private var failure: (any Error)?
    private var failureAfterResults: (any Error)?
    private var callbackFailure: (any Error)?
    private var blocking = false

    func setNode(_ node: DriveNode) { self.node = node }
    func setResults(_ results: [NodeResult]) { self.results = results }
    func setFailure(_ error: any Error) { failure = error }
    func setFailureAfterResults(_ error: any Error) { failureAfterResults = error }
    func setCallbackFailure(_ error: any Error) { callbackFailure = error }
    func blockUntilCancelled() { blocking = true }

    private func begin(_ call: Call, _ token: UUID) async throws {
        calls.append(call)
        usedTokens.append(token)
        while blocking, !cancelledTokens.contains(token) { try await Task.sleep(nanoseconds: 1_000_000) }
        if blocking { throw CancellationError() }
        if let failure { throw failure }
    }

    private func stream(_ onNodeResult: NodeResultCallback) throws {
        results.forEach { onNodeResult(.success($0)) }
        if let callbackFailure { onNodeResult(.failure(callbackFailure)) }
        if let failureAfterResults { throw failureAfterResults }
    }

    func createAlbum(name: String, cancellationToken: UUID) async throws -> DriveNode {
        try await begin(.create(name: name), cancellationToken)
        guard let node else { throw FakeError.noNode }
        return node
    }

    func updateAlbum(
        albumUid: SDKNodeUid, name: String?, coverPhotoUid: SDKNodeUid?, cancellationToken: UUID
    ) async throws -> DriveNode {
        try await begin(
            .update(album: albumUid.sdkCompatibleIdentifier, name: name, cover: coverPhotoUid?.sdkCompatibleIdentifier),
            cancellationToken)
        guard let node else { throw FakeError.noNode }
        return node
    }

    func deleteAlbum(albumUid: SDKNodeUid, config: AlbumDeletionConfig, cancellationToken: UUID) async throws {
        try await begin(.delete(album: albumUid.sdkCompatibleIdentifier, config: config), cancellationToken)
    }

    func addPhotosToAlbum(
        albumUid: SDKNodeUid, photoUids: [SDKNodeUid], cancellationToken: UUID,
        onNodeResult: @escaping NodeResultCallback
    ) async throws {
        try await begin(
            .add(album: albumUid.sdkCompatibleIdentifier, photos: photoUids.map(\.sdkCompatibleIdentifier)),
            cancellationToken)
        try stream(onNodeResult)
    }

    func removePhotosFromAlbum(
        albumUid: SDKNodeUid, photoUids: [SDKNodeUid], cancellationToken: UUID,
        onNodeResult: @escaping NodeResultCallback
    ) async throws {
        try await begin(
            .remove(album: albumUid.sdkCompatibleIdentifier, photos: photoUids.map(\.sdkCompatibleIdentifier)),
            cancellationToken)
        try stream(onNodeResult)
    }

    func cancelCreateAlbum(cancellationToken: UUID) async throws { cancelledTokens.append(cancellationToken) }
    func cancelUpdateAlbum(cancellationToken: UUID) async throws { cancelledTokens.append(cancellationToken) }
    func cancelDeleteAlbum(cancellationToken: UUID) async throws { cancelledTokens.append(cancellationToken) }
    func cancelAddPhotosToAlbum(cancellationToken: UUID) async throws { cancelledTokens.append(cancellationToken) }
    func cancelRemovePhotosFromAlbum(cancellationToken: UUID) async throws {
        cancelledTokens.append(cancellationToken)
    }
}
