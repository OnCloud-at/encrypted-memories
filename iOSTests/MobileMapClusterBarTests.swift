import DesignSystemCore
import MediaLocationCore
import PhotosCore
import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile

final class MobileMapClusterBarTests: XCTestCase {
    @MainActor func testPageActionsHaveVerticalTitlesAndKeepTheirPageLimits() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let state = MapPageBarState()
        let hosted = HostedTestWindow(scene: scene)
        let window = hosted.window
        window.rootViewController = UIHostingController(rootView: MapPageBarProbe(state: state))
        window.makeKeyAndVisible()
        defer {
            hosted.close()
        }
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(state.readEdge)
        let previous = L10n.string("map.previous_page")
        let next = L10n.string("map.next_page")
        let items = navigationBarItems(in: window)
        let detail =
            "edge=\(String(describing: state.edge)) items=\(items.map { ($0.title, $0.accessibilityLabel, $0.isEnabled) })"
        let attachment = XCTAttachment(string: detail)
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[Map bar] \(detail)")
        if state.edge != nil {
            let previousItem = try XCTUnwrap(items.first { label(of: $0) == previous })
            let nextItem = try XCTUnwrap(items.first { label(of: $0) == next })
            XCTAssertFalse(previousItem.isEnabled, "The first page has no previous page")
            XCTAssertTrue(nextItem.isEnabled)
            try activate(nextItem)
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(state.pageIndex, 1)
            XCTAssertTrue(try XCTUnwrap(navigationBarItems(in: window).first { label(of: $0) == previous }).isEnabled)
            XCTAssertFalse(try XCTUnwrap(navigationBarItems(in: window).first { label(of: $0) == next }).isEnabled)
            state.isBusy = true
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertFalse(try XCTUnwrap(navigationBarItems(in: window).first { label(of: $0) == previous }).isEnabled)
            state.isBusy = false
            try await Task.sleep(for: .milliseconds(500))
            try activate(try XCTUnwrap(navigationBarItems(in: window).first { label(of: $0) == previous }))
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(state.pageIndex, 0)
        } else {
            XCTAssertFalse(
                items.contains { label(of: $0) == previous || label(of: $0) == next },
                "Horizontal page arrows keep their existing image presentation")
            XCTAssertEqual(items.filter { $0.image != nil }.count, 2)
        }
    }

    @MainActor private func label(of item: UIBarButtonItem) -> String? {
        item.title ?? item.accessibilityLabel ?? item.customView?.accessibilityLabel
    }

    @MainActor private func activate(_ item: UIBarButtonItem) throws {
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil))
    }
}

@MainActor @Observable private final class MapPageBarState {
    let pager = PhotoLocationClusterPager(
        uids: (0..<2).map { PhotoUID(volumeID: "map-bar", nodeID: "\($0)") }, pageSize: 1)
    var pageIndex = 0
    var isBusy = false
    var edge: HorizontalEdge?
    var readEdge = false
}

private struct MapPageBarProbe: View {
    let state: MapPageBarState
    @Environment(\.verticalBarEdge) private var edge

    var body: some View {
        NavigationStack {
            Color.clear
                .navigationTitle("Places")
                .toolbar {
                    MobileMapClusterPageToolbarItems(
                        pageIndex: state.pageIndex, pageCount: state.pager.pageCount,
                        currentPage: state.pager.page(at: state.pageIndex), isBusy: state.isBusy,
                        previous: { state.pageIndex -= 1 }, next: { state.pageIndex += 1 })
                }
                .onAppear {
                    state.edge = edge
                    state.readEdge = true
                }
        }
    }
}
