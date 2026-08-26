import Foundation
import Testing

@testable import MLSearchAppleAdapter
@testable import MLSearchCore

@Suite struct MLRuntimeFailureTranslationTests {
    private struct UnknownError: Error {}

    @Test func translatesEveryAppleRuntimeErrorFamily() {
        let cases: [(Error, MLRuntimeFailureCategory)] = [
            (AppleSmartSearchRuntimeError.noModelArtifact, .missingModel),
            (AppleSmartSearchRuntimeError.unsupportedTokenizer("test"), .incompatibleModel),
            (AppleSmartSearchRuntimeError.unsupportedPreprocessing("test"), .incompatibleModel),
            (
                AppleSmartSearchRuntimeError.tokenizerContractMismatch(expected: 77, actual: 64),
                .invalidStaticInputContract
            ),
            (AppleSmartSearchRuntimeError.invalidStaticInputContract("ids"), .invalidStaticInputContract),
            (AppleSmartSearchRuntimeError.invalidOutputSchema("embedding"), .invalidOutputSchema),
        ]

        for (error, category) in cases {
            #expect(AppleSmartSearchRuntimeFailureTranslator.translate(error).category == category)
        }
    }

    @Test func translatesEveryDualEncoderErrorFamily() {
        let cases: [(CoreMLDualEncoderError, MLRuntimeFailureCategory)] = [
            (.descriptorMismatch, .incompatibleModel),
            (.invalidModelSchema("legacy"), .incompatibleModel),
            (.invalidStaticInputContract("input_ids"), .invalidStaticInputContract),
            (.invalidOutputSchema("embedding"), .invalidOutputSchema),
            (.invalidEmbedding, .invalidOutputSchema),
        ]

        for (error, category) in cases {
            #expect(AppleSmartSearchRuntimeFailureTranslator.translate(error).category == category)
        }
    }

    @Test func translatesNetworkTemporaryResourceAndUnknownErrors() {
        #expect(
            AppleSmartSearchRuntimeFailureTranslator.translate(URLError(.notConnectedToInternet)).category
                == .network
        )
        #expect(
            AppleSmartSearchRuntimeFailureTranslator.translate(
                NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOSPC.rawValue))
            ).category == .temporaryResource
        )
        #expect(
            AppleSmartSearchRuntimeFailureTranslator.translate(UnknownError()).category == .unknown
        )
        #expect(
            AppleSmartSearchRuntimeFailureTranslator.translate(UnknownError()).isRetryable
        )
    }

    @Test func passesThroughAlreadyTypedCoreFailure() {
        let original = MLRuntimeFailure(
            category: .temporaryResource,
            debugDescription: "typed"
        )
        let translated = AppleSmartSearchRuntimeFailureTranslator.translate(original)
        #expect(translated == original)
    }

    @Test func usesOnlySdkDocumentedCoreMLRetryableCodes() {
        let networkCodes = [8, 10]
        for code in networkCodes {
            let error = NSError(domain: "com.apple.CoreML", code: code)
            #expect(AppleSmartSearchRuntimeFailureTranslator.translate(error).category == .network)
        }
        let cancelled = NSError(domain: "com.apple.CoreML", code: 11)
        #expect(
            AppleSmartSearchRuntimeFailureTranslator.translate(cancelled).category
                == .retryableRuntimeState
        )

        // Generic and I/O errors are intentionally ambiguous. They retain safe retry behavior.
        for code in [0, 3, 9, 42] {
            let error = NSError(domain: "com.apple.CoreML", code: code)
            let translated = AppleSmartSearchRuntimeFailureTranslator.translate(error)
            #expect(translated.category == .unknown)
            #expect(translated.isRetryable)
        }
    }
}
