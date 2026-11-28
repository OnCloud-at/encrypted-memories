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

    /// Two drives with the same name swap their mount names between passes ("Photos" and "Photos 1"): each folder keeps
    /// its own bookmark and its own earlier path, although its new path is the other folder's path from before.
    func testTwoFoldersThatSwapTheirPathsStayTwoFolders() throws {
        let first = "/Volumes/Photos-1583/DCIM"
        let second = "/Volumes/Photos-1583 1/DCIM"
        let paths = [driveBookmark: first, diskBookmark: second]
        var registry = WatchedFolderRegistry(savedBookmarks: [driveBookmark, diskBookmark]) {
            .resolved(path: paths[$0]!, isStale: false)
        }

        XCTAssertTrue(registry.refresh { .resolved(path: $0 == self.driveBookmark ? second : first, isStale: false) })

        let drive = try XCTUnwrap(registry.folders.first { $0.bookmark == driveBookmark })
        let disk = try XCTUnwrap(registry.folders.first { $0.bookmark == diskBookmark })
        XCTAssertEqual([drive.path, disk.path], [second, first])
        XCTAssertEqual([drive.formerPaths, disk.formerPaths], [[first], [second]])
        XCTAssertEqual(registry.readableFolders.count, 2)
        XCTAssertEqual(Set(registry.bookmarks), [driveBookmark, diskBookmark])

        // The scan of a pass applies one folder after the other: the first one takes the other's path while that one
        // still holds it, and the two stay two.
        var scanned = WatchedFolderRegistry(savedBookmarks: [driveBookmark, diskBookmark]) {
            .resolved(path: paths[$0]!, isStale: false)
        }
        let diskID = try XCTUnwrap(scanned.folders.first { $0.bookmark == diskBookmark }?.id)
        let driveID = try XCTUnwrap(scanned.folders.first { $0.bookmark == driveBookmark }?.id)
        XCTAssertTrue(scanned.apply(.resolved(path: first, isStale: false), to: diskID))
        XCTAssertEqual(scanned.folders.count, 2)
        XCTAssertTrue(scanned.apply(.resolved(path: second, isStale: false), to: driveID))
        let entries = { (registry: WatchedFolderRegistry) in
            registry.folders.map { "\($0.bookmark) \($0.displayPath) \($0.formerPaths) \($0.needsRenewal)" }.sorted()
        }
        XCTAssertEqual(entries(scanned), entries(registry))
    }

    /// A rename on one disk moves one folder to the path that another folder leaves in the same refresh (Old to New,
    /// Other to Old): both stay, each with its earlier path.
    func testAChainOfRenamesKeepsEveryFolder() throws {
        let otherBookmark = Data("other".utf8)
        let before = [driveBookmark: "/Users/Shared/Old-1583", otherBookmark: "/Users/Shared/Other-1583"]
        let after = [driveBookmark: "/Users/Shared/New-1583", otherBookmark: "/Users/Shared/Old-1583"]
        var registry = WatchedFolderRegistry(savedBookmarks: [driveBookmark, otherBookmark]) {
            .resolved(path: before[$0]!, isStale: false)
        }

        XCTAssertTrue(registry.refresh { .resolved(path: after[$0]!, isStale: false) })

        XCTAssertEqual(registry.folders.count, 2)
        for bookmark in [driveBookmark, otherBookmark] {
            let folder = try XCTUnwrap(registry.folders.first { $0.bookmark == bookmark })
            XCTAssertEqual(folder.path, after[bookmark])
            XCTAssertEqual(folder.formerPaths, [before[bookmark]!])
        }
    }

    /// A folder whose drive is away keeps the path from before; another folder that resolves to that path does not
    /// take its place, so the bookmark of the drive stays registered. Both orders of the two entries in the list.
    func testAFolderThatDoesNotResolveIsNeverJoinedWithAnotherOne() throws {
        let first = "/Volumes/A-1583/DCIM"
        let second = "/Volumes/B-1583/DCIM"
        for (path, otherPath) in [(first, second), (second, first)] {
            var registry = WatchedFolderRegistry(savedBookmarks: [driveBookmark]) { _ in
                .resolved(path: path, isStale: false)
            }
            registry.add(bookmark: diskBookmark, path: otherPath, lastKnownPath: { _ in nil })

            XCTAssertTrue(
                registry.refresh { $0 == self.driveBookmark ? .unresolved : .resolved(path: path, isStale: false) })

            XCTAssertEqual(Set(registry.bookmarks), [driveBookmark, diskBookmark], path)
            XCTAssertEqual(registry.folders.map(\.path), [path, path], path)
            XCTAssertEqual(registry.readableFolders.map(\.bookmark), [diskBookmark], path)
        }
    }

    /// A folder that the person added while the bookmarks resolved has no resolution in that refresh: it stays as it is
    /// and readable.
    func testAFolderWithoutAResolutionStaysAsItIs() throws {
        var registry = WatchedFolderRegistry(savedBookmarks: [driveBookmark]) { _ in
            .resolved(path: self.drive, isStale: false)
        }
        registry.add(bookmark: diskBookmark, path: disk, lastKnownPath: { _ in nil })
        let added = try XCTUnwrap(registry.folders.first { $0.bookmark == diskBookmark })

        XCTAssertFalse(
            registry.refresh { $0 == self.driveBookmark ? .resolved(path: self.drive, isStale: false) : nil })

        XCTAssertEqual(registry.folders.first { $0.bookmark == diskBookmark }, added)
        XCTAssertTrue(admits(registry, file(in: disk)))
    }

    /// The paths of a folder outlive a relaunch: a drive that this launch found under another name ("Photos 1") and
    /// that the next launch finds under its first name again keeps both paths registered. An old saved list without
    /// paths still loads, and a damaged value knows no folder.
    func testThePathsOfAFolderOutliveARelaunch() throws {
        let renamed = "/Volumes/Drive-1583 1/Photos"
        let first = WatchedFolderRegistry(
            savedBookmarks: [driveBookmark], resolve: { _ in .resolved(path: renamed, isStale: false) },
            lastKnownPath: { _ in self.drive })
        XCTAssertTrue(first.pathsNeedSaving(comparedTo: nil), "the launch saves the path it found")
        let saved: Any = first.pathsToSave
        XCTAssertFalse(first.pathsNeedSaving(comparedTo: saved))

        for resolution in [WatchedFolderBookmarkResolution.resolved(path: drive, isStale: false), .unresolved] {
            let next = WatchedFolderRegistry(
                savedBookmarks: [driveBookmark], savedPaths: saved, resolve: { _ in resolution },
                lastKnownPath: { _ in self.drive })
            XCTAssertTrue(next.isKnown)
            XCTAssertTrue(next.folders.first?.formerPaths.contains(renamed) == true, "\(resolution)")
            XCTAssertNotEqual(scope(next).location(ofPath: file(in: renamed)), .outside, "\(resolution)")
        }

        let old = WatchedFolderRegistry(savedBookmarks: [driveBookmark], savedPaths: nil) { _ in
            .resolved(path: self.drive, isStale: false)
        }
        XCTAssertTrue(old.isKnown)
        XCTAssertEqual(old.folders.map(\.formerPaths), [[]])

        let damaged = WatchedFolderRegistry(savedBookmarks: [driveBookmark], savedPaths: "damaged") { _ in
            .resolved(path: self.drive, isStale: false)
        }
        XCTAssertFalse(damaged.isKnown)
        XCTAssertFalse(damaged.pathsNeedSaving(comparedTo: "damaged"))
        XCTAssertFalse(admits(damaged, "/elsewhere/IMG.jpg"), "no file counts as outside")
    }

    /// Adding a folder again keeps its saved paths; removing it drops them from the value to save.
    func testRemovingAFolderDropsItsSavedPaths() throws {
        let renamed = "/Volumes/Drive-1583 1/Photos"
        let saved = [driveBookmark.base64EncodedString(): [renamed]]
        var registry = WatchedFolderRegistry(savedBookmarks: [driveBookmark], savedPaths: saved) { _ in
            .resolved(path: self.drive, isStale: true)
        }
        let newBookmark = Data("drive again".utf8)

        registry.add(bookmark: newBookmark, path: drive, lastKnownPath: { _ in nil })

        XCTAssertEqual(registry.pathsToSave, [newBookmark.base64EncodedString(): [renamed, drive]])
        registry.remove(try XCTUnwrap(registry.folders.first?.id))
        XCTAssertEqual(registry.pathsToSave, [:])
    }

    /// The path that the bookmark recorded always stays, beside the newest eight others.
    func testAFolderKeepsTheNewestEarlierPathsOnce() throws {
        let recorded = "/Volumes/Recorded/Photos"
        var registry = WatchedFolderRegistry(
            savedBookmarks: [driveBookmark], resolve: { _ in .resolved(path: "/Volumes/D0/Photos", isStale: false) },
            lastKnownPath: { _ in recorded })
        let renames = (1...12).map { "/Volumes/D\($0)/Photos" } + ["/Volumes/D3/Photos", "/Volumes/D13/Photos"]
        for path in renames {
            registry.refresh(resolve: { _ in .resolved(path: path, isStale: false) }, lastKnownPath: { _ in recorded })
        }

        let others = (6...12).map { "/Volumes/D\($0)/Photos" } + ["/Volumes/D3/Photos"]
        XCTAssertEqual(WatchedFolderRegistry.formerPathLimit, others.count)
        XCTAssertEqual(registry.folders.map(\.formerPaths), [[recorded] + others])
        XCTAssertEqual(registry.folders.map(\.path), ["/Volumes/D13/Photos"])

        // Two relaunches that find the folder at its path again, and one that finds the drive away, keep every path.
        var saved = registry.pathsToSave
        for _ in 0..<2 {
            let relaunched = WatchedFolderRegistry(
                savedBookmarks: registry.bookmarks, savedPaths: saved,
                resolve: { _ in .resolved(path: "/Volumes/D13/Photos", isStale: false) },
                lastKnownPath: { _ in recorded })
            XCTAssertEqual(relaunched.folders.map(\.formerPaths), [[recorded] + others])
            XCTAssertFalse(relaunched.pathsNeedSaving(comparedTo: saved))
            saved = relaunched.pathsToSave
        }
        let away = WatchedFolderRegistry(
            savedBookmarks: registry.bookmarks, savedPaths: saved, resolve: { _ in .unresolved },
            lastKnownPath: { _ in recorded })
        XCTAssertEqual(away.folders.map(\.formerPaths), [[recorded] + others + ["/Volumes/D13/Photos"]])
    }

    /// Two entries that become one keep the paths that both bookmarks recorded, also above the limit of the others.
    func testJoinedFoldersKeepBothRecordedPaths() throws {
        let shared = "/Volumes/Photos-1583/DCIM"
        let others = (1...8).map { "/Volumes/P\($0)/DCIM" }
        let recorded = [driveBookmark: "/Volumes/DriveRecorded/DCIM", diskBookmark: "/Volumes/DiskRecorded/DCIM"]
        let saved = [
            driveBookmark.base64EncodedString(): [recorded[driveBookmark]!] + others + [shared],
            diskBookmark.base64EncodedString(): [recorded[diskBookmark]!, shared],
        ]

        let registry = WatchedFolderRegistry(
            savedBookmarks: [driveBookmark, diskBookmark], savedPaths: saved,
            resolve: { _ in .resolved(path: shared, isStale: false) }, lastKnownPath: { recorded[$0] })

        XCTAssertEqual(registry.folders.count, 1)
        let kept = try XCTUnwrap(registry.folders.first?.formerPaths)
        XCTAssertEqual(Set(kept), Set(others + recorded.values))
    }

    /// A folder that the person adds again keeps the path that the replaced bookmark recorded, also above the limit of
    /// the others.
    func testAFolderAddedAgainKeepsTheRecordedPathOfTheOneItReplaces() throws {
        let path = "/Volumes/Photos-1583/DCIM"
        let recorded = "/Volumes/Recorded-1583/DCIM"
        let others = (1...8).map { "/Volumes/P\($0)/DCIM" }
        var registry = WatchedFolderRegistry(
            savedBookmarks: [driveBookmark],
            savedPaths: [driveBookmark.base64EncodedString(): [recorded] + others + [path]],
            resolve: { _ in .resolved(path: path, isStale: true) }, lastKnownPath: { _ in recorded })
        XCTAssertEqual(registry.folders.map(\.formerPaths), [[recorded] + others])
        let newBookmark = Data("drive again".utf8)

        registry.add(
            bookmark: newBookmark, path: path, lastKnownPath: { $0 == self.driveBookmark ? recorded : nil })

        XCTAssertEqual(registry.folders.map(\.bookmark), [newBookmark])
        XCTAssertEqual(registry.folders.map(\.formerPaths), [[recorded] + others])
    }

    /// Three folders rotate their paths in one refresh: each keeps its bookmark and its own earlier path.
    func testThreeFoldersThatRotateTheirPathsStayThree() throws {
        let thirdBookmark = Data("third".utf8)
        let bookmarks = [driveBookmark, diskBookmark, thirdBookmark]
        let paths = ["/Volumes/A-1583/DCIM", "/Volumes/B-1583/DCIM", "/Volumes/C-1583/DCIM"]
        func path(of bookmark: Data, shift: Int) -> String {
            paths[(bookmarks.firstIndex(of: bookmark)! + shift) % paths.count]
        }
        var registry = WatchedFolderRegistry(savedBookmarks: bookmarks) {
            .resolved(path: path(of: $0, shift: 0), isStale: false)
        }

        XCTAssertTrue(registry.refresh { .resolved(path: path(of: $0, shift: 1), isStale: false) })

        XCTAssertEqual(registry.folders.count, 3)
        for bookmark in bookmarks {
            let folder = try XCTUnwrap(registry.folders.first { $0.bookmark == bookmark })
            XCTAssertEqual(folder.path, path(of: bookmark, shift: 1))
            XCTAssertEqual(folder.formerPaths, [path(of: bookmark, shift: 0)])
        }
    }

    /// The access that the app holds follows the readable folders: a folder that a refresh gives another path, also one
    /// whose drive came back under another name before the next pass, gets a new access at that path, so its files at
    /// the new path are read and its rows at the old path wait. With a chain of renames (Old to New, Other to Old) the
    /// old path becomes readable for the folder that lies there now.
    func testTheHeldAccessFollowsTheCurrentPathOfEachFolder() throws {
        let otherBookmark = Data("other".utf8)
        let before = [driveBookmark: "/Users/Shared/Old-1583", otherBookmark: "/Users/Shared/Other-1583"]
        let after = [driveBookmark: "/Users/Shared/New-1583", otherBookmark: "/Users/Shared/Old-1583"]
        var registry = WatchedFolderRegistry(savedBookmarks: [driveBookmark, otherBookmark]) {
            .resolved(path: before[$0]!, isStale: false)
        }
        let drive = try XCTUnwrap(registry.folders.first { $0.bookmark == driveBookmark }?.id)
        let other = try XCTUnwrap(registry.folders.first { $0.bookmark == otherBookmark }?.id)
        // The app's access loop: stop, then start at the folder's path.
        var held: [WatchedFolder.ID: String] = [:]
        func hold() {
            let changes = registry.accessChanges(holding: held)
            for id in changes.stop { held[id] = nil }
            for folder in changes.start { held[folder.id] = folder.path }
        }
        hold()
        XCTAssertEqual(held, [drive: before[driveBookmark]!, other: before[otherBookmark]!])
        XCTAssertTrue(registry.accessChanges(holding: held).stop.isEmpty, "an unchanged folder keeps its access")
        XCTAssertTrue(registry.accessChanges(holding: held).start.isEmpty)

        XCTAssertTrue(registry.refresh { .resolved(path: after[$0]!, isStale: false) })
        XCTAssertEqual(registry.accessChanges(holding: held).stop, [drive, other])
        hold()

        XCTAssertEqual(held, [drive: after[driveBookmark]!, other: after[otherBookmark]!])
        let scope = registry.scope(readable: held.values.map(URL.init(fileURLWithPath:)))
        let filter = scope.claimFilter(rootExists: { _ in true })
        XCTAssertTrue(filter.admits(path: file(in: after[driveBookmark]!)), "the files at the new path are read")
        XCTAssertTrue(filter.admits(path: file(in: after[otherBookmark]!)), "the old path is read for its new folder")
        XCTAssertFalse(filter.admits(path: file(in: before[otherBookmark]!)), "the rows of a path that was left wait")

        XCTAssertTrue(registry.apply(.unresolved, to: drive))
        XCTAssertEqual(registry.accessChanges(holding: held).stop, [drive], "a marked folder is not read")
        XCTAssertTrue(registry.accessChanges(holding: held).start.isEmpty)
    }

    /// The app saves the list after a change of its bookmarks or of the paths of a folder, and not after a change that
    /// alters neither.
    func testTheListNeedsSavingOnlyWhenItsSavedValuesChange() throws {
        let registry = WatchedFolderRegistry(savedBookmarks: [driveBookmark]) { _ in
            .resolved(path: self.drive, isStale: false)
        }
        let id = try XCTUnwrap(registry.folders.first?.id)

        var marked = registry
        XCTAssertTrue(marked.apply(.unresolved, to: id))
        XCTAssertFalse(marked.needsSaving(since: registry), "a marked folder keeps its saved values")

        var renamed = registry
        XCTAssertTrue(renamed.apply(.resolved(path: "/Volumes/Drive-1583 1/Photos", isStale: false), to: id))
        XCTAssertEqual(renamed.bookmarks, registry.bookmarks)
        XCTAssertTrue(renamed.needsSaving(since: registry), "a new path is saved")

        var added = registry
        added.add(bookmark: diskBookmark, path: disk, lastKnownPath: { _ in nil })
        XCTAssertTrue(added.needsSaving(since: registry))
    }

    /// Saved paths that a launch found damaged keep the list unknown while the folders change, until
    /// `pathsWereSaved()`: before, no row counts as outside. The app saves the list, and so calls it, right after each
    /// change that it saves.
    func testDamagedSavedPathsKeepTheListUnknownUntilTheyAreSavedAgain() throws {
        var registry = WatchedFolderRegistry(savedBookmarks: [driveBookmark, diskBookmark], savedPaths: 7) {
            .resolved(path: $0 == self.driveBookmark ? self.drive : self.disk, isStale: false)
        }
        registry.remove(try XCTUnwrap(registry.folders.first { $0.bookmark == diskBookmark }?.id))
        XCTAssertFalse(registry.isKnown)
        XCTAssertEqual(scope(registry).location(ofPath: file(in: disk)), .unavailable)

        registry.pathsWereSaved()
        XCTAssertTrue(registry.isKnown)
        XCTAssertEqual(scope(registry).location(ofPath: file(in: disk)), .outside)
    }

    /// A folder whose bookmark does not resolve shows its last known path and "Drive not connected"; without any known
    /// path it shows "?". A folder whose bookmark resolves but must be renewed keeps asking to be added again, and a
    /// readable folder shows no line.
    func testTheFolderListShowsTheLastKnownPathAndWhyAFolderIsNotRead() throws {
        let renamed = "/Volumes/Drive-1583 1/Photos"
        let recordedOnly = WatchedFolderRegistry(
            savedBookmarks: [driveBookmark], resolve: { _ in .unresolved }, lastKnownPath: { _ in self.drive })
        XCTAssertEqual(recordedOnly.folders.map(\.shownPath), [drive])
        XCTAssertEqual(recordedOnly.folders.map(\.displayPath), ["?"], "the scope still treats its place as unknown")
        XCTAssertEqual(recordedOnly.folders.map(\.notice), [.driveNotConnected])

        let saved = WatchedFolderRegistry(
            savedBookmarks: [driveBookmark], savedPaths: [driveBookmark.base64EncodedString(): [drive, renamed]],
            resolve: { _ in .unresolved }, lastKnownPath: { _ in self.drive })
        XCTAssertEqual(saved.folders.map(\.shownPath), [renamed], "the newest saved path comes first")

        let unknown = WatchedFolderRegistry(savedBookmarks: [driveBookmark]) { _ in .unresolved }
        XCTAssertEqual(unknown.folders.map(\.shownPath), ["?"])
        XCTAssertEqual(unknown.folders.map(\.notice), [.driveNotConnected])

        var registry = WatchedFolderRegistry(savedBookmarks: [driveBookmark]) { _ in
            .resolved(path: self.drive, isStale: false)
        }
        let id = try XCTUnwrap(registry.folders.first?.id)
        XCTAssertEqual(registry.folders.map(\.notice), [nil])
        XCTAssertEqual(registry.folders.map(\.shownPath), [drive])

        registry.apply(.unresolved, to: id)
        XCTAssertEqual(registry.folders.map(\.shownPath), [drive], "a drive that goes away keeps its path")
        XCTAssertEqual(registry.folders.map(\.notice), [.driveNotConnected])

        registry.apply(.resolved(path: drive, isStale: true), to: id)
        XCTAssertEqual(registry.folders.map(\.notice), [.mustBeAddedAgain])

        registry.apply(.resolved(path: drive, isStale: false), to: id)
        XCTAssertEqual(registry.folders.map(\.notice), [nil], "the line goes once the folder is read again")
    }

    /// The scan maps a failed use of a bookmark to a resolution: no resolution means the drive went away, a stale
    /// bookmark or a refused access needs a new one, and so does a folder that the app may not read; a missing folder
    /// is one whose drive went away.
    func testAFailedScanOfAFolderTellsADriveThatWentAwayFromAnAccessToRenew() {
        XCTAssertEqual(WatchedFolderBookmarkResolution.afterFailedAccess(resolvedPath: nil), .unresolved)
        XCTAssertEqual(
            WatchedFolderBookmarkResolution.afterFailedAccess(resolvedPath: drive),
            .resolved(path: drive, isStale: true))
        XCTAssertEqual(
            WatchedFolderBookmarkResolution.afterRootReadFailure(.missing, rootPath: drive), .unresolved)
        XCTAssertEqual(
            WatchedFolderBookmarkResolution.afterRootReadFailure(.permissionDenied, rootPath: drive),
            .resolved(path: drive, isStale: true))
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
