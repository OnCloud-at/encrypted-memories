import Foundation
import ProtonAuth
import ProtonDriveSDK
import UploadCore

/// Shares Proton failure classification across backend call sites.
enum ProtonFailureClassifier {
    /// What an HTTP status of a Proton answer proves about a repeat of the same request.
    enum HTTPStatus: Equatable, Sendable {
        /// A later attempt can get another answer: 408, 423, 425, 429 and 5xx.
        case temporary
        /// Proton refused the request itself, so a repeat gets the same answer: every 4xx other than 401, 403, 408,
        /// 409, 423, 425 and 429. This list is an assumption from HTTP semantics: 401 and 403 depend on the session
        /// and its rights, and 409 on state that can change. No Proton server documentation confirms it.
        case serviceRejection
        /// Any other code proves neither.
        case unproven
    }

    static func httpStatus(_ code: Int) -> HTTPStatus {
        switch code {
        case 408, 423, 425, 429, 500...599: .temporary
        case 401, 403, 409: .unproven
        case 400...499: .serviceRejection
        default: .unproven
        }
    }

    /// Related-file transfer stops at the first SDK cancellation or URL error in the chain.
    static func relatedTransferSignal(_ error: any Error) -> (any Error)? {
        firstSDKValue(error) { current -> (any Error)? in
            if current.domain == .successfulCancellation { return CancellationError() }
            if current.domain == .network, current.type == NSURLErrorDomain, let code = current.primaryCode {
                return URLError(URLError.Code(rawValue: code))
            }
            return nil
        }
    }

    /// Dedupe searches the whole chain for cancellation, even past a different URL error.
    static func containsSDKCancellation(_ error: any Error) -> Bool {
        firstSDKValue(error) { current -> Bool? in
            if current.domain == .successfulCancellation
                || (current.domain == .network && current.type == NSURLErrorDomain
                    && current.primaryCode == NSURLErrorCancelled)
            {
                return true
            }
            return nil
        } ?? false
    }

    /// Every 4xx except 408 and 429 is final for batch writes and pending remote effects.
    static func isFinal(_ error: any Error) -> Bool {
        guard case .apiError(let code, _)? = error as? ProtonAuthError else { return false }
        return (400...499).contains(code) && httpStatus(code) != .temporary
    }

    /// Only the outer SDK error counts as cancellation.
    static func isSDKCancellation(_ error: any Error) -> Bool {
        (error as? ProtonDriveSDKError)?.domain == .successfulCancellation
    }

    static func isUnauthorized(_ error: any Error) -> Bool {
        guard case .apiError(let code, _)? = error as? ProtonAuthError else { return false }
        return code == 401
    }

    /// Device enumeration only accepts a status from the outer SDK API error.
    static func rootAPIHTTPCode(_ error: any Error) -> Int? {
        (error as? ProtonDriveSDKError)?.asAPINetworkError?.httpCode
    }

    static func fileSystemError(_ error: any Error) -> ProtonDriveSDKError.FileSystemErrorCode? {
        (error as? ProtonDriveSDKError)?.underlyingFileSystemErrorCode
    }

    /// Preserve the SDK's typed failure domain at the Core boundary. URL/socket failures retry as network problems.
    /// HTTP 408, 423, 425, 429 and 5xx retry as temporary service failures. A proven API refusal becomes serviceRejected
    /// without the server text; other API answers keep backend(message).
    static func uploadError(from error: any Error, filename: String) -> any Error {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return UploadCore.UploadError.transport(code: nsError.code, message: message)
        }
        guard let sdkError = error as? ProtonDriveSDKError else {
            return UploadCore.UploadError.backend(message)
        }
        if let fileSystemError = fileSystemError(error),
            let mapped = uploadFileSystemError(fileSystemError, filename: filename)
        {
            return mapped
        }
        if sdkError.underlyingSocketNetworkError != nil {
            return UploadCore.UploadError.transport(code: NSURLErrorNetworkConnectionLost, message: message)
        }
        if let transport = sdkError.underlyingHTTPNetworkError {
            if let code = transport.httpCode, httpStatus(code) == .temporary {
                return UploadCore.UploadError.retryableBackend(code: code, message: message)
            }
            switch transport.errorType {
            case .userAuthenticationError, .configurationLimitExceeded:
                return UploadCore.UploadError.backend(message)
            default:
                return UploadCore.UploadError.transport(code: NSURLErrorNetworkConnectionLost, message: message)
            }
        }
        if let code = sdkError.underlyingAPINetworkError?.httpCode {
            switch httpStatus(code) {
            case .temporary: return UploadCore.UploadError.retryableBackend(code: code, message: message)
            case .serviceRejection: return UploadCore.UploadError.serviceRejected(code: code)
            case .unproven: break
            }
        }
        return UploadCore.UploadError.backend(message)
    }

    /// Maps SDK 0.25's normalized local-file failures into the existing queue domains. In particular, low disk
    /// space reuses the backup runner's durable resource-pressure policy.
    static func uploadFileSystemError(
        _ code: ProtonDriveSDKError.FileSystemErrorCode, filename: String
    ) -> (any Error)? {
        switch code {
        case .notFound: UploadCore.UploadError.fileMissing(filename)
        case .permissionDenied: UploadCore.UploadError.permissionDenied(filename)
        case .outOfSpace: BackupTempFileStore.BackupTempFileError.diskBudgetExceeded
        case .unknown: nil
        }
    }

    private static func firstSDKValue<Value>(
        _ error: any Error, map: (ProtonDriveSDKError) -> Value?
    ) -> Value? {
        var sdkError = error as? ProtonDriveSDKError
        while let current = sdkError {
            if let value = map(current) { return value }
            sdkError = current.innerError
        }
        return nil
    }
}
