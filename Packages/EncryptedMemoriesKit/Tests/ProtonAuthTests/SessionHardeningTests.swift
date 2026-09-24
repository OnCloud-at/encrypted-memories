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

    @Test func deviceIdentityReturnsEphemeralUUIDWhenKeychainFails() {
        let store = DeviceIdentityKeychainStore(
            service: "at.oncloud.encryptedmemories.device.tests", account: "installation",
            keychain: FailingAppleKeychainStore()
        )
        let first = store.loadOrCreate()
        let second = store.loadOrCreate()
        #expect(UUID(uuidString: first) != nil)
        #expect(UUID(uuidString: second) != nil)
        #expect(first != second)
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
}

private struct NonPersistingAppleKeychainStore: AppleKeychainStoring {
    func data(for item: AppleKeychainItem) throws -> Data? { nil }
    func setData(_ data: Data, for item: AppleKeychainItem) throws {}
    func dataOrInsert(_ data: Data, for item: AppleKeychainItem) throws -> Data { data }
    func removeData(for item: AppleKeychainItem) throws {}
    func removeAllData(service: String) throws {}
}

private struct FailingAppleKeychainStore: AppleKeychainStoring {
    func data(for item: AppleKeychainItem) throws -> Data? {
        throw AppleSecurityError(operation: .read, status: errSecNotAvailable)
    }
    func setData(_ data: Data, for item: AppleKeychainItem) throws {
        throw AppleSecurityError(operation: .add, status: errSecNotAvailable)
    }
    func dataOrInsert(_ data: Data, for item: AppleKeychainItem) throws -> Data {
        throw AppleSecurityError(operation: .add, status: errSecNotAvailable)
    }
    func removeData(for item: AppleKeychainItem) throws {
        throw AppleSecurityError(operation: .delete, status: errSecNotAvailable)
    }
    func removeAllData(service: String) throws {
        throw AppleSecurityError(operation: .delete, status: errSecNotAvailable)
    }
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
