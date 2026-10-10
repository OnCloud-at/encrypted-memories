#if os(macOS)
    import AppKit
    import CoreGraphics
    import XCTest

    /// Temporary hosted diagnosis. This file does not belong to the release gate.
    @MainActor
    enum SettingsToolbarDiagnostics {
        private struct Window {
            let order: Int
            let pid: pid_t
            let layer: Int
            let frame: CGRect
        }

        static func captureWindowOrder(_ stage: String) throws {
            let instance = try ownedApplication()
            logWindowOrder(stage, instance: instance, windows: try windows())
        }

        static func run(
            _ test: XCTestCase, app: XCUIApplication, settings: XCUIElement, tab: XCUIElement,
            title: String, isAcknowledged: () -> Bool, waitForAcknowledgement: () -> Bool
        ) throws {
            let previous = test.continueAfterFailure
            test.continueAfterFailure = true
            defer { test.continueAfterFailure = previous }

            func capture(_ stage: String) throws {
                try captureWindowOrder(stage)
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "App UI hierarchy - Settings diagnostic - \(stage)"
                hierarchy.lifetime = .keepAlways
                test.add(hierarchy)
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Settings diagnostic screenshot - \(stage)"
                screenshot.lifetime = .keepAlways
                test.add(screenshot)
                log([
                    "stage": stage, "pane": title,
                    "tabFrame": NSStringFromRect(tab.frame), "isHittable": tab.isHittable,
                    "isEnabled": tab.isEnabled, "isSelected": tab.isSelected,
                    "acknowledged": isAcknowledged(), "settingsFrame": NSStringFromRect(settings.frame),
                    "windowCount": app.windows.count,
                    "mainDisplayFrame": NSScreen.main.map { NSStringFromRect($0.frame) } ?? "unavailable",
                ])
            }

            func clickIfNeeded(_ stage: String) throws {
                try capture(stage)
                if tab.isHittable && !isAcknowledged() { tab.click() }
            }

            func attempt(_ strategy: String, _ action: () throws -> Void) throws {
                try capture(strategy + " before")
                let before = isAcknowledged()
                try action()
                let after = waitForAcknowledgement()
                log([
                    "strategy": strategy, "beforeAcknowledged": before,
                    "afterAcknowledged": after, "switchedToPane": !before && after,
                    "isHittable": tab.isHittable,
                ])
                try capture(strategy + " after")
            }

            // This attempt precedes every explicit activation after Cmd+comma.
            try attempt("f no activation then click") { tab.click() }
            app.activate()
            try capture("after app.activate")
            try attempt("g Window menu Settings") {
                app.menuBars.menuBarItems["Window"].click()
                // Native title lookup also works when the element's label is empty.
                let item = app.menuItems["Settings"]
                log([
                    "strategy": "g menu item", "exists": item.exists,
                    "isEnabled": item.isEnabled, "isHittable": item.isHittable,
                ])
                if item.exists && item.isEnabled && item.isHittable {
                    item.click()
                } else {
                    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
                    log(["strategy": "g", "status": "The Settings window menu item is unavailable"])
                }
                try clickIfNeeded("g after window selection before tab click")
            }
            try attempt("h Cmd+backtick once") {
                app.typeKey("`", modifierFlags: .command)
                try clickIfNeeded("h after window cycle before tab click")
            }
            try attempt("i uncovered Settings title bar") {
                let instance = try ownedApplication()
                let order = try windows()
                logWindowOrder("i title bar planning", instance: instance, windows: order)
                guard
                    let window = order.first(where: {
                        $0.pid == instance.processIdentifier && $0.layer == 0
                            && abs($0.frame.minX - settings.frame.minX) < 2
                            && abs($0.frame.minY - settings.frame.minY) < 2
                            && abs($0.frame.width - settings.frame.width) < 2
                            && abs($0.frame.height - settings.frame.height) < 2
                    })
                else {
                    log(["strategy": "i", "status": "No CG window matches the Settings frame; no title bar click"])
                    return
                }
                let candidates = [0.5, 0.25, 0.75, 0.4, 0.6].map {
                    CGPoint(x: window.frame.minX + window.frame.width * $0, y: window.frame.minY + 12)
                }
                let above = order.filter { $0.order < window.order }
                guard
                    let point = candidates.first(where: { candidate in
                        !above.contains(where: { $0.frame.contains(candidate) })
                    })
                else {
                    log(["strategy": "i", "status": "Every candidate title bar point is covered; no click"])
                    return
                }
                log([
                    "strategy": "i proven uncovered point", "x": point.x, "y": point.y,
                    "settingsFrontToBackIndex": window.order, "coveringWindows": 0,
                ])
                settings.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: point.x - settings.frame.minX, dy: point.y - settings.frame.minY)).click()
                try clickIfNeeded("i after title bar click before tab click")
            }
            try capture("final")
            guard isAcknowledged() else {
                throw failure("No diagnostic strategy selected the \(title) pane")
            }
        }

        private static func ownedApplication() throws -> NSRunningApplication {
            guard let path = ProcessInfo.processInfo.environment["UPGRADE_APP_PATH"] else {
                throw failure("The owned app path is missing")
            }
            let ownedURL = URL(fileURLWithPath: path).standardizedFileURL
            let instances = NSWorkspace.shared.runningApplications.filter {
                $0.bundleURL?.standardizedFileURL == ownedURL
            }
            guard instances.count == 1, let instance = instances.first else {
                throw failure("The owned app instance is missing or ambiguous")
            }
            return instance
        }

        private static func windows() throws -> [Window] {
            guard let records = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
            else {
                throw failure("CoreGraphics could not list on-screen windows")
            }
            return try records.enumerated().map { index, record in
                guard let pid = record[kCGWindowOwnerPID as String] as? NSNumber,
                    let layer = record[kCGWindowLayer as String] as? NSNumber,
                    let bounds = record[kCGWindowBounds as String] as? NSDictionary,
                    let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
                else { throw failure("CoreGraphics returned incomplete window geometry") }
                return Window(order: index, pid: pid.int32Value, layer: layer.intValue, frame: frame)
            }
        }

        private static func logWindowOrder(_ stage: String, instance: NSRunningApplication, windows: [Window]) {
            log([
                "stage": stage, "ownedAppPID": instance.processIdentifier, "ownedAppIsActive": instance.isActive,
                "ownedWindowsFrontToBack": windows.filter { $0.pid == instance.processIdentifier }.map {
                    [
                        "frontToBackIndex": $0.order, "layer": $0.layer,
                        "bounds": [
                            "X": $0.frame.minX, "Y": $0.frame.minY, "Width": $0.frame.width, "Height": $0.frame.height,
                        ],
                    ] as [String: Any]
                },
            ])
        }

        private static func failure(_ message: String) -> NSError {
            NSError(domain: "SettingsToolbarDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }

        private static func log(_ facts: [String: Any]) {
            let data = try! JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys])
            print("SETTINGS_DIAGNOSTIC " + String(decoding: data, as: UTF8.self))
        }
    }
#endif
