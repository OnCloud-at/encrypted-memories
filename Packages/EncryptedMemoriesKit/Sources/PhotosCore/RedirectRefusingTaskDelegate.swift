import Foundation

/// Declines every HTTP redirect, so a request that carries credentials or the app identity is never replayed to a
/// host that the caller's trust check did not validate. `URLSession` then delivers the 3xx response as it is. The
/// delegate holds no state, so one shared instance serves every request.
public final class RedirectRefusingTaskDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    public static let shared = RedirectRefusingTaskDelegate()

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
