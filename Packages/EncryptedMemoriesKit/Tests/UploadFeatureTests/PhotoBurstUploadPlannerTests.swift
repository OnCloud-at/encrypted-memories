import Foundation
import PhotoLibraryBackupAdapter
import XCTest

@testable import UploadCore

/// Series (burst) upload planning over platform-neutral descriptions: no PhotoKit, no photo access.
final class PhotoBurstUploadPlannerTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func asset(
        _ number: Int,
        userPick: Bool = false,
        representsBurst: Bool = false,
        filename: String? = nil,
        resources: [PhotoBackupAssetInfo.Resource]? = nil
    ) -> PhotoBurstAssetDescriptor {
        let name = filename ?? String(format: "IMG_%04d.HEIC", number)
        return PhotoBurstAssetDescriptor(
            info: PhotoBackupAssetInfo(
                localIdentifier: "asset-\(number)",
                creationDate: baseDate.addingTimeInterval(Double(number) * 0.1),
                modificationDate: baseDate.addingTimeInterval(100),
                pixelWidth: 4032, pixelHeight: 3024, durationSeconds: 0,
                isLivePhoto: false, isVideo: false,
                resources: resources ?? [.init(role: .originalPhoto, originalFilename: name, mimeType: "image/heic")]
            ),
            isUserPick: userPick,
            representsBurst: representsBurst
        )
    }

    // MARK: Main photo choice

    func testUserPickIsTheMainPhotoBeforeTheRepresentative() throws {
        let plan = try XCTUnwrap(
            PhotoBurstUploadPlanner.plan(for: [
                asset(1, representsBurst: true), asset(2), asset(3, userPick: true),
            ]))
        XCTAssertEqual(plan.mainLocalIdentifier, "asset-3")
        XCTAssertEqual(plan.members.map(\.localIdentifier), ["asset-1", "asset-2"])
    }

    func testEarliestUserPickWinsWhenTheUserPickedSeveral() throws {
        let plan = try XCTUnwrap(
            PhotoBurstUploadPlanner.plan(for: [
                asset(4, userPick: true), asset(1, representsBurst: true), asset(2, userPick: true), asset(3),
            ]))
        XCTAssertEqual(plan.mainLocalIdentifier, "asset-2", "the choice must not depend on the fetch order")
    }

    func testRepresentativeIsTheFallbackAndTheFirstPhotoIsTheLastResort() throws {
        let representative = try XCTUnwrap(
            PhotoBurstUploadPlanner.plan(for: [asset(1), asset(2, representsBurst: true), asset(3)]))
        XCTAssertEqual(representative.mainLocalIdentifier, "asset-2")

        let unmarked = try XCTUnwrap(PhotoBurstUploadPlanner.plan(for: [asset(3), asset(1), asset(2)]))
        XCTAssertEqual(unmarked.mainLocalIdentifier, "asset-1")
    }

    // MARK: Member grouping

    func testEveryOtherExportablePhotoIsAMemberInOrdinalOrder() throws {
        let broken = asset(
            5, resources: [.init(role: .adjustmentData, originalFilename: "Adjustments.plist", mimeType: nil)])
        let plan = try XCTUnwrap(
            PhotoBurstUploadPlanner.plan(for: [
                asset(10), asset(2, representsBurst: true), broken, asset(9),
            ]))
        XCTAssertEqual(
            plan.members.map(\.uploadFilename), ["IMG_0009.HEIC", "IMG_0010.HEIC"],
            "members follow the numeric filename order that assigns their resource ordinals")
        XCTAssertFalse(plan.members.contains { $0.localIdentifier == "asset-5" }, "a photo without bytes is skipped")
    }

    func testMembersWithTheSameFilenameStayDistinct() throws {
        let plan = try XCTUnwrap(
            PhotoBurstUploadPlanner.plan(for: [
                asset(1, representsBurst: true, filename: "MAIN.HEIC"),
                asset(2, filename: "SAME.HEIC"), asset(3, filename: "same.heic"),
            ]))
        XCTAssertEqual(Set(plan.members.map { $0.uploadFilename.lowercased() }).count, 2)
    }

    func testASinglePhotoIsNotASeries() {
        XCTAssertNil(PhotoBurstUploadPlanner.plan(for: [asset(1, representsBurst: true)]))
        XCTAssertNil(PhotoBurstUploadPlanner.plan(for: []))
    }

    func testMainPhotoCarriesItsMembersAsRelatedResources() throws {
        let assets = [asset(1, representsBurst: true), asset(2), asset(3)]
        let plan = try XCTUnwrap(PhotoBurstUploadPlanner.plan(for: assets))
        let main = PhotoBurstUploadPlanner.applying(plan, to: assets[0].info)

        let export = try XCTUnwrap(PhotoBackupAssetPlanner.exportPlan(for: main))
        XCTAssertEqual(export.primary.uploadFilename, "IMG_0001.HEIC")
        XCTAssertEqual(export.secondaries.map(\.uploadFilename), ["IMG_0002.HEIC", "IMG_0003.HEIC"])
        XCTAssertEqual(
            export.secondaries.map(\.sourceResource), [.burstMember(ordinal: 0), .burstMember(ordinal: 1)])
        XCTAssertTrue(export.secondaries.allSatisfy { $0.sourceResource.isBurstMember })
        XCTAssertEqual(PhotoBackupAssetPlanner.candidate(for: main)?.snapshot.resourceCount, 3)
    }

    func testOnlyTheMainPhotoIsABackupCandidate() throws {
        // PhotoKit's default fetch returns the representative and every user pick, so both surface as assets.
        let assets = [asset(1, representsBurst: true), asset(2, userPick: true), asset(3)]
        let plan = try XCTUnwrap(PhotoBurstUploadPlanner.plan(for: assets))

        let representative = PhotoBurstUploadPlanner.applying(plan, to: assets[0].info)
        XCTAssertNil(
            PhotoBackupAssetPlanner.candidate(for: representative),
            "a second standalone upload of a member would break the series relation")
        let userPick = PhotoBurstUploadPlanner.applying(plan, to: assets[1].info)
        XCTAssertNotNil(PhotoBackupAssetPlanner.candidate(for: userPick))
    }

    func testSeriesRoleSurvivesTheCatalogRoundTrip() throws {
        let assets = [asset(1, representsBurst: true), asset(2), asset(3)]
        let plan = try XCTUnwrap(PhotoBurstUploadPlanner.plan(for: assets))
        for descriptor in assets {
            let info = PhotoBurstUploadPlanner.applying(plan, to: descriptor.info)
            let replayed = PhotoLibraryCatalogMapper.info(
                for: PhotoLibraryCatalogMapper.entry(for: info, observedAt: baseDate))
            XCTAssertEqual(
                PhotoBackupAssetPlanner.candidate(for: replayed)?.snapshot,
                PhotoBackupAssetPlanner.candidate(for: info)?.snapshot,
                "a queue replay from the catalog must plan the same compound as the PhotoKit scan")
        }
    }

    // MARK: Migration of a series that an earlier build uploaded as one plain photo

    func testRepresentativeBackedUpAloneIsQueuedAgainForItsMissingMembers() async throws {
        let assets = [asset(1, representsBurst: true), asset(2), asset(3)]
        let plan = try XCTUnwrap(PhotoBurstUploadPlanner.plan(for: assets))
        let uploadedAlone = try XCTUnwrap(PhotoBackupAssetPlanner.candidate(for: assets[0].info))
        let asSeries = try XCTUnwrap(
            PhotoBackupAssetPlanner.candidate(for: PhotoBurstUploadPlanner.applying(plan, to: assets[0].info)))

        XCTAssertEqual(asSeries.snapshot.source, uploadedAlone.snapshot.source, "the same asset, never a new one")
        XCTAssertNotEqual(
            PhotoLibraryCatalogMapper.entry(for: assets[0].info, observedAt: baseDate).contentFingerprint,
            PhotoLibraryCatalogMapper.entry(
                for: PhotoBurstUploadPlanner.applying(plan, to: assets[0].info), observedAt: baseDate
            ).contentFingerprint,
            "the catalog must report the asset as changed although PhotoKit did not move its dates")

        let index = UploadBackupPreflightIndex(store: MemoryStore())
        try await index.markBackedUp(uploadedAlone.snapshot)
        let decision = try await index.classify(asSeries.snapshot)
        XCTAssertEqual(
            decision, .needsBackendCheck(.unseenEditRevision),
            "an already backed up representative must re-open, so the runner uploads only the missing members")
    }

    func testCompleteSeriesIsNotQueuedAgain() async throws {
        let assets = [asset(1, representsBurst: true), asset(2)]
        let plan = try XCTUnwrap(PhotoBurstUploadPlanner.plan(for: assets))
        let series = try XCTUnwrap(
            PhotoBackupAssetPlanner.candidate(for: PhotoBurstUploadPlanner.applying(plan, to: assets[0].info)))
        let index = UploadBackupPreflightIndex(store: MemoryStore())
        try await index.markBackedUp(series.snapshot)

        let decision = try await index.classify(series.snapshot)
        XCTAssertEqual(decision, .alreadyBackedUp)
    }

    private final class MemoryStore: UploadBackupStateStore, @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [UploadSourceIdentity: [UploadBackupRevision: UploadBackupAssetRecord]] = [:]
        func record(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupAssetRecord? {
            lock.withLock { rows[source]?[revision] }
        }
        func hasAnyRecord(for source: UploadSourceIdentity) -> Bool {
            lock.withLock { !(rows[source]?.isEmpty ?? true) }
        }
        func upsert(_ record: UploadBackupAssetRecord) -> Bool {
            lock.withLock { rows[record.source, default: [:]][record.revision] = record }
            return true
        }
        func count() -> Int { lock.withLock { rows.values.reduce(0) { $0 + $1.count } } }
    }
}
