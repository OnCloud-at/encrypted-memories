import Foundation
import PhotosCore

// MARK: - Seams

/// What the standalone copy of one series member keeps from its source: the original filename, type and
/// capture time, plus Proton's encrypted metadata sections that do not identify the source asset.
public struct SeriesMemberSource: Sendable, Equatable {
    public let filename: String
    public let mediaType: String
    public let captureTime: Date
    public let modificationDate: Date
    public let additionalMetadata: [PhotoUploadAdditionalMetadata]

    public init(
        filename: String,
        mediaType: String,
        captureTime: Date,
        modificationDate: Date,
        additionalMetadata: [PhotoUploadAdditionalMetadata]
    ) {
        self.filename = filename
        self.mediaType = mediaType
        self.captureTime = captureTime
        self.modificationDate = modificationDate
        self.additionalMetadata = additionalMetadata
    }
}

/// Remote reads and the trash write of a series dissolution. The backend implements it; tests use a fake.
public protocol SeriesDissolutionRemote: OriginalFileProvider {
    /// The account's own photos volume. A series in any other volume belongs to a shared album.
    func ownPhotosVolumeID() async throws -> String
    func source(for member: PhotoUID) async throws -> SeriesMemberSource
    /// The subset of `uids` that are active photos now: not trashed, not deleted, not drafts.
    func activeUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID>
    /// Moves the photos to the Proton trash, where the user can restore them.
    func trashSeries(_ uids: [PhotoUID]) async throws
}

// MARK: - Dedupe collision rule

/// Decides how one favorite becomes a standalone photo.
///
/// The standard upload dedupe cannot be used here. The favorite's bytes already exist remotely as the
/// series member itself, so the standard rule would answer "active duplicate" and link the favorite to the
/// member that is about to move to the trash. The favorite would be lost.
///
/// Rule. The copy keeps the member's original filename. Proton's duplicate rows for that name are read, and
/// every row that belongs to the series is ignored, because the series is the source and not a copy. Then:
/// 1. An active row with the same content is a standalone copy that already exists: an earlier attempt
///    committed it before the journal recorded it, or the user uploaded the same file separately. It is
///    adopted. No bytes upload, so a retry never creates a duplicate.
/// 2. A draft of this installation is an interrupted copy attempt. The upload replaces it.
/// 3. A draft of another client blocks the name. The operation stops and stays resumable.
/// 4. A trashed or deleted row with the same content does not block. The user chose to keep this favorite
///    now, so an older deletion of an identical file must not remove it from the result.
/// 5. A row with the same name and other content is another photo. The copy uploads under the same name.
public enum SeriesFavoriteCopyPolicy {
    public enum Decision: Sendable, Equatable {
        case adopt(remoteLinkID: String)
        case upload(replacingDraft: Bool)
        case blockedByForeignDraft
    }

    public static func decide(
        nameHash: String,
        contentHash: String,
        remoteItems: [RemotePhotoDuplicate],
        seriesLinkIDs: Set<String>,
        currentClientUID: String?
    ) -> Decision {
        let candidates = remoteItems.filter { item in
            item.nameHash == nameHash && !(item.linkID.map(seriesLinkIDs.contains) ?? false)
        }
        if let existing = candidates.first(where: { $0.linkState == .active && $0.contentHash == contentHash }),
            let linkID = existing.linkID, !linkID.isEmpty
        {
            return .adopt(remoteLinkID: linkID)
        }
        let drafts = candidates.filter { $0.linkState == .draft }
        guard !drafts.isEmpty else { return .upload(replacingDraft: false) }
        if let currentClientUID, drafts.allSatisfy({ $0.clientUID == currentClientUID }) {
            return .upload(replacingDraft: true)
        }
        return .blockedByForeignDraft
    }
}

// MARK: - Errors and progress

public enum SeriesDissolutionError: LocalizedError, Equatable {
    /// The series is not in the account's own library (a shared album, or a foreign volume).
    case notOwnLibrary
    /// The selection is empty or names a photo outside the series.
    case invalidSelection
    case alreadyRunning
    case blockedByForeignDraft(String)
    /// A confirmed copy was not active remotely even after a second copy attempt. The series is untouched.
    case copyNotConfirmed

    public var errorDescription: String? {
        switch self {
        case .notOwnLibrary: L10n.string("error.series_not_own_library")
        case .invalidSelection: L10n.string("error.series_invalid_selection")
        case .alreadyRunning: L10n.string("error.series_already_running")
        case .blockedByForeignDraft(let name): L10n.string("error.series_draft_blocked \(name)")
        case .copyNotConfirmed: L10n.string("error.series_copy_not_confirmed")
        }
    }
}

public struct SeriesDissolutionProgress: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        /// Copying favorite `index` (0-based) of `count`.
        case copyingFavorite(index: Int, count: Int)
        case movingSeriesToTrash
    }

    public let step: Step
    /// Monotonic 0…1 across the whole operation. Copies take the first 90 percent.
    public let fraction: Double

    public init(step: Step, fraction: Double) {
        self.step = step
        self.fraction = min(1, max(0, fraction))
    }
}

/// What `resumePending` did for one journaled series. `result` holds the standalone copies once the whole series
/// is in the trash, or the error that keeps the journal pending.
public struct SeriesDissolutionResumeOutcome: Sendable {
    public let seriesUIDs: [PhotoUID]
    public let result: Result<[PhotoUID], any Error>
}

// MARK: - Orchestrator

/// Runs "Keep Only Favorites" for a series: journal, copy every favorite, verify, then trash the series.
/// "Keep Everything" makes no backend call and never reaches this type.
public actor SeriesDissolutionOrchestrator {
    private let remote: any SeriesDissolutionRemote
    private let uploader: any PhotoUploading
    private let duplicateChecker: any UploadDuplicateChecking
    private let journalStore: any SeriesDissolutionJournalStore
    private let tempDirectory: URL
    private let currentClientUID: String?
    private var running: Set<PhotoUID> = []

    public init(
        remote: any SeriesDissolutionRemote,
        uploader: any PhotoUploading,
        duplicateChecker: any UploadDuplicateChecking,
        journalStore: any SeriesDissolutionJournalStore,
        tempDirectory: URL,
        currentClientUID: String?
    ) {
        self.remote = remote
        self.uploader = uploader
        self.duplicateChecker = duplicateChecker
        self.journalStore = journalStore
        self.tempDirectory = tempDirectory
        self.currentClientUID = currentClientUID
    }

    /// True only for a series that lies completely in the account's own photos volume. Shared albums live in
    /// a foreign volume, and the trash and upload writes address the own volume only.
    public func canDissolve(seriesUIDs: [PhotoUID]) async -> Bool {
        guard !seriesUIDs.isEmpty, let own = try? await remote.ownPhotosVolumeID() else { return false }
        return seriesUIDs.allSatisfy { $0.volumeID == own }
    }

    /// Copies every favorite into a standalone photo and then moves the whole series to the trash.
    /// Returns the standalone photos. Safe to call again after any failure or crash.
    @discardableResult
    public func keepOnlyFavorites(
        seriesMainUID: PhotoUID,
        seriesUIDs: [PhotoUID],
        favoriteUIDs: [PhotoUID],
        onProgress: @escaping @Sendable (SeriesDissolutionProgress) -> Void = { _ in }
    ) async throws -> [PhotoUID] {
        guard await canDissolve(seriesUIDs: seriesUIDs) else { throw SeriesDissolutionError.notOwnLibrary }
        let series = Set(seriesUIDs)
        guard !favoriteUIDs.isEmpty, series.contains(seriesMainUID), favoriteUIDs.allSatisfy(series.contains)
        else { throw SeriesDissolutionError.invalidSelection }

        var journal =
            try journalStore.journal(forSeries: seriesMainUID)
            .map { Self.merging(favoriteUIDs, into: $0) }
            ?? SeriesDissolutionJournal(
                seriesMainUID: seriesMainUID,
                seriesUIDs: seriesUIDs,
                favorites: favoriteUIDs.map { .init(memberUID: $0) }
            )
        return try await run(&journal, onProgress: onProgress)
    }

    /// Drops the operation of a series that the user left after a failure: Cancel, "Keep Everything" or closing
    /// the mode. Only a journal that still copies favorites is removed. The series is untouched in that phase,
    /// and copies that are already confirmed stay as standalone photos; no photo is deleted. A journal in the
    /// trash step stays, because the user's consent and the copies are final there.
    public func abandon(seriesMainUID: PhotoUID) throws {
        guard !running.contains(seriesMainUID) else { throw SeriesDissolutionError.alreadyRunning }
        guard try journalStore.journal(forSeries: seriesMainUID)?.phase == .copyingFavorites else { return }
        try journalStore.remove(forSeries: seriesMainUID)
    }

    /// Finishes every interrupted operation that reached the trash step, and reports each result to the host.
    /// A failure stays journaled for the next call.
    ///
    /// A journal that still copies favorites never runs here. No user confirmed it in this session, and its
    /// selection is not final. It waits on disk: "Keep Only Favorites" on the same series continues it with the
    /// confirmed copies, and `abandon` removes it.
    public func resumePending() async throws -> [SeriesDissolutionResumeOutcome] {
        var outcomes: [SeriesDissolutionResumeOutcome] = []
        for var journal in try journalStore.pendingJournals() where journal.phase == .trashingSeries {
            let result: Result<[PhotoUID], any Error>
            do {
                result = .success(try await run(&journal, onProgress: { _ in }))
            } catch {
                result = .failure(error)
            }
            outcomes.append(.init(seriesUIDs: journal.seriesUIDs, result: result))
        }
        return outcomes
    }

    private func run(
        _ journal: inout SeriesDissolutionJournal,
        onProgress: @escaping @Sendable (SeriesDissolutionProgress) -> Void
    ) async throws -> [PhotoUID] {
        let mainUID = journal.seriesMainUID
        guard running.insert(mainUID).inserted else { throw SeriesDissolutionError.alreadyRunning }
        defer { running.remove(mainUID) }

        // The journal exists before the first remote write, so every later state is recoverable.
        try journalStore.save(journal)

        if journal.phase == .copyingFavorites {
            try await copyPendingFavorites(&journal, onProgress: onProgress)
            // A copy can vanish between its confirmation and now (a crash, then a manual delete). Check the
            // server, copy again once, and only then allow the trash step.
            if try await resetInactiveCopies(&journal) {
                try await copyPendingFavorites(&journal, onProgress: onProgress)
                let stillInactive = try await resetInactiveCopies(&journal)
                guard !stillInactive else { throw SeriesDissolutionError.copyNotConfirmed }
            }
            journal.phase = .trashingSeries
            try journalStore.save(journal)
        }

        onProgress(.init(step: .movingSeriesToTrash, fraction: 0.9))
        // A resumed trash step skips photos that an earlier attempt already moved.
        let remaining = try await remote.activeUIDs(among: journal.seriesUIDs)
        if !remaining.isEmpty {
            try await remote.trashSeries(journal.seriesUIDs.filter(remaining.contains))
        }
        try journalStore.remove(forSeries: mainUID)
        await duplicateChecker.invalidateCachedRemoteState()
        onProgress(.init(step: .movingSeriesToTrash, fraction: 1))
        return journal.favorites.compactMap(\.copyUID)
    }

    /// A retry may carry another selection while no series photo is trashed yet. Confirmed copies of favorites
    /// that stay selected are kept. A confirmed copy of a favorite that the new selection drops stays in the
    /// library: the operation never deletes a standalone photo. Once the trash step started, the recorded
    /// selection is final.
    private static func merging(
        _ favoriteUIDs: [PhotoUID],
        into journal: SeriesDissolutionJournal
    ) -> SeriesDissolutionJournal {
        guard journal.phase == .copyingFavorites else { return journal }
        var merged = journal
        let confirmed = Dictionary(
            journal.favorites.compactMap { favorite in favorite.copyUID.map { (favorite.memberUID, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        merged.favorites = favoriteUIDs.map { .init(memberUID: $0, copyUID: confirmed[$0]) }
        return merged
    }

    private func copyPendingFavorites(
        _ journal: inout SeriesDissolutionJournal,
        onProgress: @escaping @Sendable (SeriesDissolutionProgress) -> Void
    ) async throws {
        let count = journal.favorites.count
        let seriesLinkIDs = Set(journal.seriesUIDs.map(\.nodeID))
        for index in journal.favorites.indices where journal.favorites[index].copyUID == nil {
            try Task.checkCancellation()
            let report: @Sendable (Double) -> Void = { itemFraction in
                onProgress(
                    .init(
                        step: .copyingFavorite(index: index, count: count),
                        fraction: 0.9 * (Double(index) + min(1, max(0, itemFraction))) / Double(count)
                    ))
            }
            report(0)
            journal.favorites[index].copyUID = try await copy(
                journal.favorites[index].memberUID,
                seriesLinkIDs: seriesLinkIDs,
                onProgress: report
            )
            // Persist each confirmation on its own, so a crash repeats at most the favorite in flight.
            try journalStore.save(journal)
            report(1)
        }
    }

    /// Clears the confirmation of every copy that is not an active remote photo. True when any was cleared.
    private func resetInactiveCopies(_ journal: inout SeriesDissolutionJournal) async throws -> Bool {
        let copies = journal.favorites.compactMap(\.copyUID)
        let active = try await remote.activeUIDs(among: copies)
        var didReset = false
        for index in journal.favorites.indices {
            guard let copy = journal.favorites[index].copyUID, !active.contains(copy) else { continue }
            journal.favorites[index].copyUID = nil
            didReset = true
        }
        if didReset { try journalStore.save(journal) }
        return didReset
    }

    /// Downloads the member's original bytes and makes them a standalone photo under the collision rule.
    /// The download takes the first half of the item's progress and the upload takes the second half.
    private func copy(
        _ member: PhotoUID,
        seriesLinkIDs: Set<String>,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> PhotoUID {
        let source = try await remote.source(for: member)
        let workDirectory = tempDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let correctedName = ProtonPhotoNameCorrection.correctedName(for: source.filename)
        let fileURL = workDirectory.appendingPathComponent(correctedName)
        try await remote.writeOriginal(for: member, to: fileURL, onProgress: { onProgress($0 * 0.5) })

        let sha1Digest = try UploadContentSHA1.digest(ofFileAt: fileURL)
        let nameHash = try await duplicateChecker.nameHash(forCorrectedName: correctedName)
        let contentHash = try await duplicateChecker.contentHash(
            forSHA1Hex: UploadContentSHA1.hexString(digest: sha1Digest))
        let decision = SeriesFavoriteCopyPolicy.decide(
            nameHash: nameHash,
            contentHash: contentHash,
            remoteItems: try await duplicateChecker.findDuplicates(nameHashes: [nameHash]),
            seriesLinkIDs: seriesLinkIDs,
            currentClientUID: currentClientUID
        )

        switch decision {
        case .adopt(let remoteLinkID):
            return PhotoUID(volumeID: member.volumeID, nodeID: remoteLinkID)
        case .blockedByForeignDraft:
            throw SeriesDissolutionError.blockedByForeignDraft(source.filename)
        case .upload(let replacingDraft):
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let request = PhotoUploadRequest(
                queueItemID: UUID(),
                cancellationToken: UUID(),
                fileURL: fileURL,
                name: correctedName,
                mediaType: source.mediaType,
                fileSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                captureTime: source.captureTime,
                modificationDate: source.modificationDate,
                // No bursts tag and no main photo: the copy is a plain standalone photo.
                tags: [],
                additionalMetadata: source.additionalMetadata,
                expectedSHA1: sha1Digest,
                overrideExistingDraft: replacingDraft
            )
            let uid = try await uploader.upload(request) { progress in
                if progress.phase == .uploading { onProgress(0.5 + progress.fraction * 0.5) }
            }
            await duplicateChecker.recordUploaded(contentHash: contentHash, remoteLinkID: uid.nodeID)
            return uid
        }
    }
}
