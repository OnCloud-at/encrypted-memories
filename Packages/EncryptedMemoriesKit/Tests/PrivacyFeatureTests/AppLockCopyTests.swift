import PhotosCore
import XCTest

@testable import PrivacyFeature

final class AppLockCopyTests: XCTestCase {
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
        let choices: [(DeviceOwnerAuthMethod, [String], [String])] = [
            (.faceID, ["Require Face ID", "Face ID anfordern"], ["Unlock with Face ID", "Mit Face ID entsperren"]),
            (
                .touchID, ["Require Touch ID", "Touch ID anfordern"],
                ["Unlock with Touch ID", "Mit Touch ID entsperren"]
            ),
            (
                .devicePasscode, ["Require Passcode", "Code anfordern"],
                ["Unlock with Passcode", "Mit Code entsperren"]
            ),
            (
                .accountPassword, ["Require Password", "Passwort anfordern"],
                ["Unlock with Password", "Mit Passwort entsperren"]
            ),
        ]
        for (method, switches, unlocks) in choices {
            XCTAssertTrue(switches.contains(AppLockCopy.switchTitle(for: .available(method))))
            XCTAssertTrue(unlocks.contains(AppLockCopy.unlockTitle(for: .available(method))))
        }
    }

    func testTheDelayUsesNativeUnitsInASupportedAppLanguage() {
        let choices: [(Duration, [String])] = [
            (.zero, ["Immediately", "Sofort"]),
            (.seconds(30), ["30 seconds", "30 Sekunden"]),
            (.seconds(60), ["1 minute", "1 Minute"]),
            (.seconds(300), ["5 minutes", "5 Minuten"]),
            (.seconds(900), ["15 minutes", "15 Minuten"]),
        ]
        for (duration, titles) in choices {
            XCTAssertTrue(titles.contains(AppLockCopy.delayTitle(duration)), "\(duration)")
        }
    }

    func testTheUnlockReasonAndAccessibilityLabelResolve() {
        XCTAssertTrue(["Unlock your library.", "Entsperre deine Mediathek."].contains(AppLockCopy.unlockReason))
        XCTAssertTrue(["Locked", "Gesperrt"].contains(AppLockCopy.lockedLabel))
    }

    func testTheUnavailableReasonNamesTheDeviceLock() {
        #if os(macOS)
            XCTAssertTrue(
                ["Set a login password to use this.", "Lege ein Anmeldepasswort fest, um dies zu nutzen."].contains(
                    AppLockCopy.noDeviceLockReason))
        #else
            XCTAssertTrue(
                ["Set a device passcode to use this.", "Lege einen Gerätecode fest, um dies zu nutzen."].contains(
                    AppLockCopy.noDeviceLockReason))
        #endif
    }
}
