import CoreGraphics
import ImageIO
import XCTest

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
            app.activate()
            let title = point.hasPrefix("backup.") ? "Backup" : "Smart Search"
            let tab = settings.toolbars.buttons[title]
            XCTAssertTrue(tab.waitForExistence(timeout: 10))
            let acknowledged = {
                if title == "Backup" {
                    return tab.isSelected || settings.buttons["Enable Photos backup…"].exists
                }
                return settings.switches["smartsearch.toggle"].exists
            }
            var clicks = 0
            try SettingsPaneTestSupport.select(
                title,
                click: {
                    clicks += 1
                    if clicks == 2 { print("Settings pane \(title): repeat the unacknowledged toolbar click once") }
                    tab.click()
                }, isAcknowledged: acknowledged,
                waitForAcknowledgement: {
                    let selected = XCTNSPredicateExpectation(
                        predicate: NSPredicate { _, _ in acknowledged() }, object: nil)
                    return XCTWaiter.wait(for: [selected], timeout: 10) == .completed
                })
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
