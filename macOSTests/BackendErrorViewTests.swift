import SwiftUI
import XCTest

@MainActor
final class BackendErrorViewTests: XCTestCase {
    func testBootFailureUsesNativeUnavailableView() {
        for isRetryable in [false, true] {
            let view = failure(message: "Fixture failure", isRetryable: isRetryable)
            XCTAssertTrue(String(reflecting: type(of: view.body)).contains("SwiftUI.ContentUnavailableView<"))
        }
    }

    func testFailureMessageDrawsForBothRetryStates() throws {
        for isRetryable in [false, true] {
            let withoutMessage = try RenderedInk.pixels(failure(message: "", isRetryable: isRetryable))
            let withMessage = try RenderedInk.pixels(
                failure(message: "The fixture library could not open.", isRetryable: isRetryable))
            XCTAssertGreaterThan(withMessage, withoutMessage)
        }
    }

    func testLongFailureMessageDrawsMoreThanShortMessage() throws {
        for isRetryable in [false, true] {
            let short = try RenderedInk.pixels(failure(message: "Short", isRetryable: isRetryable))
            let long = try RenderedInk.pixels(
                failure(
                    message:
                        "The fixture library could not open. The saved account could not read its library metadata.",
                    isRetryable: isRetryable))
            XCTAssertGreaterThan(long, short)
        }
    }

    private func failure(message: String, isRetryable: Bool) -> BackendErrorView {
        BackendErrorView(message: message, isRetryable: isRetryable, retry: {}, signOut: {})
    }
}
