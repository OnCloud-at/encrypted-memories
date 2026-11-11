import Foundation
import PhotosCore
import SQLiteTestSupport
import XCTest

/// Every text bind of the timeline store that a length fault can reach checks its result. A failed bind leaves its
/// parameter NULL: an unchecked related video ID was stored as NULL, a removal, a duration update, a media type repair or
/// an evidence prune matched no row and reported success, and a read gave no row instead of a failed read. Each test
/// fails only the binds of the target statement: a value longer than the lowered SQLITE_LIMIT_LENGTH fails with
/// SQLITE_TOOBIG, as a bind that runs out of memory does. A lowered limit also fails the read of a long stored value, so
/// a test whose call reads such a row first lowers the limit only after that read. With the check the statement never
/// steps, and the call gives the answer of a failed statement. The feature names and the metadata keys of at most 26 bytes
/// are below the smallest limit (30), so no test fails their binds; the 32-byte key of the token time fails at limit 30.
/// A failed step of a metadata read stands for a failed read of those shorter keys.
final class TimelineMetadataStoreBindingFailureTests: XCTestCase {
    private static let limit: Int32 = 2_048
    private static let long = String(repeating: "x", count: 3_000)
    private let longVolume = PhotoUID(volumeID: long, nodeID: "node")
    private let longNode = PhotoUID(volumeID: "volume", nodeID: long)
    private let shortUID = PhotoUID(volumeID: "volume", nodeID: "node")

    private var directory: URL!
    private var store: TimelineMetadataStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-binding-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try XCTUnwrap(TimelineMetadataStore(url: directory.appendingPathComponent("timeline.sqlite")))
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func photo(
        _ uid: PhotoUID, mediaType: String = "image/jpeg", relatedVideoID: String? = nil,
        tags: Set<PhotoTag> = [], burstMemberIDs: [String] = []
    ) -> PhotoItem {
        PhotoItem(
            uid: uid, captureTime: Date(timeIntervalSince1970: 500), mediaType: mediaType,
            relatedVideoID: relatedVideoID, tags: tags, burstMemberIDs: burstMemberIDs)
    }

    /// A save that fails because of `fault` keeps the stored timeline. The fault starts after the timeline is read.
    private func assertSaveFails(
        _ items: [PhotoItem], validationToken: String? = nil,
        fault makeFault: @autoclosure () throws -> BindFailureUntilStep,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let before = try store.load()
        let fault = try makeFault()
        let result =
            validationToken.map { store.save(items, validationToken: $0) } ?? store.save(items)
        XCTAssertFalse(result.succeeded, "A value that does not bind must fail the save", file: file, line: line)
        XCTAssertNil(fault.failedBeforeStepProblem, file: file, line: line)
        fault.remove()
        XCTAssertEqual(try store.load(), before, "The failed save keeps the stored timeline", file: file, line: line)
    }

    // MARK: Save

    /// The save that loses its scratch key would sweep away the photo it lists; the stored photo must stay.
    func testSaveWithAVolumeThatDoesNotBindFailsBeforeTheScratchKeyAndKeepsTheStoredPhoto() throws {
        XCTAssertTrue(store.save([photo(longVolume)]).succeeded)
        try assertSaveFails(
            [photo(longVolume, mediaType: "image/heic")],
            fault: try XCTUnwrap(
                BindFailureUntilStep(
                    onStore: store!, statement: "INSERT OR IGNORE INTO save_incoming_keys", after: nil,
                    limit: Self.limit)))
    }

    /// The save that loses its scratch key would sweep away the photo it lists; the stored photo must stay.
    func testSaveWithANodeThatDoesNotBindFailsBeforeTheScratchKeyAndKeepsTheStoredPhoto() throws {
        XCTAssertTrue(store.save([photo(longNode)]).succeeded)
        try assertSaveFails(
            [photo(longNode, mediaType: "image/heic")],
            fault: try XCTUnwrap(
                BindFailureUntilStep(
                    onStore: store!, statement: "INSERT OR IGNORE INTO save_incoming_keys", after: nil,
                    limit: Self.limit)))
    }

    func testSaveWithAVolumeThatDoesNotBindFailsBeforeThePhotoUpsert() throws {
        try assertSaveFails(
            [photo(longVolume)],
            fault: try XCTUnwrap(
                BindFailureUntilStep(
                    onStore: store!, statement: "INSERT INTO photos(vol",
                    after: "INSERT OR IGNORE INTO save_incoming_keys", limit: Self.limit)))
    }

    func testSaveWithANodeThatDoesNotBindFailsBeforeThePhotoUpsert() throws {
        try assertSaveFails(
            [photo(longNode)],
            fault: try XCTUnwrap(
                BindFailureUntilStep(
                    onStore: store!, statement: "INSERT INTO photos(vol",
                    after: "INSERT OR IGNORE INTO save_incoming_keys", limit: Self.limit)))
    }

    func testSaveWithAMediaTypeThatDoesNotBindFailsBeforeThePhotoUpsert() throws {
        try assertSaveFails(
            [photo(shortUID, mediaType: Self.long)],
            fault: try XCTUnwrap(
                BindFailureUntilStep(
                    onStore: store!, statement: "INSERT INTO photos(vol", after: nil, limit: Self.limit)))
    }

    func testSaveWithARelatedVideoThatDoesNotBindFailsInsteadOfStoringNull() throws {
        try assertSaveFails(
            [photo(shortUID, relatedVideoID: Self.long)],
            fault: try XCTUnwrap(
                BindFailureUntilStep(
                    onStore: store!, statement: "INSERT INTO photos(vol", after: nil, limit: Self.limit)))
    }

    func testSaveWithAVolumeThatDoesNotBindFailsBeforeTheTagScratchRow() throws {
        try assertSaveFails(
            [photo(longVolume, tags: [.favorites])],
            fault: try XCTUnwrap(
                BindFailureUntilStep(
                    onStore: store!, statement: "INSERT INTO save_incoming_tags",
                    after: "DELETE FROM photos WHERE NOT EXISTS", limit: Self.limit)))
    }

    func testSaveWithANodeThatDoesNotBindFailsBeforeTheTagScratchRow() throws {
        try assertSaveFails(
            [photo(longNode, tags: [.favorites])],
            fault: try XCTUnwrap(
                BindFailureUntilStep(
                    onStore: store!, statement: "INSERT INTO save_incoming_tags",
                    after: "DELETE FROM photos WHERE NOT EXISTS", limit: Self.limit)))
    }

    func testSaveWithAVolumeThatDoesNotBindFailsBeforeTheBurstScratchRow() throws {
        try assertSaveFails(
            [photo(longVolume, burstMemberIDs: ["member"])],
            fault: try XCTUnwrap(
                BindFailureUntilStep(
                    onStore: store!, statement: "INSERT INTO save_incoming_bursts",
                    after: "INSERT INTO photo_tags(vol, node, tag) SELECT", limit: Self.limit)))
    }

    func testSaveWithANodeThatDoesNotBindFailsBeforeTheBurstScratchRow() throws {
        try assertSaveFails(
            [photo(longNode, burstMemberIDs: ["member"])],
            fault: try XCTUnwrap(
                BindFailureUntilStep(
                    onStore: store!, statement: "INSERT INTO save_incoming_bursts",
                    after: "INSERT INTO photo_tags(vol, node, tag) SELECT", limit: Self.limit)))
    }

    func testSaveWithABurstMemberThatDoesNotBindFailsBeforeTheBurstScratchRow() throws {
        try assertSaveFails(
            [photo(shortUID, burstMemberIDs: [Self.long])],
            fault: try XCTUnwrap(
                BindFailureUntilStep(
                    onStore: store!, statement: "INSERT INTO save_incoming_bursts", after: nil, limit: Self.limit)))
    }

    /// The second save lists the same photos, so the token write is the first metadata write of the call.
    func testSaveWithAValidationTokenThatDoesNotBindFailsBeforeTheMetadataWrite() throws {
        XCTAssertTrue(store.save([photo(shortUID)]).succeeded)
        try assertSaveFails(
            [photo(shortUID)], validationToken: Self.long,
            fault: try XCTUnwrap(
                BindFailureUntilStep(
                    onStore: store!, statement: "INSERT INTO store_meta", after: nil, limit: Self.limit)))
        XCTAssertNil(store.validationToken())
    }

    // MARK: Metadata keys

    /// `timeline.validationTokenStoredAt` is 32 bytes, so a limit of 30 fails its bind and no other key.
    private func tokenTimeFault(_ statement: String) throws -> BindFailureUntilStep {
        try XCTUnwrap(BindFailureUntilStep(onStore: store!, statement: statement, after: statement, limit: 30))
    }

    func testSaveWithATokenTimeKeyThatDoesNotBindFailsAndKeepsTheOldToken() throws {
        XCTAssertTrue(store.save([photo(shortUID)]).succeeded)
        try assertSaveFails(
            [photo(shortUID)], validationToken: "token", fault: try tokenTimeFault("INSERT INTO store_meta"))
        XCTAssertNil(store.validationToken())
    }

    func testTokenTimeReadWithAKeyThatDoesNotBindDoesNotRunTheRead() throws {
        XCTAssertTrue(store.save([photo(shortUID)], validationToken: "token").succeeded)
        let fault = try tokenTimeFault("SELECT value FROM store_meta")
        defer { fault.remove() }
        XCTAssertNil(store.validationTokenStoredAt())
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testTokenClearWithAKeyThatDoesNotBindFailsAndKeepsTheToken() throws {
        XCTAssertTrue(store.save([photo(shortUID)], validationToken: "token").succeeded)
        let fault = try tokenTimeFault("DELETE FROM store_meta")
        XCTAssertFalse(
            store.save([photo(shortUID)], validationToken: nil).succeeded,
            "A token time that was not deleted must not leave a cleared token behind")
        XCTAssertNil(fault.failedBeforeStepProblem)
        fault.remove()
        XCTAssertEqual(store.validationToken(), "token")
    }

    // MARK: Metadata reads

    /// Fails the step of the next read of the metadata `key`. The keys below are at most 26 bytes, below the smallest
    /// length limit, so a failed step stands for a failed read of them.
    private func failRead(of key: String) throws -> SQLiteStatementFaults {
        try XCTUnwrap(
            SQLiteStatementFaults(onStore: store!, failures: 1) {
                $0.contains("SELECT value FROM store_meta WHERE key = '\(key)'")
            })
    }

    /// A generation that cannot be read must not start the timeline again from generation 1.
    func testSaveWithAGenerationThatCannotBeReadFailsAndKeepsTheGeneration() throws {
        XCTAssertTrue(store.save([photo(shortUID)]).succeeded)
        XCTAssertEqual(store.save([photo(longNode)]).generation, 2)
        let fault = try failRead(of: "timeline.generation")
        defer { fault.stop() }
        XCTAssertFalse(store.save([photo(longVolume)]).succeeded, "A generation that cannot be read fails the save")
        XCTAssertEqual(fault.firedCount, 1, "The fault must reach the generation read")
        fault.stop()
        XCTAssertEqual(store.save([photo(longVolume)]).generation, 3, "The stored generation stays")
    }

    /// A revision that cannot be read must not publish a revision that moves back.
    func testRevisionPublishWithARevisionThatCannotBeReadFailsAndKeepsTheRevision() throws {
        XCTAssertTrue(store.publishMediaTypeEvidenceRevision())
        XCTAssertTrue(store.publishMediaTypeEvidenceRevision())
        let fault = try failRead(of: "mediaTypeEvidence.revision")
        defer { fault.stop() }
        XCTAssertFalse(store.publishMediaTypeEvidenceRevision(), "A revision that cannot be read fails the publish")
        XCTAssertEqual(fault.firedCount, 1, "The fault must reach the revision read")
        fault.stop()
        XCTAssertEqual(store.mediaTypeEvidenceRevision(), 2)
    }

    func testEvidenceWithARevisionThatCannotBeReadFailsAndKeepsTheRevision() throws {
        XCTAssertTrue(store.publishMediaTypeEvidenceRevision())
        XCTAssertTrue(store.publishMediaTypeEvidenceRevision())
        let fault = try failRead(of: "mediaTypeEvidence.revision")
        defer { fault.stop() }
        XCTAssertFalse(
            store.recordMediaTypeEvidence([shortUID: "video/mp4"]).succeeded,
            "A revision that cannot be read fails the evidence update")
        XCTAssertEqual(fault.firedCount, 1, "The fault must reach the revision read")
        fault.stop()
        XCTAssertEqual(store.mediaTypeEvidenceRevision(), 2)
    }

    /// A stored cursor that cannot be read is no proof that it changed, so the time of the stored cursor stays.
    func testRevalidationWithATokenThatCannotBeReadKeepsTheTokenTime() throws {
        XCTAssertTrue(store.save([photo(shortUID)], validationToken: "first").succeeded)
        let storedAt = try XCTUnwrap(store.validationTokenStoredAt())
        let fault = try failRead(of: "timeline.validationToken")
        defer { fault.stop() }
        XCTAssertTrue(store.save([photo(shortUID)], validationToken: "second").succeeded)
        XCTAssertEqual(fault.firedCount, 1, "The fault must reach the token read")
        fault.stop()
        XCTAssertEqual(store.validationToken(), "second")
        XCTAssertEqual(store.validationTokenStoredAt(), storedAt)
    }

    /// A mark for generation 0 could match a mark that an earlier failed read wrote, so a generation that cannot be
    /// read writes no mark.
    func testRelatedVideoMarkWithAGenerationThatCannotBeReadIsNotWritten() throws {
        XCTAssertTrue(store.save([photo(shortUID, relatedVideoID: "video")]).succeeded)
        let fault = try failRead(of: "timeline.generation")
        defer { fault.stop() }
        XCTAssertFalse(store.markRelatedVideosChosen(by: "rule"))
        XCTAssertEqual(fault.firedCount, 1, "The fault must reach the generation read")
        fault.stop()
        XCTAssertFalse(store.relatedVideosChosen(by: "rule"))
    }

    /// Before the first save the generation is 0, so the mark names generation 0; a failed read must not match it.
    func testRelatedVideoRuleWithAGenerationThatCannotBeReadIsNotChosen() throws {
        XCTAssertTrue(store.markRelatedVideosChosen(by: "rule"))
        XCTAssertTrue(store.relatedVideosChosen(by: "rule"))
        let fault = try failRead(of: "timeline.generation")
        defer { fault.stop() }
        XCTAssertFalse(store.relatedVideosChosen(by: "rule"), "A generation that cannot be read matches no mark")
        XCTAssertEqual(fault.firedCount, 1, "The fault must reach the generation read")
    }

    // MARK: Media type evidence

    private func assertEvidenceFails(
        _ batch: [PhotoUID: String], fault: BindFailureUntilStep, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(
            store.recordMediaTypeEvidence(batch).succeeded, "A value that does not bind must fail the update",
            file: file, line: line)
        XCTAssertNil(fault.failedBeforeStepProblem, file: file, line: line)
        fault.remove()
    }

    func testEvidenceWithAVolumeThatDoesNotBindFailsBeforeTheEvidenceWrite() throws {
        assertEvidenceFails(
            [longVolume: "video/mp4"],
            fault: try XCTUnwrap(
                BindFailureUntilStep(
                    onStore: store!, statement: "INSERT INTO media_type_evidence", after: nil, limit: Self.limit)))
    }

    func testEvidenceWithANodeThatDoesNotBindFailsBeforeTheEvidenceWrite() throws {
        assertEvidenceFails(
            [longNode: "video/mp4"],
            fault: try XCTUnwrap(
                BindFailureUntilStep(
                    onStore: store!, statement: "INSERT INTO media_type_evidence", after: nil, limit: Self.limit)))
    }

    func testEvidenceWithAMediaTypeThatDoesNotBindFailsBeforeTheEvidenceWrite() throws {
        assertEvidenceFails(
            [shortUID: "video/" + Self.long],
            fault: try XCTUnwrap(
                BindFailureUntilStep(
                    onStore: store!, statement: "INSERT INTO media_type_evidence", after: nil, limit: Self.limit)))
    }

    func testEvidenceWithAVolumeThatDoesNotBindFailsBeforeThePhotoRepair() throws {
        XCTAssertTrue(store.save([photo(longVolume)]).succeeded)
        assertEvidenceFails(
            [longVolume: "video/mp4"],
            fault: try XCTUnwrap(
                BindFailureUntilStep(
                    onStore: store!, statement: "UPDATE photos SET mime", after: "INSERT INTO media_type_evidence",
                    limit: Self.limit)))
        XCTAssertEqual(try store.load().map(\.mediaType), ["image/jpeg"])
    }

    func testEvidenceWithANodeThatDoesNotBindFailsBeforeThePhotoRepair() throws {
        XCTAssertTrue(store.save([photo(longNode)]).succeeded)
        assertEvidenceFails(
            [longNode: "video/mp4"],
            fault: try XCTUnwrap(
                BindFailureUntilStep(
                    onStore: store!, statement: "UPDATE photos SET mime", after: "INSERT INTO media_type_evidence",
                    limit: Self.limit)))
        XCTAssertEqual(try store.load().map(\.mediaType), ["image/jpeg"])
    }

    func testEvidenceWithAMediaTypeThatDoesNotBindFailsBeforeThePhotoRepair() throws {
        XCTAssertTrue(store.save([photo(shortUID)]).succeeded)
        assertEvidenceFails(
            [shortUID: "video/" + Self.long],
            fault: try XCTUnwrap(
                BindFailureUntilStep(
                    onStore: store!, statement: "UPDATE photos SET mime", after: "INSERT INTO media_type_evidence",
                    limit: Self.limit)))
        XCTAssertEqual(try store.load().map(\.mediaType), ["image/jpeg"])
    }

    func testEvidenceWithAVolumeThatDoesNotBindFailsBeforeTheVideoTag() throws {
        XCTAssertTrue(store.save([photo(longVolume)]).succeeded)
        assertEvidenceFails(
            [longVolume: "video/mp4"],
            fault: try XCTUnwrap(
                BindFailureUntilStep(
                    onStore: store!, statement: "INSERT OR IGNORE INTO photo_tags", after: "UPDATE photos SET mime",
                    limit: Self.limit)))
    }

    func testEvidenceWithANodeThatDoesNotBindFailsBeforeTheVideoTag() throws {
        XCTAssertTrue(store.save([photo(longNode)]).succeeded)
        assertEvidenceFails(
            [longNode: "video/mp4"],
            fault: try XCTUnwrap(
                BindFailureUntilStep(
                    onStore: store!, statement: "INSERT OR IGNORE INTO photo_tags", after: "UPDATE photos SET mime",
                    limit: Self.limit)))
    }

    func testUnmaterializedEvidenceReadWithAVolumeThatDoesNotBindIsAFailedRead() throws {
        XCTAssertTrue(store.recordMediaTypeEvidence([longVolume: "video/mp4"]).succeeded)
        let fault = try XCTUnwrap(
            BindFailureUntilStep(onStore: store!, statement: "SELECT evidence.node", after: nil, limit: Self.limit))
        defer { fault.remove() }
        XCTAssertNil(
            store.unmaterializedMediaTypeEvidenceNodeIDs(volumeID: Self.long),
            "A failed evidence read is no proof that every upload is listed")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testEvidencePruneWithAVolumeThatDoesNotBindFailsAndKeepsTheEvidence() throws {
        XCTAssertTrue(store.recordMediaTypeEvidence([longVolume: "video/mp4"]).succeeded)
        let fault = try XCTUnwrap(
            BindFailureUntilStep(
                onStore: store!, statement: "DELETE FROM media_type_evidence", after: nil, limit: Self.limit))
        XCTAssertFalse(
            store.pruneUnmaterializedMediaTypeEvidence(volumeID: Self.long),
            "A prune that matched no row removed nothing")
        XCTAssertNil(fault.failedBeforeStepProblem)
        fault.remove()
        XCTAssertEqual(store.mediaTypeEvidence(volumeID: Self.long), ["node": "video/mp4"])
    }

    // MARK: Durations, reads and removal

    func testDurationUpdateWithAVolumeThatDoesNotBindFails() throws {
        XCTAssertTrue(store.save([photo(longVolume)]).succeeded)
        let fault = try XCTUnwrap(
            BindFailureUntilStep(onStore: store!, statement: "UPDATE photos SET dur", after: nil, limit: Self.limit))
        defer { fault.remove() }
        XCTAssertFalse(store.updateDurations([longVolume: 3]).succeeded, "An update that matched no row is no update")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testDurationUpdateWithANodeThatDoesNotBindFails() throws {
        XCTAssertTrue(store.save([photo(longNode)]).succeeded)
        let fault = try XCTUnwrap(
            BindFailureUntilStep(onStore: store!, statement: "UPDATE photos SET dur", after: nil, limit: Self.limit))
        defer { fault.remove() }
        XCTAssertFalse(store.updateDurations([longNode: 3]).succeeded, "An update that matched no row is no update")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    private func assertRelatedVideoReadDoesNotRun(
        _ uid: PhotoUID, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertTrue(
            store.save([photo(uid, relatedVideoID: "video"), photo(shortUID, relatedVideoID: "video")]).succeeded,
            file: file, line: line)
        XCTAssertTrue(store.markRelatedVideosChosen(by: "rule"), file: file, line: line)
        let fault = try XCTUnwrap(
            BindFailureUntilStep(
                onStore: store!, statement: "SELECT relvid, live FROM photos", after: nil, limit: Self.limit))
        defer { fault.remove() }
        XCTAssertTrue(
            store.relatedVideos(for: [uid, shortUID], chosenBy: "rule").isEmpty,
            "A key that does not bind leaves the whole answer unknown", file: file, line: line)
        XCTAssertNil(fault.failedBeforeStepProblem, file: file, line: line)
    }

    func testRelatedVideoReadWithAVolumeThatDoesNotBindDoesNotRunTheRead() throws {
        try assertRelatedVideoReadDoesNotRun(longVolume)
    }

    func testRelatedVideoReadWithANodeThatDoesNotBindDoesNotRunTheRead() throws {
        try assertRelatedVideoReadDoesNotRun(longNode)
    }

    private func assertItemReadDoesNotRun(_ uid: PhotoUID, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(store.save([photo(uid), photo(shortUID)]).succeeded, file: file, line: line)
        let fault = try XCTUnwrap(
            BindFailureUntilStep(
                onStore: store!, statement: "SELECT t, mime FROM photos", after: nil, limit: Self.limit))
        defer { fault.remove() }
        XCTAssertEqual(
            store.items(for: [uid, shortUID]), [], "A key that does not bind leaves the whole answer unknown",
            file: file, line: line)
        XCTAssertNil(fault.failedBeforeStepProblem, file: file, line: line)
    }

    func testItemReadWithAVolumeThatDoesNotBindDoesNotRunTheRead() throws {
        try assertItemReadDoesNotRun(longVolume)
    }

    func testItemReadWithANodeThatDoesNotBindDoesNotRunTheRead() throws {
        try assertItemReadDoesNotRun(longNode)
    }

    private func assertRemovalFailsAndKeepsThePhoto(
        _ uid: PhotoUID, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertTrue(store.save([photo(uid)]).succeeded, file: file, line: line)
        let fault = try XCTUnwrap(
            BindFailureUntilStep(
                onStore: store!, statement: "DELETE FROM photos WHERE vol=?", after: nil, limit: Self.limit))
        XCTAssertFalse(store.remove([uid]), "A removal that matched no row removed nothing", file: file, line: line)
        XCTAssertNil(fault.failedBeforeStepProblem, file: file, line: line)
        fault.remove()
        XCTAssertEqual(try store.load().map(\.uid), [uid], file: file, line: line)
    }

    func testRemovalWithAVolumeThatDoesNotBindFailsAndKeepsThePhoto() throws {
        try assertRemovalFailsAndKeepsThePhoto(longVolume)
    }

    func testRemovalWithANodeThatDoesNotBindFailsAndKeepsThePhoto() throws {
        try assertRemovalFailsAndKeepsThePhoto(longNode)
    }
}
