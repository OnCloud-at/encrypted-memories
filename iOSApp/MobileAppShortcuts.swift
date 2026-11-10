import AppIntents
import AppRouteIntents

/// Siri phrases and Spotlight shortcuts for the route intents. App Shortcuts exist only on iOS and iPadOS; on the
/// Mac the same intents appear as actions in the Shortcuts app.
struct MobileAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenLibraryIntent(),
            phrases: ["Show my library in \(.applicationName)"],
            shortTitle: LocalizedStringResource("Open Library", table: "AppIntents"),
            systemImageName: "photo.on.rectangle.angled"
        )
        AppShortcut(
            intent: OpenCollectionIntent(),
            phrases: ["Show \(\.$target) in \(.applicationName)"],
            shortTitle: LocalizedStringResource("Open Collection", table: "AppIntents"),
            systemImageName: "square.stack"
        )
    }
}
