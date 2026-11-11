#if os(macOS) && DEBUG
    import CryptoKit
    import Foundation
    import MediaByteCache
    import MediaFeedCore
    import PhotosCore
    import XCTest

    private enum SummaryCase: String, CaseIterable {
        case batch, item, unreported, withheld, timeout, partial, manual, disk, skipped, late, disabled

        var errorText: String {
            switch self {
            case .batch: "thumbnail batch failed"
            case .item: "thumbnail refused"
            case .unreported: "thumbnail batch missing"
            case .withheld: "thumbnail withheld"
            case .timeout: "thumbnail batch timed out"
            case .partial: "thumbnail refused"
            case .manual: "thumbnail batch missing"
            case .disk: "thumbnail refused"
            case .skipped: "thumbnail batch missing"
            case .late: "thumbnail batch missing"
            case .disabled: ""
            }
        }

        var field: String {
            switch self {
            case .batch: "failedBatchError"
            case .item: "failedItemError"
            case .unreported: "failedUnreported"
            case .withheld: "failedWithheld"
            case .timeout: "failedTimeout"
            case .partial: "failedItemError"
            case .manual: "failedUnreported"
            case .disk: "failedItemError"
            case .skipped: "failedItemError"
            case .late: "failedTimeout"
            case .disabled: ""
            }
        }
    }

    /// Holds the crawl before the wrapped loader returns.
    private actor HoldingLoader: ThumbnailBatchLoader {
        let loader: any ThumbnailBatchLoader
        let runtime: LibraryRuntimeState
        private(set) var requests = 0

        init(loader: any ThumbnailBatchLoader, runtime: LibraryRuntimeState) {
            self.loader = loader
            self.runtime = runtime
        }

        func loadThumbnails(
            for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
        ) async -> ThumbnailBatchLoadResult {
            requests += 1
            runtime.update { $0.executionOpportunity = .suspended }
            return await loader.loadThumbnails(for: uids, onLoaded: onLoaded)
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
            let clock = MutableClock(Date(timeIntervalSince1970: 10_000))
            let cache = ThumbnailCache(namespace: "summary-child", rootDirectory: root, runtimeState: runtime)
            cache.configure(accountUID: "summary", key: SymmetricKey(size: .bits256))
            let uids = (0..<4).map { PhotoUID(volumeID: "summary", nodeID: "\(name)-\($0)") }
            let body: any ThumbnailBatchLoader
            var manualLoader: ControlledLateLoader?
            var lateLoader: ControlledLateLoader?
            switch scenario {
            case .batch:
                body = RecordingLoader(batchError: "batch-error")
            case .item, .skipped:
                body = RecordingLoader(itemErrors: Dictionary(uniqueKeysWithValues: uids.map { ($0, "item-error") }))
            case .unreported:
                body = RecordingLoader(failAll: true)
            case .withheld:
                body = RecordingLoader(withheldOnce: Set(uids))
            case .timeout:
                body = CancellationAwareLoader(delay: .seconds(60))
            case .disk:
                let png = makePNGData(width: 8, height: 8)
                cache.storeToDisk(png, for: uids[0])
                cache.storeToDisk(png, for: uids[1])
                body = RecordingLoader(itemErrors: [uids[2]: "item-error", uids[3]: "item-error"])
            case .late:
                let png = makePNGData(width: 8, height: 8)
                let controlled = ControlledLateLoader(
                    payloads: Dictionary(uniqueKeysWithValues: uids.map { ($0, png) }))
                lateLoader = controlled
                body = controlled
            case .manual, .disabled:
                let controlled = ControlledLateLoader(payloads: [:])
                manualLoader = controlled
                body = controlled
            case .partial:
                let png = makePNGData(width: 8, height: 8)
                body = RecordingLoader(
                    payloads: [uids[0]: png, uids[1]: png],
                    itemErrors: [uids[2]: "item-error", uids[3]: "item-error"])
            }
            let loader = HoldingLoader(loader: body, runtime: runtime)
            let feed = ThumbnailFeedCore(
                cache: cache, loader: loader,
                configuration: ThumbnailFeedCoreConfiguration(
                    downloadConcurrencyLimit: 1, batchSize: 4, crawlBackoffSeconds: 0,
                    downloadTimeoutSeconds: scenario == .timeout || scenario == .late ? 0.1 : 30),
                diagnostics: PhotoDiagnostics(), clock: { clock.read() }
            )
            await feed.startPrefetch(uids)
            if let manualLoader {
                let started = await ThumbnailFeedCoreTests.waitForLeaseTest { await manualLoader.isWaiting() }
                XCTAssertTrue(started)
                if scenario == .manual {
                    await feed.pausePrefetch()
                } else {
                    await feed.setPrefetchEnabled(false)
                }
                await manualLoader.release()
            }
            if let lateLoader {
                let cancelled = await ThumbnailFeedCoreTests.waitForLeaseTest { await lateLoader.cancellations() == 1 }
                XCTAssertTrue(cancelled)
                await lateLoader.release()
            }
            // A held crawl stops its worker only after it classifies the batch and emits the summary.
            try await ThumbnailFeedCoreTests.waitForCrawl(feed)
            if scenario == .late {
                XCTAssertTrue(uids.allSatisfy { cache.hasUsableDiskData($0) }, "late bytes were persisted")
            }
            if scenario == .skipped || scenario == .late {
                clock.advance(2)
                let queued = scenario == .skipped ? uids : []
                _ = await feed.replaceVisiblePriorityDemand(
                    queued + [PhotoUID(volumeID: "summary", nodeID: "sentinel")])
                try await ThumbnailFeedCoreTests.waitForCrawl(feed)
            }
            let requests = await loader.requests
            XCTAssertEqual(requests, scenario == .skipped || scenario == .late ? 2 : 1)
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
                let summaries = text.split(separator: "\n").filter { $0.hasPrefix("[ThumbPrefetch] ") }
                if scenario == .disabled {
                    XCTAssertTrue(summaries.isEmpty, "a stopped generation emits no summary: \(text)")
                    continue
                }
                let summary = try XCTUnwrap(summaries.last)
                if scenario == .late {
                    XCTAssertEqual(summaries.count, 2)
                    let before = try XCTUnwrap(summaries.first)
                    XCTAssertTrue(before.contains("failed=4"), "\(before)")
                    XCTAssertTrue(before.contains("failedTimeout=4"), "\(before)")
                    XCTAssertTrue(before.contains("downloadStarted=4"), "\(before)")
                    XCTAssertTrue(before.contains("downloadCompleted=0"), "\(before)")
                }
                let fields = summary.split(separator: " ").dropFirst().compactMap { token -> (String, String)? in
                    let parts = token.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2 else { return nil }
                    return (String(parts[0]), String(parts[1]))
                }
                let values = Dictionary(fields, uniquingKeysWith: { first, _ in first })
                let expectedFailed = scenario == .partial || scenario == .disk ? 2 : 4
                XCTAssertEqual(values["failed"], "\(expectedFailed)", "\(scenario.rawValue): \(summary)")
                let classified = [
                    "failedTimeout", "failedBatchError", "failedItemError", "failedUnreported", "failedWithheld",
                ]
                let counts = try classified.map { try XCTUnwrap(values[$0].flatMap(Int.init), "\($0): \(summary)") }
                XCTAssertEqual(counts.reduce(0, +), expectedFailed, "\(scenario.rawValue): \(summary)")
                XCTAssertEqual(
                    values["downloadStarted"], scenario == .disk ? "2" : "4", "\(scenario.rawValue): \(summary)")
                XCTAssertEqual(values["diskHit"], scenario == .disk ? "2" : "0", "\(scenario.rawValue): \(summary)")
                XCTAssertEqual(values["downloadCompleted"], scenario == .partial ? "2" : "0")
                XCTAssertEqual(
                    values["unfetchable"],
                    scenario == .item || scenario == .skipped
                        ? "4" : scenario == .partial || scenario == .disk ? "2" : "0")
                XCTAssertTrue(summary.contains("lastError=\(scenario.errorText)"), "\(scenario.rawValue): \(summary)")
                if scenario == .item || scenario == .partial || scenario == .disk {
                    XCTAssertTrue(summary.contains("item-error"), "\(summary)")
                }
                if scenario == .batch { XCTAssertTrue(summary.contains("batch-error"), "\(summary)") }
                XCTAssertEqual(values["skippedUnfetchable"], scenario == .skipped ? "4" : "0")
                XCTAssertEqual(values["pausedReason"], scenario == .manual ? "manual" : "none")
                for kind in SummaryCase.allCases
                where kind != .partial && kind != .manual && kind != .disk && kind != .skipped && kind != .late
                    && kind != .disabled
                {
                    let count =
                        scenario == .skipped
                        ? (kind == .item ? 4 : 0)
                        : kind.field == scenario.field ? expectedFailed : 0
                    XCTAssertEqual(values[kind.field], "\(count)", "\(scenario.rawValue): \(summary)")
                }
            }
        }
    }
#endif
