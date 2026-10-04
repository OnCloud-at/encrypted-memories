import Foundation
import UploadCore
import XCTest

final class UploadLineageMarkerTests: XCTestCase {
    func testTheMarkerNamesEachLinkOnceAndKeepsTheNewestWithinTheLimit() throws {
        XCTAssertNil(UploadLineageMarker(reason: .edit, replaces: []))
        XCTAssertNil(UploadLineageMarker(reason: .edit, replaces: [""]))

        let links = (0..<250).map { "link-\($0)" }
        let marker = try XCTUnwrap(UploadLineageMarker(reason: .undo, replaces: ["link-0"] + links))
        XCTAssertEqual(marker.replaces.count, UploadLineageMarker.maximumReplacedLinks)
        XCTAssertEqual(marker.replaces.first, "link-0")
        XCTAssertEqual(marker.replaces.last, "link-199")

        let metadata = marker.additionalMetadata
        XCTAssertEqual(metadata.name, "EncryptedMemories.lineage")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata.utf8JsonValue) as? [String: Any])
        XCTAssertEqual(json["V"] as? Int, 1)
        XCTAssertEqual(json["Reason"] as? String, "undo")
        XCTAssertEqual(json["Replaces"] as? [String], marker.replaces)
        // The server accepts at most 65,535 characters for all encrypted sections together.
        let longest = UploadLineageMarker(
            reason: .edit, replaces: (0..<300).map { _ in String(repeating: "A", count: 86) + "==" })
        XCTAssertLessThan(try XCTUnwrap(longest).additionalMetadata.utf8JsonValue.count, 20_000)
    }

    func testAboveTheLimitTheMarkerKeepsTheNewestWholeGroups() throws {
        let newest = (0..<150).map { ["own-\($0)"] }
        // The uploads that a remote photo replaced have no order, so the marker never names only a part of them.
        let inherited = (0..<60).map { "inherited-\($0)" }
        let marker = try XCTUnwrap(
            UploadLineageMarker(reason: .edit, history: newest + [inherited] + [["oldest"]]))

        XCTAssertEqual(marker.replaces, newest.flatMap { $0 })
        XCTAssertFalse(marker.replaces.contains("oldest"), "a link older than a dropped group is dropped as well")

        let fitting = try XCTUnwrap(
            UploadLineageMarker(reason: .edit, history: [["head"], ["b", "a", "head"], [""], ["older"]]))
        XCTAssertEqual(fitting.replaces, ["head", "b", "a", "older"])
        XCTAssertNil(UploadLineageMarker(reason: .edit, history: [(0..<201).map { "link-\($0)" }]))
    }
}
