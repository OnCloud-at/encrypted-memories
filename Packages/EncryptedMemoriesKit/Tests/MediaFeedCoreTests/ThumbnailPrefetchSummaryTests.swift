#if os(macOS) && DEBUG
    import CryptoKit
    import Foundation
    import MediaByteCache
    import MediaFeedCore
    import PhotosCore
    import XCTest

    private enum SummaryCase: String, CaseIterable {
        case batch, item, unreported, withheld, timeout

        var errorText: String {
            switch self {
            case .batch: "thumbnail batch failed"
            case .item: "thumbnail refused"
            case .unreported: "thumbnail batch missing"
            case .withheld: "thumbnail withheld"
            case .timeout: "thumbnail batch timed out"
            }
        }

        var field: String {
            switch self {
            case .batch: "failedBatchError"
            case .item: "failedItemError"
            case .unreported: "failedUnreported"
            case .withheld: "failedWithheld"
            case .timeout: "failedTimeout"
            }
        }
    }

    /// Holds the crawl while the loader runs, so worker completion follows the real summary emission.
    private actor SummaryLoader: ThumbnailBatchLoader {
        let scenario: SummaryCase
        let runtime: LibraryRuntimeState
        private(set) var requests = 0

        init(scenario: SummaryCase, runtime: LibraryRuntimeState) {
            self.scenario = scenario
            self.runtime = runtime
        }

        func loadThumbnails(
            for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
        ) async -> ThumbnailBatchLoadResult {
            requests += 1
            let uid = uids[0]
            runtime.update { $0.executionOpportunity = .suspended }
            if scenario == .timeout {
                do { try await Task.sleep(for: .seconds(60)) } catch {}
                return .delivered
            }
            switch scenario {
            case .batch: return ThumbnailBatchLoadResult(batchError: "batch-error")
            case .item: return ThumbnailBatchLoadResult(itemErrors: [uid: "item-error"])
            case .unreported: return .delivered
            case .withheld: return ThumbnailBatchLoadResult(withheldUIDs: [uid])
            case .timeout: return .delivered
            }
        }
    }

    final class ThumbnailPrefetchSummaryTests: XCTestCase {
        private static let scenarioKey = "THUMBNAIL_SUMMARY_CHILD_SCENARIO"

        /// Selected by the parent in its own process. The ordinary suite leaves this child idle.
        func testSummaryChild() async throws {
            guard let name = ProcessInfo.processInfo.environment[Self.scenarioKey] else { return }
            let scenario = try XCTUnwrap(SummaryCase(rawValue: name))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let runtime = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(executionOpportunity: .foregroundActive))
            let cache = ThumbnailCache(namespace: "summary-child", rootDirectory: root, runtimeState: runtime)
            cache.configure(accountUID: "summary", key: SymmetricKey(size: .bits256))
            let loader = SummaryLoader(scenario: scenario, runtime: runtime)
            let feed = ThumbnailFeedCore(
                cache: cache, loader: loader,
                configuration: ThumbnailFeedCoreConfiguration(
                    downloadConcurrencyLimit: 1, batchSize: 1, crawlBackoffSeconds: 0,
                    downloadTimeoutSeconds: 0.1),
                diagnostics: PhotoDiagnostics()
            )
            await feed.startPrefetch([PhotoUID(volumeID: "summary", nodeID: name)])
            // A held crawl stops its worker only after it classifies the batch and emits the summary.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await feed.waitForPrefetchToFinish() }
                group.addTask {
                    try await Task.sleep(for: .seconds(15))
                    throw CancellationError()
                }
                defer { group.cancelAll() }
                try await group.next()
            }
            let requests = await loader.requests
            XCTAssertEqual(requests, 1)
            await feed.stopPrefetchAndWait()
        }

        func testDebugSummaryClassifiesFailuresAndTimeout() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            for scenario in SummaryCase.allCases {
                let outputURL = directory.appendingPathComponent(scenario.rawValue)
                XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
                let output = try FileHandle(forWritingTo: outputURL)
                let child = Process()
                child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                child.arguments = [
                    "xctest", "-XCTest", "MediaFeedCoreTests.ThumbnailPrefetchSummaryTests/testSummaryChild",
                    Bundle(for: Self.self).bundlePath,
                ]
                child.environment = ProcessInfo.processInfo.environment.merging([Self.scenarioKey: scenario.rawValue]) {
                    _, new in new
                }
                child.standardOutput = output
                child.standardError = output
                let done = DispatchSemaphore(value: 0)
                child.terminationHandler = { _ in done.signal() }
                try child.run()
                guard done.wait(timeout: .now() + 20) == .success else {
                    child.terminate()
                    if done.wait(timeout: .now() + 5) != .success {
                        kill(child.processIdentifier, SIGKILL)
                        _ = done.wait(timeout: .now() + 5)
                    }
                    try output.close()
                    XCTFail("summary child timed out: \(scenario.rawValue)")
                    continue
                }
                try output.close()
                let text = try String(contentsOf: outputURL, encoding: .utf8)
                XCTAssertEqual(child.terminationStatus, 0, "\(scenario.rawValue): \(text)")
                let summary = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("[ThumbPrefetch] ") })
                let fields = summary.split(separator: " ").dropFirst().compactMap { token -> (String, String)? in
                    let parts = token.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2 else { return nil }
                    return (String(parts[0]), String(parts[1]))
                }
                let values = Dictionary(fields, uniquingKeysWith: { first, _ in first })
                XCTAssertEqual(values["failed"], "1", "\(scenario.rawValue): \(summary)")
                XCTAssertTrue(summary.contains("lastError=\(scenario.errorText)"), "\(scenario.rawValue): \(summary)")
                for kind in SummaryCase.allCases {
                    XCTAssertEqual(values[kind.field], kind == scenario ? "1" : "0", "\(scenario.rawValue): \(summary)")
                }
            }
        }
    }
#endif
