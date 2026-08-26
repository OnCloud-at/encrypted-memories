import XCTest

final class AlbumActionRouteTests: XCTestCase {
    private var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testEveryPlatformRoutesAlbumActionsThroughSharedFeatureUI() throws {
        let sharedViews = try source(
            "Packages/EncryptedMemoriesKit/Sources/AlbumsFeature/AlbumActionViews.swift"
        )
        XCTAssertTrue(sharedViews.contains("public struct AlbumCreationSheet"))
        XCTAssertTrue(sharedViews.contains("public struct AlbumDestinationPicker"))
        XCTAssertTrue(
            sharedViews.contains(".presentationCompactAdaptation(.sheet)"),
            "the album destination list must become a usable sheet in compact iPhone layouts")
        XCTAssertFalse(
            sharedViews.contains("horizontal: .popover"),
            "forcing a fitted list popover on compact iPhone collapses its content into overflow")

        let mac = try source("App/Views/MainView.swift")
        XCTAssertTrue(mac.contains("AlbumCreationSheet("))
        XCTAssertTrue(mac.contains("AlbumDestinationPicker("))

        for mobileRoute in [
            "iOSApp/MobileTimelineScreen.swift",
            "iOSApp/MobileAlbumsScreen.swift",
            "iOSApp/MobileMapClusterSeriesScreen.swift",
        ] {
            let source = try source(mobileRoute)
            XCTAssertTrue(
                source.contains("AlbumDestinationPicker("),
                "\(mobileRoute) must keep add-to-album on the shared interaction flow"
            )
        }

        let collections = try source("iOSApp/MobileAlbumsScreen.swift")
        XCTAssertTrue(collections.contains("AlbumCreationSheet("))
    }

    func testMobileFilteredCollectionsRecoverAfterTransientLoadFailure() throws {
        let collections = try source("iOSApp/MobileAlbumsScreen.swift")
        XCTAssertTrue(collections.contains("Button(L10n.string(\"action.retry\"))"))
        XCTAssertTrue(collections.contains("networkMonitor.didRecentlyRestoreConnection"))
        XCTAssertTrue(collections.contains("guard restored, phase.isFailure"))
        XCTAssertTrue(
            collections.contains("generation == loadGeneration"),
            "late responses must not overwrite a newer retry result")
    }
}
