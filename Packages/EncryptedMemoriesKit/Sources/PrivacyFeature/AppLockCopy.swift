import Foundation
import PhotosCore

/// The app lock's copy, shared by the native settings and every window cover.
public enum AppLockCopy {
    public static func switchTitle(for availability: DeviceOwnerAuthAvailability) -> String {
        L10n.string("settings.privacy_app_lock_require_method \(methodName(for: availability))")
    }

    public static func unlockTitle(for availability: DeviceOwnerAuthAvailability) -> String {
        L10n.string("settings.privacy_app_lock_unlock_method \(methodName(for: availability))")
    }

    public static var unlockReason: String { L10n.string("settings.privacy_app_lock_unlock_reason") }
    public static var lockedLabel: String { L10n.string("settings.privacy_app_lock_locked") }

    public static var noDeviceLockReason: String {
        #if os(macOS)
            L10n.string("settings.privacy_app_lock_no_password")
        #else
            L10n.string("settings.privacy_app_lock_no_passcode")
        #endif
    }

    public static func delayTitle(_ duration: Duration) -> String {
        if duration == .zero { return L10n.string("settings.privacy_app_lock_immediately") }
        return Duration.UnitsFormatStyle(allowedUnits: [.minutes, .seconds], width: .wide, maximumUnitCount: 1)
            .locale(durationLocale(preferredLanguages: Locale.preferredLanguages))
            .format(duration)
    }

    static func durationLocale(preferredLanguages: [String]) -> Locale {
        let bundle = L10n.resourceBundle
        let fallback = bundle.developmentLocalization ?? "en"
        let languages = [fallback] + bundle.localizations.filter { $0 != fallback && $0 != "Base" }
        let language = Bundle.preferredLocalizations(from: languages, forPreferences: preferredLanguages).first
        return Locale(identifier: language ?? fallback)
    }

    private static func methodName(for availability: DeviceOwnerAuthAvailability) -> String {
        switch availability {
        case .available(.faceID): return "Face ID"
        case .available(.touchID): return "Touch ID"
        // Unreachable on the shipped iOS and macOS targets; use the approved device credential label.
        case .available(.opticID): return L10n.string("settings.privacy_app_lock_passcode")
        case .available(.devicePasscode): return L10n.string("settings.privacy_app_lock_passcode")
        case .available(.accountPassword): return L10n.string("settings.privacy_app_lock_password")
        case .noDeviceLock:
            #if os(macOS)
                return L10n.string("settings.privacy_app_lock_password")
            #else
                return L10n.string("settings.privacy_app_lock_passcode")
            #endif
        }
    }
}
