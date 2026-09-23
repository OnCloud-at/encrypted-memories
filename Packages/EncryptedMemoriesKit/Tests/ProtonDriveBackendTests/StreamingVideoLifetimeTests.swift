import AVFoundation
import Foundation
import PhotosCore
import ProtonAuth
import ProtonCoreCryptoGoInterface
import ProtonCoreCryptoPatchedGoImplementation
import Testing

@testable import ProtonDriveBackend

@Suite(.serialized)
struct StreamingVideoLifetimeTests {
    @Test func closeFinishesARealAVFoundationLoadingRequest() async throws {
        injectDefaultCryptoImplementation()
        let governor = ProtonRequestGovernor()
        var permits: [ProtonRequestGovernor.Permit] = []
        for _ in 0..<4 { permits.append(try await governor.acquire(scope: .storageDownload)) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = DriveSession(
            session: ProtonSession(uid: "test", accessToken: "test", refreshToken: "test", keyPassword: "test"),
            store: SessionKeychainStore(service: "tests.loading-close.unused"), accountCacheDirectory: root,
            requestGovernor: governor, urlProtocolClasses: [VideoBlockURLProtocol.self])
        let crypto = DriveCrypto(addressKeys: [], signers: [])
        let source = PhotoVideoStreamSource(session: session, crypto: crypto, shareID: "test")
        let key = try #require(CryptoGo.CryptoNewSessionKeyFromToken(Data(repeating: 4, count: 32), "aes256"))
        let prepared = PreparedVideo(
            uid: PhotoUID(volumeID: "test", nodeID: "pending"), totalSize: 64,
            contentTypeUTI: "com.apple.quicktime-movie",
            blocks: [
                VideoBlock(index: 1, url: "https://example.invalid/block", token: nil, clearOffset: 0, clearSize: 64)
            ],
            sessionKey: key)
        let loader = ProtonVideoResourceLoader(
            prepared: prepared, source: source, crypto: crypto, admission: JoinedShutdownGate(),
            cache: VideoByteRangeCache(rootDirectory: root.appendingPathComponent("blocks")))
        let asset = AVURLAsset(url: URL(string: "protonvideo://test/pending.mov")!)
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "tests.video-loading-close"))
        let outcome = VideoLoadOutcome()
        let loading = Task {
            do {
                _ = try await asset.load(.duration)
                outcome.complete(failed: false)
            } catch {
                outcome.complete(failed: true)
            }
        }
        defer {
            loader.close()
            asset.cancelLoading()
            loading.cancel()
        }
        try await waitUntil { await governor.snapshot().storageDownload.queued == 1 }
        loader.close()
        for _ in 0..<500 where !outcome.completed { try await Task.sleep(for: .milliseconds(2)) }
        #expect(outcome.completed)
        #expect(outcome.failed)
        asset.cancelLoading()
        loading.cancel()
        for permit in permits { await governor.finish(permit, statusCode: nil) }
    }

    @Test(arguments: [32, 64, 80])
    func decryptedBlockRejectsShortDataButPreservesTrailingBytesCompatibility(byteCount: Int) async throws {
        injectDefaultCryptoImplementation()
        let key = try #require(CryptoGo.CryptoNewSessionKeyFromToken(Data(repeating: 3, count: 32), "aes256"))
        let clear = Data(repeating: 7, count: byteCount)
        VideoBlockURLProtocol.configure(try key.encrypt(CryptoGo.CryptoNewPlainMessage(clear)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = DriveSession(
            session: ProtonSession(uid: "test", accessToken: "test", refreshToken: "test", keyPassword: "test"),
            store: SessionKeychainStore(service: "tests.streaming-integrity.unused"), accountCacheDirectory: root,
            urlProtocolClasses: [VideoBlockURLProtocol.self])
        let crypto = DriveCrypto(addressKeys: [], signers: [])
        let source = PhotoVideoStreamSource(session: session, crypto: crypto, shareID: "test")
        let block = VideoBlock(
            index: 1, url: "https://example.invalid/block", token: nil, clearOffset: 0, clearSize: 64)
        let prepared = PreparedVideo(
            uid: PhotoUID(volumeID: "test", nodeID: "one"), totalSize: 64,
            contentTypeUTI: "public.movie", blocks: [block], sessionKey: key)
        let loader = ProtonVideoResourceLoader(
            prepared: prepared, source: source, crypto: crypto, admission: JoinedShutdownGate(),
            cache: VideoByteRangeCache(rootDirectory: root.appendingPathComponent("blocks")))
        defer { loader.close() }
        if byteCount < 64 {
            await #expect(throws: StreamingError.self) {
                _ = try await loader.decryptedBlock(block, priority: .immediate)
            }
        } else {
            let (data, _) = try await loader.decryptedBlock(block, priority: .immediate)
            #expect(Data(data.prefix(64)) == Data(repeating: 7, count: 64))
        }
    }

    @Test(arguments: [true, false])
    func concurrentDemandReusesOneEncryptedPrefetchAndSurvivesOneCancelledWaiter(prefetchFirst: Bool) async throws {
        injectDefaultCryptoImplementation()
        let key = try #require(CryptoGo.CryptoNewSessionKeyFromToken(Data(repeating: 2, count: 32), "aes256"))
        let clear = Data(repeating: 7, count: 64)
        VideoBlockURLProtocol.configure(try key.encrypt(CryptoGo.CryptoNewPlainMessage(clear)))
        let governor = ProtonRequestGovernor()
        var permits: [ProtonRequestGovernor.Permit] = []
        for _ in 0..<4 { permits.append(try await governor.acquire(scope: .storageDownload)) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = DriveSession(
            session: ProtonSession(uid: "test", accessToken: "test", refreshToken: "test", keyPassword: "test"),
            store: SessionKeychainStore(service: "tests.streaming-singleflight.unused"), accountCacheDirectory: root,
            requestGovernor: governor, urlProtocolClasses: [VideoBlockURLProtocol.self])
        let crypto = DriveCrypto(addressKeys: [], signers: [])
        let source = PhotoVideoStreamSource(session: session, crypto: crypto, shareID: "test")
        let block = VideoBlock(
            index: 1, url: "https://example.invalid/block", token: nil,
            clearOffset: 0, clearSize: clear.count)
        let prepared = PreparedVideo(
            uid: PhotoUID(volumeID: "test", nodeID: "one"), totalSize: clear.count,
            contentTypeUTI: "public.movie", blocks: [block], sessionKey: key)
        let loader = ProtonVideoResourceLoader(
            prepared: prepared, source: source, crypto: crypto, admission: JoinedShutdownGate(),
            cache: VideoByteRangeCache(rootDirectory: root.appendingPathComponent("blocks")))
        defer { loader.close() }
        if prefetchFirst {
            loader.primePlaybackStart()
            try await waitUntil { await governor.snapshot().storageDownload.queued == 1 }
        }
        let requests = (0..<20).map { _ in
            Task { try await loader.decryptedBlock(block, priority: .immediate).0 }
        }
        if !prefetchFirst {
            try await waitUntil { await governor.snapshot().storageDownload.queued > 0 }
            loader.primePlaybackStart()
        }
        requests[0].cancel()
        do {
            _ = try await requests[0].value
            Issue.record("Cancelled demand unexpectedly completed")
        } catch is CancellationError {}
        for permit in permits { await governor.finish(permit, statusCode: nil) }
        for request in requests.dropFirst() { #expect(try await request.value == clear) }
        #expect(VideoBlockURLProtocol.requestCount == 1)
        #expect(await governor.snapshot().storageDownload.inFlight == 0)
    }

    @Test func releasingAnAssetCancelsItsPrefetchWithoutWaitingForLoaderDeinit() async throws {
        injectDefaultCryptoImplementation()
        let governor = ProtonRequestGovernor()
        var permits: [ProtonRequestGovernor.Permit] = []
        for _ in 0..<4 {
            permits.append(try await governor.acquire(scope: .storageDownload))
        }
        let admission = JoinedShutdownGate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = DriveSession(
            session: ProtonSession(uid: "test", accessToken: "test", refreshToken: "test", keyPassword: "test"),
            store: SessionKeychainStore(service: "tests.streaming-lifetime.unused"),
            accountCacheDirectory: root, requestGovernor: governor)
        let crypto = DriveCrypto(addressKeys: [], signers: [])
        let source = PhotoVideoStreamSource(session: session, crypto: crypto, shareID: "test")
        let key = try #require(CryptoGo.CryptoNewSessionKeyFromToken(Data(repeating: 1, count: 32), "aes256"))
        func makeLoader(_ node: String) -> ProtonVideoResourceLoader {
            let prepared = PreparedVideo(
                uid: PhotoUID(volumeID: "test", nodeID: node), totalSize: 8, contentTypeUTI: "public.movie",
                blocks: [
                    VideoBlock(
                        index: 1, url: "https://example.invalid/block", token: nil,
                        clearOffset: 0, clearSize: 8)
                ], sessionKey: key)
            return ProtonVideoResourceLoader(
                prepared: prepared, source: source, crypto: crypto, admission: admission,
                cache: VideoByteRangeCache(rootDirectory: root.appendingPathComponent(node)))
        }
        let other = makeLoader("other")
        other.primePlaybackStart()
        try await waitUntil { await governor.snapshot().storageDownload.queued == 1 }
        for index in 0..<20 {
            let loader = makeLoader("closed-\(index)")
            var asset: StreamingVideoAsset? = StreamingVideoAsset(
                asset: AVURLAsset(url: URL(string: "protonvideo://test/\(index)")!), retaining: loader)
            loader.primePlaybackStart()
            try await waitUntil { await governor.snapshot().storageDownload.queued == 2 }
            if index.isMultiple(of: 2) {
                asset?.close()
                asset?.close()
            }
            asset = nil
            // `loader` stays strongly owned here; deinit cannot perform this cancellation.
            try await waitUntil { await governor.snapshot().storageDownload.queued == 1 }
            loader.primePlaybackStart()
            #expect(!admission.isClosed)
        }
        other.close()
        try await waitUntil { await governor.snapshot().storageDownload.queued == 0 }
        for permit in permits { await governor.finish(permit, statusCode: nil) }
        #expect(try await admission.withAdmission { 42 } == 42)
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<1_000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Timed out waiting for owner cancellation at the real governor queue")
        throw CancellationError()
    }
}

private final class VideoLoadOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    var completed: Bool { lock.withLock { result != nil } }
    var failed: Bool { lock.withLock { result == true } }
    func complete(failed: Bool) { lock.withLock { result = failed } }
}

private final class VideoBlockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bytes = Data()
    nonisolated(unsafe) private static var count = 0
    static var requestCount: Int { lock.withLock { count } }
    static func configure(_ data: Data) {
        lock.withLock {
            bytes = data
            count = 0
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.lock.withLock {
            Self.count += 1
            return Self.bytes
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
