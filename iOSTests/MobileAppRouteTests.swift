import AppRouteIntents
import Foundation
import PhotosCore
import Testing

@testable import EncryptedMemoriesMobile

/// Links and Shortcuts actions on iPhone and iPad: the account states they wait for and the texts that the app
/// bundle ships for the Shortcuts app and Siri.
@Suite struct MobileAppRouteTests {
    @Test func routesWaitWhileTheSavedSessionIsRestored() {
        #expect(MobileRootPresentation.restoringSession.routeSession(isSigningOut: false) == .restoring)
    }

    @Test func routesOpenOnlyForASignedInAccount() {
        #expect(MobileRootPresentation.signedIn.routeSession(isSigningOut: false) == .usable)
        #expect(MobileRootPresentation.signedOut.routeSession(isSigningOut: false) == .signedOut)
        #expect(MobileRootPresentation.unsupportedDevice.routeSession(isSigningOut: false) == .signedOut)
    }

    @Test func routesAreDroppedWhileASignOutRunsOrItsCleanupFailed() {
        for presentation in [
            MobileRootPresentation.restoringSession, .signedIn, .signedOut, .unsupportedDevice,
        ] {
            #expect(presentation.routeSession(isSigningOut: true) == .signedOut)
        }
    }

    /// App Intents look their texts up in the app's main bundle, so the shared table must ship in it.
    @Test func theAppBundleShipsTheIntentTextsInEnglishAndGerman() {
        let expected: [(LocalizedStringResource, String, String)] = [
            (OpenLibraryIntent.title, "Open Library", "Mediathek öffnen"),
            (OpenCollectionIntent.title, "Open Collection", "Sammlung öffnen"),
            (AppRouteCollection.typeDisplayRepresentation.name, "Collection", "Sammlung"),
        ]
        for (resource, english, german) in expected {
            #expect(localized(resource, "en") == english)
            #expect(localized(resource, "de") == german)
        }
    }

    /// Xcode extracts the intents from the statically linked package into the app's App Intents metadata; the
    /// system reads only that file, so both actions and both App Shortcuts must be in the shipped bundle.
    @Test func theAppBundleListsBothActionsAndTheirShortcuts() throws {
        let url = try #require(
            Bundle.main.url(forResource: "extract", withExtension: "actionsdata", subdirectory: "Metadata.appintents"))
        let metadata = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let actions = try #require(metadata["actions"] as? [String: Any])
        #expect(Set(actions.keys) == ["OpenLibraryIntent", "OpenCollectionIntent"])
        let shortcuts = try #require(metadata["autoShortcuts"] as? [[String: Any]])
        let shortcutActions = shortcuts.compactMap { $0["actionIdentifier"] as? String }
        #expect(shortcutActions == ["OpenLibraryIntent", "OpenCollectionIntent"])
    }

    private func localized(_ resource: LocalizedStringResource, _ language: String) -> String {
        var resource = resource
        resource.locale = Locale(identifier: language)
        return String(localized: resource)
    }
}
