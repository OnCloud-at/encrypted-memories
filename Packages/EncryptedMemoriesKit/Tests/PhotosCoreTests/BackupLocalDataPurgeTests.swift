import XCTest

@testable import PhotosCore

/// Verifies that explicit sign-out arms the purge and failed cleanup remains pending.
final class BackupLocalDataPurgeTests: XCTestCase {
    private actor Gate {
        private var isOpen = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "purge-test-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "purge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: url.appendingPathComponent("queue.sqlite"))
        return url
    }

    func testPurgeRunsOnlyWhenArmedThenDisarms() throws {
        let root = try makeTempRoot()

        // An unarmed purge must not touch local data.
        XCTAssertFalse(BackupLocalDataPurge.purgeIfSignOutRequested(defaults: defaults, roots: [root]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "an un-armed purge must not delete anything")

        // Explicit sign-out arms the purge, which then purges and disarms.
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        XCTAssertTrue(BackupLocalDataPurge.purgeIfSignOutRequested(defaults: defaults, roots: [root]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "an armed purge removes the account root")

        // After disarming, a second teardown is a no-op.
        let root2 = try makeTempRoot()
        XCTAssertFalse(BackupLocalDataPurge.purgeIfSignOutRequested(defaults: defaults, roots: [root2]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root2.path))
    }

    func testLogoutClearsPersistentDomainButRetainsRecoveryMarker() throws {
        defaults.set("bookmark", forKey: "backup.folderBookmarks.v1")
        BackupLocalDataPurge.requestPurgeOnSignOut(
            defaults: defaults,
            persistentDomainName: suiteName
        )

        XCTAssertNil(defaults.string(forKey: "backup.folderBookmarks.v1"))
        XCTAssertTrue(BackupLocalDataPurge.isPurgePending(defaults: defaults))
    }

    func testSettingsResetClearsPreferencesAndHandsOffToOneResumablePurge() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        defaults.set(12345, forKey: "thumbnail.cachedBytes")
        defaults.set(true, forKey: "ml.enabled")
        XCTAssertFalse(
            BackupLocalDataPurge.prepareRequestedResetForLaunch(
                defaults: defaults, persistentDomainName: suiteName
            ))
        XCTAssertEqual(defaults.integer(forKey: "thumbnail.cachedBytes"), 12345)

        defaults.set(true, forKey: BackupLocalDataPurge.resetOnNextLaunchKey)
        XCTAssertTrue(
            BackupLocalDataPurge.prepareRequestedResetForLaunch(
                defaults: defaults, persistentDomainName: suiteName
            ))
        XCTAssertFalse(defaults.bool(forKey: BackupLocalDataPurge.resetOnNextLaunchKey))
        XCTAssertNil(defaults.object(forKey: "thumbnail.cachedBytes"))
        XCTAssertNil(defaults.object(forKey: "ml.enabled"))
        XCTAssertTrue(BackupLocalDataPurge.isPurgePending(defaults: defaults))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "Arming must not do UI-thread filesystem work")

        // A second launch must retain the already-armed transaction rather than clear its retry marker.
        XCTAssertFalse(
            BackupLocalDataPurge.prepareRequestedResetForLaunch(
                defaults: defaults, persistentDomainName: suiteName
            ))
        let claim = try XCTUnwrap(BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [root]))
        XCTAssertTrue(claim.perform(defaults: defaults).succeeded)
        XCTAssertFalse(BackupLocalDataPurge.isPurgePending(defaults: defaults))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testFailedClaimKeepsPendingMarkerForNextLaunch() throws {
        let root = try makeTempRoot()
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        let claim = try XCTUnwrap(
            BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [root])
        )

        let result = claim.perform(
            defaults: defaults,
            completesRequestOnSuccess: true,
            removeItem: { _ in throw CocoaError(.fileWriteNoPermission) }
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.failedRoots, [root])
        XCTAssertTrue(BackupLocalDataPurge.isPurgePending(defaults: defaults))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testClaimWaitsForExplicitPerformanceAndCompletesMarker() throws {
        let root = try makeTempRoot()
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)

        let claim = try XCTUnwrap(
            BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [root])
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "claiming must not race open stores")
        let result = claim.perform(defaults: defaults)
        XCTAssertEqual(result.removedRoots, [root])
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertFalse(BackupLocalDataPurge.purgeIfSignOutRequested(defaults: defaults, roots: [root]))
    }

    func testPurgeAllIsIdempotentOverMissingRoots() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(
            "does-not-exist-\(UUID().uuidString)")
        let result = BackupLocalDataPurge.purgeAllLocalAccountData(roots: [missing])
        XCTAssertTrue(result.succeeded, "missing roots are ignored, not errors")
        XCTAssertTrue(result.removedRoots.isEmpty)
    }

    func testTransientShareExportPurgeDeletesOnlyCanonicalChildWithoutFollowingSymlinks() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("transient-purge-\(UUID().uuidString)", isDirectory: true)
        let exports = parent.appendingPathComponent("ShareExports", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("transient-purge-outside-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent("must-survive.txt")
        try Data("private".utf8).write(to: outsideFile)
        try Data("export".utf8).write(to: exports.appendingPathComponent("stale.jpg"))
        try FileManager.default.createSymbolicLink(
            at: exports.appendingPathComponent("outside-link"),
            withDestinationURL: outside
        )

        let result = TransientPlaintextPurge.purgeShareExports(temporaryDirectory: parent)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.directory, exports.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exports.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    func testDisplayWakePolicyRequiresExplicitForegroundActiveBackup() {
        for optedIn in [false, true] {
            for foreground in [false, true] {
                for active in [false, true] {
                    XCTAssertEqual(
                        BackupDisplayWakePolicy.shouldKeepDisplayAwake(
                            userOptedIn: optedIn,
                            applicationIsForegroundActive: foreground,
                            backupIsActivelyProcessing: active
                        ),
                        optedIn && foreground && active
                    )
                }
            }
        }
        XCTAssertFalse(AppSettingsDefault.keepDisplayAwakeDuringForegroundBackup)
    }

    @MainActor
    func testSignOutBarrierRejectsOverlapAndWaitsForCleanup() async {
        let barrier = AccountSignOutBarrier()
        let gate = Gate()
        var completed = 0

        XCTAssertTrue(
            barrier.begin {
                await gate.wait()
                completed += 1
            })
        XCTAssertTrue(barrier.isRunning)
        XCTAssertFalse(barrier.begin { completed += 100 })

        await gate.open()
        await barrier.waitUntilFinished()

        XCTAssertFalse(barrier.isRunning)
        XCTAssertEqual(completed, 1)
    }
}
