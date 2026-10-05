#if os(macOS)
    import AppKit
    import PhotosCore
    import SwiftUI
    import XCTest

    @testable import UploadCore
    @testable import UploadFeature

    /// Renders the Duplicates screen of macOS in light and dark for a visual review. Runs only when
    /// `DUPLICATES_SCREENSHOT_DIR` names an output directory, so the gates never depend on it.
    @MainActor
    final class ExactDuplicatesScreenshotTests: XCTestCase {
        private func outputDirectory() throws -> URL {
            let path = ProcessInfo.processInfo.environment["DUPLICATES_SCREENSHOT_DIR"]
            try XCTSkipIf(path == nil, "Set DUPLICATES_SCREENSHOT_DIR to render the screenshots.")
            let url = URL(fileURLWithPath: path ?? "", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func testRenderTheDuplicatesStates() async throws {
            let directory = try outputDirectory()
            let members = (0..<6).map { PhotoUID(volumeID: "v", nodeID: "photo-\($0)") }
            let groups = [
                ExactDuplicateGroup(contentHash: "A", hashKeyEpoch: "e", members: Array(members[0..<3])),
                ExactDuplicateGroup(contentHash: "B", hashKeyEpoch: "e", members: Array(members[3..<5])),
            ]
            let states: [(String, ScreenshotFinder)] = [
                ("groups", ScreenshotFinder(groups: groups, coverage: .complete, build: .none)),
                ("checking", ScreenshotFinder(groups: [], coverage: .indexing, build: .counted)),
                ("ranking", ScreenshotFinder(groups: groups, coverage: .complete, build: .counted, holdsRanking: true)),
                (
                    "unchecked",
                    ScreenshotFinder(groups: groups, coverage: .incomplete(unresolvedCount: 12), build: .none)
                ),
            ]
            for (name, finder) in states {
                // The view starts the load itself, as the screen does when it opens.
                let model = ExactDuplicatesModel(finder: finder)
                let (window, host) = host(model: model)
                for _ in 0..<200 where !finder.isSettled(model) {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertTrue(finder.isSettled(model), name)
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    window.appearance = NSAppearance(named: appearance)
                    try await Task.sleep(for: .milliseconds(500))
                    let url = directory.appendingPathComponent(
                        "duplicates-macos-\(name)-\(appearance == .aqua ? "light" : "dark").png")
                    try capture(host, to: url)
                }
                window.orderOut(nil)
            }
        }

        private func host(model: ExactDuplicatesModel) -> (NSWindow, NSView) {
            let view = ExactDuplicatesView(
                model: model, confirmsMergeAll: .constant(false), accent: .accentColor, cornerRadius: 6,
                onOpen: { _, _ in }
            ) { uid in
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(hue: Self.hue(of: uid), saturation: 0.45, brightness: 0.8))
                    .frame(width: 132, height: 132)
            }
            .frame(width: 1400, height: 900)
            // The Mac route draws the window background behind the screen, as `MacDuplicatesView` does.
            .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            return (window, host)
        }

        /// A stable color for each photo, so the copies of a group look alike between runs.
        private static func hue(of uid: PhotoUID) -> Double {
            Double(uid.nodeID.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 100) / 100
        }

        private func capture(_ host: NSView, to url: URL) throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: url)
        }
    }

    /// Fixed answers for one state of the screen. A held ranking or build never finishes while the screen renders.
    private final class ScreenshotFinder: ExactDuplicateMerging, @unchecked Sendable {
        enum Build { case none, counted }

        let groups: [ExactDuplicateGroup]
        let coverage: ExactDuplicateCoverage
        let build: Build
        let holdsRanking: Bool

        init(
            groups: [ExactDuplicateGroup], coverage: ExactDuplicateCoverage, build: Build, holdsRanking: Bool = false
        ) {
            self.groups = groups
            self.coverage = coverage
            self.build = build
            self.holdsRanking = holdsRanking
        }

        @MainActor func isSettled(_ model: ExactDuplicatesModel) -> Bool {
            guard model.content != .loading else { return false }
            if build == .counted, model.checkLine == nil { return false }
            if holdsRanking, model.rankingLine == nil { return false }
            if case .incomplete = coverage, model.uncheckedNote == nil { return false }
            return true
        }

        func duplicateGroups(
            progress: @escaping @Sendable (ExactDuplicateScanProgress) async -> Void
        ) async throws -> ExactDuplicateScan {
            ExactDuplicateScan(groups: groups, coverage: coverage, byteSizes: ["A": 4_200_000, "B": 18_400_000])
        }

        func prepareIndex(
            progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
        ) async throws -> Bool {
            guard build == .counted else { return false }
            await progress(.init(phase: .indexing, completed: 21_480, total: 51_220))
            try await Task.sleep(for: .seconds(3_600))
            return false
        }

        func fallbackMembers(of groups: [ExactDuplicateGroup]) async -> [String: [PhotoUID]] {
            Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.members) })
        }

        /// Group A on one day, group B on two days.
        func captureDates(of members: [PhotoUID]) async -> [PhotoUID: Date] {
            let day = Date(timeIntervalSince1970: 1_749_456_000)
            var dates: [PhotoUID: Date] = [:]
            for group in groups {
                for (index, member) in group.members.enumerated() where members.contains(member) {
                    let offset = group.id == "B" ? Double(index) * 86_400 * 5 : Double(index) * 60
                    dates[member] = day.addingTimeInterval(offset)
                }
            }
            return dates
        }

        func rankMembers(
            of groups: [ExactDuplicateGroup], ranked: @escaping @Sendable (ExactDuplicateRankingPage) async -> Void
        ) async {
            if holdsRanking {
                await ranked(ExactDuplicateRankingPage(members: [:], groupCount: 1))
                try? await Task.sleep(for: .seconds(3_600))
                return
            }
            // The first copy of A is a favorite in an album and backed up here; the second copy of B is shared.
            let facts: [String: [PhotoUID: ExactDuplicateKeepFacts]] = Dictionary(
                uniqueKeysWithValues: groups.map { group in
                    let memberFacts = group.members.enumerated().map { index, member in
                        (
                            member,
                            ExactDuplicateKeepFacts(
                                isInOwnAlbum: group.id == "A" && index == 0, isFavorite: group.id == "A" && index == 0,
                                isNamedByManifest: group.id == "A" && index == 0, captureDate: nil,
                                isShared: group.id == "B" && index == 1)
                        )
                    }
                    return (group.id, Dictionary(uniqueKeysWithValues: memberFacts))
                })
            let order = Dictionary(
                uniqueKeysWithValues: groups.map { group in
                    (group.id, group.id == "B" ? Array(group.members.reversed()) : group.members)
                })
            await ranked(ExactDuplicateRankingPage(members: order, groupCount: groups.count, facts: facts))
        }

        func merge(
            _ requests: [(group: ExactDuplicateGroup, kept: PhotoUID)]
        ) async -> [Result<ExactDuplicateMergeOutcome, any Error>] {
            requests.map { _ in .failure(CancellationError()) }
        }
    }
#endif
