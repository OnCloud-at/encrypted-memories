import AlbumCore
import LibrarySourceRuntime
import MLSearchCore
import MediaCacheUIKitAdapter
import PhotosCore
import Testing
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile
@testable import ProtonDriveBackend

/// The view and all of its subviews, depth first.
@MainActor func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
}

/// Checks `condition` every `interval` until it holds or `timeout` has passed, then checks it once more.
/// Returns whether it held at the last check. The condition runs on the caller's isolation.
func pollUntil(
    timeout: Duration, every interval: Duration = .milliseconds(10),
    isolation: isolated (any Actor)? = #isolation, _ condition: () async -> Bool
) async throws -> Bool {
    try await poll(timeout: timeout, isolation: isolation, pause: { try await Task.sleep(for: interval) }, condition)
}

/// Like `pollUntil`, but yields to other tasks between checks instead of sleeping.
func yieldUntil(
    timeout: Duration = .seconds(5), isolation: isolated (any Actor)? = #isolation, _ condition: () async -> Bool
) async -> Bool {
    await poll(timeout: timeout, isolation: isolation, pause: { await Task.yield() }, condition)
}

private func poll(
    timeout: Duration, isolation: isolated (any Actor)?, pause: () async throws -> Void,
    _ condition: () async -> Bool
) async rethrows -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try await pause()
    }
    return await condition()
}

/// Installs a source analysis runtime without album sources into `model`. With an authority, the runtime first
/// admits the fixture photos with that authority and generation.
@MainActor func installSourceRuntime(
    into model: MobileLibraryModel, fixture: MobileSignedInFixture, feed: UIKitThumbnailFeed? = nil,
    startingWith authority: SourceInventoryAuthority? = nil, generation: UInt64 = 0
) async -> LibrarySourceAnalysisRuntime {
    let coordinator = LibrarySourceCoordinator(
        remote: NoLibrarySources(), thumbnailLoader: fixture.backend, inventoryStore: nil)
    await coordinator.prepare()
    let runtime = LibrarySourceAnalysisRuntime(
        coordinator: coordinator, feed: (feed ?? fixture.feed).feedCore,
        assets: MLAssetUniverse(), initiallyActive: false, onAssetsChanged: {})
    if let authority {
        #expect(
            await runtime.start(primaryItems: fixture.items, authority: authority, generation: generation)
                == .accepted)
    }
    model.installIsolatedSourceAnalysisForTests(runtime)
    return runtime
}

/// A library without album sources.
private struct NoLibrarySources: LibrarySourceRemoteBackend {
    func librarySourceLocators() async throws -> [AlbumNodeIdentifier] { [] }
    func librarySourceItems(for _: AlbumNodeIdentifier) async throws -> [LibrarySourceItem] { [] }
}

extension XCTestCase {
    /// Attaches a screenshot of `window` and, when `ENCRYPTED_MEMORIES_UI_SNAPSHOT_DIR` is set, saves it there.
    @MainActor func snapshot(_ window: UIWindow, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let data = image.pngData() { writeArtifact("\(name).png", data) }
    }

    func writeArtifact(_ name: String, _ data: Data) {
        guard let directory = ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_UI_SNAPSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? data.write(to: url.appendingPathComponent(name))
    }
}
