import PhotosCore
import XCTest

@testable import PrivacyFeature

final class AppLockCopyTests: XCTestCase {
    /// The catalog language the duration units of the delay title resolve to, through the same
    /// `durationLocale` selection `delayTitle` uses. The remaining app-lock copy resolves through
    /// `String(localized:bundle: .module)`, which follows the process language of this test run against
    /// the same module bundle, so every run checks the one process language, not both catalogs.
    private var resolvedAppLanguage: String {
        AppLockCopy.durationLocale(preferredLanguages: Locale.preferredLanguages).identifier
    }

    /// The one expected string for the resolved app language, so each language is tested against
    /// its own copy instead of accepting either catalog entry.
    private func expectedCopy(english: String, german: String) -> String {
        resolvedAppLanguage == "de" ? german : english
    }

    func testTheDisabledSwitchNamesThePlatformCredential() {
        #if os(macOS)
            XCTAssertEqual(
                AppLockCopy.switchTitle(for: .noDeviceLock),
                AppLockCopy.switchTitle(for: .available(.accountPassword)))
        #else
            XCTAssertEqual(
                AppLockCopy.switchTitle(for: .noDeviceLock),
                AppLockCopy.switchTitle(for: .available(.devicePasscode)))
        #endif
    }

    func testTheOpticIDCaseUsesTheApprovedPasscodeLabel() {
        XCTAssertEqual(
            AppLockCopy.switchTitle(for: .available(.opticID)),
            AppLockCopy.switchTitle(for: .available(.devicePasscode)))
        XCTAssertEqual(
            AppLockCopy.unlockTitle(for: .available(.opticID)),
            AppLockCopy.unlockTitle(for: .available(.devicePasscode)))
    }

    func testUnsupportedLanguagesUseEnglishDurationUnits() {
        let formatter = Duration.UnitsFormatStyle(
            allowedUnits: [.minutes, .seconds], width: .wide, maximumUnitCount: 1)
        XCTAssertEqual(
            formatter.locale(AppLockCopy.durationLocale(preferredLanguages: ["fr"])).format(.seconds(30)), "30 seconds")
        XCTAssertEqual(
            formatter.locale(AppLockCopy.durationLocale(preferredLanguages: ["de"])).format(.seconds(30)), "30 Sekunden"
        )
        XCTAssertEqual(
            formatter.locale(AppLockCopy.durationLocale(preferredLanguages: ["fr", "de"])).format(.seconds(30)),
            "30 Sekunden")
    }

    func testTheLabelsNameTheAvailableAuthenticationMethod() {
        let choices: [(DeviceOwnerAuthMethod, String, String, String, String)] = [
            (.faceID, "Require Face ID", "Face ID anfordern", "Unlock with Face ID", "Mit Face ID entsperren"),
            (
                .touchID, "Require Touch ID", "Touch ID anfordern", "Unlock with Touch ID",
                "Mit Touch ID entsperren"
            ),
            (.devicePasscode, "Require Passcode", "Code anfordern", "Unlock with Passcode", "Mit Code entsperren"),
            (
                .accountPassword, "Require Password", "Passwort anfordern", "Unlock with Password",
                "Mit Passwort entsperren"
            ),
        ]
        for (method, englishSwitch, germanSwitch, englishUnlock, germanUnlock) in choices {
            XCTAssertEqual(
                AppLockCopy.switchTitle(for: .available(method)),
                expectedCopy(english: englishSwitch, german: germanSwitch))
            XCTAssertEqual(
                AppLockCopy.unlockTitle(for: .available(method)),
                expectedCopy(english: englishUnlock, german: germanUnlock))
        }
    }

    func testTheDelayUsesNativeUnitsInASupportedAppLanguage() {
        let choices: [(Duration, String, String)] = [
            (.zero, "Immediately", "Sofort"),
            (.seconds(30), "30 seconds", "30 Sekunden"),
            (.seconds(60), "1 minute", "1 Minute"),
            (.seconds(300), "5 minutes", "5 Minuten"),
            (.seconds(900), "15 minutes", "15 Minuten"),
        ]
        for (duration, english, german) in choices {
            XCTAssertEqual(
                AppLockCopy.delayTitle(duration), expectedCopy(english: english, german: german), "\(duration)")
        }
    }

    func testTheUnlockReasonAndAccessibilityLabelResolve() {
        XCTAssertEqual(
            AppLockCopy.unlockReason,
            expectedCopy(english: "Unlock your library.", german: "Entsperre deine Mediathek."))
        XCTAssertEqual(AppLockCopy.lockedLabel, expectedCopy(english: "Locked", german: "Gesperrt"))
    }

    func testTheUnavailableReasonNamesTheDeviceLock() {
        let english: String
        let german: String
        #if os(macOS)
            english = "Set a login password to use this."
            german = "Lege ein Anmeldepasswort fest, um dies zu nutzen."
        #else
            english = "Set a device passcode to use this."
            german = "Lege einen Gerätecode fest, um dies zu nutzen."
        #endif
        XCTAssertEqual(AppLockCopy.noDeviceLockReason, expectedCopy(english: english, german: german))
    }
}
