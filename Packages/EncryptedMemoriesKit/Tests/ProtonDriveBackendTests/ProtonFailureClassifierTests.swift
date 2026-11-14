import Foundation
import PhotosCore
import Testing
import UploadCore

@testable import ProtonDriveBackend
@testable import ProtonDriveSDK

@Suite struct ProtonFailureClassifierTests {
    @Test(arguments: [
        (200, ProtonFailureClassifier.HTTPStatus.unproven), (304, .unproven), (399, .unproven),
        (400, .serviceRejection), (401, .unproven), (403, .unproven), (404, .serviceRejection),
        (408, .temporary), (409, .unproven), (410, .serviceRejection), (413, .serviceRejection),
        (422, .serviceRejection),
        (423, .temporary),
        (425, .temporary),
        (429, .temporary), (499, .serviceRejection), (500, .temporary), (503, .temporary), (599, .temporary),
        (600, .unproven),
    ])
    func everyStatusHasOneMeaning(code: Int, expected: ProtonFailureClassifier.HTTPStatus) {
        #expect(ProtonFailureClassifier.httpStatus(code) == expected)
    }

    private static func sdkError(httpCode: Int?, wrapped: Bool, httpTransport: Bool = false) -> ProtonDriveSDKError {
        var proto = Proton_Drive_Sdk_Error.with {
            $0.type = "fixture-api"
            $0.domain = httpTransport ? .transport : .api
            $0.message = "PRIVATE SERVER TEXT"
            $0.primaryCode =
                httpTransport
                ? Int64(ProtonDriveSDKHTTPNetworkError.HttpErrorType.userAuthenticationError.rawValue) : 2501
            if let httpCode { $0.secondaryCode = Int64(httpCode) }
        }
        if wrapped {
            let inner = proto
            proto = Proton_Drive_Sdk_Error.with {
                $0.type = "fixture-outer"
                $0.domain = .undefined
                $0.message = "PRIVATE OUTER TEXT"
                $0.innerError = inner
            }
        }
        return ProtonDriveSDKError(protoError: proto)
    }

    @Test(arguments: [false, true])
    func onlyAProvenAPIRejectionBecomesAServiceRejection(wrapped: Bool) {
        func mapped(_ code: Int?) -> UploadCore.UploadError? {
            DriveSDKBridge.uploadError(from: Self.sdkError(httpCode: code, wrapped: wrapped), filename: "a.jpg")
                as? UploadCore.UploadError
        }
        #expect(mapped(422) == .serviceRejected(code: 422))
        #expect(mapped(400) == .serviceRejected(code: 400))
        for temporary in [408, 423, 425, 429, 503] {
            guard case .retryableBackend(let code, _)? = mapped(temporary), code == temporary else {
                Issue.record("HTTP \(temporary) must stay a temporary failure")
                continue
            }
        }
        for unproven in [401, 403, 409, nil] {
            guard case .backend? = mapped(unproven) else {
                Issue.record("HTTP \(String(describing: unproven)) must stay a backend failure")
                continue
            }
        }
    }

    @Test(arguments: [false, true])
    func transport423And425AreTemporary(wrapped: Bool) {
        for status in [423, 425] {
            let failure = Self.sdkError(httpCode: status, wrapped: wrapped, httpTransport: true)
            #expect(failure.underlyingHTTPNetworkError?.httpCode == status)
            let mapped = DriveSDKBridge.uploadError(from: failure, filename: "a.jpg") as? UploadCore.UploadError
            guard case .retryableBackend(let code, _)? = mapped else {
                Issue.record("HTTP transport \(status) must be temporary")
                continue
            }
            #expect(code == status)
        }
    }

    @Test func aServiceRejectionNeverShowsTheServerText() {
        let error = DriveSDKBridge.uploadError(from: Self.sdkError(httpCode: 422, wrapped: false), filename: "a.jpg")
        let description = (error as? LocalizedError)?.errorDescription ?? ""
        #expect(description == L10n.string("backup.fail_reason_generic"))
        #expect(!description.contains("PRIVATE"))
    }
}
