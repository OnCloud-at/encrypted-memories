import Foundation
import LocalAuthentication
import PhotosCore

/// The system's device owner authentication for every protected area: Face ID, Touch ID or Optic ID first, then
/// the device passcode on iPhone and iPad or the account password on the Mac.
@MainActor
public final class DeviceOwnerAuthenticator: DeviceOwnerAuthenticating {
    private var context: LAContext?

    public init() {}

    /// Reads the system state each time; the result can change at any moment.
    public func availability() -> DeviceOwnerAuthAvailability {
        let context = LAContext()
        let biometrics = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        let biometryType = context.biometryType
        var error: NSError?
        let deviceOwner = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        return DeviceOwnerAuthMapping.availability(
            biometrics: biometrics, biometryType: biometryType, deviceOwner: deviceOwner,
            deviceOwnerError: (error as? LAError)?.code)
    }

    public func authenticate(reason: String) async -> DeviceOwnerAuthResult {
        context?.invalidate()
        let context = LAContext()
        self.context = context
        let result: DeviceOwnerAuthResult = await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                continuation.resume(returning: DeviceOwnerAuthMapping.result(success: success, error: error))
            }
        }
        if self.context === context { self.context = nil }
        return result
    }

    /// Invalidating the context ends its prompt; the result then arrives as `cancelled`.
    public func cancel() {
        context?.invalidate()
        context = nil
    }
}

/// Pure translations of LocalAuthentication answers, so every case is testable without a prompt.
public enum DeviceOwnerAuthMapping {
    /// Names biometry only when biometric evaluation can run now; otherwise the passcode or password. Only a
    /// missing passcode means that the device has no lock: any other failed check is left to the authentication
    /// itself, so a passing problem never turns the lock off.
    public static func availability(
        biometrics: Bool, biometryType: LABiometryType, deviceOwner: Bool, deviceOwnerError: LAError.Code?
    ) -> DeviceOwnerAuthAvailability {
        if biometrics {
            switch biometryType {
            case .faceID: return .available(.faceID)
            case .touchID: return .available(.touchID)
            case .opticID: return .available(.opticID)
            case .none: break
            @unknown default: break
            }
        }
        if !deviceOwner, deviceOwnerError == .passcodeNotSet { return .noDeviceLock }
        #if os(macOS)
            return .available(.accountPassword)
        #else
            return .available(.devicePasscode)
        #endif
    }

    public static func result(success: Bool, error: (any Error)?) -> DeviceOwnerAuthResult {
        if success { return .success }
        guard let error = error as? LAError else { return .failed }
        switch error.code {
        case .userCancel, .systemCancel, .appCancel, .notInteractive, .userFallback: return .cancelled
        case .passcodeNotSet: return .noDeviceLock
        default: return .failed
        }
    }
}
