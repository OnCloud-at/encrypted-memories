import Foundation

@testable import UploadCore

/// Forwards every call to a real catalog store and counts the pages that it serves. A test can also make
/// `isOperational()` answer false from a chosen call on.
final class PageCatalog: PhotoLibraryCatalogStore, @unchecked Sendable {
    let inner: PhotoLibraryCatalogManifestStore
    private let lock = NSLock()
    private var metrics = (pages: 0, maximum: 0, main: false)
    private var operationalCalls = 0
    private var operationalFailure: Int?
    var pages: Int { lock.withLock { metrics.pages } }
    var maximumPageSize: Int { lock.withLock { metrics.maximum } }
    var usedMainThread: Bool { lock.withLock { metrics.main } }
    init(inner: PhotoLibraryCatalogManifestStore) { self.inner = inner }
    func presentEntries(afterLocalIdentifier: String?, limit: Int) -> PhotoLibraryCatalogPage? {
        let page = inner.presentEntries(afterLocalIdentifier: afterLocalIdentifier, limit: limit)
        lock.withLock {
            metrics.pages += 1
            if let page { metrics.maximum = max(metrics.maximum, page.entries.count) }
            metrics.main = metrics.main || Thread.isMainThread
        }
        return page
    }
    func presence(for ids: [String]) -> PhotoLibraryCatalogPresence { inner.presence(for: ids) }
    /// From this call of `isOperational()` on (1-based) the catalog answers false, whatever the store says.
    var failsOperationalFromCall: Int? {
        get { lock.withLock { operationalFailure } }
        set { lock.withLock { operationalFailure = newValue } }
    }
    func isOperational() -> Bool {
        let failing = lock.withLock {
            operationalCalls += 1
            return operationalFailure.map { operationalCalls >= $0 } ?? false
        }
        return !failing && inner.isOperational()
    }
    func reconciledMissingSourceGeneration() -> Int64? { inner.reconciledMissingSourceGeneration() }
    func missingSourceSweepProgress() -> PhotoLibraryMissingSourceSweepProgress? {
        inner.missingSourceSweepProgress()
    }
    func recordMissingSourceSweepProgress(_ p: PhotoLibraryMissingSourceSweepProgress) -> Bool {
        inner.recordMissingSourceSweepProgress(p)
    }
    func completeMissingSourceSweep(generation: Int64) -> Bool {
        inner.completeMissingSourceSweep(generation: generation)
    }
    func entry(for id: String) throws -> PhotoLibraryCatalogEntry? { try inner.entry(for: id) }
    func classifyBatch(_ e: [PhotoLibraryCatalogEntry]) -> [PhotoLibraryCatalogChange] { inner.classifyBatch(e) }
    func upsertBatch(_ e: [PhotoLibraryCatalogEntry]) -> Bool { inner.upsertBatch(e) }
    func markRemoved(_ ids: [String], removedAt: Date) -> PhotoLibraryCatalogMutationResult {
        inner.markRemoved(ids, removedAt: removedAt)
    }
    func sweepRemoved(notSeenAfter: Date, removedAt: Date) -> PhotoLibraryCatalogMutationResult {
        inner.sweepRemoved(notSeenAfter: notSeenAfter, removedAt: removedAt)
    }
    func snapshot() -> PhotoLibraryCatalogSnapshot? { inner.snapshot() }
    func count() -> Int? { inner.count() }
    func hasCompletedFullScan() -> Bool { inner.hasCompletedFullScan() }
    func markFullScanOwed() -> Bool { inner.markFullScanOwed() }
    func synchronizeToDisk() -> Bool { inner.synchronizeToDisk() }
    func fullScanProgress() throws -> PhotoLibraryFullScanProgress? { try inner.fullScanProgress() }
    func recordFullScanProgress(_ p: PhotoLibraryFullScanProgress) -> Bool { inner.recordFullScanProgress(p) }
    func completeFullScan() -> Bool { inner.completeFullScan() }
    func clearFullScanResumePoint() -> Bool { inner.clearFullScanResumePoint() }
    func hasReconciledLateRenders() -> Bool { inner.hasReconciledLateRenders() }
    func markLateRendersReconciled() -> Bool { inner.markLateRendersReconciled() }
    func lateRenderSweepResumePoint() -> String? { inner.lateRenderSweepResumePoint() }
    func recordLateRenderSweepResumePoint(_ id: String) -> Bool { inner.recordLateRenderSweepResumePoint(id) }
    func beginFullScanSnapshot(epochStart: Date) -> Bool { inner.beginFullScanSnapshot(epochStart: epochStart) }
    func appendFullScanSnapshotIdentifiers(_ ids: [String]) -> Bool { inner.appendFullScanSnapshotIdentifiers(ids) }
    func finishFullScanSnapshot() -> Bool { inner.finishFullScanSnapshot() }
    func fullScanSnapshotIdentifiers(startingAt: Int, limit: Int) -> [String]? {
        inner.fullScanSnapshotIdentifiers(startingAt: startingAt, limit: limit)
    }
    func fullScanSnapshotCount() -> Int? { inner.fullScanSnapshotCount() }
}
