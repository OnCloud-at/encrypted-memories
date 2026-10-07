import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile

final class MobileSearchLandingLayoutTests: XCTestCase {
    @MainActor func testSearchClearanceFollowsSizeClassWithoutGrowingWithDynamicType() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let model = MobileLibraryModel()
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let content = MobileSearchLandingContent(
            recents: (0..<5).map {
                MobileSearchRecentEntry(query: "Recent search \($0)", representativeUID: nil, suggestion: nil)
            })
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        // A narrow iPad window uses the same compact placement as a phone. Reuse one host to test resizing too.
        for size in [DynamicTypeSize.large, .accessibility5, .xSmall] {
            for sizeClass in [UserInterfaceSizeClass.compact, .regular, .compact] {
                host.rootView = AnyView(
                    MobileSearchLandingScreen(content: content)
                        .environment(model)
                        .environment(\.horizontalSizeClass, sizeClass)
                        .environment(\.dynamicTypeSize, size)
                        .ignoresSafeArea())
                try await Task.sleep(for: .milliseconds(100))
                host.view.layoutIfNeeded()
                let scroll = try XCTUnwrap(scrollView(in: host.view))
                XCTAssertEqual(
                    scroll.contentInset.bottom, sizeClass == .compact ? 56 : 0, accuracy: 1,
                    "Only a bottom search field needs clearance, at every text size")
            }
        }
    }

    @MainActor private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }
}
