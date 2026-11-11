import Foundation
import PhotosCore
import Testing
import UploadCore

@testable import ProtonDriveBackend

extension DriveSessionStubSuite {
    @Suite
    struct DriveSessionAlbumPaginationRetryTests {
        private static let route = "GET /drive/photos/volumes/vol1/albums/album1/children"

        private static func page(_ id: String, more: Bool, anchor: String? = nil) -> (status: Int, json: String) {
            let cursor = anchor.map { #","AnchorID":"\#($0)""# } ?? ""
            return (
                200,
                #"{"Code":1000,"Photos":[{"LinkID":"\#(id)","CaptureTime":1,"Tags":[],"RelatedPhotos":[]}],"More":\#(more)"#
                    + cursor + "}"
            )
        }

        @Test(arguments: [true, false])
        func retriesMalformedPageWithoutPublishingItsPhotos(repeated: Bool) async throws {
            StubURLProtocol.reset()
            let malformed = Self.page("invalid", more: true, anchor: repeated ? "x" : nil)
            StubURLProtocol.routeSequence(
                Self.route,
                responses: [
                    Self.page("first", more: true, anchor: "x"), malformed, Self.page("last", more: false),
                ])

            let entries = try await makeSessionForPhotosListTests().fetchAlbumPhotos(
                volumeID: "vol1", albumLinkID: "album1")

            #expect(entries.map(\.linkID) == ["first", "last"])
            let requests = StubURLProtocol.requests()
            #expect(requests.count == 3)
            if requests.count >= 3 {
                #expect(requests[1].path == requests[2].path)
            }
        }

        @Test(arguments: [true, false])
        func persistentMalformedPageFailsTheWholeReadAfterBoundedRetries(repeated: Bool) async {
            StubURLProtocol.reset()
            let malformed = Self.page("invalid", more: true, anchor: repeated ? "x" : nil)
            StubURLProtocol.routeSequence(
                Self.route,
                responses: [
                    Self.page("first", more: true, anchor: "x"), malformed,
                ])

            do {
                let entries = try await makeSessionForPhotosListTests().fetchAlbumPhotos(
                    volumeID: "vol1", albumLinkID: "album1")
                Issue.record("A failed read returned \(entries.count) partial entries")
            } catch {
                let cause = (error as? UploadError)?.failureCause
                #expect(cause == .serviceTemporary)
                if let cause {
                    let policy = FailurePolicy.resolve(
                        cause, situation: .awaitedByPerson, safety: .safeRead, retriesExhausted: true)
                    #expect(policy.retry == .manual)
                    #expect(policy.presentation == .alert)
                }
                #expect(LibraryLoadFailureMessage.message(for: error) == L10n.string("albums.load_failed_message"))
            }
            let requests = StubURLProtocol.requests()
            #expect(requests.count == 3, "The invalid page is retried once before the read fails")
            if let retryPath = requests.dropFirst().first?.path {
                #expect(requests.dropFirst().allSatisfy { $0.path == retryPath })
            }
        }
    }
}
