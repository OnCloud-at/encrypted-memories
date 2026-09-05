import AppleSecurityCore
import Foundation
import PhotosCore
import Security
import Testing

@testable import ProtonAuth

/// Session secrets must never have a plaintext developer bypass. Tokens and the key password are always
/// stored in the macOS Keychain.
@Suite("Session secret hardening")
struct SessionHardeningTests {
    @Test func appOwnedKeychainServicesUseEncryptedMemoriesNamespace() {
        #if os(macOS)
            #expect(SessionKeychainStore.defaultService == "at.oncloud.encryptedmemories.session")
        #endif
        #expect(DeviceIdentityKeychainStore.defaultService == "at.oncloud.encryptedmemories.device-identity")
    }

    @Test func noDeveloperPlaintextSessionSwitchExists() {
        #expect(ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_DEV_PLAINTEXT_SESSION"] == nil)
    }

    @Test func sessionEncodingRoundTripsThroughSharedKeychainContract() throws {
        let keychain = MemoryAppleKeychainStore()
        let store = SessionKeychainStore(
            service: "at.oncloud.encryptedmemories.session.tests-\(UUID().uuidString)",
            account: "default",
            keychain: keychain
        )
        let session = ProtonSession(uid: "uid-test", accessToken: "at", refreshToken: "rt", keyPassword: "kp")
        try store.save(session)
        defer { try? store.clear() }

        #expect(try store.load() == session)
        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test func sessionSaveFailsWhenDurableReadBackDoesNotMatch() {
        let keychain = NonPersistingAppleKeychainStore()
        let store = SessionKeychainStore(
            service: "at.oncloud.encryptedmemories.session.tests-\(UUID().uuidString)",
            account: "default",
            keychain: keychain
        )
        let session = ProtonSession(uid: "uid-test", accessToken: "at", refreshToken: "rt", keyPassword: "kp")

        #expect(throws: SessionKeychainError.verificationFailed) {
            try store.save(session)
        }
    }

    @Test func deviceIdentityIsStableAndDeviceLocal() {
        let keychain = MemoryAppleKeychainStore()
        let store = DeviceIdentityKeychainStore(
            service: "at.oncloud.encryptedmemories.device.tests-\(UUID().uuidString)",
            account: "installation",
            keychain: keychain
        )
        defer { store.clear() }

        let first = store.loadOrCreate()
        #expect(!first.isEmpty)
        #expect(store.loadOrCreate() == first)
    }

    @Test func fullPurgeCompletesMarkerOnlyAfterFilesAndKeychainSucceed() throws {
        let suite = "auth-purge-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-purge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("account.sqlite"))
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        let claim = try #require(BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [root]))

        let failed = ProtonAuthLocalDataPurge.perform(claim: claim, defaults: defaults) {
            throw AppleSecurityError(operation: .delete, status: errSecNotAvailable)
        }
        #expect(!failed)
        #expect(BackupLocalDataPurge.isPurgePending(defaults: defaults))

        let retry = try #require(BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [root]))
        let succeeded = ProtonAuthLocalDataPurge.perform(claim: retry, defaults: defaults) {}
        #expect(succeeded)
        #expect(!BackupLocalDataPurge.isPurgePending(defaults: defaults))
    }

    @Test func settingsResetRemovesSessionIdentityAndCachesBeforeBootstrap() async throws {
        let suite = "settings-reset-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["library.sqlite", "ml.sqlite", "thumbnail.cache", "model.artifact"] {
            try Data([1]).write(to: root.appendingPathComponent(name))
        }
        let keychain = MemoryAppleKeychainStore()
        let store = SessionKeychainStore(
            service: SessionKeychainStore.defaultService, account: "default", keychain: keychain)
        try store.save(ProtonSession(uid: "test", accessToken: "test", refreshToken: "test", keyPassword: "test"))
        let identity = DeviceIdentityKeychainStore(
            service: DeviceIdentityKeychainStore.defaultService, account: "installation", keychain: keychain)
        let oldIdentity = identity.loadOrCreate()
        defaults.set(true, forKey: BackupLocalDataPurge.resetOnNextLaunchKey)
        #expect(BackupLocalDataPurge.prepareRequestedResetForLaunch(defaults: defaults, persistentDomainName: suite))
        let claim = try #require(BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [root]))
        #expect(
            await ProtonAuthLocalDataPurge.performStartupOffMain(
                claim: claim, defaults: SendableUserDefaults(defaults), plaintextPurge: { true },
                purgeKeychain: { try ProtonAuthLocalDataPurge.purgeKeychain(using: keychain) }
            ))
        #expect(try store.load() == nil)
        #expect(identity.loadOrCreate() != oldIdentity)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(!BackupLocalDataPurge.isPurgePending(defaults: defaults))
        #expect(!defaults.bool(forKey: BackupLocalDataPurge.resetOnNextLaunchKey))
    }

    @Test @MainActor func awaitedPurgeLeavesTheUIExecutor() async throws {
        let suite = "auth-purge-off-main-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-purge-off-main-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("account.sqlite"))
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        let claim = try #require(BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [root]))
        let probe = ThreadProbe()

        let succeeded = await ProtonAuthLocalDataPurge.performOffMain(
            claim: claim,
            defaults: SendableUserDefaults(defaults)
        ) {
            probe.recordCurrentThread()
        }

        #expect(succeeded)
        #expect(probe.wasMainThread == false)
    }

    @Test @MainActor func startupCleanupRunsInOrderOffMainAndWaitsForAccountPurge() async throws {
        let suite = "auth-startup-purge-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-startup-purge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("account.sqlite"))
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        let claim = try #require(BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [root]))
        let probe = StartupPurgeProbe()

        let succeeded = await ProtonAuthLocalDataPurge.performStartupOffMain(
            claim: claim,
            defaults: SendableUserDefaults(defaults),
            plaintextPurge: {
                probe.record("plaintext")
                return true
            },
            purgeKeychain: {
                probe.record("keychain")
            }
        )

        #expect(succeeded)
        #expect(probe.events == ["plaintext", "keychain"])
        #expect(probe.usedMainThread == false)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(!BackupLocalDataPurge.isPurgePending(defaults: defaults))
    }

    @Test func platformInitializersUseTheSharedOwnedStartupBarrier() throws {
        var repoRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            repoRoot.deleteLastPathComponent()
        }

        for relativePath in ["App/AppModel.swift", "iOSApp/MobileSessionModel.swift"] {
            let source = try String(
                contentsOf: repoRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            let initializer = try startupInitializer(in: source, path: relativePath)

            #expect(initializer.contains("ProtonAuthLocalDataPurge.performStartupOffMain("))
            #expect(!initializer.contains("TransientPlaintextPurge.purgeShareExports"))
            #expect(!initializer.contains("Task.detached"))
            #expect(initializer.contains("startupCleanupTask = Task { @MainActor"))
            #expect(
                initializer.contains("beginStartupCleanup(plaintextPurgeSucceeded: startupPlaintextPurgeSucceeded)"))
            #expect(source.contains("beginStartupCleanup(signInAfterCleanup: true)"))
            #expect(source.contains("guard startupCleanupTask == nil"))
            if relativePath == "App/AppModel.swift" {
                #expect(
                    source.contains("guard !didBootstrap else { return }"),
                    "the cleanup task and SwiftUI scene task must not bootstrap macOS twice")
            }
        }
    }

    @Test func platformSignOutFailureKeepsTheDurablePurgeRecoverable() throws {
        var repoRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            repoRoot.deleteLastPathComponent()
        }

        let mac = try String(
            contentsOf: repoRoot.appendingPathComponent("App/AppModel.swift"),
            encoding: .utf8
        )
        let mobile = try String(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/MobileLibraryModel.swift"),
            encoding: .utf8
        )

        for source in [mac, mobile] {
            #expect(source.contains("pendingSignOutPurgeClaim"))
            #expect(source.contains("func retrySignOutCleanup()"))
            #expect(source.contains("ProtonAuthLocalDataPurge.performOffMain(claim: claim)"))
        }
        #expect(!mac.contains("NSApp.terminate(nil)"))
        #expect(mobile.contains("!BackupLocalDataPurge.isPurgePending()"))
    }

    private func startupInitializer(in source: String, path: String) throws -> String {
        let start = try #require(source.range(of: "init(startupPlaintextPurgeSucceeded:"))
        let endMarker =
            path.hasPrefix("App/")
            ? "\n    /// Restore a persisted session"
            : "\n    deinit"
        let end = try #require(source.range(of: endMarker, range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }
}

private struct NonPersistingAppleKeychainStore: AppleKeychainStoring {
    func data(for item: AppleKeychainItem) throws -> Data? { nil }
    func setData(_ data: Data, for item: AppleKeychainItem) throws {}
    func dataOrInsert(_ data: Data, for item: AppleKeychainItem) throws -> Data { data }
    func removeData(for item: AppleKeychainItem) throws {}
    func removeAllData(service: String) throws {}
}

private final class MemoryAppleKeychainStore: AppleKeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AppleKeychainItem: Data] = [:]

    func data(for item: AppleKeychainItem) throws -> Data? {
        lock.withLock { storage[item] }
    }

    func setData(_ data: Data, for item: AppleKeychainItem) throws {
        lock.withLock { storage[item] = data }
    }

    func dataOrInsert(_ data: Data, for item: AppleKeychainItem) throws -> Data {
        lock.withLock {
            if let existing = storage[item] { return existing }
            storage[item] = data
            return data
        }
    }

    func removeData(for item: AppleKeychainItem) throws {
        lock.withLock { _ = storage.removeValue(forKey: item) }
    }

    func removeAllData(service: String) throws {
        lock.withLock { storage = storage.filter { $0.key.service != service } }
    }
}

private final class ThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    var wasMainThread: Bool? { lock.withLock { value } }

    func recordCurrentThread() {
        lock.withLock { value = Thread.isMainThread }
    }
}

private final class StartupPurgeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []
    private var recordedMainThread = false

    var events: [String] { lock.withLock { recordedEvents } }
    var usedMainThread: Bool { lock.withLock { recordedMainThread } }

    func record(_ event: String) {
        lock.withLock {
            recordedEvents.append(event)
            recordedMainThread = recordedMainThread || Thread.isMainThread
        }
    }
}
