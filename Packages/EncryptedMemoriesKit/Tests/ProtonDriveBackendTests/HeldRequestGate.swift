import Foundation

/// Holds the answer of the requests that `hold(whenRequest:)` matches until `release(status:body:)`, so a test can
/// run other work while one request of the code under test is still on its way. Every other request falls through to
/// the next protocol of the session, usually `StubURLProtocol`. The state is static because URLSession creates the
/// protocol itself; suites that use it are nested in `DriveSessionStubSuite`, which runs serialized. It holds one
/// request at a time: a second matching request while one is held is not supported.
final class HeldRequestGate: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var matcher: (@Sendable (URLRequest) -> Bool)?
    nonisolated(unsafe) private static var holding: HeldRequestGate?

    static var isHolding: Bool { lock.withLock { holding != nil } }

    /// Releases nothing; a held request ends when its task is cancelled.
    static func reset() {
        lock.withLock {
            matcher = nil
            holding = nil
        }
    }

    /// Holds every later request for which `matches` is true. The match stays until `reset()`.
    static func hold(whenRequest matches: @escaping @Sendable (URLRequest) -> Bool) {
        lock.withLock { matcher = matches }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.withLock { matcher }?(request) == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.holding = self } }
    override func stopLoading() {
        Self.lock.withLock { if Self.holding === self { Self.holding = nil } }
    }

    /// Answers the held request with `status` and `body`. Later matching requests are held again.
    static func release(status: Int = 200, body: String) {
        let pending = lock.withLock { () -> HeldRequestGate? in
            defer { holding = nil }
            return holding
        }
        guard let pending, let url = pending.request.url else { return }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        pending.client?.urlProtocol(pending, didReceive: response, cacheStoragePolicy: .notAllowed)
        pending.client?.urlProtocol(pending, didLoad: Data(body.utf8))
        pending.client?.urlProtocolDidFinishLoading(pending)
    }
}
