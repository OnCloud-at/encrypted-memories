import Foundation
import XCTest

@testable import UploadCore

final class SeriesFailurePresentationTests: XCTestCase {
    private let failures: [SeriesDissolutionError] = [
        .invalidSelection, .notOwnLibrary, .alreadyRunning, .blockedByForeignDraft("example.jpg"),
        .copyNotConfirmed, .trashNotConfirmed,
    ]

    func testTypedFailuresKeepTheirExistingReason() {
        for failure in failures {
            XCTAssertEqual(SeriesFailurePresentation(error: failure).message, failure.errorDescription)
        }
    }

    func testUnknownFailureHasAnEmptyReasonAndKeepsRetry() {
        let failure = NSError(
            domain: "ExampleSeriesFailure", code: 503,
            userInfo: [NSLocalizedDescriptionKey: "Example service diagnostic"])
        XCTAssertEqual(SeriesFailurePresentation(error: failure).message, "")
        XCTAssertTrue(SeriesFailurePresentation(error: failure).canRetry)
    }

    func testInvalidSelectionDoesNotOfferRetry() {
        XCTAssertFalse(SeriesFailurePresentation(error: SeriesDissolutionError.invalidSelection).canRetry)
    }

    func testTransientAndAmbiguousFailuresKeepRetry() {
        let retryable: [SeriesDissolutionError] = [
            .notOwnLibrary, .alreadyRunning, .blockedByForeignDraft("example.jpg"),
            .copyNotConfirmed, .trashNotConfirmed,
        ]
        for failure in retryable {
            XCTAssertTrue(SeriesFailurePresentation(error: failure).canRetry)
        }
    }
}
