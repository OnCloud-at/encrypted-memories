import Foundation

enum MLModelRequestIdentity {
    static let headerName = "X-EncryptedMemories-App-ID"

    static var appIdentifier: String {
        Bundle.main.bundleIdentifier ?? "at.oncloud.encryptedmemories.unknown"
    }

    static func apply(to request: inout URLRequest) {
        request.setValue(appIdentifier, forHTTPHeaderField: headerName)
    }

    static func isExactEndpoint(_ candidate: URL?, expected: URL?) -> Bool {
        guard let candidate, let expected else { return false }
        return candidate.scheme?.lowercased() == expected.scheme?.lowercased()
            && candidate.host?.lowercased() == expected.host?.lowercased()
            && candidate.port == expected.port
            && candidate.path == expected.path
            && candidate.user == expected.user
            && candidate.password == expected.password
            && candidate.query == expected.query
            && candidate.fragment == expected.fragment
    }
}

final class MLModelNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = MLModelNoRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
