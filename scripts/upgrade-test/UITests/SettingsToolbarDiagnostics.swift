#if os(macOS)
    import AppKit
    import ApplicationServices
    import XCTest

    /// Temporary hosted diagnosis. This file does not belong to the release gate.
    @MainActor
    enum SettingsToolbarDiagnostics {
        static func run(
            _ test: XCTestCase, app: XCUIApplication, settings: XCUIElement, tab: XCUIElement,
            title: String, isAcknowledged: () -> Bool, waitForAcknowledgement: () -> Bool
        ) throws {
            let previous = test.continueAfterFailure
            test.continueAfterFailure = true
            defer { test.continueAfterFailure = previous }

            func capture(_ stage: String) {
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "App UI hierarchy - Settings diagnostic - \(stage)"
                hierarchy.lifetime = .keepAlways
                test.add(hierarchy)
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Settings diagnostic screenshot - \(stage)"
                screenshot.lifetime = .keepAlways
                test.add(screenshot)
                var facts: [String: Any] = [
                    "stage": stage, "pane": title,
                    "tabFrame": NSStringFromRect(tab.frame), "isHittable": tab.isHittable,
                    "isEnabled": tab.isEnabled, "isSelected": tab.isSelected,
                    "acknowledged": isAcknowledged(), "settingsFrame": NSStringFromRect(settings.frame),
                    "windowCount": app.windows.count,
                    "ownedWindowFacts": app.windows.allElementsBoundByIndex.map { window in
                        [
                            "title": ["Settings", "Library"].contains(window.label)
                                ? window.label : "other owned window",
                            "frame": NSStringFromRect(window.frame),
                            "treeHasKeyboardFocus": window.debugDescription.contains("Keyboard Focused"),
                        ] as [String: Any]
                    },
                    "mainDisplayFrame": NSScreen.main.map { NSStringFromRect($0.frame) } ?? "unavailable",
                ]
                facts.merge(focusedWindowFacts()) { _, new in new }
                log(facts)
            }

            func attempt(_ strategy: String, _ action: () -> Void) {
                capture(strategy + " before")
                let before = isAcknowledged()
                action()
                let after = waitForAcknowledgement()
                log([
                    "strategy": strategy, "beforeAcknowledged": before,
                    "afterAcknowledged": after, "switchedToPane": !before && after,
                ])
                capture(strategy + " after")
            }

            capture("initial")
            attempt("a element click") { tab.click() }
            attempt("b center coordinate click") {
                tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            }
            attempt("c hover then click") {
                tab.hover()
                tab.click()
            }

            // The pinned historical toolbar declares no pane keyboard shortcut.
            // Inspect native menus for an exact pane command; never trigger backup work instead.
            var menuCommandFound = false
            for menu in app.menuBars.menuBarItems.allElementsBoundByIndex {
                menu.click()
                let commands = app.menuItems.matching(NSPredicate(format: "label == %@", title))
                log(["strategy": "d menu lookup", "menu": menu.label, "matchingPaneCommands": commands.count])
                if commands.count == 1, commands.firstMatch.isEnabled, commands.firstMatch.isHittable {
                    menuCommandFound = true
                    attempt("d exact pane menu command") { commands.firstMatch.click() }
                    break
                }
                app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            }
            if !menuCommandFound {
                log(["strategy": "d", "status": "No exact pane menu command; no declared toolbar shortcut"])
            }
            log(["strategy": "e", "status": "AXPress is unavailable through XCUIElement; no action"])
            capture("final")
            guard isAcknowledged() else {
                throw NSError(
                    domain: "SettingsToolbarDiagnostics", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No diagnostic strategy selected the \(title) pane"])
            }
        }

        private static func focusedWindowFacts() -> [String: Any] {
            guard let path = ProcessInfo.processInfo.environment["UPGRADE_APP_PATH"] else {
                return ["focusedWindowStatus": "Missing owned app path"]
            }
            let ownedURL = URL(fileURLWithPath: path).standardizedFileURL
            let instances = NSWorkspace.shared.runningApplications.filter {
                $0.bundleURL?.standardizedFileURL == ownedURL
            }
            guard instances.count == 1, let instance = instances.first else {
                return ["focusedWindowStatus": "Owned app instance is missing or ambiguous"]
            }
            var focused: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                AXUIElementCreateApplication(instance.processIdentifier),
                kAXFocusedWindowAttribute as CFString, &focused)
            var facts: [String: Any] = [
                "ownedAppIsActive": instance.isActive, "focusedWindowAXStatus": result.rawValue,
            ]
            guard result == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
                facts["settingsWindowIsKey"] = "unverified"
                return facts
            }
            var title: CFTypeRef?
            let titleResult = AXUIElementCopyAttributeValue(
                focused as! AXUIElement, kAXTitleAttribute as CFString, &title)
            facts["focusedWindowTitleAXStatus"] = titleResult.rawValue
            if titleResult == .success, let name = title as? String {
                facts["focusedWindow"] = ["Settings", "Library"].contains(name) ? name : "other owned window"
                facts["settingsWindowIsKey"] = name == "Settings"
            } else {
                facts["settingsWindowIsKey"] = "unverified"
            }
            return facts
        }

        private static func log(_ facts: [String: Any]) {
            let data = try! JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys])
            print("SETTINGS_DIAGNOSTIC " + String(decoding: data, as: UTF8.self))
        }
    }
#endif
