import Foundation
import PhotosCore
import PrivacyFeature

/// The mobile process gate; only the existing DEBUG offline fixture can supply an authenticator.
@MainActor
enum MobileAppProtection {
    static let gate: AccessGate = {
        #if DEBUG
            if MobileUITestLaunch.isRequested && !MobileUITestLaunch.usesLargeGridFixture {
                UserDefaults.standard.removeObject(forKey: AppSettingsKey.appLockEnabled)
                UserDefaults.standard.removeObject(forKey: AppSettingsKey.appLockGracePeriodSeconds)
            }
            if let result = MobileUITestLaunch.appLockFixtureResult() {
                UserDefaults.standard.set(
                    ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesAppLockInitiallyEnabled"),
                    forKey: AppSettingsKey.appLockEnabled)
                return AccessGate(authenticator: FixtureAuthenticator(result: result))
            }
        #endif
        return AppProtection.gate
    }()

    #if DEBUG
        private final class FixtureAuthenticator: DeviceOwnerAuthenticating {
            let result: DeviceOwnerAuthResult
            init(result: DeviceOwnerAuthResult) { self.result = result }
            func availability() -> DeviceOwnerAuthAvailability {
                result == .noDeviceLock ? .noDeviceLock : .available(.faceID)
            }
            func authenticate(reason: String) async -> DeviceOwnerAuthResult { result }
            func cancel() {}
        }
    #endif
}
