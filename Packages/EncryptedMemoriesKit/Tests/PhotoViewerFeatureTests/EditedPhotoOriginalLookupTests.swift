import Foundation
import PhotosCore
import XCTest

@testable import PhotoViewerCore

@MainActor
final class EditedPhotoOriginalLookupTests: XCTestCase {
    private let edited = item("edited")
    private let other = item("other")
    private let original = item("original", mediaType: "image/heic")

    // MARK: - Lookup

    func testTheAskStartsOnlyAfterThePhotoStaysForTheDwell() async throws {
        let (lookup, provider, dwell) = make()
        var found: [PhotoUID: PhotoUID] = [:]

        lookup.settled(on: edited, provider: provider) { base, original in found[base.uid] = original.uid }
        try await dwell.nextStart()
        let beforeDwell = await provider.asked
        XCTAssertEqual(beforeDwell, [])
        dwell.release()
        await lookup.pending?.value

        let asked = await provider.asked
        XCTAssertEqual(asked, [edited.uid])
        XCTAssertEqual(found, [edited.uid: original.uid])
        XCTAssertEqual(dwell.requested, [EditedPhotoOriginalLookup.dwell])
    }

    func testPagingOnBeforeTheDwellAsksOnlyForTheNewPage() async throws {
        let (lookup, provider, dwell) = make()

        lookup.settled(on: edited, provider: provider) { _, _ in }
        try await dwell.nextStart()
        lookup.settled(on: other, provider: provider) { _, _ in }
        try await dwell.nextStart()
        dwell.release()
        await lookup.pending?.value

        let asked = await provider.asked
        XCTAssertEqual(asked, [other.uid])
    }

    func testLivePhotosAndSeriesAskNothing() {
        let (lookup, provider, _) = make()
        let live = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "live"), captureTime: .distantPast, mediaType: "image/heic",
            isLivePhoto: true, relatedVideoID: "video")
        let series = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "series"), captureTime: .distantPast, mediaType: "image/heic",
            burstMemberIDs: ["series", "frame"])

        lookup.settled(on: live, provider: provider) { _, _ in }
        XCTAssertNil(lookup.pending)
        lookup.settled(on: series, provider: provider) { _, _ in }
        XCTAssertNil(lookup.pending)
    }

    func testAPhotoWithoutAProviderAsksNothing() {
        let (lookup, _, _) = make()
        lookup.settled(on: edited, provider: nil) { _, _ in }
        XCTAssertNil(lookup.pending)
    }

    func testEachPhotoIsAskedOncePerViewerAlsoWithoutAnOriginal() async throws {
        let (lookup, provider, dwell) = make(hasOriginal: false)

        lookup.settled(on: edited, provider: provider) { _, _ in XCTFail("no original") }
        try await dwell.nextStart()
        dwell.release()
        await lookup.pending?.value
        lookup.settled(on: other, provider: provider) { _, _ in }
        try await dwell.nextStart()
        lookup.settled(on: edited, provider: provider) { _, _ in }

        XCTAssertNil(lookup.pending)
        let asked = await provider.asked
        XCTAssertEqual(asked, [edited.uid])
    }

    func testNothingIsAskedWithoutAdmissionAndThePhotoIsAskedOnceItIsAdmitted() async throws {
        let admission = Admission(false)
        let (lookup, provider, dwell) = make(admits: { admission.value })

        lookup.settled(on: edited, provider: provider) { _, _ in }
        try await dwell.nextStart()
        dwell.release()
        await lookup.pending?.value
        let refused = await provider.asked
        XCTAssertEqual(refused, [])

        admission.value = true
        lookup.settled(on: edited, provider: provider) { _, _ in }
        try await dwell.nextStart()
        dwell.release()
        await lookup.pending?.value
        let admitted = await provider.asked
        XCTAssertEqual(admitted, [edited.uid])
    }

    func testOnlyAnActiveForegroundOnAnUnconstrainedNetworkAdmitsTheAsk() {
        XCTAssertTrue(EditedPhotoOriginalLookup.admits(LibraryRuntimeSnapshot()))
        for opportunity in [LibraryExecutionOpportunity.foregroundInactive, .backgroundPermitted, .suspended] {
            XCTAssertFalse(EditedPhotoOriginalLookup.admits(LibraryRuntimeSnapshot(executionOpportunity: opportunity)))
        }
        XCTAssertFalse(
            EditedPhotoOriginalLookup.admits(LibraryRuntimeSnapshot(network: LibraryNetworkState(isConstrained: true))))
        XCTAssertFalse(
            EditedPhotoOriginalLookup.admits(LibraryRuntimeSnapshot(network: LibraryNetworkState(isReachable: false))))
    }

    // MARK: - State

    func testAPageShowsItsOriginalOnlyAfterTheOriginalIsKnown() {
        var state = EditedPhotoOriginalState()
        state.toggle(edited.uid)
        XCTAssertFalse(state.canShowOriginal(of: edited.uid))
        XCTAssertEqual(state.displayed(edited), edited)

        state.record(original, of: edited.uid)
        XCTAssertTrue(state.canShowOriginal(of: edited.uid))
        XCTAssertEqual(state.displayed(edited), edited)
        state.toggle(edited.uid)
        XCTAssertTrue(state.isShowingOriginal(of: edited.uid))
        XCTAssertEqual(state.displayed(edited), original)
        state.toggle(edited.uid)
        XCTAssertEqual(state.displayed(edited), edited)
    }

    func testAnotherPageShowsTheEditedVersionAgainAndTheControlStays() {
        var state = EditedPhotoOriginalState()
        state.record(original, of: edited.uid)
        state.toggle(edited.uid)

        state.pageChanged(to: edited.uid)
        XCTAssertTrue(state.isShowingOriginal(of: edited.uid))
        state.pageChanged(to: other.uid)
        state.pageChanged(to: edited.uid)
        XCTAssertFalse(state.isShowingOriginal(of: edited.uid))
        XCTAssertTrue(state.canShowOriginal(of: edited.uid))
    }

    func testTheFirstFoundOriginalStays() {
        var state = EditedPhotoOriginalState()
        state.record(original, of: edited.uid)
        state.record(Self.item("later"), of: edited.uid)
        state.toggle(edited.uid)
        XCTAssertEqual(state.displayed(edited), original)
    }

    // MARK: - Helpers

    private static func item(_ nodeID: String, mediaType: String = "image/jpeg") -> PhotoItem {
        PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: nodeID), captureTime: .distantPast, mediaType: mediaType)
    }

    private func make(
        hasOriginal: Bool = true, admits: @escaping @Sendable () -> Bool = { true }
    ) -> (EditedPhotoOriginalLookup, Provider, ManualDwell) {
        let provider = Provider(original: hasOriginal ? original : nil)
        let dwell = ManualDwell()
        let lookup = EditedPhotoOriginalLookup(sleep: { try await dwell.sleep($0) }, admits: admits)
        return (lookup, provider, dwell)
    }

    private actor Provider: EditedPhotoOriginalProviding {
        let original: PhotoItem?
        private(set) var asked: [PhotoUID] = []

        init(original: PhotoItem?) { self.original = original }

        func editedOriginal(of item: PhotoItem) async throws -> PhotoItem? {
            asked.append(item.uid)
            return original
        }
    }

    private final class Admission: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool
        init(_ value: Bool) { stored = value }
        var value: Bool {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// A dwell that ends only when the test releases it, and that reports when a wait starts.
    private final class ManualDwell: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        private var durations: [Duration] = []
        private let starts: AsyncStream<Void>
        private let startContinuation: AsyncStream<Void>.Continuation
        private var startIterator: AsyncStream<Void>.Iterator

        init() {
            (starts, startContinuation) = AsyncStream.makeStream()
            startIterator = starts.makeAsyncIterator()
        }

        var requested: [Duration] { lock.withLock { durations } }

        func sleep(_ duration: Duration) async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let cancelled = lock.withLock { () -> Bool in
                        guard !Task.isCancelled else { return true }
                        waiters[id] = continuation
                        durations.append(duration)
                        return false
                    }
                    if cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        startContinuation.yield()
                    }
                }
            } onCancel: {
                lock.withLock { waiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
            }
        }

        /// Waits until a dwell starts.
        func nextStart() async throws {
            guard await startIterator.next() != nil else { throw CancellationError() }
        }

        func release() {
            let released = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
                defer { waiters = [:] }
                return Array(waiters.values)
            }
            for waiter in released { waiter.resume() }
        }
    }
}
