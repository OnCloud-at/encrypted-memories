import Foundation
import ProtonAuth
import Testing

@testable import ProtonDriveBackend

extension DriveSessionStubSuite {
    @Suite
    struct DriveSessionPhotosListTests {
        @Test
        func streamsCursorPagesWithoutBuildingTheListInTheSession() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.routeSequence(
                "GET /drive/volumes/vol1/photos",
                responses: [
                    (
                        status: 200,
                        json:
                            #"{"Code":1000,"Photos":[{"LinkID":"p1","CaptureTime":1,"Tags":[],"RelatedPhotos":[]},{"LinkID":"p2","CaptureTime":2,"Tags":[],"RelatedPhotos":[]}] }"#
                    ),
                    (
                        status: 200,
                        json: #"{"Code":1000,"Photos":[{"LinkID":"p3","CaptureTime":3,"Tags":[],"RelatedPhotos":[]}] }"#
                    ),
                ]
            )

            var pages: [[String]] = []
            try await makeSessionForPhotosListTests().forEachPhotosListPage(
                volumeID: "vol1",
                pageSize: 2
            ) { page in
                pages.append(page.map(\.linkID))
            }

            #expect(pages == [["p1", "p2"], ["p3"]])
            let requests = StubURLProtocol.requests()
            #expect(requests.count == 2)
            #expect(requests[0].path.contains("PageSize=2"))
            #expect(requests[1].path.contains("PreviousPageLastLinkID=p2"))
        }
    }
}

private func makeSessionForPhotosListTests() -> DriveSession {
    DriveSession(
        session: ProtonSession(uid: "test-uid", accessToken: "at", refreshToken: "rt", keyPassword: "kp"),
        store: SessionKeychainStore(service: "at.oncloud.encryptedmemories.tests.never-used"),
        accountCacheDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("drive-photos-list-tests-\(UUID().uuidString)"),
        urlProtocolClasses: [StubURLProtocol.self]
    )
}
