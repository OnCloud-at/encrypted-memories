import AppKit
import PhotosCore
import UniformTypeIdentifiers
import XCTest

@testable import TimelineFeature

/// A sidebar album reads the dragged photos from the drag pasteboard. These tests write the same items as the grid
/// (`PhotoFilePromiseProvider`) to a privately named pasteboard, because a real drag cannot be automated on macOS.
@MainActor
final class PhotoDragPasteboardTests: XCTestCase {
    private final class PromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
        func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String
        ) -> String {
            "photo.jpg"
        }

        func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
            completionHandler: @escaping (Error?) -> Void
        ) { completionHandler(nil) }
    }

    private let delegate = PromiseDelegate()
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("PhotoDragPasteboardTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
    }

    private func gridItem(_ uid: PhotoUID, session: UUID) -> PhotoFilePromiseProvider {
        let provider = PhotoFilePromiseProvider(fileType: UTType.jpeg.identifier, delegate: delegate)
        provider.photoReference = PhotoDragReference.data(for: uid, session: session)
        return provider
    }

    func testEveryPhotoOfAGridDragReadsBackInDragOrder() {
        let session = UUID()
        let uids = (0..<4).map { PhotoUID(volumeID: "volume", nodeID: "node-\($0)") }
        XCTAssertTrue(pasteboard.writeObjects(uids.map { gridItem($0, session: session) }))

        let references = PhotoDragPasteboard.references(on: pasteboard)

        XCTAssertEqual(references.uids, uids)
        XCTAssertEqual(references.sessions, [session])
    }

    func testItemsWithoutAPhotoReferenceAreSkipped() {
        let session = UUID()
        let uid = PhotoUID(volumeID: "volume", nodeID: "node")
        let otherAppFile = NSFilePromiseProvider(fileType: UTType.jpeg.identifier, delegate: delegate)
        XCTAssertTrue(
            pasteboard.writeObjects([
                otherAppFile, URL(fileURLWithPath: "/tmp/photo.jpg") as NSURL, "text" as NSString,
                gridItem(uid, session: session),
            ]))

        let references = PhotoDragPasteboard.references(on: pasteboard)

        XCTAssertEqual(references.uids, [uid])
        XCTAssertEqual(references.sessions, [session])
    }

    func testADragWithoutPhotoReferencesReadsNoPhoto() {
        let otherAppFile = NSFilePromiseProvider(fileType: UTType.jpeg.identifier, delegate: delegate)
        XCTAssertTrue(pasteboard.writeObjects([otherAppFile, URL(fileURLWithPath: "/tmp/photo.jpg") as NSURL]))

        let references = PhotoDragPasteboard.references(on: pasteboard)

        XCTAssertTrue(references.uids.isEmpty)
        XCTAssertTrue(references.sessions.isEmpty)
    }
}
