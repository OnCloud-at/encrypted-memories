import Foundation
import Testing

@testable import ProtonAuth

/// The sign-in requests answer with a redirect: it must be handled as the answer, and nothing may be sent to the
/// new location.
@Suite("Sign-in redirects", .serialized)
struct ProtonSignInRedirectTests {
    private static let redirectPath = "/redirected/target"

    private func makeAuthenticator() -> ProtonForkAuthenticator {
        ProtonForkAuthenticator(
            config: ProtonAPIConfig(baseURL: URL(string: "https://drive-api.proton.me")!),
            urlProtocolClasses: [SignInRedirectURLProtocol.self])
    }

    /// The message of the API error that `body` throws, or nil when it throws something else or nothing.
    private func apiErrorMessage(_ body: () async throws -> Void) async -> String? {
        do {
            try await body()
        } catch ProtonAuthError.apiError(_, let message) {
            return message
        } catch {}
        return nil
    }

    @Test(arguments: [301, 302, 303, 307, 308])
    func aSignInStartRedirectIsNotFollowed(status: Int) async throws {
        SignInRedirectURLProtocol.reset(answers: [status], location: "https://untrusted.invalid\(Self.redirectPath)")

        let message = await apiErrorMessage { _ = try await makeAuthenticator().initFork() }

        #expect(message == "HTTP \(status)", "the redirect ends the sign-in with the API error of its status")

        #expect(SignInRedirectURLProtocol.paths.count == 1, "exactly one request is sent")
        #expect(
            !SignInRedirectURLProtocol.paths.contains(Self.redirectPath),
            "the request must never be sent to the redirect target")
    }

    @Test(arguments: [307, 302])
    func aSignInPollRedirectIsNotFollowed(status: Int) async throws {
        SignInRedirectURLProtocol.reset(
            answers: [200, status], location: "https://untrusted.invalid\(Self.redirectPath)")

        let message = await apiErrorMessage { _ = try await makeAuthenticator().authenticate(openURL: { _ in }) }

        #expect(message == "HTTP \(status)", "the redirect ends the sign-in with the API error of its status")

        #expect(SignInRedirectURLProtocol.paths.count == 2, "the start and the poll are the only requests")
        #expect(
            !SignInRedirectURLProtocol.paths.contains(Self.redirectPath),
            "the poll must never be sent to the redirect target")
    }
}

private final class SignInRedirectURLProtocol: URLProtocol, @unchecked Sendable {
    /// Hands the protocol instance to the task that answers a refused redirect, without holding it strongly.
    private final class LoadingProtocol: @unchecked Sendable {
        weak var owner: URLProtocol?
        init(_ owner: URLProtocol) { self.owner = owner }
    }

    private static let lock = NSLock()
    private var answerRedirectedLoad: Task<Void, Never>?
    nonisolated(unsafe) private static var answers: [Int] = []
    nonisolated(unsafe) private static var location: String?
    nonisolated(unsafe) private static var recorded: [String] = []

    static var paths: [String] { lock.withLock { recorded } }

    static func reset(answers: [Int], location: String?) {
        lock.withLock {
            self.answers = answers
            self.location = location
            recorded = []
        }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let (status, location) = Self.lock.withLock { () -> (Int, String?) in
            Self.recorded.append(url.path)
            let status = Self.answers.count > 1 ? Self.answers.removeFirst() : Self.answers.first ?? 200
            return (status, Self.location)
        }
        let body = Data(#"{"Code":1000,"Selector":"sel","UserCode":"code"}"#.utf8)
        var headers = ["Content-Type": "application/json"]
        if (300...399).contains(status), let location { headers["Location"] = location }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        if (300...399).contains(status), let location {
            // Mirror URLSession's redirect handling: the client decides whether the new request is sent.
            client?.urlProtocol(
                self, wasRedirectedTo: URLRequest(url: URL(string: location)!), redirectResponse: response)
            // A refused redirect leaves this load to answer with the redirect itself, as a real HTTP stack does; a
            // followed one stops it first, which cancels the answer.
            let loading = LoadingProtocol(self)
            answerRedirectedLoad = Task { [loading] in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let owner = loading.owner else { return }
                owner.client?.urlProtocol(owner, didReceive: response, cacheStoragePolicy: .notAllowed)
                owner.client?.urlProtocol(owner, didLoad: body)
                owner.client?.urlProtocolDidFinishLoading(owner)
            }
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { answerRedirectedLoad?.cancel() }
}
