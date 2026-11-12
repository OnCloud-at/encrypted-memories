import Foundation
import XCTest

@testable import UploadCore

/// One fresh failure and cancellation signal for an optional-read scenario.
final class CancellationReadFault: @unchecked Sendable {
    enum Scenario: String, CaseIterable {
        case taskDuringReadFailure
        case reportedCancellation
        case reportedCancellationAndTask
        case bridgedNativeCancellation
        case bridgedNativeCancellationAndTask
    }

    let scenario: Scenario
    let error: any Error
    private let lock = NSLock()
    private var reads = 0

    init(_ scenario: Scenario) {
        self.scenario = scenario
        switch scenario {
        case .taskDuringReadFailure:
            error = UploadError.retryableBackend(code: 503, message: "unavailable")
        case .reportedCancellation, .reportedCancellationAndTask:
            error = NSError(
                domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                userInfo: [NSLocalizedDescriptionKey: "read cancelled"])
        case .bridgedNativeCancellation, .bridgedNativeCancellationAndTask:
            error = CancellationError() as NSError
        }
    }

    /// Invoke outside the reader's lock: cancellation handlers may run synchronously.
    func read() {
        lock.withLock { reads += 1 }
        switch scenario {
        case .taskDuringReadFailure, .reportedCancellationAndTask, .bridgedNativeCancellationAndTask:
            withUnsafeCurrentTask { $0?.cancel() }
        case .reportedCancellation, .bridgedNativeCancellation:
            break
        }
    }

    func assertRead(_ context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            lock.withLock { reads }, 1, "\(context): the faulted read was reached once", file: file, line: line)
    }

    func assertCaught(
        _ caught: any Error, context: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        switch scenario {
        case .taskDuringReadFailure:
            XCTAssertTrue(
                caught is CancellationError, "\(context): task cancellation precedes the read failure", file: file,
                line: line)
        case .reportedCancellation, .reportedCancellationAndTask:
            XCTAssertTrue(
                (caught as NSError) === (error as NSError), "\(context): the reported error keeps its identity",
                file: file, line: line)
        case .bridgedNativeCancellation, .bridgedNativeCancellationAndTask:
            XCTAssertTrue(
                error is CancellationError, "\(context): the input box bridges to native cancellation", file: file,
                line: line)
            XCTAssertTrue(
                caught is CancellationError, "\(context): native cancellation stays native", file: file, line: line)
            XCTAssertFalse(
                (caught as NSError) === (error as NSError), "\(context): native cancellation gets a fresh box",
                file: file, line: line)
        }
    }
}
