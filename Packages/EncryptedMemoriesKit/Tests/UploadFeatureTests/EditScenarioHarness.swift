import CryptoKit
import Foundation
import PhotoLibraryBackupAdapter
import PhotosCore
import XCTest

@testable import UploadCore

/// A mutable library resolves the current revision, even when the queue contains an earlier scan.
final class EditScenarioLibrary: UploadBackupAssetCatalog, @unchecked Sendable {
    struct Asset: Sendable {
        let identifier: String
        let basename: String
        let original: Data
        let pairedVideo: Data?
        let captureTime = Date(timeIntervalSince1970: 1_720_000_000)
        var render: Data?
        var adjustmentData: Data?
        var hasAdjustments = false
        var adjustmentTimestamp: Date?
        var modificationGeneration = 1
        var generation = 1
        var deleted = false
        var omitOriginal = false

        var source: UploadSourceIdentity {
            UploadSourceIdentity(kind: .photoLibraryAsset, identifier: identifier)
        }
        var current: Data { render ?? original }
        var modificationDate: Date { captureTime.addingTimeInterval(Double(modificationGeneration)) }
        var info: PhotoBackupAssetInfo {
            var resources: [PhotoBackupAssetInfo.Resource] = [
                .init(role: .originalPhoto, originalFilename: "\(basename).HEIC", mimeType: "image/heic")
            ]
            if render != nil {
                resources.append(.init(role: .fullSizePhoto, originalFilename: "Render.JPG", mimeType: "image/jpeg"))
            }
            if adjustmentData != nil {
                resources.append(
                    .init(
                        role: .adjustmentData, originalFilename: "Adjustments.AAE", mimeType: "application/octet-stream"
                    ))
            }
            if pairedVideo != nil {
                resources.append(
                    .init(role: .pairedVideo, originalFilename: "\(basename).MOV", mimeType: "video/quicktime"))
            }
            return PhotoBackupAssetInfo(
                localIdentifier: identifier, creationDate: captureTime,
                modificationDate: modificationDate,
                pixelWidth: 10, pixelHeight: 10, durationSeconds: pairedVideo == nil ? 0 : 1,
                isLivePhoto: pairedVideo != nil, isVideo: false, resources: resources,
                cloudIdentifier: "cloud-\(identifier)", hasAdjustments: hasAdjustments,
                adjustmentTimestamp: adjustmentTimestamp)
        }
    }

    private let directory: URL
    private let lock = NSLock()
    private var assets: [String: Asset] = [:]
    private var resolvedEntries: [UploadBackupSyncQueueEntry] = []
    private var secondaryMaterializations: [SecondaryMaterialization] = []

    struct SecondaryMaterialization: Sendable {
        let resolvedGeneration: Int
        let currentGeneration: Int
        let resource: UploadSourceIdentity.Resource
        let digestChanged: Bool
    }

    init(directory: URL) { self.directory = directory }
    var snapshot: [Asset] { lock.withLock { assets.values.sorted { $0.identifier < $1.identifier } } }
    var resolutions: [UploadBackupSyncQueueEntry] { lock.withLock { resolvedEntries } }
    var materializations: [SecondaryMaterialization] { lock.withLock { secondaryMaterializations } }

    func add(_ identifier: String = "asset-1", live: Bool = false, basename: String = "IMG_1") {
        lock.withLock {
            assets[identifier] = Asset(
                identifier: identifier, basename: basename, original: Data("original-\(identifier)".utf8),
                pairedVideo: live ? Data("video-\(identifier)".utf8) : nil)
        }
    }

    func edit(
        _ bytes: String, identifier: String = "asset-1", omitOriginal: Bool = false,
        at timestamp: Date, renderPresent: Bool = true, timestampPresent: Bool = true
    ) {
        lock.withLock {
            guard var asset = assets[identifier] else { return }
            asset.generation += 1
            asset.modificationGeneration = asset.generation
            asset.hasAdjustments = true
            asset.adjustmentTimestamp = timestampPresent ? timestamp : nil
            asset.render = renderPresent ? Data(bytes.utf8) : nil
            asset.adjustmentData = Data("adjustment-\(identifier)-\(asset.generation)-\(bytes)".utf8)
            asset.omitOriginal = omitOriginal
            assets[identifier] = asset
        }
    }

    func makeOriginalAvailable(_ identifier: String = "asset-1") {
        lock.withLock { assets[identifier]?.omitOriginal = false }
    }

    func undo(_ identifier: String = "asset-1", at timestamp: Date, restoreEarlierDate: Bool = false) {
        lock.withLock {
            guard var asset = assets[identifier] else { return }
            asset.generation += 1
            asset.modificationGeneration = restoreEarlierDate ? 1 : asset.generation
            asset.hasAdjustments = false
            asset.adjustmentTimestamp = restoreEarlierDate ? nil : timestamp
            asset.render = nil
            asset.adjustmentData = nil
            asset.omitOriginal = false
            assets[identifier] = asset
        }
    }

    func delete(_ identifier: String = "asset-1") {
        lock.withLock {
            guard var asset = assets[identifier] else { return }
            asset.generation += 1
            asset.modificationGeneration = asset.generation
            asset.deleted = true
            assets[identifier] = asset
        }
    }

    func candidate(_ identifier: String = "asset-1") throws -> UploadBackupAssetCandidate {
        let asset = try XCTUnwrap(lock.withLock { assets[identifier] })
        return try XCTUnwrap(PhotoBackupAssetPlanner.candidate(for: asset.info))
    }

    func publishRender(_ bytes: String, identifier: String = "asset-1") {
        lock.withLock { assets[identifier]?.render = Data(bytes.utf8) }
    }

    /// Metadata drifts without changing the compound bytes or its adjustment data.
    func changeModificationDate(_ identifier: String = "asset-1") {
        lock.withLock {
            guard var asset = assets[identifier] else { return }
            asset.generation += 1
            asset.modificationGeneration = asset.generation
            assets[identifier] = asset
        }
    }

    func candidates() -> AsyncThrowingStream<UploadBackupAssetCandidate, any Error> {
        let candidates = snapshot.filter { !$0.deleted }.compactMap { PhotoBackupAssetPlanner.candidate(for: $0.info) }
        return AsyncThrowingStream { continuation in
            for candidate in candidates { continuation.yield(candidate) }
            continuation.finish()
        }
    }

    func resolve(_ entry: UploadBackupSyncQueueEntry, now: Date) async throws -> BackupResolvedResource? {
        lock.withLock { resolvedEntries.append(entry) }
        guard let asset = lock.withLock({ assets[entry.source.identifier] }), !asset.deleted else { return nil }
        if let until = PhotoBackupAssetPlanner.notReadyUntil(for: asset.info, now: now) {
            throw UploadError.sourceNotReady(entry.originalFilename, until: until)
        }
        let candidate = try XCTUnwrap(PhotoBackupAssetPlanner.candidate(for: asset.info))
        let plan = try XCTUnwrap(PhotoBackupAssetPlanner.exportPlan(for: asset.info))
        // The real planner supplies edit fingerprints and every secondary resource role.
        // PhotoBackupAssetPlan.swift:213-217, 251-288, 325-332.
        // Mirror PhotoLibraryResourceResolver.swift:78-81, 106-111, 187-194:
        // stable capture date on descriptors; asset identity plus each planned secondary role.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let metadata = [
            PhotoUploadAdditionalMetadata(
                name: "iOS.photos",
                utf8JsonValue: try JSONEncoder().encode(
                    PhotoUploadMetadataEncoder.IOSPhotos(
                        iCloudID: asset.info.cloudIdentifier,
                        modificationTime: formatter.string(from: asset.modificationDate))))
        ]
        // Fault injection for defect 5b: the resolved compound omits its original secondary.
        let secondaries = try plan.secondaries.filter { !asset.omitOriginal || $0.role != .originalPhoto }.map { item in
            let identity = try descriptor(item, asset: asset, materialize: false)
            return BackupSecondaryResource(
                descriptor: identity, mediaType: item.mimeType ?? "image/heic", additionalMetadata: metadata,
                materialize: { [self] in
                    guard let current = lock.withLock({ assets[asset.identifier] }), !current.deleted else {
                        throw UploadError.fileMissing(item.uploadFilename)
                    }
                    // Production re-fetches the resource after the primary upload, before checking its digest.
                    let exported = try descriptor(item, asset: current, materialize: true)
                    lock.withLock {
                        secondaryMaterializations.append(
                            SecondaryMaterialization(
                                resolvedGeneration: asset.generation, currentGeneration: current.generation,
                                resource: item.sourceResource,
                                digestChanged: exported.precomputedSHA1Digest != identity.precomputedSHA1Digest))
                    }
                    return exported
                })
        }
        return BackupResolvedResource(
            candidate: candidate, descriptor: try descriptor(plan.primary, asset: asset, materialize: true),
            mediaType: plan.primary.mimeType ?? "image/heic", additionalMetadata: metadata,
            captureDate: asset.captureTime, secondaries: secondaries)
    }

    private func descriptor(
        _ item: PhotoBackupExportPlan.Item, asset: Asset, materialize: Bool
    ) throws -> UploadResourceDescriptor {
        let bytes: Data
        switch item.role {
        case .fullSizePhoto: bytes = try XCTUnwrap(asset.render)
        case .pairedVideo: bytes = try XCTUnwrap(asset.pairedVideo)
        case .originalPhoto: bytes = asset.original
        case .adjustmentData: bytes = try XCTUnwrap(asset.adjustmentData)
        default: throw UploadError.backend("The scenario has no bytes for resource \(item.role.rawValue)")
        }
        let assetDirectory = directory.appendingPathComponent(asset.identifier, isDirectory: true)
        let url = assetDirectory.appendingPathComponent(
            materialize ? "\(asset.generation)-\(item.role.rawValue)" : ".not-materialized")
        if materialize {
            try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        return UploadResourceDescriptor(
            source: UploadSourceIdentity(
                kind: .photoLibraryAsset, identifier: asset.identifier, resource: item.sourceResource),
            fileURL: url, filename: item.uploadFilename, fileSize: Int64(bytes.count),
            modificationDate: asset.captureTime,
            precomputedSHA1Digest: Data(Insecure.SHA1.hash(data: bytes)))
    }
}

/// Each device resolves the shared library with its own scheduler clock.
private struct EditScenarioResolver: BackupResourceResolving {
    let library: EditScenarioLibrary
    let clock: BackupTestClock

    func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
        try await library.resolve(entry, now: clock.now)
    }
}

/// Rebuilds the real runner, pipeline, SQLite stores, and file journal over one account directory.
final class EditScenarioHarness {
    let directory: URL
    let server: EditScenarioServer
    let library: EditScenarioLibrary
    let clock: BackupTestClock
    private let coordinator = LibraryResourceCoordinator(runtimeState: LibraryRuntimeState())
    private(set) var queue: UploadBackupSyncQueueManifestStore!
    private(set) var identities: UploadIdentityManifestStore!
    private var backupState: UploadBackupStateManifestStore!
    private(set) var journal: EditReplacementJournalFileStore!
    private var pipeline: UploadDedupePipeline!
    private var runner: BackupSyncRunner!
    private var engine: UploadBackupSyncEngine!
    private(set) var lastScan = UploadBackupSyncScanResult()
    private var entries: [UploadBackupSyncQueueEntry] = []
    private var checkedSteps = 0

    init(
        live: Bool = false, basename: String = "IMG_1", server: EditScenarioServer = EditScenarioServer(),
        library sharedLibrary: EditScenarioLibrary? = nil, clock: BackupTestClock = BackupTestClock()
    ) throws {
        self.server = server
        self.clock = clock
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edit-scenario-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let sharedLibrary {
            library = sharedLibrary
        } else {
            library = EditScenarioLibrary(directory: directory.appendingPathComponent("library"))
            library.add(live: live, basename: basename)
        }
        checkedSteps = server.steps.count
        try open()
    }

    private func open() throws {
        queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
        identities = try XCTUnwrap(
            UploadIdentityManifestStore(
                url: directory.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)))
        backupState = try XCTUnwrap(
            UploadBackupStateManifestStore(
                url: directory.appendingPathComponent(UploadBackupStateManifestStore.databaseFileName)))
        journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        pipeline = UploadDedupePipeline(
            store: identities, checker: server, resourceCoordinator: coordinator, replacementJournal: journal,
            now: { [clock] in clock.now })
        let replacement = EditedPhotoReplacement(
            remote: server, albums: server, relations: server, identities: identities, journal: journal)
        let preflight = UploadBackupPreflightIndex(store: backupState, now: { [clock] in clock.now })
        engine = UploadBackupSyncEngine(
            preflight: preflight, queue: queue, remoteProofResolver: pipeline, now: { [clock] in clock.now })
        runner = BackupSyncRunner(
            queue: queue, preflight: preflight,
            resolver: EditScenarioResolver(library: library, clock: clock), identityResolver: pipeline,
            uploader: server, editReplacement: replacement,
            resourceCoordinator: coordinator,
            configuration: .init(
                retry: .init(baseDelay: 1, maxDelay: 8, maxAttempts: 4),
                throttle: .init(baseConcurrency: 1)),
            clock: clock, now: { [clock] in clock.now })
    }

    func close() {
        engine = nil
        runner = nil
        pipeline = nil
        queue?.close()
        identities?.close()
        backupState?.close()
    }

    func cleanup() throws {
        close()
        try FileManager.default.removeItem(at: directory)
    }

    func relaunch() throws {
        close()
        clock.advance(by: 1)
        try open()
    }

    /// Discovery uses the real scan, preflight, remote proof lookup, and persistent queue upsert.
    @discardableResult
    func enqueue(_ identifier: String = "asset-1") async throws -> UploadBackupSyncQueueEntry {
        let candidate = try library.candidate(identifier)
        lastScan = try await engine.scan(library)
        // The runner takes over a row that the scan left in a checking state only once its date lies in the past.
        clock.advance(by: 1)
        let entry = try XCTUnwrap(queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision))
        entries.append(entry)
        return entry
    }

    /// A removed asset cannot occur in a production scan. Seed stale work to test resolver deletion handling.
    @discardableResult
    func enqueueStaleRemovedAsset(_ identifier: String = "asset-1") throws -> UploadBackupSyncQueueEntry {
        let candidate = try library.candidate(identifier)
        let entry = UploadBackupSyncQueueEntry(
            source: candidate.snapshot.source, revision: candidate.snapshot.revision,
            originalFilename: candidate.originalFilename, byteCount: candidate.byteCount, updatedAt: clock.now)
        XCTAssertTrue(queue.upsert(entry), "The scenario must persist stale work for a removed asset")
        entries.append(entry)
        return entry
    }

    /// The in-flight scenario joins this task before it checks safety or removes the device stores.
    func startPass() -> Task<BackupSyncProgress, Never> {
        let runningRunner: BackupSyncRunner = runner
        return Task { await runningRunner.runUntilDrained(mode: .eligibleOnly) }
    }

    func pass(file: StaticString = #filePath, line: UInt = #line) async {
        // Time passes between two passes. The runner takes over a row that an interrupted pass left active only
        // once its date lies in the past.
        clock.advance(by: 1)
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        assertSafety(file: file, line: line)
    }

    func drain(file: StaticString = #filePath, line: UInt = #line) async {
        clock.advance(by: 1)
        _ = await runner.runUntilDrained(mode: .waitForScheduledRetries)
        assertSafety(file: file, line: line)
        assertQuiescent(file: file, line: line)
    }

    func state(of entry: UploadBackupSyncQueueEntry) -> UploadBackupSyncQueueState? {
        queue.entry(for: entry.source, revision: entry.revision)?.state
    }

    func primaryDecision(for entry: UploadBackupSyncQueueEntry) async throws -> UploadDuplicateDecision {
        let resource = try await library.resolve(entry, now: clock.now)
        let resolved = try XCTUnwrap(resource)
        return try await pipeline.resolve(resolved.descriptor).decision
    }

    var activeMains: [EditScenarioServer.Link] {
        server.links.filter { $0.assetID == "asset-1" && $0.state == .active && $0.mainLinkID == nil }
    }

    func liveMain() throws -> PhotoUID { try XCTUnwrap(activeMains.last).uid }

    /// While set, invariant violations are collected in `recordedViolations` instead of failing the test. A scenario
    /// that reproduces a known defect sets it and then requires the defect to show; its fix turns the scenario into a
    /// regular test. XCTExpectFailure does not follow an async test across its suspension points.
    var knownDefect: String?
    private(set) var recordedViolations: [String] = []

    func check(
        _ condition: Bool, _ message: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard !condition else { return }
        if knownDefect != nil {
            recordedViolations.append(message())
        } else {
            XCTFail(message(), file: file, line: line)
        }
    }

    func expectKnownDefect(
        signature: String, consequences: [String], file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(
            recordedViolations.contains { $0.contains(signature) },
            "\(knownDefect ?? "The defect") no longer reproduces; turn this scenario into a regular test",
            file: file, line: line)
        for violation in recordedViolations {
            if !violation.contains(signature), !consequences.contains(where: { violation.hasPrefix($0) }) {
                XCTFail("Unexpected violation: \(violation)", file: file, line: line)
            }
        }
    }

    func assertSafety(file: StaticString = #filePath, line: UInt = #line) {
        // Inspect every server mutation, including transient states hidden by the final snapshot.
        let steps = server.steps
        for step in steps.dropFirst(checkedSteps) {
            for violation in step.violations {
                check(false, "\(violation) (\(step.action))", file: file, line: line)
            }
            for main in step.links where main.mainLinkID == nil && main.generation > 1 {
                check(
                    main.albums.allSatisfy { $0.volumeID == "vol" },
                    "S4 shared-volume memberships must not copy to a new main: \(main.linkID)", file: file, line: line)
            }
            for id in step.trashedByBackup {
                let target = step.links.first { $0.linkID == id }
                let asset = library.snapshot.first { $0.identifier == target?.assetID }
                check(
                    target?.mainLinkID == nil && target != nil && asset != nil
                        && (target?.generation ?? Int.max) < (asset?.generation ?? 0),
                    "S6 backup trash must target an earlier main of the same asset: \(id)", file: file, line: line)
            }
        }
        checkedSteps = steps.count
        for entry in entries where state(of: entry) == .skippedRemoteDeletion {
            check(
                server.links.contains { $0.assetID == entry.source.identifier && $0.personDeleted },
                "U2 skippedRemoteDeletion has no positive person-deletion proof for \(entry.source.identifier)",
                file: file, line: line)
        }
    }

    /// U4: `retired` names only links that left the library: a trashed main, or a related file whose main is trashed.
    /// The server never trashes a related file on its own; it stays active under its trashed main.
    func assertRetired(file: StaticString = #filePath, line: UInt = #line) {
        let links = server.links
        for asset in library.snapshot {
            for id in journal.entry(for: asset.source).retired {
                guard let link = links.first(where: { $0.linkID == id }) else { continue }
                let main = link.mainLinkID.flatMap { mainID in links.first { $0.linkID == mainID } }
                check(
                    link.state != .active || (main.map { $0.state != .active } ?? false),
                    "U4 retired names a link that is still in the library: \(id)", file: file, line: line)
            }
        }
    }

    /// A cached upload proof must name the live compound, never an orphan under a trashed main.
    func assertCurrentManifest(file: StaticString = #filePath, line: UInt = #line) {
        let links = server.links
        for asset in library.snapshot where !asset.deleted {
            guard let plan = PhotoBackupAssetPlanner.exportPlan(for: asset.info) else { continue }
            let mainID = identities.record(for: asset.source)?.remoteLinkID
            let main = links.first { $0.linkID == mainID }
            check(
                main?.state == .active && main?.mainLinkID == nil,
                "U1 current primary proof must name an active main", file: file, line: line)
            for item in plan.secondaries {
                let source = UploadSourceIdentity(
                    kind: .photoLibraryAsset, identifier: asset.identifier, resource: item.sourceResource)
                let linkID = identities.record(for: source)?.remoteLinkID
                let related = links.first { $0.linkID == linkID }
                check(
                    related?.state == .active && related?.mainLinkID == mainID && main?.state == .active,
                    "U1 an orphan cannot count as a backed-up resource: \(item.role.rawValue)", file: file, line: line)
            }
        }
    }

    func assertQuiescent(file: StaticString = #filePath, line: UInt = #line) {
        let summary = queue.summary()
        check(
            summary.waiting + summary.active + summary.blocked + summary.failed == 0, "the queue must drain",
            file: file, line: line)
        let links = server.links
        for asset in library.snapshot {
            let mains = links.filter {
                $0.assetID == asset.identifier && $0.mainLinkID == nil && $0.state == .active
            }
            if links.contains(where: { $0.assetID == asset.identifier && $0.personDeleted }) {
                check(mains.isEmpty, "S5 a deleted asset has a new active main", file: file, line: line)
                continue
            }
            // Local deletion does not remove a backup from the server.
            guard !asset.deleted else { continue }
            if asset.hasAdjustments && asset.render == nil {
                check(
                    false, "K6 missing render cannot count an original as the current version", file: file, line: line)
                continue
            }
            check(mains.count == 1, "S1/U3 mains: \(mains.map(\.linkID))", file: file, line: line)
            guard let main = mains.first else { continue }
            check(
                main.contentHash == EditScenarioServer.contentHash(Data(Insecure.SHA1.hash(data: asset.current))),
                "S1 the main must hold the current version", file: file, line: line)
            check(main.captureTime == asset.captureTime, "S1 the main keeps the capture time", file: file, line: line)
            let resources = links.filter { $0.mainLinkID == main.linkID && $0.state == .active }
            if asset.hasAdjustments {
                let currentHash = EditScenarioServer.contentHash(Data(Insecure.SHA1.hash(data: asset.current)))
                for editedMain in mains where editedMain.contentHash == currentHash {
                    let editedResources = links.filter { $0.mainLinkID == editedMain.linkID && $0.state == .active }
                    check(
                        editedResources.contains {
                            $0.contentHash
                                == EditScenarioServer.contentHash(Data(Insecure.SHA1.hash(data: asset.original)))
                        }, "S3 the edited main lacks its active original", file: file, line: line)
                    if let adjustmentData = asset.adjustmentData {
                        check(
                            editedResources.contains {
                                $0.contentHash
                                    == EditScenarioServer.contentHash(Data(Insecure.SHA1.hash(data: adjustmentData)))
                            }, "S3 the edited main lacks its current adjustment data", file: file, line: line)
                    } else {
                        check(false, "S3 the edited asset lacks adjustment data", file: file, line: line)
                    }
                }
            }
            if let video = asset.pairedVideo {
                check(
                    resources.contains {
                        $0.contentHash == EditScenarioServer.contentHash(Data(Insecure.SHA1.hash(data: video)))
                    }, "S3 the Live Photo main lacks its active video", file: file, line: line)
            }
            if links.contains(where: { $0.assetID == asset.identifier && $0.favorite }) {
                check(main.favorite, "S4 the favorite must move", file: file, line: line)
            }
            let ownAlbums = links.filter { $0.assetID == asset.identifier }.reduce(into: Set<SeriesAlbumReference>()) {
                $0.formUnion($1.albums.filter { $0.volumeID == "vol" })
            }
            check(ownAlbums.isSubset(of: main.albums), "S4 own albums must move", file: file, line: line)
        }
        assertRetired(file: file, line: line)
    }
}
