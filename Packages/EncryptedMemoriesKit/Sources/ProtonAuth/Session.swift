import AppleSecurityCore
import Foundation
import PhotosCore

/// A fully-authenticated Proton session obtained via the web-link (session fork) flow.
public struct ProtonSession: Codable, Sendable, Equatable {
    public let uid: String
    public var accessToken: String
    public var refreshToken: String
    /// Mailbox/key password (decrypted from the fork payload). Unlocks the user's PGP keys.
    public let keyPassword: String

    public init(uid: String, accessToken: String, refreshToken: String, keyPassword: String) {
        self.uid = uid
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.keyPassword = keyPassword
    }
}

/// Persists the session (tokens + key password) in the platform Keychain.
public struct SessionKeychainStore: Sendable {
    private let item: AppleKeychainItem
    private let keychain: any AppleKeychainStoring

    public init(service: String = Self.defaultService, account: String = "default") {
        self.init(service: service, account: account, keychain: SystemAppleKeychainStore())
    }

    public init(service: String, account: String, keychain: any AppleKeychainStoring) {
        self.item = AppleKeychainItem(
            service: service,
            account: account,
            accessibility: .whenUnlockedThisDeviceOnly
        )
        self.keychain = keychain
    }

    public static let defaultService = "at.oncloud.encryptedmemories.session"

    public func load() throws -> ProtonSession? {
        guard let data = try keychain.data(for: item) else { return nil }
        do {
            return try JSONDecoder().decode(ProtonSession.self, from: data)
        } catch {
            throw SessionKeychainError.invalidPayload
        }
    }

    public func save(_ session: ProtonSession) throws {
        let data = try JSONEncoder().encode(session)
        try keychain.setData(data, for: item)
        guard try keychain.data(for: item) == data else {
            throw SessionKeychainError.verificationFailed
        }
    }

    public func clear() throws {
        try keychain.removeData(for: item)
    }
}

public enum SessionKeychainError: Error, LocalizedError, Sendable, Equatable {
    case invalidPayload
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPayload:
            "The saved Proton session is invalid."
        case .verificationFailed:
            "The Proton session could not be verified after saving."
        }
    }
}

/// Full app-private Keychain reset shared by macOS, iOS and iPadOS.
public enum ProtonAuthLocalDataPurge {
    /// Performs the shared file + Keychain transaction. The durable request is completed only when
    /// both halves succeed, so an interrupted or partially-failed logout is retried before the next
    /// session can open account-owned stores.
    @discardableResult
    public static func perform(
        claim: BackupLocalDataPurge.Claim,
        defaults: UserDefaults = .standard
    ) -> Bool {
        perform(claim: claim, defaults: defaults) {
            try purgeKeychain()
        }
    }

    /// Runs the same ordered purge away from the UI executor. The caller still awaits completion, so a
    /// new account cannot open stores while deletion is in flight.
    @discardableResult
    public static func performOffMain(
        claim: BackupLocalDataPurge.Claim,
        defaults: UserDefaults = .standard
    ) async -> Bool {
        await performOffMain(claim: claim, defaults: SendableUserDefaults(defaults)) {
            try purgeKeychain()
        }
    }

    /// Runs all cold-start cleanup in one ordered utility task. The caller still awaits the task, so
    /// session bootstrap cannot open account stores while either purge is in flight.
    @discardableResult
    public static func performStartupOffMain(
        claim: BackupLocalDataPurge.Claim?,
        defaults: UserDefaults = .standard,
        plaintextPurgeSucceeded: Bool? = nil
    ) async -> Bool {
        await performStartupOffMain(
            claim: claim,
            defaults: SendableUserDefaults(defaults),
            plaintextPurge: {
                if let plaintextPurgeSucceeded {
                    return plaintextPurgeSucceeded
                }
                return TransientPlaintextPurge.purgeShareExports().succeeded
            },
            purgeKeychain: {
                try purgeKeychain()
            }
        )
    }

    static func performOffMain(
        claim: BackupLocalDataPurge.Claim,
        defaults: SendableUserDefaults,
        purgeKeychain: @escaping @Sendable () throws -> Void
    ) async -> Bool {
        return await Task.detached(priority: .utility) {
            perform(claim: claim, defaults: defaults.value, purgeKeychain: purgeKeychain)
        }.value
    }

    static func performStartupOffMain(
        claim: BackupLocalDataPurge.Claim?,
        defaults: SendableUserDefaults,
        plaintextPurge: @escaping @Sendable () -> Bool,
        purgeKeychain: @escaping @Sendable () throws -> Void
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            let plaintextPurgeSucceeded = plaintextPurge()
            let signOutPurgeSucceeded =
                claim.map {
                    perform(claim: $0, defaults: defaults.value, purgeKeychain: purgeKeychain)
                } ?? true
            return plaintextPurgeSucceeded && signOutPurgeSucceeded
        }.value
    }

    static func perform(
        claim: BackupLocalDataPurge.Claim,
        defaults: UserDefaults,
        purgeKeychain: () throws -> Void
    ) -> Bool {
        let fileResult = claim.perform(defaults: defaults, completesRequestOnSuccess: false)
        let keychainPurged: Bool
        do {
            try purgeKeychain()
            keychainPurged = true
        } catch {
            keychainPurged = false
        }
        guard fileResult.succeeded, keychainPurged else { return false }
        BackupLocalDataPurge.markPurgeCompleted(defaults: defaults)
        return true
    }

    public static func purgeKeychain() throws {
        let keychain = SystemAppleKeychainStore()
        let services = [
            SessionKeychainStore.defaultService,
            DeviceIdentityKeychainStore.defaultService,
        ]
        for service in services {
            try keychain.removeAllData(service: service)
        }
    }
}

/// Foundation documents `UserDefaults` access as thread-safe, but the type is not annotated Sendable.
/// Keep the unchecked boundary private and transport only an immutable reference into the purge task.
struct SendableUserDefaults: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}
