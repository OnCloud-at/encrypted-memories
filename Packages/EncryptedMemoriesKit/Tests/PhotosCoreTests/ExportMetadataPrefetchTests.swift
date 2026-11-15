import Foundation
import Testing

@testable import PhotosCore

@Suite struct ExportMetadataPrefetchTests {
    /// The export takes one original after another; no read starts more than four originals beyond it, and each
    /// original's metadata is read once.
    @Test func noReadStartsMoreThanFourOriginalsAheadOfTheExport() async {
        let items = Self.items(20)
        let provider = RecordingMetadataProvider()
        let prefetch = ExportMetadataPrefetch()
        async let reading: Void = prefetch.read(items, from: provider) { _, _ in }
        for index in items.indices {
            #expect(await prefetch.metadata(at: index) != nil)
            try? await Task.sleep(for: .milliseconds(5))
            #expect(provider.highestStarted <= index + 4, "the read ran ahead at \(index): \(provider.highestStarted)")
        }
        await reading
        // Up to four reads run at the same time, so their order may vary.
        #expect(provider.reads.count == items.count && Set(provider.reads) == Set(items.map(\.uid)), "one read each")
    }

    @Test func anEmptyExportReadsNothing() async {
        let provider = RecordingMetadataProvider()
        await ExportMetadataPrefetch().read([], from: provider) { _, _ in }
        #expect(provider.reads.isEmpty)
    }

    @Test func fewerOriginalsThanTheReadAheadAreAllRead() async {
        let items = Self.items(2)
        let provider = RecordingMetadataProvider()
        let prefetch = ExportMetadataPrefetch()
        await prefetch.read(items, from: provider) { _, _ in }
        #expect(await prefetch.metadata(at: 0)?.filename == "0")
        #expect(await prefetch.metadata(at: 1)?.filename == "1")
    }

    @Test func aFailedReadDeliversNoMetadata() async {
        let items = Self.items(3)
        let provider = RecordingMetadataProvider(failing: [items[1].uid])
        let prefetch = ExportMetadataPrefetch()
        await prefetch.read(items, from: provider) { _, _ in }
        #expect(await prefetch.metadata(at: 0) != nil)
        #expect(await prefetch.metadata(at: 1) == nil)
        #expect(await prefetch.metadata(at: 2) != nil)
    }

    /// When the export stops early, the read ends without reading the rest, and an original that was not read
    /// still delivers nil, so nothing waits forever.
    @Test func aCancelledReadDeliversNilForEveryOriginalItDidNotRead() async {
        let items = Self.items(30)
        let provider = RecordingMetadataProvider()
        let prefetch = ExportMetadataPrefetch()
        let reading = Task { await prefetch.read(items, from: provider) { _, _ in } }
        #expect(await prefetch.metadata(at: 0) != nil)
        reading.cancel()
        let late = await Self.within(seconds: 5) { await prefetch.metadata(at: 25) }
        #expect(late == .some(nil), "a waiting export stayed suspended or got metadata")
        #expect(await Self.within(seconds: 5) { await reading.value } != nil, "the cancelled read did not end")
        #expect(provider.reads.count < 10, "the cancelled read kept reading: \(provider.reads.count)")
    }

    private static func items(_ count: Int) -> [PhotoItem] {
        (0..<count).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "volume", nodeID: "\($0)"), captureTime: Date(timeIntervalSince1970: 0),
                mediaType: "image/jpeg")
        }
    }

    /// The value of `operation`, or nil when it takes longer than `seconds`. A suspended operation does not hold the
    /// test, because it runs in its own task.
    private static func within<T: Sendable>(
        seconds: Double, _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        let finish = Once<T?>()
        return await withCheckedContinuation { continuation in
            finish.set(continuation)
            Task { finish.resume(await operation()) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                finish.resume(nil)
            }
        }
    }
}

/// Resumes a continuation once; later results are dropped.
private final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    func set(_ continuation: CheckedContinuation<T, Never>) { lock.withLock { self.continuation = continuation } }

    func resume(_ value: T) {
        let pending = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

/// Answers every metadata read with the node identifier as filename, records the reads and the highest index that
/// started, and fails for the given photos.
private final class RecordingMetadataProvider: PhotoMetadataProvider, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private let failing: Set<PhotoUID>
    private var recorded: [PhotoUID] = []
    private var highest = -1

    init(failing: Set<PhotoUID> = []) {
        self.failing = failing
    }

    var reads: [PhotoUID] { lock.withLock { recorded } }
    var highestStarted: Int { lock.withLock { highest } }

    func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
        lock.withLock {
            recorded.append(uid)
            highest = max(highest, Int(uid.nodeID) ?? -1)
        }
        guard !failing.contains(uid) else { throw Failure() }
        return PhotoMetadata(filename: uid.nodeID, fileSize: 1_000)
    }
}
