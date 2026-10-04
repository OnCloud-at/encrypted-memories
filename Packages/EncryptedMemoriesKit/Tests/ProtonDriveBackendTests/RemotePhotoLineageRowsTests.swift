import Foundation
import UploadCore
import XCTest

@testable import ProtonDriveBackend

final class RemotePhotoLineageRowsTests: XCTestCase {
    func testV1MarkerAndCloudIdentifierDoNotRequireModificationTimeOrDigest() throws {
        let rows = try rows(marker: ["V": 1, "Reason": "edit", "Replaces": ["old", "older"]])
        XCTAssertEqual(rows.identities.first?.externalIdentifier, "cloud")
        XCTAssertEqual(rows.identities.first?.isMain, true)
        XCTAssertEqual(Set(rows.lineage.map(\.replacedLinkID)), ["old", "older"])
        XCTAssertEqual(Set(rows.lineage.map(\.replacingLinkID)), ["main"])
        XCTAssertEqual(rows.unresolvedLinkIDs, [])
    }

    func testAMalformedPhotoSectionLeavesTheRoleUnknownAndKeepsTheRestOfTheLink() throws {
        for photo in ["[]", #"{"MainPhotoLinkID":42}"#, "\"text\""] {
            let json =
                #"{"LinkID":"a","State":1,"FileProperties":{"ActiveRevision":{"#
                + #""XAttr":"armored","Photo":"# + photo + "}}}"
            let link = try JSONDecoder().decode(AlbumPhotoLinkBody.self, from: Data(json.utf8))
            XCTAssertEqual(
                link.fileProperties?.activeRevision?.xAttr, "armored", "the content index still reads it")
            XCTAssertNil(link.fileProperties?.activeRevision?.photo, "the role stays unknown")
        }
    }

    func testTheIndexReadsTheMarkerThatAReplacingUploadWrites() throws {
        let written = try XCTUnwrap(UploadLineageMarker(reason: .edit, replaces: ["old", "older"]))
        let marker = try JSONSerialization.jsonObject(with: written.additionalMetadata.utf8JsonValue)
        let rows = try rows(marker: marker)
        XCTAssertEqual(rows.lineage.map(\.replacedLinkID).sorted(), ["old", "older"])
        XCTAssertEqual(Set(rows.lineage.map(\.replacingLinkID)), ["main"])
        XCTAssertEqual(rows.unresolvedLinkIDs, [])
    }

    func testMissingMarkerIsIgnored() throws {
        let rows = try rows(marker: nil)
        XCTAssertEqual(rows.identities.count, 1)
        XCTAssertTrue(rows.lineage.isEmpty)
        XCTAssertEqual(rows.unresolvedLinkIDs, [])
    }

    func testEveryV1ReasonIsReadableAndMissingCloudIdentifierIsIgnored() throws {
        for reason in ["edit", "undo", "seriesKeepFavorites", "futureReason"] {
            let rows = try rows(marker: ["V": 1, "Reason": reason, "Replaces": []])
            XCTAssertEqual(rows.unresolvedLinkIDs, [])
        }
        let attributes = try JSONDecoder().decode(DedupeXAttr.self, from: Data("{}".utf8))
        let link = try JSONDecoder().decode(
            AlbumPhotoLinkBody.self,
            from: Data(#"{"State":1,"FileProperties":{"ActiveRevision":{"Photo":{}}}}"#.utf8))
        let rows = RemotePhotoLineageRows(
            attributes: attributes, link: link, remoteLinkID: "main", hashKeyEpoch: "epoch")
        XCTAssertTrue(rows.identities.isEmpty)
        XCTAssertTrue(rows.lineage.isEmpty)
        XCTAssertEqual(rows.unresolvedLinkIDs, [])
    }

    func testOtherVersionAndMalformedMarkerDoNotBreakOtherAttributes() throws {
        let markers: [Any] = [
            ["V": 2, "Reason": "edit", "Replaces": ["old"]],
            ["V": 1, "Reason": "edit", "Replaces": "old"],
            ["V": 1, "Reason": "edit", "Replaces": [""]],
            ["V": 1, "Reason": "edit", "Replaces": [1]],
            NSNull(),
        ]
        for marker in markers {
            let rows = try rows(marker: marker)
            XCTAssertEqual(rows.identities.first?.externalIdentifier, "cloud")
            XCTAssertTrue(rows.lineage.isEmpty)
            XCTAssertEqual(rows.unresolvedLinkIDs, ["main"])
        }
    }

    func testReasonDoesNotLimitReadableV1Markers() throws {
        let markers: [[String: Any]] = [
            ["V": 1, "Reason": "futureReason", "Replaces": ["old"]],
            ["V": 1, "Replaces": ["old"]],
        ]
        for marker in markers {
            let rows = try rows(marker: marker)
            XCTAssertEqual(rows.lineage.map(\.replacedLinkID), ["old"])
            XCTAssertTrue(rows.unresolvedLinkIDs.isEmpty)
        }
    }

    func testMainPhotoLinkIDMarksRelatedIdentityAndSuppressesLineage() throws {
        let rows = try rows(marker: ["V": 1, "Reason": "undo", "Replaces": ["old"]], mainPhotoLinkID: "parent")
        XCTAssertEqual(rows.identities.first?.isMain, false)
        XCTAssertTrue(rows.lineage.isEmpty)
    }

    func testInactiveLinkProducesNoRows() throws {
        let rows = try rows(marker: ["V": 1, "Reason": "seriesKeepFavorites", "Replaces": ["old"]], state: 2)
        XCTAssertTrue(rows.identities.isEmpty)
        XCTAssertTrue(rows.lineage.isEmpty)
        XCTAssertEqual(rows.unresolvedLinkIDs, [])
    }

    func testUnknownStateOrMissingPhotoProducesOnlyUnresolvedLink() throws {
        for rows in [
            try rows(marker: ["V": 1, "Reason": "edit", "Replaces": ["old"]], state: nil),
            try rows(marker: ["V": 1, "Reason": "edit", "Replaces": ["old"]], state: 99),
            try rows(marker: ["V": 1, "Reason": "edit", "Replaces": ["old"]], hasPhoto: false),
        ] {
            XCTAssertTrue(rows.identities.isEmpty)
            XCTAssertTrue(rows.lineage.isEmpty)
            XCTAssertEqual(rows.unresolvedLinkIDs, ["main"])
        }
    }

    func testAbsentMainPhotoLinkIDWithPhotoMetadataIsMain() throws {
        let attributes = try JSONDecoder().decode(
            DedupeXAttr.self, from: Data(#"{"iOS.photos":{"ICloudID":"cloud"}}"#.utf8))
        let link = try JSONDecoder().decode(
            AlbumPhotoLinkBody.self,
            from: Data(#"{"State":1,"FileProperties":{"ActiveRevision":{"Photo":{}}}}"#.utf8))
        let rows = RemotePhotoLineageRows(
            attributes: attributes, link: link, remoteLinkID: "main", hashKeyEpoch: "epoch")
        XCTAssertEqual(rows.identities.first?.isMain, true)
        XCTAssertTrue(rows.unresolvedLinkIDs.isEmpty)
    }

    private func rows(
        marker: Any?, mainPhotoLinkID: String? = nil, state: Int? = 1, hasPhoto: Bool = true
    ) throws -> RemotePhotoLineageRows {
        var object: [String: Any] = ["iOS.photos": ["ICloudID": "cloud"]]
        if let marker { object["EncryptedMemories.lineage"] = marker }
        let attributes = try JSONDecoder().decode(
            DedupeXAttr.self, from: JSONSerialization.data(withJSONObject: object))
        var link: [String: Any] = ["LinkID": "main", "Type": 2]
        if let state { link["State"] = state }
        if hasPhoto {
            let photo: [String: Any] = ["MainPhotoLinkID": mainPhotoLinkID as Any? ?? NSNull()]
            link["FileProperties"] = ["ActiveRevision": ["Photo": photo]]
        }
        let metadata = try JSONDecoder().decode(
            AlbumPhotoLinkBody.self, from: JSONSerialization.data(withJSONObject: link))
        return RemotePhotoLineageRows(
            attributes: attributes, link: metadata, remoteLinkID: "main", hashKeyEpoch: "epoch")
    }
}
