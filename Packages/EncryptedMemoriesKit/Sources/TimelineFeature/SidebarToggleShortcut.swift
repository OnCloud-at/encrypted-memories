import AppKit

/// Handles ⌥⌘S before any menu sees it.
///
/// AppKit keeps a hidden "Toggle Sidebar" item in the Help menu and gives it ⌥⌘S after the first sidebar toggle. Its
/// `toggleSidebar:` action changes the split view behind SwiftUI's back, and SwiftUI restores its column binding at
/// once, so the shortcut seems to stop working after one use. The app therefore runs its own toggle for the shortcut,
/// which moves the sidebar and the grid together.
@MainActor public enum SidebarToggleShortcut {
    private static var monitor: Any?

    /// Installs the shortcut once for the process. `onToggle` runs for every ⌥⌘S in a window of the app.
    public static func install(onToggle: @escaping @MainActor () -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard matches(event) else { return event }
            onToggle()
            return nil
        }
    }

    static func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return event.type == .keyDown && flags == [.command, .option]
            && event.charactersIgnoringModifiers?.lowercased() == "s"
    }
}
