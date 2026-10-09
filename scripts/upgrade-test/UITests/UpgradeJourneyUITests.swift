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
                #if os(iOS)
                    let photos = app.descendants(matching: .any)
                        .matching(NSPredicate(format: "label BEGINSWITH 'Photo, '"))
                    let window = app.windows.firstMatch.frame
                    let top = app.navigationBars.allElementsBoundByIndex.map { $0.frame.maxY }.max() ?? window.minY
                    let visiblePhoto = try XCTUnwrap(
                        photos.allElementsBoundByIndex.first {
                            !$0.frame.isEmpty && window.contains($0.frame) && $0.frame.minY > top
                        }, "No complete photo tile is visible below the navigation bar")
                #else
                    let visiblePhoto = photo
                #endif
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
            let tab = app.windows["Settings"].toolbars.buttons[
                point.hasPrefix("backup.") ? "Backup" : "Smart Search"]
            XCTAssertTrue(tab.waitForExistence(timeout: 10))
            tab.click()
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
            #if os(macOS)
                let toggle = app.checkBoxes["smartsearch.toggle"]
            #else
                let toggle = app.switches["smartsearch.toggle"]
            #endif
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
            if verifiesUpgrade {
                XCTAssertEqual(toggle.value as? String, "1", "The saved Smart Search preference was lost")
                XCTAssertTrue(
                    app.staticTexts["8 photos and videos are searchable."].waitForExistence(timeout: 180),
                    "Smart Search did not resume its download and index")
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
