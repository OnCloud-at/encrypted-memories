import PhotosCore
import ProtonAuth
import XCTest

@testable import ProtonDriveBackend

/// The video viewer classifies the errors of the Drive backend by their type. Retry stays hidden only for a cause
/// that is confirmed permanent, never for an HTTP answer that a new attempt can change.
final class VideoFailureClassificationTests: XCTestCase {
    func testEveryTypedCryptoFailureIsADecryptionFailureWithoutRetry() {
        for failure in [DriveCryptoError.keyRing, .badMessage, .base64] {
            let classified = VideoPlaybackError.classify(failure)
            XCTAssertEqual(classified, .decryptionFailed, "\(failure)")
            XCTAssertFalse(classified.isRetryable, "\(failure) reads the same on every attempt")
        }
    }

    func testMalformedContentKeyDataThatTheCryptoThrowsIsADecryptionFailure() throws {
        let crypto = DriveCrypto(addressKeys: [], signers: [])
        let node = UnlockableKey(armored: "", passphrase: "")
        XCTAssertThrowsError(try crypto.contentSessionKey(contentKeyPacketBase64: "***", node: node)) { error in
            XCTAssertEqual(VideoPlaybackError.classify(error), .decryptionFailed)
        }
    }

    func testTextOfAnotherErrorNeverMakesADecryptionFailure() {
        let text = NSError(
            domain: "Custom", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not decrypt the cache"])
        XCTAssertNotEqual(VideoPlaybackError.classify(text), .decryptionFailed)
        XCTAssertTrue(VideoPlaybackError.classify(text).isRetryable)
    }

    func testAnExpiredStreamReferenceKeepsRetry() {
        for status in [404, 410] {
            let classified = VideoPlaybackError.classify(Self.apiError(status))
            XCTAssertTrue(classified.isRetryable, "HTTP \(status) does not prove that a new attempt fails")
            XCTAssertNotEqual(classified, .streamURLUnavailable, "only a host without a stream provider sets it")
        }
    }

    func testARangeAnswerThatNothingConfirmsKeepsRetry() {
        let classified = VideoPlaybackError.classify(Self.apiError(416))
        XCTAssertEqual(classified, .rangeNotSupported)
        XCTAssertTrue(classified.isRetryable)
    }

    func testTheBackendHTTPErrorsKeepTheirClasses() {
        XCTAssertEqual(VideoPlaybackError.classify(Self.apiError(401)), .authExpired)
        XCTAssertEqual(VideoPlaybackError.classify(Self.apiError(429)), .quotaOrRateLimited)
    }

    /// The error that `DriveSession` throws for a failed request.
    private static func apiError(_ status: Int) -> ProtonAuthError {
        .apiError(code: status, message: "HTTP \(status) for /drive/shares/s/links/l")
    }
}
