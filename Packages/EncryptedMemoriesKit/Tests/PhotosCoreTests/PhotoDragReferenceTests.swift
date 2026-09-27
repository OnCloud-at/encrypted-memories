import Foundation
import XCTest

@testable import PhotosCore

final class PhotoDragReferenceTests: XCTestCase {
    func testAReferenceReadsBackAsTheSamePhotoAndSession() throws {
        let uid = PhotoUID(volumeID: "volume", nodeID: "node")
        let session = UUID()

        let decoded = try XCTUnwrap(PhotoDragReference.decode(PhotoDragReference.data(for: uid, session: session)))

        XCTAssertEqual(decoded.uid, uid)
        XCTAssertEqual(decoded.session, session)
    }

    func testDataThatIsNotAPhotoReferenceIsRefused() {
        let session = UUID().uuidString
        for text in [
            "", "node", "{}", #"{"volumeID":"volume","nodeID":"node"}"#,
            #"{"volumeID":"","nodeID":"node","session":"\#(session)"}"#,
            #"{"volumeID":"volume","nodeID":"node","session":"not-a-uuid"}"#,
        ] {
            XCTAssertNil(PhotoDragReference.decode(Data(text.utf8)), text)
        }
    }

    func testAnInternalDropNamesOnlyItsOwnSessions() {
        let first = UUID()
        let second = UUID()
        let expectation = expectation(forNotification: PhotoDragReference.internalDropCompleted, object: nil) {
            PhotoDragReference.sessions(in: $0) == [second]
        }

        PhotoDragReference.postInternalDrop(sessions: [second])

        wait(for: [expectation], timeout: 1)
        XCTAssertTrue(PhotoDragReference.sessions(in: Notification(name: .init("other"))).isEmpty)
        XCTAssertNotEqual(first, second)
    }
}
