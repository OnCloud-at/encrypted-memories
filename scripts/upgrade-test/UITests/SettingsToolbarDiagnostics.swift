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
            let owner: String
            let layer: Int
            let alpha: Double
            let isOnscreen: Bool?
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
                    "windowCount": app.windows.count, "appIsEnabled": app.isEnabled,
                    "settingsIsEnabled": settings.isEnabled, "toolbarIsEnabled": settings.toolbars.firstMatch.isEnabled,
                    "toolbarFrame": NSStringFromRect(settings.toolbars.firstMatch.frame),
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

            try inspectSystemOwners(settings: settings, tab: tab)

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
                    let alpha = record[kCGWindowAlpha as String] as? NSNumber,
                    let bounds = record[kCGWindowBounds as String] as? NSDictionary,
                    let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
                else { throw failure("CoreGraphics returned incomplete window geometry") }
                return Window(
                    order: index, pid: pid.int32Value,
                    owner: record[kCGWindowOwnerName as String] as? String ?? "unavailable",
                    layer: layer.intValue, alpha: alpha.doubleValue,
                    isOnscreen: record[kCGWindowIsOnscreen as String] as? Bool, frame: frame)
            }
        }

        private static func logWindowOrder(_ stage: String, instance: NSRunningApplication, windows: [Window]) {
            log([
                "stage": stage, "ownedAppPID": instance.processIdentifier, "ownedAppIsActive": instance.isActive,
                "onScreenWindowsFrontToBack": windows.map {
                    [
                        "frontToBackIndex": $0.order, "ownerPID": $0.pid, "ownerName": $0.owner,
                        "layer": $0.layer, "alpha": $0.alpha,
                        "isOnscreen": $0.isOnscreen.map { $0 as Any } ?? "unavailable",
                        "bounds": [
                            "X": $0.frame.minX, "Y": $0.frame.minY, "Width": $0.frame.width, "Height": $0.frame.height,
                        ],
                    ] as [String: Any]
                },
            ])
        }

        private static func inspectSystemOwners(settings: XCUIElement, tab: XCUIElement) throws {
            let owners = [
                "com.apple.UserNotificationCenter", "com.apple.notificationcenterui",
                "com.apple.systempreferences", "com.apple.SecurityAgent",
                "com.apple.accessibility.universalAccessAuthWarn",
            ]
            let instance = try ownedApplication()
            let order = try windows()
            let settingsOrder = order.first {
                $0.pid == instance.processIdentifier && $0.layer == 0
                    && abs($0.frame.minX - settings.frame.minX) < 2
                    && abs($0.frame.minY - settings.frame.minY) < 2
                    && abs($0.frame.width - settings.frame.width) < 2
                    && abs($0.frame.height - settings.frame.height) < 2
            }?.order
            var candidates: [[String: Any]] = []
            for identifier in owners {
                let instances = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == identifier }
                guard !instances.isEmpty else {
                    log(["strategy": "j system owner", "bundleIdentifier": identifier, "status": "not running"])
                    continue
                }
                let system = XCUIApplication(bundleIdentifier: identifier)
                let state = system.state
                guard state != .notRunning && state != .unknown else {
                    log([
                        "strategy": "j system owner", "bundleIdentifier": identifier,
                        "state": state.rawValue, "status": "No running XCTest application; no window query",
                    ])
                    continue
                }
                let pids = instances.map(\.processIdentifier)
                let windows = system.windows.allElementsBoundByIndex
                let alerts = system.alerts.count
                var buttons: [[String: Any]] = []
                var windowFacts: [[String: Any]] = []
                for (index, window) in windows.enumerated() {
                    windowFacts.append([
                        "index": index, "frame": NSStringFromRect(window.frame),
                        "isEnabled": window.isEnabled, "isHittable": window.isHittable,
                    ])
                    for button in window.buttons.allElementsBoundByIndex {
                        buttons.append([
                            "windowIndex": index, "title": buttonTitle(button),
                            "frame": NSStringFromRect(button.frame),
                            "isEnabled": button.isEnabled, "isHittable": button.isHittable,
                        ])
                    }
                }
                // Window titles and full system hierarchies must never enter the diagnostic output.
                let coversTab = settingsOrder.map { settingsIndex in
                    order.contains {
                        pids.contains($0.pid) && $0.order < settingsIndex && $0.alpha > 0
                            && $0.frame.contains(CGPoint(x: tab.frame.midX, y: tab.frame.midY))
                    }
                }
                let facts: [String: Any] = [
                    "strategy": "j system owner", "bundleIdentifier": identifier, "ownerPIDs": pids,
                    "state": state.rawValue, "alertCount": alerts, "windows": windowFacts, "buttons": buttons,
                    "coversTabCenterAboveSettings": coversTab.map { $0 as Any } ?? "unverified",
                ]
                log(facts)
                if alerts > 0 || coversTab == true {
                    candidates.append([
                        "strategy": "k known system alert or covering window", "bundleIdentifier": identifier,
                        "alertCount": alerts,
                        "coversTabCenterAboveSettings": coversTab.map { $0 as Any } ?? "unverified",
                        "buttons": buttons, "action": "No system button clicked; blocking status requires evidence",
                    ])
                }
            }
            if candidates.isEmpty {
                log([
                    "strategy": "k",
                    "status": "No alert or covering window found among the five known owners; no system input",
                ])
            } else {
                candidates.forEach(log)
            }
        }

        private static func buttonTitle(_ button: XCUIElement) -> String {
            if !button.label.isEmpty { return String(button.label.prefix(60)) }
            let description = button.debugDescription
            let expression = try! NSRegularExpression(pattern: "title: '(.*?)'(?=, | <|$)")
            guard
                let match = expression.firstMatch(
                    in: description, range: NSRange(description.startIndex..., in: description)),
                let range = Range(match.range(at: 1), in: description)
            else { return "unavailable" }
            return String(description[range].prefix(60))
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
