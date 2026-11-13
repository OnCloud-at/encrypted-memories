import XCTest

@testable import UploadCore

final class UploadResourceRoleTests: XCTestCase {
    func testRoleClassificationsKeepLiteralPrefixBoundaries() {
        let cases: [(raw: String, held: Bool, original: Bool, carried: Bool, edit: Bool, burst: Bool)] = [
            ("primary", false, false, false, false, false),
            ("livePairedVideo", false, true, true, false, false),
            ("photoKit.originalPhoto.0", true, true, false, false, false),
            ("photoKit.originalVideo.7", true, true, false, false, false),
            ("photoKit.alternatePhoto.0", false, true, true, false, false),
            ("photoKit.pairedVideo.0", false, true, true, false, false),
            ("photoKit.adjustmentData.0", false, false, false, true, false),
            ("photoKit.adjustmentBasePhoto.0", false, false, false, true, false),
            ("photoKit.adjustmentBaseVideo.0", false, false, false, true, false),
            ("photoKit.adjustmentBasePairedVideo.0", false, false, false, true, false),
            ("photoKit.fullSizePhoto.0", false, false, false, true, false),
            ("photoKit.fullSizeVideo.0", false, false, false, true, false),
            ("photoKit.fullSizePairedVideo.0", false, false, false, true, false),
            ("photoKit.burstMember.0", false, false, false, false, true),
            ("photoKit.originalPhoto.", true, true, false, false, false),
            ("photoKit.originalPhoto.not-a-number", true, true, false, false, false),
            ("photoKit.originalPhoto.-1", true, true, false, false, false),
            ("photoKit.originalPhoto.1.extra", true, true, false, false, false),
            ("photoKit.originalPhoto", false, false, false, false, false),
            ("photoKit.originalPhotoExtra.0", false, false, false, false, false),
            ("photoKit.originalPhot.0", false, false, false, false, false),
            ("PhotoKit.originalPhoto.0", false, false, false, false, false),
            ("photoKit.OriginalPhoto.0", false, false, false, false, false),
            ("photoKit.fullSizePhoto", false, false, false, false, false),
            ("photoKit.fullSizePhotoExtra.0", false, false, false, false, false),
            ("photoKit.fullSizePhoto.", false, false, false, true, false),
            ("photoKit.burstMember.", false, false, false, false, true),
            ("photoKit.burstMember.not-a-number", false, false, false, false, true),
            ("photoKit.burstMemberExtra.0", false, false, false, false, false),
            ("photoKit.burstMember", false, false, false, false, false),
            ("", false, false, false, false, false),
            ("photoKit.unknown.0", false, false, false, false, false),
        ]
        for row in cases {
            let resource = UploadSourceIdentity.Resource(rawValue: row.raw)
            XCTAssertEqual(
                EditedPhotoReplacement.holdsOriginal(editRevision: .unavailable, secondaries: [resource]),
                row.held, "\(row.raw): original proof")
            XCTAssertEqual(
                EditedPhotoReplacement.isOriginal(resource, carriedByPrimary: false), row.original,
                "\(row.raw): original secondary")
            XCTAssertEqual(
                EditedPhotoReplacement.isOriginal(resource, carriedByPrimary: true), row.carried,
                "\(row.raw): original carried by primary")
            XCTAssertEqual(UploadRemoteReplacementSafety.isEditRole(resource), row.edit, "\(row.raw): edit")
            XCTAssertEqual(resource.isBurstMember, row.burst, "\(row.raw): burst")
        }
    }

    func testKnownEditRevisionKeepsOriginalProofWithoutAnOriginalSecondary() {
        let revision = UploadBackupEditRevision.revision(UploadBackupRevision(rawValue: 1))
        XCTAssertTrue(EditedPhotoReplacement.holdsOriginal(editRevision: revision, secondaries: []))
        XCTAssertTrue(EditedPhotoReplacement.holdsOriginal(editRevision: revision, secondaries: [.primary]))
        XCTAssertFalse(EditedPhotoReplacement.holdsOriginal(editRevision: .unavailable, secondaries: []))
    }

    func testAnyOriginalSecondaryProvesAnUnavailableEdit() {
        let original = UploadSourceIdentity.Resource(rawValue: "photoKit.originalVideo.2")
        XCTAssertTrue(
            EditedPhotoReplacement.holdsOriginal(editRevision: .unavailable, secondaries: [.primary, original]))
        XCTAssertTrue(
            EditedPhotoReplacement.holdsOriginal(editRevision: .unavailable, secondaries: [original, .primary]))
        XCTAssertFalse(
            EditedPhotoReplacement.holdsOriginal(editRevision: .unavailable, secondaries: [.primary, .livePairedVideo]))
    }
}
