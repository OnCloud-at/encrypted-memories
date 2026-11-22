import CoreGraphics
import Foundation
import ImageIO
import PhotosCore
import Testing

@testable import MLSearchAppleAdapter

struct FileImageSource: CoreMLImageSource {
    let urlsByUID: [PhotoUID: URL]

    func image(for uid: PhotoUID) async -> CoreMLImageSourceOutcome {
        guard let url = urlsByUID[uid],
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return .permanentFailure(reason: "unreadable reference image") }
        return .image(CoreMLSourceImage(cgImage: image))
    }
}

struct EmptyImageSource: CoreMLImageSource {
    func image(for uid: PhotoUID) async -> CoreMLImageSourceOutcome { .transientFailure }
}

/// Each subclass has its own responses and request history, even when suites run concurrently.
class CatalogStubProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var responses: [URL: Data] = [:]
        /// URLs that answer with a 302 redirect to the mapped URL instead of their response.
        var redirects: [URL: URL] = [:]
        var requests: [URLRequest] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [ObjectIdentifier: State] = [:]
    private var finishRedirectedLoad: Task<Void, Never>?

    /// Hands the protocol instance to the task that finishes a refused redirect, without holding it strongly.
    private final class LoadingProtocol: @unchecked Sendable {
        weak var owner: URLProtocol?
        init(_ owner: URLProtocol) { self.owner = owner }
    }

    class func configure(responses: [URL: Data], redirects: [URL: URL] = [:]) {
        CatalogStubProtocol.lock.withLock {
            CatalogStubProtocol.states[ObjectIdentifier(self)] = State(responses: responses, redirects: redirects)
        }
    }

    class func replaceResponse(_ data: Data, for url: URL) {
        CatalogStubProtocol.lock.withLock {
            CatalogStubProtocol.states[ObjectIdentifier(self), default: State()].responses[url] = data
        }
    }

    class var recordedRequests: [URLRequest] {
        CatalogStubProtocol.lock.withLock { CatalogStubProtocol.states[ObjectIdentifier(self)]?.requests ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (data, redirectTarget) = CatalogStubProtocol.lock.withLock { () -> (Data?, URL?) in
            let key = ObjectIdentifier(type(of: self))
            CatalogStubProtocol.states[key, default: State()].requests.append(request)
            guard let url = request.url else { return (nil, nil) }
            return (CatalogStubProtocol.states[key]?.responses[url], CatalogStubProtocol.states[key]?.redirects[url])
        }
        if let redirectTarget, let url = request.url {
            let redirect = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": redirectTarget.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirectTarget), redirectResponse: redirect)
            // The task delegate decides after this call. A refused redirect leaves this load to answer with the
            // redirect itself, as a real HTTP stack does; a followed one stops it first, which cancels the answer.
            let loading = LoadingProtocol(self)
            finishRedirectedLoad = Task { [loading] in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let owner = loading.owner else { return }
                owner.client?.urlProtocol(owner, didReceive: redirect, cacheStoragePolicy: .notAllowed)
                owner.client?.urlProtocolDidFinishLoading(owner)
            }
            return
        }
        guard let data, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { finishRedirectedLoad?.cancel() }
}

func catalogStubSession(for protocolClass: CatalogStubProtocol.Type) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [protocolClass]
    return URLSession(configuration: configuration)
}

@Suite(.serialized) struct CatalogStubProtocolIsolationTests {
    private final class First: CatalogStubProtocol, @unchecked Sendable {}
    private final class Second: CatalogStubProtocol, @unchecked Sendable {}

    @Test func independentSuitesCanUseTheSameURL() async throws {
        let url = URL(string: "https://catalog-fixture.test/data")!
        First.configure(responses: [url: Data("first".utf8)])
        Second.configure(responses: [url: Data("second".utf8)])
        let firstSession = catalogStubSession(for: First.self)
        let secondSession = catalogStubSession(for: Second.self)
        defer {
            firstSession.invalidateAndCancel()
            secondSession.invalidateAndCancel()
        }
        async let first = firstSession.data(from: url)
        async let second = secondSession.data(from: url)
        let (a, b) = try await (first, second)
        #expect(a.0 == Data("first".utf8))
        #expect(b.0 == Data("second".utf8))
        #expect(First.recordedRequests.map(\.url) == [url])
        #expect(Second.recordedRequests.map(\.url) == [url])
    }

    @Test func reconfigurationAndReplacementStayIsolated() async throws {
        let url = URL(string: "https://catalog-fixture.test/reset")!
        First.configure(responses: [url: Data("first".utf8)])
        Second.configure(responses: [url: Data("second".utf8)])
        let first = catalogStubSession(for: First.self)
        let second = catalogStubSession(for: Second.self)
        defer {
            first.invalidateAndCancel()
            second.invalidateAndCancel()
        }
        #expect(try await first.data(from: url).0 == Data("first".utf8))
        #expect(try await second.data(from: url).0 == Data("second".utf8))
        First.replaceResponse(Data("updated".utf8), for: url)
        #expect(try await first.data(from: url).0 == Data("updated".utf8))
        #expect(try await second.data(from: url).0 == Data("second".utf8))
        #expect(First.recordedRequests.count == 2)
        #expect(Second.recordedRequests.count == 2)
        First.configure(responses: [url: Data("reset".utf8)])
        #expect(First.recordedRequests.isEmpty)
        #expect(Second.recordedRequests.count == 2)
        #expect(try await first.data(from: url).0 == Data("reset".utf8))
        #expect(try await second.data(from: url).0 == Data("second".utf8))
        #expect(First.recordedRequests.count == 1)
        #expect(Second.recordedRequests.count == 3)
    }

    @Test func concurrentRequestsOnOneSubclassAreAllRecorded() async throws {
        let url = URL(string: "https://catalog-fixture.test/concurrent")!
        let payload = Data("payload".utf8)
        First.configure(responses: [url: payload])
        let session = catalogStubSession(for: First.self)
        defer { session.invalidateAndCancel() }
        let results = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<16 {
                group.addTask { try await session.data(from: url).0 }
            }
            var data: [Data] = []
            for try await value in group { data.append(value) }
            return data
        }
        #expect(results.count == 16)
        #expect(results.allSatisfy { $0 == payload })
        #expect(First.recordedRequests.count == 16)
        #expect(First.recordedRequests.allSatisfy { $0.url == url })
    }
}
