@testable import ProtonDriveSDK

enum ProtonFailureTestFixture {
    /// An API answer, or with `httpTransport` an HTTP transport failure that carries the status code.
    static func api(httpCode: Int?, wrapped: Bool, httpTransport: Bool = false) -> ProtonDriveSDKError {
        let proto = Proton_Drive_Sdk_Error.with {
            $0.type = "fixture-api"
            $0.domain = httpTransport ? .transport : .api
            $0.message = "PRIVATE SERVER TEXT"
            $0.primaryCode =
                httpTransport
                ? Int64(ProtonDriveSDKHTTPNetworkError.HttpErrorType.userAuthenticationError.rawValue) : 2501
            if let httpCode { $0.secondaryCode = Int64(httpCode) }
        }
        return ProtonDriveSDKError(protoError: wrapped ? self.wrapped(proto) : proto)
    }

    static func wrapped(
        _ inner: Proton_Drive_Sdk_Error, domain: Proton_Drive_Sdk_ErrorDomain = .undefined
    ) -> Proton_Drive_Sdk_Error {
        Proton_Drive_Sdk_Error.with {
            $0.type = "fixture-outer"
            $0.domain = domain
            $0.message = "PRIVATE OUTER TEXT"
            $0.innerError = inner
        }
    }

    static var cancelled: Proton_Drive_Sdk_Error {
        Proton_Drive_Sdk_Error.with {
            $0.type = "fixture-cancel"
            $0.domain = .successfulCancellation
            $0.message = "fixture"
        }
    }
}
