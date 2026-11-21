import CoreGraphics
import XCTest

/// Whether a bar frame from the accessibility tree covers content in `window`. iOS 27 also reports a toolbar container
/// as large as the window; it covers nothing. A real bar is much narrower or much lower than the window, also the
/// vertical bar of iPhone Duo.
func barCoversContent(_ bar: CGRect, in window: CGRect) -> Bool {
    !bar.isEmpty && !(bar.width >= window.width * 0.9 && bar.height >= window.height * 0.9)
}

/// The frames that cover content, from the frames of the bars and the presentations on screen. A presentation (alert,
/// sheet, popover, menu) always covers what lies behind it, also when it nearly fills the window like a page sheet;
/// the window-sized container rule is only for bars.
func framesCoveringContent(window: CGRect, bars: [CGRect], presentations: [CGRect]) -> [CGRect] {
    bars.filter { barCoversContent($0, in: window) } + presentations.filter { !$0.isEmpty }
}

/// The column of the tab buttons that share one midX, as the union of their frames. Nil for no frame, an empty frame,
/// and for buttons that sit side by side. The strict and the non-asserting check of the vertical bar share this rule.
func tabColumn(of frames: [CGRect]) -> CGRect? {
    guard let first = frames.first, !frames.contains(where: \.isEmpty),
        frames.allSatisfy({ abs($0.midX - first.midX) <= 2 })
    else { return nil }
    return frames.dropFirst().reduce(first) { $0.union($1) }
}

extension CGRect {
    /// A 40 point square at the centre: a row that a test puts at a place to check what covers it.
    var centreProbe: CGRect { CGRect(x: midX - 20, y: midY - 20, width: 40, height: 40) }
}

extension XCUIApplication {
    /// The titles of the first three tabs, in English and in German.
    static let englishTabTitles = ["Library", "Collections", "Search"]
    static let germanTabTitles = ["Mediathek", "Sammlungen", "Suchen"]

    /// The viewer's menu button. It reports its long accessibility name or the short system name, in English or
    /// German ("More actions" or "More", "Weitere Aktionen" or "Weitere").
    var viewerMoreButton: XCUIElement {
        buttons.matching(
            NSPredicate(format: "label IN %@", ["More actions", "More", "Weitere Aktionen", "Weitere"])
        ).firstMatch
    }

    /// The first photo of the visible grid; every grid photo reports a label that starts with "Photo, ".
    var firstPhoto: XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Photo, '")).firstMatch
    }

    /// Opens Recently Deleted from the visible Collections list, which may need scrolling first.
    func openRecentlyDeleted() {
        openCollectionsRow(buttons["Recently Deleted"].firstMatch)
    }

    /// Opens a row of the Collections list, which may need scrolling first, with `tapOnScreen(_:)`.
    func openCollectionsRow(_ row: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<6 {
            guard row.waitForExistence(timeout: 3) else {
                swipeUp()
                continue
            }
            if liesOnScreenClearOfBars(row.frame) { break }
            if row.frame.midY > windows.firstMatch.frame.midY { swipeUp() } else { swipeDown() }
        }
        tapOnScreen(row, file: file, line: line)
    }

    /// Taps an element at its centre after checking that it lies fully in the window and clear of every bar, the
    /// keyboard and every alert, sheet, popover and menu. On iOS 26.5 XCTest reports an element of a SwiftUI list as not
    /// hittable, and its own scroll into view moves the list back to the top. The element belongs to the page: an
    /// element inside a presentation is covered by that presentation and fails the check. A failed check ends the call
    /// without a tap.
    func tapOnScreen(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        guard element.waitForExistence(timeout: 10) else {
            XCTFail("\(element) does not exist", file: file, line: line)
            return
        }
        let frame = element.frame
        guard liesOnScreenClearOfBars(frame) else {
            XCTFail("\(frame) lies in the window, clear of \(coveringFrames())", file: file, line: line)
            return
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    func liesOnScreenClearOfBars(_ frame: CGRect) -> Bool {
        windows.firstMatch.frame.contains(frame) && !coveringFrames().contains { $0.intersects(frame) }
    }

    /// Every navigation bar, tab bar, toolbar and keyboard on screen that covers content, in any column, the
    /// vertical tab bar of iPhone Duo, and every alert, sheet, popover and menu.
    private func coveringFrames() -> [CGRect] {
        let bars = [navigationBars, tabBars, toolbars, keyboards].flatMap(\.allElementsBoundByIndex).filter(\.exists)
            .map(\.frame)
        let presentations = [alerts, sheets, popovers, menus].flatMap(\.allElementsBoundByIndex).filter(\.exists)
            .map(\.frame)
        return framesCoveringContent(
            window: windows.firstMatch.frame, bars: bars + [verticalTabStrip()].compactMap { $0 },
            presentations: presentations)
    }

    /// The strip of a vertical tab bar, as iPhone Duo shows it beside the content: the column of the tab buttons
    /// over the full window height. The system reports no tab bar or toolbar element for it. Nil for horizontal tabs.
    func verticalTabStrip() -> CGRect? {
        let window = windows.firstMatch.frame
        for titles in [Self.englishTabTitles, Self.germanTabTitles] {
            let frames = titles.compactMap { tabButtonFrame(titled: $0, timeout: 0) }
            guard frames.count == titles.count else { continue }
            return tabColumn(of: frames).map {
                CGRect(x: $0.minX, y: window.minY, width: $0.width, height: window.height)
            }
        }
        return nil
    }

    /// The frame of a tab button. It waits up to `timeout` seconds for the button and returns nil when it is missing.
    private func tabButtonFrame(titled title: String, timeout: TimeInterval) -> CGRect? {
        let button = barButton(titled: title)
        guard timeout > 0 ? button.waitForExistence(timeout: timeout) : button.exists else { return nil }
        return button.frame
    }

    /// Read a rendered screen pixel in window coordinates, outside the native button backgrounds.
    func screenshotPixel(at point: CGPoint, in window: CGRect) throws -> [UInt8] {
        let image = try XCTUnwrap(screenshot().image.cgImage)
        let x = (point.x - window.minX) * CGFloat(image.width) / window.width
        let y = (point.y - window.minY) * CGFloat(image.height) / window.height
        let crop = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(
                CGContext(
                    data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel
    }

    /// Tabs are native toolbar buttons when the system presents its bars vertically.
    func barButton(titled title: String) -> XCUIElement {
        buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    /// Keep native tab queries scoped where UIKit exposes a tab bar, and use the vertical or sidebar role otherwise.
    func tab(titled title: String) -> XCUIElement {
        let tab = tabBars.buttons[title]
        if tab.exists { return tab }
        let button = barButton(titled: title)
        return button.exists ? button : cells[title].firstMatch
    }

    /// Keep the original tab-bar query first. Other roles must match the confirmed native bar geometry.
    func verifiedTab(titled title: String) throws -> XCUIElement {
        let nativeTab = tabBars.buttons[title]
        if nativeTab.exists { return nativeTab }
        let column = try verticalTabColumn()
        let candidate = tab(titled: title)
        XCTAssertTrue(candidate.exists, "The native bar has no \(title) tab")
        XCTAssertFalse(candidate.frame.isEmpty, "The \(title) tab has no frame")
        if let column {
            XCTAssertEqual(
                candidate.frame.midX, column.midX, accuracy: 2, "The \(title) tab is outside the vertical bar column")
        } else {
            XCTAssertEqual(
                candidate.frame.midY, barButton(titled: "Library").frame.midY, accuracy: 2,
                "The \(title) tab is outside the confirmed horizontal tab row")
        }
        return candidate
    }

    /// Vertical navigation exposes the native chevron by its UIKit identifier instead of the previous page title.
    func backButton(to title: String) -> XCUIElement {
        let titled = buttons[title].firstMatch
        return titled.exists ? titled : buttons["BackButton"].firstMatch
    }

    /// Native tabs can form a horizontal row without a tab-bar accessibility role.
    /// Missing controls and unknown layouts still fail the strict vertical checks.
    func verticalTabColumn(titles: [String] = XCUIApplication.englishTabTitles) throws -> CGRect? {
        let frames = try titles.map { title in
            try XCTUnwrap(tabButtonFrame(titled: title, timeout: 10), "The native bar has no \(title) tab")
        }
        let distinctX = frames.indices.allSatisfy { index in
            frames.dropFirst(index + 1).allSatisfy { abs($0.midX - frames[index].midX) > 1 }
        }
        let isHorizontalRow =
            frames.allSatisfy {
                !$0.isEmpty && abs($0.midY - frames[0].midY) <= 2
            } && distinctX
        print("[Native tabs] frames=\(frames) horizontal=\(isHorizontalRow)")
        if isHorizontalRow { return nil }

        for frame in frames {
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
        }
        let column = try XCTUnwrap(tabColumn(of: frames), "The tabs do not form a vertical column")
        XCTAssertGreaterThan(abs(frames[0].midY - frames[1].midY), 1)
        let window = windows.firstMatch.frame
        XCTAssertTrue(
            column.maxX <= window.midX || column.minX >= window.midX,
            "The vertical controls are not beside the content")
        return column
    }

    /// Metal photo elements do not report hittability. Select a complete tile below horizontal navigation,
    /// clear of the vertical controls, so its centre cannot tap the status bar or a bar action.
    func visiblePhoto(beside column: CGRect?) throws -> XCUIElement {
        let photos = descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'Photo, ' OR label BEGINSWITH 'Foto, '"))
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 60), "The library shows no photo")
        let window = windows.firstMatch.frame
        let navigationBottom = navigationBars.allElementsBoundByIndex
            .map(\.frame)
            .filter { $0.width > $0.height }
            .reduce(window.minY) { max($0, $1.maxY) }
        let statusBottom = statusBars.allElementsBoundByIndex
            .map(\.frame)
            .reduce(window.minY) { max($0, $1.maxY) }
        let top = max(navigationBottom, statusBottom)
        let isClear: (XCUIElement) -> Bool = { photo in
            let frame = photo.frame
            guard frame.width > 0, frame.height > 0, window.contains(frame), frame.minY >= top else { return false }
            guard let column else { return true }
            return column.midX > window.midX ? frame.maxX <= column.minX : frame.minX >= column.maxX
        }
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in photos.allElementsBoundByIndex.contains(where: isClear) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, "No complete photo is clear of the bars")
        return try XCTUnwrap(photos.allElementsBoundByIndex.first(where: isClear))
    }
}
