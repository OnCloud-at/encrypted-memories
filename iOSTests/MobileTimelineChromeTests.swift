import PhotosCore
import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile
@testable import TimelineUIKitFeature

/// The library's native top bar through the production `MobileTimelineScreen`.
///
/// Outside selection the trailing bar holds the display-options menu and Select. Selection mode swaps the menu
/// slot for the bulk actions: iOS 26 shows the app-owned "More actions" menu in that slot, iOS 27 hands them to
/// the system overflow menu and leaves no invisible menu behind. The leading title must keep its position while
/// the slot content changes, and the bar must not carry the app ellipsis or an overflow entry outside selection.
final class MobileTimelineChromeTests: XCTestCase {
    private var report: [String] = []

    @MainActor func testSelectionModeSwapsTheTrailingMenuWithoutMovingTheTitle() async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        let fixture = try await MobileSignedInFixture(itemsPerSection: 6)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        fixture.install(into: model)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let sceneContext = MobileSceneContext()
        sceneContext.attach(window: window)
        let root = UIHostingController(
            rootView: MobileTimelineScreen(surface: .library)
                .environment(model)
                .environment(MobileViewerRouter())
                .environment(sceneContext)
        )
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }.forEach { $0.setActive(false) }
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
            writeArtifact("timeline-chrome-report.txt", Data(report.joined(separator: "\n").utf8))
        }

        let selectLabel = L10n.string("action.select")
        let doneLabel = L10n.string("action.done")
        let optionsLabel = String(localized: "library.options")
        let appMoreLabel = String(localized: "selection.more_a11y")
        try await waitUntil("the production grid and its navigation bar appear") {
            !descendants(window).compactMap({ $0 as? UIKitTimelineGridHostView }).filter { !$0.itemUIDs.isEmpty }
                .isEmpty && barItem(labelled: selectLabel, in: window) != nil
        }
        try await Task.sleep(for: .milliseconds(800))

        let browsingLabels = barItemLabels(in: window)
        let browsingTitle = try XCTUnwrap(titleFrame(L10n.string("library.title"), in: window))
        report.append("browsing: items=\(browsingLabels) title=\(browsingTitle)")
        XCTAssertNotNil(barItem(labelled: optionsLabel, in: window), "the options menu is a bar item while browsing")
        XCTAssertNil(barItem(labelled: appMoreLabel, in: window), "the bulk-action menu stays out of the browsing bar")
        report.append("browsing: systemOverflow=\(systemOverflowIsMounted(in: window))")
        XCTAssertFalse(
            systemOverflowIsMounted(in: window),
            "no system overflow button while browsing: an empty overflow menu still shows the ellipsis")
        snapshot(window, "timeline-chrome-browsing")

        // Enter selection mode through the native Select item.
        try await activate(label: selectLabel, in: window)
        try await waitUntil("Done replaces Select") { barItem(labelled: doneLabel, in: window) != nil }
        try await Task.sleep(for: .milliseconds(800))
        let selectingLabels = barItemLabels(in: window)
        let selectingTitle = try XCTUnwrap(titleFrame(L10n.selectionCenterText(selectedCount: 0), in: window))
        report.append("selecting: items=\(selectingLabels) title=\(selectingTitle)")
        XCTAssertNil(
            accessibilityElement(labelled: optionsLabel, in: window),
            "the options menu leaves the bar in selection mode instead of hiding behind opacity")
        if #available(iOS 27.0, *) {
            XCTAssertNil(
                barItem(labelled: appMoreLabel, in: window),
                "iOS 27 moves the bulk actions into the system overflow menu; no app ellipsis remains")
            report.append("selecting: systemOverflow=\(systemOverflowIsMounted(in: window))")
            XCTAssertTrue(
                systemOverflowIsMounted(in: window),
                "iOS 27 shows the system overflow button once the bulk actions join it")
        } else {
            XCTAssertNotNil(
                barItem(labelled: appMoreLabel, in: window),
                "iOS 26 keeps the app-owned bulk-action menu in the trailing slot")
        }
        // The selection count replaces the route title. iOS 26.5 lays the longer title out 2 pt further right
        // (measured on iPhone 17 Pro Max; the shift stayed at 2 pt with both trailing menus mounted, so the slot swap
        // is not the cause). iOS 27 keeps it in place. A larger shift is a real title jump.
        let titleTolerance: CGFloat
        if #available(iOS 27.0, *) {
            titleTolerance = 1
        } else {
            titleTolerance = 2.5
        }
        XCTAssertEqual(
            selectingTitle.minX, browsingTitle.minX, accuracy: titleTolerance, "the leading title must not jump")
        XCTAssertEqual(selectingTitle.midY, browsingTitle.midY, accuracy: 1, "the leading title must not jump")
        snapshot(window, "timeline-chrome-selecting")

        // Leave selection mode; the options menu returns to its slot.
        try await activate(label: doneLabel, in: window)
        try await waitUntil("Select replaces Done") { barItem(labelled: selectLabel, in: window) != nil }
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertNotNil(barItem(labelled: optionsLabel, in: window), "the options menu returns after Done")
        let restoredTitle = try XCTUnwrap(titleFrame(L10n.string("library.title"), in: window))
        XCTAssertEqual(restoredTitle.minX, browsingTitle.minX, accuracy: 1)
        report.append("restored: items=\(barItemLabels(in: window)) title=\(restoredTitle)")
    }

    // MARK: - Helpers

    @MainActor private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private func barItems(in window: UIWindow) -> [UIBarButtonItem] {
        var items: [UIBarButtonItem] = []
        for bar in descendants(window).compactMap({ $0 as? UINavigationBar }) {
            for navigationItem in bar.items ?? [] {
                items += (navigationItem.leftBarButtonItems ?? []) + (navigationItem.rightBarButtonItems ?? [])
                items += navigationItem.leadingItemGroups.flatMap(\.barButtonItems)
                items += navigationItem.centerItemGroups.flatMap(\.barButtonItems)
                items += navigationItem.trailingItemGroups.flatMap(\.barButtonItems)
            }
        }
        return items
    }

    @MainActor private func label(of item: UIBarButtonItem) -> String? {
        if let title = item.title, !title.isEmpty { return title }
        if let label = item.accessibilityLabel, !label.isEmpty { return label }
        guard let custom = item.customView else { return nil }
        if let label = custom.accessibilityLabel, !label.isEmpty { return label }
        return descendants(custom).lazy.compactMap { view -> String? in
            if let label = view.accessibilityLabel, !label.isEmpty { return label }
            if let text = (view as? UILabel)?.text, !text.isEmpty { return text }
            return (view as? UIButton)?.titleLabel?.text
        }.first
    }

    @MainActor private func barItemLabels(in window: UIWindow) -> [String] {
        barItems(in: window).compactMap(label(of:))
    }

    @MainActor private func barItem(labelled label: String, in window: UIWindow) -> UIBarButtonItem? {
        barItems(in: window).first { item in
            if item.title == label || item.accessibilityLabel == label { return true }
            guard let custom = item.customView else { return false }
            if custom.accessibilityLabel == label { return true }
            return descendants(custom).contains { view in
                view.accessibilityLabel == label || (view as? UILabel)?.text == label
                    || (view as? UIButton)?.titleLabel?.text == label
            }
        }
    }

    /// Whether a navigation bar carries system overflow content. SwiftUI's `ToolbarOverflowMenu` fills
    /// `UINavigationItem.additionalOverflowItems`, and UIKit shows the ellipsis whenever that property is set. The
    /// check does not depend on the localized title of the overflow button.
    @MainActor private func systemOverflowIsMounted(in window: UIWindow) -> Bool {
        descendants(window).compactMap { $0 as? UINavigationBar }
            .flatMap { $0.items ?? [] }
            .contains { $0.additionalOverflowItems != nil }
    }

    /// The frame of the navigation bar's title label in window coordinates.
    @MainActor private func titleFrame(_ title: String, in window: UIWindow) -> CGRect? {
        for bar in descendants(window).compactMap({ $0 as? UINavigationBar }) {
            if let label = descendants(bar).compactMap({ $0 as? UILabel }).first(where: { $0.text == title }) {
                return label.convert(label.bounds, to: window)
            }
        }
        return nil
    }

    @MainActor private func accessibilityElement(labelled label: String, in root: UIView) -> UIView? {
        if root.isHidden || root.alpha < 0.01 || root.accessibilityElementsHidden { return nil }
        if root.isAccessibilityElement, root.accessibilityLabel == label { return root }
        for subview in root.subviews {
            if let match = accessibilityElement(labelled: label, in: subview) { return match }
        }
        return nil
    }

    /// Activates a bar item the way a pointer or VoiceOver would: the item's action, then its custom control.
    @MainActor private func activate(label: String, in window: UIWindow) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(15)
        while clock.now < deadline {
            if let item = barItem(labelled: label, in: window) {
                if let action = item.action,
                    UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil)
                {
                    report.append("activated '\(label)' through UIBarButtonItem")
                    return
                }
                if let custom = item.customView {
                    if let control = descendants(custom).compactMap({ $0 as? UIControl }).first {
                        control.sendActions(for: .touchUpInside)
                        report.append("activated '\(label)' through UIControl")
                        return
                    }
                    if let element = accessibilityElement(labelled: label, in: custom), element.accessibilityActivate()
                    {
                        report.append("activated '\(label)' through accessibility")
                        return
                    }
                }
            }
            if let element = accessibilityElement(labelled: label, in: window), element.accessibilityActivate() {
                report.append("activated '\(label)' through window accessibility")
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        report.append("DIAGNOSTICS for '\(label)': items=\(barItemLabels(in: window))")
        XCTFail("no activatable bar item labelled '\(label)'")
        throw MobileFixtureError.unavailable
    }

    @MainActor private func waitUntil(
        _ what: String, timeout: Duration = .seconds(20), _ condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        report.append("TIMEOUT: \(what)")
        XCTFail("timed out: \(what)")
        throw MobileFixtureError.unavailable
    }

    @MainActor private func snapshot(_ window: UIWindow, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let data = image.pngData() { writeArtifact("\(name).png", data) }
    }

    private func writeArtifact(_ name: String, _ data: Data) {
        guard let directory = ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_UI_SNAPSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? data.write(to: url.appendingPathComponent(name))
    }
}
