import Foundation

/// The progress of an archive export, weighted by the byte size of each original, so a large video moves the progress
/// further than a small photo. A size that is not known yet counts as the mean of the known sizes; with no known size,
/// every original counts the same. The reported fraction never goes back when a later size changes that estimate.
final class ExportByteProgress: @unchecked Sendable {
    /// The share of one original's weight that its download covers; writing it into the archive covers the rest.
    static let downloadShare = 0.85

    private let lock = NSLock()
    private var sizes: [Int?]
    private var reported = 0.0

    init(itemCount: Int) {
        sizes = Array(repeating: nil, count: itemCount)
    }

    /// Records the byte size of the original at `index`; a missing or empty size stays an estimate.
    func record(size: Int?, at index: Int) {
        lock.withLock {
            guard sizes.indices.contains(index) else { return }
            sizes[index] = size.flatMap { $0 > 0 ? $0 : nil }
        }
    }

    /// The fraction after `completedItems` originals are in the archive and the next one is downloaded to
    /// `currentItemProgress` (0...1). A value that is not a number counts as no progress, so it can never fill the
    /// whole fraction.
    func fraction(completedItems: Int, currentItemProgress: Double) -> Double {
        lock.withLock {
            // Sizes add up as Double, so even the largest file sizes cannot overflow.
            let known = sizes.compactMap { $0.map(Double.init) }
            let estimate = known.isEmpty ? 1 : known.reduce(0, +) / Double(known.count)
            let weights = sizes.map { $0.map(Double.init) ?? estimate }
            let total = weights.reduce(0, +)
            guard total > 0 else { return reported }
            let completed = min(max(completedItems, 0), weights.count)
            let done = weights.prefix(completed).reduce(0, +)
            let downloaded = currentItemProgress.isFinite ? min(max(currentItemProgress, 0), 1) : 0
            let current = completed < weights.count ? weights[completed] * Self.downloadShare * downloaded : 0
            reported = max(reported, min(1, (done + current) / total))
            return reported
        }
    }
}

/// Reads the metadata of every original of an export ahead of its download, so the byte sizes of later originals are
/// known early. It never starts a read more than `readAhead` originals beyond the one the export takes, so a large
/// export never reads all its metadata at once. Each original's metadata is read once; the export takes it from here.
actor ExportMetadataPrefetch {
    /// How many originals beyond the one the export takes may have their metadata read, at most at the same time.
    static let readAhead = 4

    private var delivered: [Int: PhotoMetadata?] = [:]
    private var waiting: [Int: CheckedContinuation<PhotoMetadata?, Never>] = [:]
    /// One more than the highest index the export asked for.
    private var taken = 0
    private var reader: CheckedContinuation<Void, Never>?

    /// The metadata of the original at `index`, or nil when it could not be read.
    func metadata(at index: Int) async -> PhotoMetadata? {
        taken = max(taken, index + 1)
        resumeReader()
        if let metadata = delivered.removeValue(forKey: index) { return metadata }
        return await withCheckedContinuation { waiting[index] = $0 }
    }

    private func deliver(_ metadata: PhotoMetadata?, at index: Int) {
        if let continuation = waiting.removeValue(forKey: index) {
            continuation.resume(returning: metadata)
        } else {
            delivered[index] = .some(metadata)
        }
    }

    private func resumeReader() {
        reader?.resume()
        reader = nil
    }

    /// Waits until the export takes another original or the read is cancelled.
    private func waitForTheExport() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() } else { reader = continuation }
            }
        } onCancel: {
            Task { await self.resumeReader() }
        }
    }

    /// Reads the metadata of the items in order and delivers each result. A failed read delivers nil. After a
    /// cancellation every original that was not read delivers nil without a read, so no waiting export stays
    /// suspended.
    func read(
        _ items: [PhotoItem], from provider: any PhotoMetadataProvider,
        onRead: @escaping @Sendable (Int, PhotoMetadata?) -> Void
    ) async {
        await withTaskGroup(of: (Int, PhotoMetadata?).self) { group in
            var next = 0
            var running = 0
            while next < items.count || running > 0 {
                if Task.isCancelled {
                    while next < items.count {
                        deliver(nil, at: next)
                        next += 1
                    }
                }
                while next < items.count, next < taken + Self.readAhead {
                    let index = next
                    let uid = items[index].uid
                    group.addTask {
                        if Task.isCancelled { return (index, nil) }
                        return (index, try? await provider.metadata(for: uid))
                    }
                    next += 1
                    running += 1
                }
                if running > 0, let (index, metadata) = await group.next() {
                    running -= 1
                    onRead(index, metadata)
                    deliver(metadata, at: index)
                } else if next < items.count {
                    await waitForTheExport()
                }
            }
        }
    }
}
