import CryptoKit
import Foundation
import XCTest

#if os(macOS)
    final class UpgradeFixtureTests: XCTestCase {
        struct Manifest: Decodable {
            let format: Int
            let release: String
            let commit: String
            let sdk: String
            let scenarios: [String: [Snapshot]]
        }
        struct Snapshot: Decodable {
            struct Event: Decodable {
                let id: Int
                let kind: String
                let path: String
                let frames: Int
                let threshold: Int
                let result: Int
            }
            let event: Event
            let atomicTargets: [String: [String]]
            let atomicHelpers: [String: String]
            let retryIssueObserved: Bool
            struct FileMetadata: Decodable {
                let mtimeNanoseconds: Int64
                let mode: Int
                let byteCount: Int
            }
            let files: [String: String]
            let metadata: [String: FileMetadata]
            let directories: [String]
            let oracle: FixtureOracle
        }
        private func manifest() throws -> Manifest {
            let url = try XCTUnwrap(
                Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Fixtures"),
                "The recorded release corpus is missing")
            return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        }

        func testCommittedCorpusCoversEveryScenario() throws {
            guard ProcessInfo.processInfo.environment["UPGRADE_CHECK_SCENARIO"] == nil else { return }
            let corpus = try manifest()
            XCTAssertEqual(corpus.format, 1)
            XCTAssertEqual(corpus.release, "v1.0.5")
            XCTAssertEqual(corpus.commit, "79d55a3fb5e3537f429808c19cfc44b6ee4d3647")
            XCTAssertEqual(corpus.sdk, "0.29.1")
            XCTAssertEqual(Set(corpus.scenarios.keys), Set(FixtureWorkloads.scenarios))
            for scenario in FixtureWorkloads.scenarios {
                let snapshots = try XCTUnwrap(corpus.scenarios[scenario])
                XCTAssertFalse(snapshots.isEmpty, scenario)
                XCTAssertEqual(
                    snapshots.map(\.event.id), Array(1..<(snapshots.count + 1)), "Every boundary must be retained")
                if scenario == "backup" || scenario == "index" {
                    XCTAssertTrue(snapshots.contains { $0.event.kind == "commit" }, "No SQLite commit observed")
                    XCTAssertTrue(snapshots.contains { $0.files.keys.contains { $0.hasSuffix("-wal") } }, "WAL missing")
                    XCTAssertTrue(snapshots.contains { $0.files.keys.contains { $0.hasSuffix("-shm") } }, "SHM missing")
                }
            }
            let backup = try XCTUnwrap(corpus.scenarios["backup"])
            XCTAssertTrue(backup.contains { !$0.oracle.complete.isEmpty }, "No historical backed-up revision in corpus")
            XCTAssertTrue(backup.contains { !$0.oracle.remote.isEmpty }, "No independent server commit in corpus")
            let states = Set(backup.flatMap { $0.oracle.queueStates ?? [] })
            XCTAssertTrue(
                states.isSuperset(of: [
                    "discovered", "checking", "uploading", "needsRemoteReconciliation", "completed", "alreadyBackedUp",
                ]),
                "Missing persisted upload boundaries")
            XCTAssertTrue(backup.contains { $0.retryIssueObserved }, "Network retry boundary missing")
            XCTAssertTrue(backup.contains { $0.oracle.generation == 2 }, "Edit boundaries missing")
            XCTAssertTrue(backup.contains { $0.oracle.generation == 3 }, "Undo boundaries missing")
            for scenario in ["model", "index"] {
                let snapshots = try XCTUnwrap(corpus.scenarios[scenario])
                XCTAssertTrue(
                    snapshots.contains { snapshot in
                        snapshot.metadata.contains { path, file in
                            path.contains("weights.bin") && file.byteCount > 0
                                && file.byteCount < FixtureWorkloads.payload.count
                        }
                    }, "Partial model download missing")
            }
            let caches = try XCTUnwrap(corpus.scenarios["cache"])
            for namespace in ["thumbnails.enc", "previews.enc"] {
                XCTAssertTrue(
                    caches.contains { snapshot in
                        snapshot.metadata.contains { path, file in
                            snapshot.atomicHelpers[path]?.contains(namespace) == true && file.byteCount > 2048
                                && file.byteCount < FixtureWorkloads.cacheBytes.count
                        }
                    }, "Partial atomic cache helper missing: \(namespace)")
            }
            let fixtureRoot = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
            let entries = try XCTUnwrap(
                FileManager.default.enumerator(
                    at: fixtureRoot, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]))
            let size = try entries.compactMap { $0 as? URL }.reduce(0) { result, url in
                let metadata = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                return result + (metadata.isRegularFile == true ? metadata.fileSize ?? 0 : 0)
            }
            XCTAssertLessThanOrEqual(size, 15_000_000)
        }

        func testEveryRecordedFirstLaunch() throws {
            guard ProcessInfo.processInfo.environment["UPGRADE_CHECK_SCENARIO"] == nil else { return }
            _ = try manifest()
            let started = ContinuousClock.now
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "upgrade-check-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let archive = try XCTUnwrap(
                Bundle.module.url(forResource: "corpus", withExtension: "tar.gz", subdirectory: "Fixtures"))
            let extraction = Process()
            extraction.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            extraction.arguments = ["-xzf", archive.path, "-C", root.path]
            try extraction.run()
            extraction.waitUntilExit()
            XCTAssertEqual(extraction.terminationStatus, 0)
            guard extraction.terminationStatus == 0 else { return }

            let limit = max(1, min(3, ProcessInfo.processInfo.activeProcessorCount / 2))
            let slots = DispatchSemaphore(value: limit)
            let group = DispatchGroup()
            let results = Results()
            for scenario in FixtureWorkloads.scenarios {
                group.enter()
                DispatchQueue.global().async {
                    slots.wait()
                    defer {
                        slots.signal()
                        group.leave()
                    }
                    do {
                        let log = root.appendingPathComponent("\(scenario).log")
                        FileManager.default.createFile(atPath: log.path, contents: nil)
                        let output = try FileHandle(forWritingTo: log)
                        defer { try? output.close() }
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
                        process.arguments = [
                            "-p", "(version 1)(allow default)(deny network*)", "/usr/bin/xcrun", "xctest", "-XCTest",
                            "UpgradeFixtureTests.UpgradeFixtureTests/testScenarioWorker",
                            Bundle(for: UpgradeFixtureTests.self).bundleURL.path,
                        ]
                        let inherited = ProcessInfo.processInfo.environment
                        let allowed = [
                            "HOME", "PATH", "DEVELOPER_DIR", "TMPDIR", "LANG", "LC_ALL",
                            "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
                        ]
                        var environment = Dictionary(
                            uniqueKeysWithValues: allowed.compactMap { key in
                                inherited[key].map { (key, $0) }
                            })
                        environment["UPGRADE_CHECK_SCENARIO"] = scenario
                        environment["UPGRADE_CHECK_POOL"] = root.path
                        let dataRoot = root.appendingPathComponent("data-\(scenario)")
                        let temporary = dataRoot.appendingPathComponent("Temporary")
                        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                        environment["TMPDIR"] = temporary.path + "/"
                        process.environment = environment
                        process.standardOutput = output
                        process.standardError = output
                        let done = DispatchSemaphore(value: 0)
                        process.terminationHandler = { _ in done.signal() }
                        try process.run()
                        if done.wait(timeout: .now() + 120) == .timedOut {
                            process.terminate()
                            if done.wait(timeout: .now() + 2) == .timedOut {
                                kill(process.processIdentifier, SIGKILL)
                                process.waitUntilExit()
                            }
                            results.append("\(scenario): exceeded 120 second deadline")
                        } else {
                            let text = try String(contentsOf: log, encoding: .utf8)
                            if process.terminationStatus != 0 {
                                let errors = text.split(separator: "\n").filter { $0.contains("error:") }
                                results.append(
                                    "\(scenario): worker exit \(process.terminationStatus)\n\(errors.joined(separator: "\n"))\n\(text.suffix(1500))"
                                )
                            } else if !text.contains("Verified upgrade scenario: \(scenario)") {
                                results.append("\(scenario): worker did not verify any recorded boundaries")
                            } else {
                                let expected = text.components(separatedBy: "Expected failure").count - 1
                                print("Verified upgrade scenario: \(scenario), expected failures: \(expected)")
                            }
                        }
                    } catch { results.append("\(scenario): \(error)") }
                }
            }
            group.wait()
            for failure in results.failures { XCTFail(failure) }
            let elapsed = started.duration(to: .now)
            print("Upgrade corpus verification duration: \(elapsed)")
            XCTAssertLessThan(elapsed, .seconds(300), "Upgrade verification exceeds the CI runtime budget")
        }

        func testScenarioWorker() async throws {
            let environment = ProcessInfo.processInfo.environment
            guard let scenario = environment["UPGRADE_CHECK_SCENARIO"], let poolPath = environment["UPGRADE_CHECK_POOL"]
            else { return }
            let snapshots = try XCTUnwrap(try manifest().scenarios[scenario])
            let pool = URL(fileURLWithPath: poolPath)
            for snapshot in snapshots {
                let root = pool.appendingPathComponent("data-\(scenario)")
                print(
                    "Checking \(scenario) boundary \(snapshot.event.id) \(snapshot.event.kind) \(snapshot.event.path)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                var failure: (any Error)?
                do {
                    for directory in snapshot.directories {
                        try validateRelativePath(directory)
                        try FileManager.default.createDirectory(
                            at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
                    }
                    for (relative, digest) in snapshot.files {
                        try validateRelativePath(relative)
                        try fixtureRequire(
                            digest.count == 64 && digest.allSatisfy { $0.isHexDigit }, "Invalid fixture hash")
                        let data = try Data(contentsOf: pool.appendingPathComponent("blobs/\(digest)"))
                        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        try fixtureRequire(actual == digest, "Fixture blob hash mismatch")
                        let destination = root.appendingPathComponent(relative)
                        try data.write(to: destination)
                        let metadata = try XCTUnwrap(snapshot.metadata[relative])
                        try FileManager.default.setAttributes(
                            [
                                .modificationDate: Date(
                                    timeIntervalSince1970: Double(metadata.mtimeNanoseconds) / 1_000_000_000),
                                .posixPermissions: metadata.mode,
                            ], ofItemAtPath: destination.path)
                    }
                    for (target, allowed) in snapshot.atomicTargets {
                        if let digest = snapshot.files[target] {
                            try fixtureRequire(
                                allowed.contains(digest), "Atomic target was partially visible: \(target)")
                        }
                    }
                    try await FixtureWorkloads.run(scenario, root: root, recording: false, oracle: snapshot.oracle)
                    if snapshot.atomicHelpers.keys.contains(where: { !$0.hasPrefix("Temporary/") }) {
                        for helper in snapshot.atomicHelpers.keys where !helper.hasPrefix("Temporary/") {
                            try fixtureRequire(
                                !FileManager.default.fileExists(atPath: root.appendingPathComponent(helper).path),
                                "Interrupted atomic helper remains outside system-managed temporary storage: \(helper)")
                        }
                        let afterFirstLaunch = try auxiliaryUsage(root, snapshot: snapshot)
                        for _ in 0..<2 {
                            try await FixtureWorkloads.run(
                                scenario, root: root, recording: false, oracle: snapshot.oracle)
                            let repeated = try auxiliaryUsage(root, snapshot: snapshot)
                            try fixtureRequire(
                                repeated.files <= afterFirstLaunch.files && repeated.bytes <= afterFirstLaunch.bytes,
                                "Interrupted-write helpers grow over repeated launches")
                        }
                    }
                } catch { failure = error }
                let reportFailure = {
                    if let failure { XCTFail("\(scenario) boundary \(snapshot.event.id): \(failure)") }
                }
                if let known = knownFailure(scenario, snapshot: snapshot) {
                    let options = XCTExpectedFailure.Options()
                    options.issueMatcher = { issue in
                        issue.compactDescription.contains(
                            "\(scenario) boundary \(snapshot.event.id): \(known.signature)")
                    }
                    XCTExpectFailure(known.issue, options: options) { reportFailure() }
                } else {
                    reportFailure()
                }
                try FileManager.default.removeItem(at: root)
            }
            print("Verified upgrade scenario: \(scenario), boundaries: \(snapshots.count)")
        }

        private func knownFailure(_ scenario: String, snapshot: Snapshot) -> (issue: String, signature: String)? {
            if ["model", "index"].contains(scenario), snapshot.event.id == 14,
                snapshot.event.path == "/SmartSearch/tmp/staging-synthetic-model-r1/install.json"
            {
                return (
                    "Issue #390: interrupted staging install record prevents recovery",
                    "installation: ambiguousModelArtifact"
                )
            }
            let failures: [String: [Int: String]] = [
                "backup": [
                    3: "queue", 4: "queue", 20: "backup state", 21: "backup state",
                    33: "identity manifest", 34: "identity manifest", 71: "catalog", 72: "catalog",
                ],
                "model": [18: "semantic index", 19: "semantic index"],
                "index": [66: "native index", 67: "native index"],
            ]
            guard let store = failures[scenario]?[snapshot.event.id] else { return nil }
            return (
                "Issue #391: empty WAL database cannot pass read-only schema inspection",
                store == "semantic index" ? "storage: index store unavailable" : "Fatal store open: \(store)"
            )
        }

        private func auxiliaryUsage(_ root: URL, snapshot: Snapshot) throws -> (files: Int, bytes: Int) {
            let parents = Set(
                snapshot.atomicHelpers.keys.map { path in
                    path.hasPrefix("Temporary/")
                        ? "Temporary" : path.split(separator: "/").dropLast().joined(separator: "/")
                })
            var count = 0
            var bytes = 0
            for parent in parents {
                let directory = root.appendingPathComponent(parent)
                guard FileManager.default.fileExists(atPath: directory.path) else { continue }
                let entries = try XCTUnwrap(
                    FileManager.default.enumerator(
                        at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]))
                for case let file as URL in entries {
                    let path = String(file.path.dropFirst(root.path.count + 1))
                    guard snapshot.atomicTargets[path] == nil else { continue }
                    let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    if values.isRegularFile == true {
                        count += 1
                        bytes += values.fileSize ?? 0
                    }
                }
            }
            return (count, bytes)
        }

        private func validateRelativePath(_ path: String) throws {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            try fixtureRequire(
                !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." },
                "Unsafe fixture path")
        }

        private final class Results: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String] = []
            func append(_ value: String) { lock.withLock { values.append(value) } }
            var failures: [String] { lock.withLock { values } }
        }
    }
#endif
