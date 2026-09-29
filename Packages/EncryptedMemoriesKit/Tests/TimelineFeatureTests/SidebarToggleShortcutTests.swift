import AppKit
import XCTest

@testable import TimelineFeature

@MainActor final class SidebarToggleShortcutTests: XCTestCase {
    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 1))
    }

    func testOnlyOptionCommandSTogglesTheSidebar() throws {
        XCTAssertTrue(SidebarToggleShortcut.matches(try key("s", [.command, .option])))
        XCTAssertTrue(SidebarToggleShortcut.matches(try key("S", [.command, .option, .capsLock])))
        XCTAssertFalse(SidebarToggleShortcut.matches(try key("s", [.command])))
        XCTAssertFalse(SidebarToggleShortcut.matches(try key("s", [.command, .control])))
        XCTAssertFalse(SidebarToggleShortcut.matches(try key("s", [.command, .option, .shift])))
        XCTAssertFalse(SidebarToggleShortcut.matches(try key("r", [.command, .option])))
    }
}
