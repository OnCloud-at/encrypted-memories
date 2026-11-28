import Foundation
import XCTest

@testable import UploadCore

/// The folder list that the Mac app derives from its bookmark resolutions (#1583).
final class WatchedFolderRegistryTests: XCTestCase {
    private let drive = "/Volumes/Drive-1583/Photos"
    private let disk = "/Users/Shared/Photos-1583"
    private let driveBookmark = Data("drive".utf8)
    private let diskBookmark = Data("disk".utf8)

    private func file(in folder: String) -> String { folder + "/IMG_0001.jpg" }

    /// The scope as the app sees it: it holds access to every folder that it may read.
    private func scope(_ registry: WatchedFolderRegistry) -> WatchedFolderScope {
        registry.scope(readable: registry.readableFolders.compactMap { $0.path.map(URL.init(fileURLWithPath:)) })
    }

    /// A claim admits a file only while its folder exists, so the tests treat every folder as present.
    private func admits(_ registry: WatchedFolderRegistry, _ path: String) -> Bool {
        scope(registry).claimFilter(rootExists: { _ in true }).admits(path: path)
    }

    func testADriveThatWasAwayAtLaunchIsReadableOnceItsBookmarkResolvesAgain() throws {
        var registry = WatchedFolderRegistry(savedBookmarks: [driveBookmark, diskBookmark]) {
            $0 == self.driveBookmark ? .unresolved : .resolved(path: self.disk, isStale: false)
        }
        let id = try XCTUnwrap(registry.folders.first { $0.bookmark == driveBookmark }?.id)
        XCTAssertEqual(registry.folders.map(\.displayPath).sorted(), [disk, "?"].sorted())
        XCTAssertEqual(registry.readableFolders.map(\.path), [disk])
        XCTAssertFalse(admits(registry, file(in: drive)), "a file of the drive waits")
        XCTAssertFalse(admits(registry, "/elsewhere/IMG.jpg"), "a \"?\" folder proves no file outside")
        XCTAssertTrue(admits(registry, file(in: disk)))

        XCTAssertTrue(
            registry.refresh { .resolved(path: $0 == self.driveBookmark ? self.drive : self.disk, isStale: false) })

        let mounted = registry.folders.first { $0.id == id }
        XCTAssertEqual(mounted?.path, drive)
        XCTAssertEqual(mounted?.needsRenewal, false)
        XCTAssertTrue(admits(registry, file(in: drive)))
        XCTAssertTrue(admits(registry, "/elsewhere/IMG.jpg"), "every folder is known again")
    }

    func testAFolderStaysUnreadableWhileItsBookmarkStillFails() {
        var registry = WatchedFolderRegistry(savedBookmarks: [driveBookmark]) { _ in .unresolved }
        let before = registry

        XCTAssertFalse(registry.refresh { _ in .unresolved })

        XCTAssertEqual(registry, before)
        XCTAssertFalse(admits(registry, file(in: drive)))
    }

    /// The scan of a pass finds the drive gone: the folder keeps its path, so its rows stay where they are, and becomes
    /// readable again once its bookmark resolves.
    func testADriveThatGoesAwayDuringAPassKeepsItsPathAndIsReadableAgainOnceItIsBack() throws {
        var registry = WatchedFolderRegistry(savedBookmarks: [driveBookmark]) { _ in
            .resolved(path: self.drive, isStale: false)
        }
        let id = try XCTUnwrap(registry.folders.first?.id)

        XCTAssertTrue(registry.apply(.unresolved, to: id))
        XCTAssertEqual(registry.folders.first?.path, drive)
        XCTAssertEqual(registry.folders.first?.needsRenewal, true)
        XCTAssertFalse(admits(registry, file(in: drive)))
        XCTAssertTrue(admits(registry, "/elsewhere/IMG.jpg"), "the folder still has a known path")

        XCTAssertTrue(registry.apply(.resolved(path: drive, isStale: false), to: id))
        XCTAssertTrue(admits(registry, file(in: drive)))
    }

    func testAStaleBookmarkKeepsItsPathButIsNotRead() {
        let registry = WatchedFolderRegistry(savedBookmarks: [driveBookmark]) { _ in
            .resolved(path: self.drive, isStale: true)
        }

        XCTAssertEqual(registry.folders.map(\.displayPath), [drive])
        XCTAssertEqual(registry.folders.map(\.needsRenewal), [true])
        XCTAssertFalse(admits(registry, file(in: drive)))
    }

    /// The person adds a folder again whose bookmark does not resolve: the new entry replaces the "?" entry with the same
    /// recorded path, so no entry is left that hides every other folder's rows. A "?" entry of another folder stays.
    func testAddingAFolderAgainReplacesItsQuestionMarkEntry() {
        let otherBookmark = Data("other".utf8)
        var registry = WatchedFolderRegistry(savedBookmarks: [driveBookmark, otherBookmark]) { _ in .unresolved }
        let recorded = [driveBookmark: drive, otherBookmark: "/Volumes/Other-1583/Photos"]
        let newBookmark = Data("drive again".utf8)

        registry.add(bookmark: newBookmark, path: drive, lastKnownPath: { recorded[$0] })

        XCTAssertEqual(registry.folders.map(\.bookmark).sorted { $0.count < $1.count }, [otherBookmark, newBookmark])
        XCTAssertEqual(registry.folders.filter { $0.path == drive }.map(\.needsRenewal), [false])
        XCTAssertEqual(registry.folders.filter { $0.path == nil }.map(\.bookmark), [otherBookmark])
        XCTAssertEqual(registry.bookmarks.count, 2)
    }

    func testAddingAFolderWithAKnownPathReplacesItsEntry() {
        var registry = WatchedFolderRegistry(savedBookmarks: [driveBookmark]) { _ in
            .resolved(path: self.drive, isStale: true)
        }
        let newBookmark = Data("drive again".utf8)

        registry.add(bookmark: newBookmark, path: drive, lastKnownPath: { _ in nil })

        XCTAssertEqual(registry.folders.map(\.bookmark), [newBookmark])
        XCTAssertEqual(registry.folders.map(\.needsRenewal), [false])
    }

    /// The drive is mounted under another name ("Drive 1"): the folder reads its files at the new path, and the path
    /// that its bookmark recorded stays registered, so the rows of the old path are neither outside nor read (#1583).
    func testADriveMountedUnderAnotherNameKeepsItsEarlierPathRegistered() throws {
        let renamed = "/Volumes/Drive-1583 1/Photos"
        let atLaunch = WatchedFolderRegistry(
            savedBookmarks: [driveBookmark], resolve: { _ in .resolved(path: renamed, isStale: false) },
            lastKnownPath: { _ in self.drive })
        var whileRunning = WatchedFolderRegistry(savedBookmarks: [driveBookmark]) { _ in
            .resolved(path: self.drive, isStale: false)
        }
        let id = try XCTUnwrap(whileRunning.folders.first?.id)
        XCTAssertTrue(whileRunning.apply(.resolved(path: renamed, isStale: false), to: id))

        for registry in [atLaunch, whileRunning] {
            XCTAssertEqual(registry.folders.map(\.path), [renamed])
            XCTAssertEqual(registry.folders.map(\.formerPaths), [[drive]])
            XCTAssertTrue(admits(registry, file(in: renamed)))
            XCTAssertFalse(admits(registry, file(in: drive)), "a row of the old path is not read")
            XCTAssertEqual(scope(registry).location(ofPath: file(in: drive)), .unavailable, "and not outside")
        }
        var addedAgain = whileRunning
        addedAgain.add(bookmark: Data("renamed".utf8), path: renamed, lastKnownPath: { _ in nil })
        XCTAssertEqual(addedAgain.folders.map(\.formerPaths), [[drive]], "adding it again keeps the old path")
        var removed = whileRunning
        removed.remove(id)
        XCTAssertEqual(scope(removed).location(ofPath: file(in: drive)), .outside, "until the person removes it")
    }

    /// A "?" entry whose bookmark resolves again to the path of another entry becomes one entry with that path: the one
    /// that the app may read.
    func testTwoFoldersThatResolveToOnePathBecomeOne() throws {
        let newBookmark = Data("drive again".utf8)
        var registry = WatchedFolderRegistry(savedBookmarks: [driveBookmark, newBookmark]) {
            $0 == self.driveBookmark ? .unresolved : .resolved(path: self.drive, isStale: false)
        }
        XCTAssertEqual(registry.folders.count, 2)

        XCTAssertTrue(registry.refresh { _ in .resolved(path: self.drive, isStale: false) })

        XCTAssertEqual(registry.folders.map(\.path), [drive])
        XCTAssertEqual(registry.folders.map(\.needsRenewal), [false])
        XCTAssertEqual(registry.bookmarks.count, 1)

        let stale = WatchedFolderRegistry(savedBookmarks: [driveBookmark, newBookmark]) {
            .resolved(path: self.drive, isStale: $0 == self.driveBookmark)
        }
        XCTAssertEqual(stale.bookmarks, [newBookmark], "the entry that the app may read stays")
    }

    /// A missing saved list knows no folder, so no file counts as outside; adding or removing a folder saves a list.
    func testAMissingListIsUnknownUntilTheAppSavesOne() throws {
        var registry = WatchedFolderRegistry(savedBookmarks: nil) { _ in .unresolved }
        XCTAssertFalse(registry.isKnown)
        XCTAssertFalse(admits(registry, "/elsewhere/IMG.jpg"))

        registry.add(bookmark: diskBookmark, path: disk, lastKnownPath: { _ in nil })
        XCTAssertTrue(registry.isKnown)
        XCTAssertTrue(admits(registry, "/elsewhere/IMG.jpg"))

        registry.remove(try XCTUnwrap(registry.folders.first?.id))
        XCTAssertEqual(registry.bookmarks, [])
        XCTAssertTrue(registry.isKnown)
        XCTAssertTrue(admits(registry, "/elsewhere/IMG.jpg"))
    }
}
