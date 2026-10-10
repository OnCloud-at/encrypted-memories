import CoreGraphics
import ImageIO
import XCTest

#if os(macOS)
    import AppKit
#endif

/// Drives the installed app. This target has no app dependency and cannot replace the historical app.
final class UpgradeJourneyUITests: XCTestCase {
    private lazy var app: XCUIApplication = {
        #if os(macOS)
            return XCUIApplication(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["UPGRADE_APP_PATH"]!))
        #else
            return XCUIApplication(bundleIdentifier: "at.oncloud.encryptedmemories.upgrade-test")
        #endif
    }()
    private static func switchIsEnabled(_ value: Any?) -> Bool {
        if let value = value as? String { return value == "1" }
        if let value, type(of: value) is NSNumber.Type, let number = value as? NSNumber {
            return number == NSNumber(value: 1)
        }
        return false
    }

    func testSwitchValueRequiresExactOne() {
        for value: Any in ["1", NSNumber(value: 1)] {
            XCTAssertTrue(Self.switchIsEnabled(value), "Enabled value rejected: \(value)")
        }
        let disabled: [Any?] = [
            "0", NSNumber(value: 0), nil, "01", "true", NSNumber(value: 2),
            NSNumber(value: 1.5), NSNull(), [1], NSObject(), 1, 1.0, true,
        ]
        for value in disabled {
            XCTAssertFalse(Self.switchIsEnabled(value), "Unexpected enabled value: \(String(describing: value))")
        }
    }

    private var point: String { ProcessInfo.processInfo.environment["UPGRADE_POINT"]! }
    private var verifiesUpgrade: Bool { ProcessInfo.processInfo.environment["UPGRADE_PHASE"] == "verify" }

    private func hasSyntheticPixels(_ png: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return false }
        let width = 16
        var pixels = [UInt8](repeating: 0, count: width * width * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: width, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: width))
            var matching = 0
            for offset in stride(from: 0, to: buffer.count, by: 4) {
                let red = Int(buffer[offset])
                let green = Int(buffer[offset + 1])
                let blue = Int(buffer[offset + 2])
                if abs(green - 80) < 15 && abs(blue - 180) < 15 && (20...220).contains(red) {
                    matching += 1
                }
            }
            return matching > width * width / 2
        }
    }

    private func indexedSearchIsComplete(resultCount: Int, visiblePhotoPNG: Data) -> Bool {
        resultCount == 8 && hasSyntheticPixels(visiblePhotoPNG)
    }

    private func visiblePhoto(in photos: XCUIElementQuery) -> XCUIElement? {
        #if os(iOS)
            let window = app.windows.firstMatch.frame
            let top = app.navigationBars.allElementsBoundByIndex.map { $0.frame.maxY }.max() ?? window.minY
            return photos.allElementsBoundByIndex.first {
                !$0.frame.isEmpty && window.contains($0.frame) && $0.frame.minY > top
            }
        #else
            let photo = photos.firstMatch
            return photo.exists ? photo : nil
        #endif
    }

    func testPendingSearchCannotUseTheRetainedLibrary() throws {
        let photo = try XCTUnwrap(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGNQCNhCU8QwasGoBaMWjFowasGoBaMW"
                    + "jFowasGoBaMWDBULAFr4kD3OWQ/uAAAAAElFTkSuQmCC"))
        let pendingOverlay = try XCTUnwrap(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAJklEQVR4nO3NMQ0AAAwDoPo33arYsQQMkB6LQCAQ"
                    + "CAQCgUAg+BIMi1X0pjxKe0gAAAAASUVORK5CYII="))
        XCTAssertFalse(
            indexedSearchIsComplete(resultCount: 8, visiblePhotoPNG: pendingOverlay),
            "Eight retained accessibility elements beneath an opaque loading overlay are not completed results")
        XCTAssertTrue(indexedSearchIsComplete(resultCount: 8, visiblePhotoPNG: photo))
        for count in [0, 7, 9] {
            XCTAssertFalse(indexedSearchIsComplete(resultCount: count, visiblePhotoPNG: photo))
        }
    }

    /// Query the native search surface to prove that all eight saved index entries are usable.
    private func verifyIndexedSearchResults() throws {
        #if os(iOS)
            app.navigationBars.buttons.firstMatch.tap()
            let done = app.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 10))
            done.tap()
            app.tabBars.buttons["Search"].tap()
        #else
            app.typeKey("w", modifierFlags: .command)
        #endif
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "The native search field is missing")
        #if os(macOS)
            search.click()
        #else
            search.tap()
        #endif
        search.typeText("fixture query\n")
        let results = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Photo, '"))
        let indexed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard results.count == 8, let photo = self.visiblePhoto(in: results) else { return false }
                return self.indexedSearchIsComplete(
                    resultCount: results.count, visiblePhotoPNG: photo.screenshot().pngRepresentation)
            }, object: nil)
        let result = XCTWaiter.wait(for: [indexed], timeout: 60)
        for attachment in [XCTAttachment(screenshot: app.screenshot()), XCTAttachment(string: app.debugDescription)] {
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(result, .completed, "The saved index did not return all eight photos")
    }

    #if os(macOS)
        func testSettingsWindowDragUsesOnlyForeignVisibleNormalAndModalWindows() throws {
            let screen = CGRect(x: 0, y: 0, width: 1024, height: 768)
            let frame = CGRect(x: 232, y: 94, width: 560, height: 608)
            let tab = CGRect(x: 565, y: 126, width: 55, height: 56)
            let settings = SettingsWindowPlacement.Window(pid: 1, layer: 0, frame: frame)
            let dialog = SettingsWindowPlacement.Window(
                pid: 2, layer: 8, frame: CGRect(x: 382, y: 118, width: 260, height: 250))
            for layer in [0, 8] {
                let window = SettingsWindowPlacement.Window(pid: 2, layer: layer, frame: dialog.frame)
                XCTAssertEqual(SettingsWindowPlacement.obstacles([window], ownedPID: 1).count, 1)
            }
            for layer in [-1, 9, 20, 1000] {
                let surface = SettingsWindowPlacement.Window(pid: 2, layer: layer, frame: screen)
                XCTAssertTrue(SettingsWindowPlacement.obstacles([surface], ownedPID: 1).isEmpty)
            }
            XCTAssertTrue(SettingsWindowPlacement.obstacles([settings], ownedPID: 1).isEmpty)
            let transparent = SettingsWindowPlacement.Window(pid: 2, layer: 8, alpha: 0, frame: screen)
            let offscreen = SettingsWindowPlacement.Window(pid: 2, layer: 8, isOnscreen: false, frame: screen)
            XCTAssertTrue(SettingsWindowPlacement.obstacles([transparent, offscreen], ownedPID: 1).isEmpty)

            let plan = try XCTUnwrap(
                SettingsWindowPlacement.plan(
                    settings: frame, tab: tab, screen: screen, obstacles: [dialog.frame],
                    titleBarObstacles: [dialog.frame]))
            XCTAssertFalse(dialog.frame.contains(plan.start), "The drag must not press the system window")
            XCTAssertTrue(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 32).contains(plan.start))
            XCTAssertTrue(screen.contains(plan.window))
            XCTAssertFalse(plan.tab.intersects(dialog.frame), "The complete tab must leave the dialog")
            XCTAssertEqual(plan.window.minX, 456)
            XCTAssertNil(
                SettingsWindowPlacement.plan(
                    settings: frame, tab: tab, screen: screen, obstacles: [], titleBarObstacles: []))
            XCTAssertNil(
                SettingsWindowPlacement.plan(
                    settings: frame, tab: tab, screen: screen, obstacles: [screen], titleBarObstacles: []))
            XCTAssertNil(
                SettingsWindowPlacement.plan(
                    settings: frame, tab: tab, screen: screen, obstacles: [dialog.frame], titleBarObstacles: [screen]))
        }
    #endif

    #if os(macOS)
        @MainActor
        private func moveSettingsAwayFromForeignWindows(settings: XCUIElement, tab: XCUIElement) throws {
            let appPath = try XCTUnwrap(ProcessInfo.processInfo.environment["UPGRADE_APP_PATH"])
            let ownedURL = URL(fileURLWithPath: appPath).standardizedFileURL
            let instances = NSWorkspace.shared.runningApplications.filter {
                $0.bundleURL?.standardizedFileURL == ownedURL
            }
            guard instances.count == 1, let instance = instances.first else {
                throw SettingsWindowPlacement.failure("The exact owned app instance is missing or ambiguous")
            }
            let windows = try SettingsWindowPlacement.windows()
            let matches = windows.filter {
                $0.pid == instance.processIdentifier && $0.layer == 0
                    && abs($0.frame.minX - settings.frame.minX) < 2
                    && abs($0.frame.minY - settings.frame.minY) < 2
                    && abs($0.frame.width - settings.frame.width) < 2
                    && abs($0.frame.height - settings.frame.height) < 2
            }
            guard matches.count == 1, let ownWindow = matches.first else {
                throw SettingsWindowPlacement.failure("CoreGraphics did not identify the exact Settings window")
            }
            let obstacles = SettingsWindowPlacement.obstacles(windows, ownedPID: instance.processIdentifier)
            SettingsWindowPlacement.log("before Settings placement", windows: windows, settings: settings, tab: tab)
            retainSettingsHierarchy("before placement")
            try captureRunnerSystemDialog(windows)
            if obstacles.contains(where: { $0.frame.intersects(tab.frame) }) {
                let titleBarObstacles = windows.filter {
                    $0.order < ownWindow.order && SettingsWindowPlacement.isObstacleSurface($0)
                }.map(\.frame)
                guard
                    let plan = SettingsWindowPlacement.plan(
                        settings: settings.frame, tab: tab.frame,
                        screen: CGDisplayBounds(CGMainDisplayID()), obstacles: obstacles.map(\.frame),
                        titleBarObstacles: titleBarObstacles)
                else {
                    throw SettingsWindowPlacement.failure(
                        "No uncovered Settings title-bar point or unobstructed on-screen tab position is available")
                }
                let origin = settings.coordinate(withNormalizedOffset: .zero)
                let start = origin.withOffset(
                    CGVector(
                        dx: plan.start.x - settings.frame.minX, dy: plan.start.y - settings.frame.minY))
                let end = origin.withOffset(
                    CGVector(
                        dx: plan.end.x - settings.frame.minX, dy: plan.end.y - settings.frame.minY))
                start.click(forDuration: 0.5, thenDragTo: end)
                SettingsWindowPlacement.log(
                    "after Settings drag", windows: try SettingsWindowPlacement.windows(), settings: settings, tab: tab)
                retainSettingsHierarchy("after drag")
            }
            let hittable = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in tab.exists && tab.isHittable }, object: nil)
            guard XCTWaiter.wait(for: [hittable], timeout: 10) == .completed else {
                throw SettingsWindowPlacement.failure("The Settings tab did not become hittable before its click")
            }
        }

        private func retainSettingsHierarchy(_ stage: String) {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "App UI hierarchy - Settings placement - " + stage
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        // This capture belongs only to the authorized throw-away diagnostic branch.
        private func captureRunnerSystemDialog(_ windows: [SettingsWindowPlacement.Window]) throws {
            let path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Developer/xcode/EncryptedMemories/UpgradeCheck/evidence/system-dialog.png")
            guard !FileManager.default.fileExists(atPath: path.path) else { return }
            guard
                let dialog = windows.first(where: {
                    $0.owner == "UserNotificationCenter" && SettingsWindowPlacement.isObstacleSurface($0)
                })
            else { return }
            guard CGDisplayBounds(CGMainDisplayID()).contains(dialog.frame), !dialog.frame.isEmpty else {
                throw SettingsWindowPlacement.failure("The system dialog crop is outside the main display")
            }
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let crop = dialog.frame
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = [
                "-x", "-R\(Int(crop.minX)),\(Int(crop.minY)),\(Int(crop.width)),\(Int(crop.height))", path.path,
            ]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: path.path) else {
                throw SettingsWindowPlacement.failure("The single system-dialog crop failed")
            }
        }
    #endif

    #if os(macOS)
        @MainActor
    #endif
    func testInstalledAppJourney() throws {
        continueAfterFailure = false
        #if os(iOS)
            addUIInterruptionMonitor(withDescription: "Unexpected system UI in the synthetic journey") { _ in
                XCTFail("The synthetic journey requested system access instead of its offline input")
                return false
            }
        #endif
        #if os(macOS)
            let arguments = try XCTUnwrap(
                ProcessInfo.processInfo.environment["UPGRADE_APP_ARGUMENTS"]?.data(using: .utf8),
                "The owned app launch arguments are missing")
            app.launchArguments = try JSONDecoder().decode([String].self, from: arguments)
            app.launch()
            app.menuBars.menuBarItems["Window"].click()
            app.menuItems["Library"].click()
            let larger = app.buttons["Larger thumbnails"]
            XCTAssertTrue(larger.waitForExistence(timeout: 60))
            larger.click()
        #else
            app.activate()
        #endif
        let photo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Photo, '")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 60), "The saved account did not open its library")
        if point.hasPrefix("thumbnail.") {
            if verifiesUpgrade {
                let photos = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label BEGINSWITH 'Photo, '"))
                let visiblePhoto = try XCTUnwrap(
                    self.visiblePhoto(in: photos), "No complete photo tile is visible below the navigation bar")
                let rendered = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in
                        self.hasSyntheticPixels(visiblePhoto.screenshot().pngRepresentation)
                    },
                    object: nil)
                let result = XCTWaiter.wait(for: [rendered], timeout: 60)
                for screenshot in [app.screenshot(), visiblePhoto.screenshot()] {
                    let attachment = XCTAttachment(screenshot: screenshot)
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                XCTAssertEqual(result, .completed, "The thumbnail did not render after the upgrade")
            }
            return
        }
        #if os(iOS)
            app.buttons["Proton Account and Settings"].tap()
            let title = point.hasPrefix("backup.") ? "Backup" : "Smart Search"
            let feature = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
            XCTAssertTrue(feature.waitForExistence(timeout: 10))
            feature.tap()
        #else
            app.typeKey(",", modifierFlags: .command)
            let settings = app.windows["Settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 10), "The Settings window is missing")
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in settings.exists && settings.isHittable }, object: nil)
            XCTAssertEqual(
                XCTWaiter.wait(for: [ready], timeout: 10), .completed,
                "The Settings window did not become hittable")
            let title = point.hasPrefix("backup.") ? "Backup" : "Smart Search"
            let tab = settings.toolbars.buttons[title]
            XCTAssertTrue(tab.waitForExistence(timeout: 10))
            let acknowledged = {
                if title == "Backup" {
                    return tab.isSelected || settings.buttons["Enable Photos backup…"].exists
                }
                return settings.switches["smartsearch.toggle"].exists
            }
            app.activate()
            var placementError: Error?
            do {
                try SettingsPaneTestSupport.select(
                    title,
                    click: {
                        guard placementError == nil else { return }
                        do {
                            try self.moveSettingsAwayFromForeignWindows(settings: settings, tab: tab)
                            tab.click()
                        } catch { placementError = error }
                    },
                    isAcknowledged: { placementError == nil && acknowledged() },
                    waitForAcknowledgement: {
                        guard placementError == nil else { return false }
                        let selected = XCTNSPredicateExpectation(
                            predicate: NSPredicate { _, _ in acknowledged() }, object: nil)
                        return XCTWaiter.wait(for: [selected], timeout: 10) == .completed
                    })
            } catch { throw placementError ?? error }

        #endif
        if point.hasPrefix("backup.") {
            let enable = app.buttons["Enable Photos backup…"]
            if verifiesUpgrade {
                XCTAssertFalse(enable.exists, "The saved backup preference was lost")
                let settled = app.staticTexts["All files backed up"]
                XCTAssertTrue(settled.waitForExistence(timeout: 180), "Backup remains unfinished after the upgrade")
            } else {
                XCTAssertTrue(enable.waitForExistence(timeout: 10))
                #if os(macOS)
                    enable.click()
                #else
                    enable.tap()
                #endif
            }
        } else {
            let toggle = app.switches["smartsearch.toggle"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
            if verifiesUpgrade {
                XCTAssertTrue(Self.switchIsEnabled(toggle.value), "The saved Smart Search preference was lost")
                XCTAssertTrue(
                    app.staticTexts["Smart Search is ready"].waitForExistence(timeout: 180),
                    "Smart Search did not resume its download and index")
                try verifyIndexedSearchResults()
            } else {
                #if os(macOS)
                    toggle.click()
                #else
                    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
                #endif
            }
        }
    }
}

#if os(macOS)
    enum SettingsWindowPlacement {
        struct Window {
            var pid: Int32
            var layer: Int
            var alpha: Double = 1
            var isOnscreen: Bool = true
            var frame: CGRect
            var order: Int = 0
            var owner: String = "unavailable"
        }

        struct Drag {
            var start: CGPoint
            var end: CGPoint
            var window: CGRect
            var tab: CGRect
        }

        static func isObstacleSurface(_ window: Window) -> Bool {
            window.isOnscreen && window.alpha > 0 && window.layer >= 0
                && window.layer <= Int(CGWindowLevelForKey(.modalPanelWindow))
        }

        static func obstacles(_ windows: [Window], ownedPID: Int32) -> [Window] {
            windows.filter { $0.pid != ownedPID && isObstacleSurface($0) }
        }

        static func plan(
            settings: CGRect, tab: CGRect, screen: CGRect,
            obstacles: [CGRect], titleBarObstacles: [CGRect]
        ) -> Drag? {
            guard !settings.isEmpty, !tab.isEmpty, obstacles.contains(where: { $0.intersects(tab) }) else { return nil }
            let titleBarPoints = [0.5, 0.25, 0.75, 0.4, 0.6].map {
                CGPoint(x: settings.minX + settings.width * $0, y: settings.minY + 12)
            }
            guard
                let start = titleBarPoints.first(where: { point in
                    !titleBarObstacles.contains(where: { $0.contains(point) })
                })
            else { return nil }
            let usable = CGRect(
                x: screen.minX + 8, y: screen.minY + 32, width: screen.width - 16, height: screen.height - 40)
            guard settings.width <= usable.width, settings.height <= usable.height else { return nil }
            for y in [settings.minY, usable.minY, usable.maxY - settings.height] {
                for x in [usable.maxX - settings.width, usable.minX] {
                    let moved = CGRect(x: x, y: y, width: settings.width, height: settings.height)
                    let dx = x - settings.minX
                    let dy = y - settings.minY
                    let movedTab = tab.offsetBy(dx: dx, dy: dy)
                    if usable.contains(moved), !obstacles.contains(where: { $0.intersects(movedTab) }) {
                        return Drag(
                            start: start, end: CGPoint(x: start.x + dx, y: start.y + dy),
                            window: moved, tab: movedTab)
                    }
                }
            }
            return nil
        }

        static func windows() throws -> [Window] {
            guard let records = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
            else { throw failure("CoreGraphics could not list on-screen windows") }
            return try records.enumerated().map { index, record in
                guard let pid = record[kCGWindowOwnerPID as String] as? NSNumber,
                    let layer = record[kCGWindowLayer as String] as? NSNumber,
                    let alpha = record[kCGWindowAlpha as String] as? NSNumber,
                    let onScreen = record[kCGWindowIsOnscreen as String] as? Bool,
                    let bounds = record[kCGWindowBounds as String] as? NSDictionary,
                    let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
                else { throw failure("CoreGraphics returned incomplete window geometry") }
                return Window(
                    pid: pid.int32Value, layer: layer.intValue, alpha: alpha.doubleValue,
                    isOnscreen: onScreen, frame: frame, order: index,
                    owner: record[kCGWindowOwnerName as String] as? String ?? "unavailable")
            }
        }

        static func log(_ stage: String, windows: [Window], settings: XCUIElement, tab: XCUIElement) {
            let facts: [String: Any] = [
                "stage": stage, "settingsFrame": NSStringFromRect(settings.frame),
                "tabFrame": NSStringFromRect(tab.frame), "tabIsHittable": tab.isHittable,
                "onScreenWindowsFrontToBack": windows.map {
                    [
                        "frontToBackIndex": $0.order, "ownerPID": $0.pid, "ownerName": $0.owner,
                        "layer": $0.layer, "alpha": $0.alpha, "isOnscreen": $0.isOnscreen,
                        "bounds": [
                            "X": $0.frame.minX, "Y": $0.frame.minY,
                            "Width": $0.frame.width, "Height": $0.frame.height,
                        ],
                    ] as [String: Any]
                },
            ]
            let data = try! JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys])
            print("SETTINGS_DIAGNOSTIC " + String(decoding: data, as: UTF8.self))
        }

        static func failure(_ message: String) -> NSError {
            NSError(domain: "SettingsWindowPlacement", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
#endif
