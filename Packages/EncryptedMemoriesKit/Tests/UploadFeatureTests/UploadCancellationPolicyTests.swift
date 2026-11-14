import Foundation
import XCTest

@testable import UploadCore

final class UploadCancellationPolicyTests: XCTestCase {
    func testDefaultPolicyKeepsCancellationPriority() async {
        await assertCancellationPolicy(preservesNativeBox: false) { error in
            try UploadError.rethrowIfCancelled(error)
        }
    }

    func testOriginalPolicyKeepsNativeBoxesAndReportedCancellationPriority() async {
        await assertCancellationPolicy(preservesNativeBox: true) { error in
            try UploadError.rethrowIfCancelled(error, nativeCancellation: .preserveOriginal)
        }
    }

    private func assertCancellationPolicy(
        preservesNativeBox: Bool, rethrow: @escaping @Sendable (any Error) throws -> Void
    ) async {
        for scenario in CancellationReadFault.Scenario.allCases {
            let fault = CancellationReadFault(scenario)
            let context = "\(preservesNativeBox ? "original" : "default")/\(scenario.rawValue)"
            let operation = Task {
                fault.read()
                do {
                    try rethrow(fault.error)
                    XCTFail("\(context): cancellation must propagate")
                } catch {
                    fault.assertCaught(error, context: context, preservesNativeBox: preservesNativeBox)
                }
            }
            await operation.value
            fault.assertRead(context)
            XCTAssertFalse(Task.isCancelled, "Each scenario cancels only its own task")
        }
    }

    func testOrdinaryErrorsAndPlainNativeLookalikesReturn() {
        let native = CancellationError() as NSError
        let lookalike = NSError(domain: native.domain, code: native.code)
        XCTAssertFalse(lookalike is CancellationError)
        XCTAssertFalse(UploadError.isCancellation(lookalike))
        for error in [NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError), lookalike] {
            XCTAssertNoThrow(try UploadError.rethrowIfCancelled(error))
            XCTAssertNoThrow(try UploadError.rethrowIfCancelled(error, nativeCancellation: .preserveOriginal))
        }
    }
}
