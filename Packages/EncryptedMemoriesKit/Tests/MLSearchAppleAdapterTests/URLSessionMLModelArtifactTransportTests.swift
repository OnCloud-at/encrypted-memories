import Foundation
import Testing

@testable import MLSearchAppleAdapter

@Suite(.serialized) struct URLSessionMLModelArtifactTransportTests {
    @Test func responseEndpointValidationRejectsEveryChangedComponent() {
        let expected = URL(string: "https://models.oncloud.at/models/test/weights.bin")!
        #expect(MLModelRequestIdentity.isExactEndpoint(expected, expected: expected))
        for changed in [
            "http://models.oncloud.at/models/test/weights.bin",
            "https://example.test/models/test/weights.bin",
            "https://models.oncloud.at:8443/models/test/weights.bin",
            "https://models.oncloud.at/models/other/weights.bin",
            "https://models.oncloud.at/models/test/weights.bin?token=1",
        ] {
            #expect(!MLModelRequestIdentity.isExactEndpoint(URL(string: changed), expected: expected))
        }
    }

    private final class RangeProtocol: URLProtocol {
        private final class ChunkDelivery: @unchecked Sendable {
            weak var owner: RangeProtocol?
            let body: Data
            let chunkSize: Int

            init(owner: RangeProtocol, body: Data, chunkSize: Int) {
                self.owner = owner
                self.body = body
                self.chunkSize = chunkSize
            }
        }

        nonisolated(unsafe) static var payload = Data()
        nonisolated(unsafe) static var requests: [URLRequest] = []
        nonisolated(unsafe) static var responseChunkSize: Int?
        nonisolated(unsafe) static var statusCode = 206
        nonisolated(unsafe) static var contentRangeStartDelta = 0
        private var loadingTask: Task<Void, Never>?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requests.append(request)
            let range = request.value(forHTTPHeaderField: "Range") ?? ""
            let bounds =
                range
                .replacingOccurrences(of: "bytes=", with: "")
                .split(separator: "-")
                .compactMap { Int($0) }
            guard bounds.count == 2 else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let requestedLower = bounds[0]
            let requestedUpper = min(bounds[1], Self.payload.count - 1)
            let lower = Self.statusCode == 200 ? 0 : requestedLower
            let upper = Self.statusCode == 200 ? Self.payload.count - 1 : requestedUpper
            let body = upper >= lower ? Self.payload.subdata(in: lower..<(upper + 1)) : Data()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: Self.statusCode,
                httpVersion: nil,
                headerFields: [
                    "Content-Length": String(body.count),
                    "Content-Range": "bytes \(lower + Self.contentRangeStartDelta)-\(upper)/\(Self.payload.count)",
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let responseChunkSize = Self.responseChunkSize {
                let delivery = ChunkDelivery(owner: self, body: body, chunkSize: responseChunkSize)
                loadingTask = Task { [delivery] in
                    guard let owner = delivery.owner else { return }
                    var offset = 0
                    while offset < delivery.body.count, !Task.isCancelled {
                        let end = min(delivery.body.count, offset + delivery.chunkSize)
                        owner.client?.urlProtocol(
                            owner,
                            didLoad: delivery.body.subdata(in: offset..<end)
                        )
                        offset = end
                        try? await Task.sleep(for: .milliseconds(2))
                    }
                    guard !Task.isCancelled else { return }
                    owner.client?.urlProtocolDidFinishLoading(owner)
                }
            } else {
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
        }

        override func stopLoading() {
            loadingTask?.cancel()
            loadingTask = nil
        }
    }

    private func configureProtocol(payload: Data, chunkSize: Int? = nil) {
        RangeProtocol.payload = payload
        RangeProtocol.requests = []
        RangeProtocol.responseChunkSize = chunkSize
        RangeProtocol.statusCode = 206
        RangeProtocol.contentRangeStartDelta = 0
    }

    @Test func resumesFromPartialFileAndIdentifiesTheApp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-range-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("weights.partial")
        let payload = Data((0..<251).map(UInt8.init))
        try payload.prefix(37).write(to: destination)
        configureProtocol(payload: payload)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeProtocol.self]
        let transport = URLSessionMLModelArtifactTransport(session: URLSession(configuration: configuration))

        try await transport.download(
            from: URL(string: "https://models.oncloud.at/models/test/weights.bin")!,
            to: destination,
            expectedByteCount: Int64(payload.count),
            progress: { _, _ in }
        )

        #expect(try Data(contentsOf: destination) == payload)
        #expect(RangeProtocol.requests.first?.value(forHTTPHeaderField: "Range") == "bytes=37-250")
        #expect(
            RangeProtocol.requests.allSatisfy {
                $0.value(forHTTPHeaderField: MLModelRequestIdentity.headerName) == MLModelRequestIdentity.appIdentifier
            })
    }

    @Test func reportsProgressWhileOneRangeIsStillArriving() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-progress-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("weights.partial")
        let payload = Data(repeating: 0xAB, count: 2 << 20)
        configureProtocol(payload: payload, chunkSize: 64 << 10)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeProtocol.self]
        let transport = URLSessionMLModelArtifactTransport(session: URLSession(configuration: configuration))
        let progress = ProgressRecorder()

        try await transport.download(
            from: URL(string: "https://models.oncloud.at/models/test/weights.bin")!,
            to: destination,
            expectedByteCount: Int64(payload.count)
        ) { received, _ in
            progress.append(received)
        }

        let values = progress.values
        #expect(values == values.sorted())
        #expect(values.contains { $0 > 0 && $0 < Int64(payload.count) })
        #expect(values.last == Int64(payload.count))
    }

    @Test func cancellationStopsTheDelegateBackedTransfer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("weights.partial")
        let payload = Data(repeating: 0xCD, count: 8 << 20)
        configureProtocol(payload: payload, chunkSize: 64 << 10)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeProtocol.self]
        let transport = URLSessionMLModelArtifactTransport(session: URLSession(configuration: configuration))

        let progress = ProgressProbe(expectedByteCount: Int64(payload.count))
        let transfer = Task {
            try await transport.download(
                from: URL(string: "https://models.oncloud.at/models/test/weights.bin")!,
                to: destination,
                expectedByteCount: Int64(payload.count),
                progress: { received, _ in await progress.record(received) }
            )
        }
        await progress.waitForIntermediateProgress()
        transfer.cancel()

        do {
            try await transfer.value
            Issue.record("A cancelled model transfer must not complete successfully")
        } catch is CancellationError {
            // Expected: lifecycle cancellation remains distinct from a retryable network failure.
        } catch {
            Issue.record("Expected CancellationError, received \(error)")
        }
    }

    @Test func rejectsMismatchedContentRangeWithoutMutatingPartialFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-bad-range-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("weights.partial")
        let payload = Data((0..<251).map(UInt8.init))
        let original = Data(payload.prefix(37))
        try original.write(to: destination)
        configureProtocol(payload: payload)
        RangeProtocol.contentRangeStartDelta = 1
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeProtocol.self]
        let transport = URLSessionMLModelArtifactTransport(session: URLSession(configuration: configuration))

        await #expect(throws: MLArtifactTransportError.invalidContentRange) {
            try await transport.download(
                from: URL(string: "https://models.oncloud.at/models/test/weights.bin")!,
                to: destination,
                expectedByteCount: Int64(payload.count),
                progress: { _, _ in }
            )
        }
        #expect(try Data(contentsOf: destination) == original)
    }

    @Test func ignoredRangeDiscardsPartialAndReportsUnsupportedResume() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-ignored-range-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("weights.partial")
        let payload = Data((0..<251).map(UInt8.init))
        try payload.prefix(37).write(to: destination)
        configureProtocol(payload: payload)
        RangeProtocol.statusCode = 200
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeProtocol.self]
        let transport = URLSessionMLModelArtifactTransport(session: URLSession(configuration: configuration))

        await #expect(throws: MLArtifactTransportError.rangeUnsupported) {
            try await transport.download(
                from: URL(string: "https://models.oncloud.at/models/test/weights.bin")!,
                to: destination,
                expectedByteCount: Int64(payload.count),
                progress: { _, _ in }
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func emptyOrShortHTTP200ResponseThrowsWithoutRetrying() async throws {
        for (payload, expectedError) in [
            (Data(), MLArtifactTransportError.responseTooSmall),
            (Data(repeating: 0xAB, count: 37), MLArtifactTransportError.responseTooSmall),
        ] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("model-short-200-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let destination = root.appendingPathComponent("weights.partial")
            configureProtocol(payload: payload)
            RangeProtocol.statusCode = 200
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RangeProtocol.self]
            let transport = URLSessionMLModelArtifactTransport(session: URLSession(configuration: configuration))

            await #expect(throws: expectedError) {
                try await transport.download(
                    from: URL(string: "https://models.oncloud.at/models/test/weights.bin")!,
                    to: destination,
                    expectedByteCount: 251,
                    progress: { _, _ in }
                )
            }
            #expect(RangeProtocol.requests.count == 1)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test func propagatesRangeNotSatisfiableWithoutDestroyingPartialFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-range-416-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("weights.partial")
        let payload = Data((0..<251).map(UInt8.init))
        let original = Data(payload.prefix(37))
        try original.write(to: destination)
        configureProtocol(payload: payload)
        RangeProtocol.statusCode = 416
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeProtocol.self]
        let transport = URLSessionMLModelArtifactTransport(session: URLSession(configuration: configuration))

        await #expect(throws: MLArtifactTransportError.httpStatus(416)) {
            try await transport.download(
                from: URL(string: "https://models.oncloud.at/models/test/weights.bin")!,
                to: destination,
                expectedByteCount: Int64(payload.count),
                progress: { _, _ in }
            )
        }
        #expect(try Data(contentsOf: destination) == original)
    }

    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Int64] = []

        func append(_ value: Int64) {
            lock.withLock { storage.append(value) }
        }

        var values: [Int64] {
            lock.withLock { storage }
        }
    }

    private actor ProgressProbe {
        private let expectedByteCount: Int64
        private var observedIntermediate = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(expectedByteCount: Int64) {
            self.expectedByteCount = expectedByteCount
        }

        func record(_ received: Int64) {
            guard received > 0, received < expectedByteCount else { return }
            observedIntermediate = true
            let continuations = waiters
            waiters.removeAll(keepingCapacity: false)
            continuations.forEach { $0.resume() }
        }

        func waitForIntermediateProgress() async {
            guard !observedIntermediate else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}
