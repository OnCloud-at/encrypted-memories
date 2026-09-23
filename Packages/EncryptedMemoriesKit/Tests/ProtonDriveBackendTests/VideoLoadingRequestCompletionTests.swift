import Foundation
import Testing

@testable import ProtonDriveBackend

struct VideoLoadingRequestCompletionTests {
    @Test func ownerCloseFinishesOnceButAVCancellationDoesNotFinishAgain() {
        let record = CompletionRecord()
        for _ in 0..<20 {
            let request = VideoLoadingRequestCompletion { record.record($0) }
            request.finish(CancellationError())
            request.finish(nil)
        }
        #expect(record.values.count == 20)
        #expect(record.values.allSatisfy { $0 })
        let cancelledByAV = VideoLoadingRequestCompletion { record.record($0) }
        cancelledByAV.cancel()
        cancelledByAV.finish(CancellationError())
        #expect(record.values.count == 20)
    }
}

private final class CompletionRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []
    var values: [Bool] { lock.withLock { recorded } }
    func record(_ error: Error?) { lock.withLock { recorded.append(error is CancellationError) } }
}
