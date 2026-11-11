import Foundation
import ProtonAuth
import Testing
import UploadCore

@testable import ProtonDriveBackend
@testable import ProtonDriveSDK

@Suite("Proton upload failure characterization")
struct ProtonFailureCharacterizationTests {
    @Test func apiHTTPBoundariesAndNestedErrors() {
        for code in [407, 408, 409, 429, 499, 500, 599, 600] {
            for wrapped in [false, true] {
                let failure = ProtonFailureTestFixture.api(httpCode: code, wrapped: wrapped)
                let mapped = ProtonFailureClassifier.uploadError(from: failure, filename: "a")
                if code == 408 || code == 429 || (500...599).contains(code) {
                    guard case .retryableBackend(let actual, _) = mapped as? UploadCore.UploadError else {
                        Issue.record("Expected retryable backend for HTTP \(code), wrapped: \(wrapped)")
                        continue
                    }
                    #expect(actual == code)
                } else if code == 407 || code == 499 {
                    guard case .serviceRejected(let actual) = mapped as? UploadCore.UploadError else {
                        Issue.record("Expected service rejection for HTTP \(code), wrapped: \(wrapped)")
                        continue
                    }
                    #expect(actual == code)
                } else {
                    guard case .backend = mapped as? UploadCore.UploadError else {
                        Issue.record("Expected backend for HTTP \(code), wrapped: \(wrapped)")
                        continue
                    }
                }
            }
        }
    }

    @Test func urlCancellationRemainsATransportFailure() {
        let mapped = ProtonFailureClassifier.uploadError(from: URLError(.cancelled), filename: "a")
        guard case .transport(let code, _) = mapped as? UploadCore.UploadError else {
            Issue.record("Expected transport failure")
            return
        }
        #expect(code == NSURLErrorCancelled)
    }

    @Test func sdkTransportKeepsAuthenticationAndServiceBoundaries() {
        for type in [0, 2, 7, 11] {
            for code in [400, 408, 429, 500, 599, 600] {
                var proto = Proton_Drive_Sdk_Error.with {
                    $0.type = "fixture-transport"
                    $0.domain = .transport
                    $0.message = "fixture"
                    $0.primaryCode = Int64(type)
                    $0.secondaryCode = Int64(code)
                }
                for wrapped in [false, true] {
                    if wrapped {
                        proto = ProtonFailureTestFixture.wrapped(proto)
                    }
                    let mapped =
                        ProtonFailureClassifier.uploadError(
                            from: ProtonDriveSDKError(protoError: proto), filename: "a") as? UploadCore.UploadError
                    if code == 408 || code == 429 || (500...599).contains(code) {
                        guard case .retryableBackend(let actual, _) = mapped else {
                            Issue.record("Expected retryable HTTP \(code), type \(type), wrapped \(wrapped)")
                            continue
                        }
                        #expect(actual == code)
                    } else if type == 7 || type == 11 {
                        guard case .backend = mapped else {
                            Issue.record("Expected backend HTTP \(code), type \(type), wrapped \(wrapped)")
                            continue
                        }
                    } else {
                        guard case .transport(let actual, _) = mapped else {
                            Issue.record("Expected transport HTTP \(code), type \(type), wrapped \(wrapped)")
                            continue
                        }
                        #expect(actual == NSURLErrorNetworkConnectionLost)
                    }
                }
            }
        }
    }

    @Test func relatedTransferSignalPreservesFirstRecognizedSDKError() {
        let cancelled = ProtonFailureTestFixture.cancelled
        let network = Proton_Drive_Sdk_Error.with {
            $0.type = NSURLErrorDomain
            $0.domain = .network
            $0.message = "fixture"
            $0.primaryCode = Int64(NSURLErrorTimedOut)
            $0.innerError = cancelled
        }
        let outer = ProtonFailureTestFixture.wrapped(network)
        let result = ProtonFailureClassifier.relatedTransferSignal(ProtonDriveSDKError(protoError: outer))
        #expect((result as? URLError)?.code == .timedOut)
        #expect(
            ProtonFailureClassifier.relatedTransferSignal(ProtonDriveSDKError(protoError: cancelled))
                is CancellationError)
        #expect(ProtonFailureClassifier.relatedTransferSignal(NSError(domain: "foreign", code: -999)) == nil)
    }

    @Test func sdkCancellationSearchesPastNonCancelledNetworkErrors() {
        let cancelled = ProtonFailureTestFixture.cancelled
        let outer = Proton_Drive_Sdk_Error.with {
            $0.type = NSURLErrorDomain
            $0.domain = .network
            $0.message = "fixture"
            $0.primaryCode = Int64(NSURLErrorTimedOut)
            $0.innerError = cancelled
        }
        #expect(ProtonFailureClassifier.containsSDKCancellation(ProtonDriveSDKError(protoError: outer)))
        let urlCancelled = Proton_Drive_Sdk_Error.with {
            $0.type = NSURLErrorDomain
            $0.domain = .network
            $0.message = "fixture"
            $0.primaryCode = Int64(NSURLErrorCancelled)
        }
        #expect(ProtonFailureClassifier.containsSDKCancellation(ProtonDriveSDKError(protoError: urlCancelled)))
        #expect(!ProtonFailureClassifier.containsSDKCancellation(NSError(domain: "foreign", code: -999)))
    }

    @Test func uploadCancellationChecksOnlyTheSDKRoot() {
        let cancelled = ProtonFailureTestFixture.cancelled
        let outer = ProtonFailureTestFixture.wrapped(cancelled)
        #expect(ProtonFailureClassifier.isSDKCancellation(ProtonDriveSDKError(protoError: cancelled)))
        #expect(!ProtonFailureClassifier.isSDKCancellation(ProtonDriveSDKError(protoError: outer)))
        #expect(!ProtonFailureClassifier.isSDKCancellation(CancellationError()))
    }

    @Test func batchFinalityKeepsItsExistingHTTPBoundaries() {
        for code in [399, 400, 401, 403, 408, 409, 429, 499, 500] {
            let error = ProtonAuthError.apiError(code: code, message: "fixture")
            #expect(
                ProtonFailureClassifier.isFinal(error)
                    == ((400...499).contains(code) && code != 408 && code != 429))
        }
        #expect(!ProtonFailureClassifier.isFinal(URLError(.timedOut)))
    }

    @Test func libraryOpenUnauthorizedMatchesTheExistingPolicy() {
        for code in [400, 401, 403, 408, 409, 429, 500] {
            let error = ProtonAuthError.apiError(code: code, message: "fixture")
            #expect(ProtonFailureClassifier.isUnauthorized(error) == (code == 401))
            #expect(LibraryOpenFailurePermanence.isPermanent(error) == (code == 401))
        }
        #expect(!ProtonFailureClassifier.isUnauthorized(URLError(.userAuthenticationRequired)))
    }

    @Test func pendingEffectKeepsFinalAndRetryableHTTPOutcomes() async {
        for code in [400, 401, 403, 408, 409, 429, 499, 500] {
            let result = await ProtonPendingRemoteEffects.run {
                throw ProtonAuthError.apiError(code: code, message: "fixture")
            }
            let final = (400...499).contains(code) && code != 408 && code != 429
            #expect(result == (final ? .permanentFailure : .retry))
        }
    }

    @Test func classifierUploadMappingKeepsURLAndForeignErrorsDistinct() {
        for code in [URLError.Code.timedOut, .cancelled] {
            guard
                case .transport(let actual, _)? =
                    ProtonFailureClassifier.uploadError(from: URLError(code), filename: "a") as? UploadCore.UploadError
            else {
                Issue.record("Expected URL transport failure")
                continue
            }
            #expect(actual == code.rawValue)
        }
        guard
            case .backend? =
                ProtonFailureClassifier.uploadError(from: NSError(domain: "foreign", code: -999), filename: "a")
                as? UploadCore.UploadError
        else {
            Issue.record("Expected foreign error to remain a backend failure")
            return
        }
        #expect(
            ProtonFailureClassifier.uploadFileSystemError(.notFound, filename: "a") as? UploadCore.UploadError
                == .fileMissing("a"))
        #expect(ProtonFailureClassifier.uploadFileSystemError(.unknown, filename: "a") == nil)
    }

    @Test func sdkFilesystemAndSocketFailuresKeepTheirUploadDomains() {
        for (code, expected) in [
            (POSIXErrorCode.ENOENT, UploadCore.UploadError.fileMissing("a")),
            (.EACCES, .permissionDenied("a")),
        ] {
            let proto = Proton_Drive_Sdk_Error.from(nsError: POSIXError(code) as NSError)
            let mapped = ProtonFailureClassifier.uploadError(
                from: ProtonDriveSDKError(protoError: proto), filename: "a")
            #expect(mapped as? UploadCore.UploadError == expected)
        }
        let full = Proton_Drive_Sdk_Error.from(nsError: POSIXError(.ENOSPC) as NSError)
        #expect(
            ProtonFailureClassifier.uploadError(from: ProtonDriveSDKError(protoError: full), filename: "a")
                as? BackupTempFileStore.BackupTempFileError == .diskBudgetExceeded)
        let socket = Proton_Drive_Sdk_Error.with {
            $0.type = "fixture-socket"
            $0.domain = .network
            $0.message = "fixture"
            $0.primaryCode = 42
            $0.secondaryCode = -1
        }
        guard
            case .transport(let code, _)? =
                ProtonFailureClassifier.uploadError(from: ProtonDriveSDKError(protoError: socket), filename: "a")
                as? UploadCore.UploadError
        else {
            Issue.record("Expected socket transport failure")
            return
        }
        #expect(code == NSURLErrorNetworkConnectionLost)
    }

    @Test func deviceRootOnlyReadsTheOuterSDKAPIStatus() {
        let api = ProtonFailureTestFixture.api(httpCode: 404, wrapped: false)
        let outer = ProtonFailureTestFixture.api(httpCode: 404, wrapped: true)
        #expect(ProtonFailureClassifier.rootAPIHTTPCode(api) == 404)
        #expect(ProtonFailureClassifier.rootAPIHTTPCode(outer) == nil)
        #expect(ProtonFailureClassifier.rootAPIHTTPCode(NSError(domain: "foreign", code: 404)) == nil)
    }

    @Test func sdkFilesystemLookupFindsNestedStoragePressure() {
        let full = Proton_Drive_Sdk_Error.from(nsError: POSIXError(.ENOSPC) as NSError)
        let outer = ProtonFailureTestFixture.wrapped(full)
        #expect(ProtonFailureClassifier.fileSystemError(ProtonDriveSDKError(protoError: outer)) == .outOfSpace)
        #expect(ProtonFailureClassifier.fileSystemError(POSIXError(.ENOSPC)) == nil)
    }
}
