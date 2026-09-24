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

    func testSharedAlbumRowsUseTheSharedPresentationAndNeverEvaluateRoles() throws {
        for path in ["App/Views/MacLibrarySidebar.swift", "iOSApp/MobileAlbumsScreen.swift"] {
            let view = try source(path)
            XCTAssertTrue(view.contains("presentation.detailLine"), "\(path) must show the shared role line")
            XCTAssertTrue(
                view.contains(".accessibilityLabel(presentation.accessibilityLabel)"),
                "\(path) must expose the effective role to VoiceOver")
            for forbidden in [
                "SharedAlbumPermissions.resolve", "album.role", "invitation?.role", "canWriteSharedAlbums",
                "SharedAlbumRole",
            ] {
                XCTAssertFalse(view.contains(forbidden), "\(path) must not evaluate shared roles (\(forbidden))")
            }
            XCTAssertFalse(view.contains("import ProtonDriveSDK"), "\(path) must not import SDK types")
        }
        let mac = try source("App/Views/MainView.swift")
        for forbidden in [
            "SharedAlbumPermissions.resolve", "album.role", "invitation?.role", "canWriteSharedAlbums",
            "SharedAlbumRole", "import ProtonDriveSDK",
        ] {
            XCTAssertFalse(mac.contains(forbidden), "MainView must not evaluate shared roles (\(forbidden))")
        }
        let core = try source("Packages/EncryptedMemoriesKit/Sources/AlbumCore/AlbumModels.swift")
        XCTAssertFalse(core.contains("import ProtonDriveSDK"))
    }

    func testSharedAlbumsOpenAsReadOnlyRoutesOnEveryPlatform() throws {
        let macSidebar = try source("App/Views/MacLibrarySidebar.swift")
        XCTAssertTrue(
            macSidebar.contains("PhotoFilter.sharedAlbum("), "macOS sidebar rows must select the shared route")
        let mac = try source("App/Views/MainView.swift")
        XCTAssertTrue(mac.contains("!selection.isReadOnly"), "macOS mutation toolbar must hide on read-only routes")

        let mobile = try source("iOSApp/MobileAlbumsScreen.swift")
        XCTAssertTrue(mobile.contains("filter: .sharedAlbum("), "iOS shared rows must navigate to the shared route")
        XCTAssertTrue(mobile.contains("filter.isReadOnly ? nil"), "iOS grid must drop mutations on read-only routes")

        let bridge = try source("Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/DriveSDKBridge.swift")
        XCTAssertTrue(
            bridge.contains("case .sharedAlbum(let volumeID, let nodeID, _):")
                && bridge.contains(".librarySourceItems(for: AlbumNodeIdentifier(volumeID: volumeID, nodeID: nodeID))"),
            "shared album contents must come from the volume-qualified SDK adapter, never the owned HTTP route")
    }

    func testMobileFilteredCollectionsRecoverAfterTransientLoadFailure() throws {
        let collections = try source("iOSApp/MobileAlbumsScreen.swift")
        XCTAssertTrue(collections.contains("Button(L10n.string(\"action.retry\"))"))
        XCTAssertTrue(collections.contains("networkMonitor.didRecentlyRestoreConnection"))
        XCTAssertTrue(collections.contains("guard restored, phase.isFailure"))
        XCTAssertTrue(collections.contains("snapshotReconciler.beginLoad()"))
        XCTAssertTrue(
            collections.contains("snapshotReconciler.publishLoaded(prepared, token: token)"),
            "successful loads must pass the shared generation and snapshot-revision guard")
        XCTAssertTrue(
            collections.contains("snapshotReconciler.isCurrent(token)"),
            "late load failures must not overwrite a newer retry result")
    }
}
