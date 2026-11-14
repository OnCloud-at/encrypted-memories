import Foundation
import PhotosCore
import ProtonAuth
import ProtonDriveSDK
import SQLite3
import Testing

@testable import ProtonDriveBackend

/// The listing names the related files of a Live Photo newest first and without a type. An edited Live Photo names its
/// paired video, its adjustment data, its edited motion (`FullSizeRender.mov`), and its original photo.
@Suite
struct LivePhotoMotionLinksTests {
    private let types = [
        "plist": "application/xml",
        "paired": "video/quicktime",
        "edited": "video/quicktime",
        "original": "image/heic",
        "other": "application/octet-stream",
        "motion": "video/quicktime",
        "render": "image/heic",
    ]
    private let names = [
        "plist": "Adjustments.plist", "paired": "IMG_2000.MOV", "edited": "FullSizeRender.mov",
        "original": "IMG_2000.HEIC", "render": "FullSizeRender.heic",
    ]

    /// An answer of the metadata read: each requested file with its type, and its name when it was asked for.
    private func answer(
        _ linkIDs: [String], _ nameLinkIDs: Set<String>, types: [String: String], names: [String: String]
    ) -> LivePhotoMotionLinks.Answer {
        LivePhotoMotionLinks.Answer(
            files: Dictionary(
                uniqueKeysWithValues: linkIDs.map { linkID in
                    (linkID, .init(mimeType: types[linkID], name: nameLinkIDs.contains(linkID) ? names[linkID] : nil))
                }))
    }

    @Test
    func aMarkedRenderReadsItsMainInTheSameBatchAndKeepsTheAnswerForTheSession() async throws {
        var links = LivePhotoMotionLinks()
        let photos = ["loop": ["paired", "edited"], "single": ["motion"], "adjusted": ["plist"], "empty": []]
        var requests = 0
        let first = try await links.motions(of: photos, stored: [:], evidence: types) { ids, nameIDs, mainIDs in
            requests += 1
            #expect(Set(ids) == ["paired", "edited", "loop"])
            #expect(nameIDs == ["paired", "edited"])
            #expect(mainIDs == ["loop"], "no ordinary, empty or single-video primary")
            var result = answer(ids, nameIDs, types: types, names: names)
            result.playback = ["loop": true]
            return result
        }
        #expect(first.motions["loop"] == .loopingVideo("edited"))
        #expect(first.motions["single"] == .video("motion"))
        #expect(first.read.playback == ["loop": true])
        #expect(first.read.types.isEmpty, "a name read cannot replace already-known MIME types")
        links.record(first.read)
        let second = try await links.motions(of: photos, stored: [:], evidence: types) { _, _, _ in
            requests += 1
            throw URLError(.notConnectedToInternet)
        }
        #expect(requests == 1)
        #expect(second.motions["loop"] == .loopingVideo("edited"))
    }

    @Test
    func anUnreadMainMarkerRetriesWithoutReadingVideoNamesAgain() async throws {
        var links = LivePhotoMotionLinks()
        let photos = ["live": ["paired", "edited"]]
        let first = try await links.motions(of: photos, stored: [:], evidence: types) { ids, nameIDs, _ in
            return answer(ids, nameIDs, types: types, names: names)
        }
        #expect(first.motions["live"] == .unknown, "an unread marker is not known ordinary playback")
        #expect(first.read.playback.isEmpty)
        links.record(first.read)
        let second = try await links.motions(of: photos, stored: [:], evidence: types) { ids, nameIDs, mainIDs in
            #expect(ids == ["live"])
            #expect(nameIDs.isEmpty)
            #expect(mainIDs == ["live"])
            return .init(files: [:], playback: ["live": true])
        }
        #expect(second.motions["live"] == .loopingVideo("edited"))
    }

    @Test
    func aMarkerNeverLoopsAnOrdinaryMotionOrOneOfItsSecondaryFiles() async throws {
        let photos = ["ordinary": ["paired", "motion"], "unmarked": ["paired", "edited"]]
        let selectedNames = names.merging(["motion": "Other.mov"]) { first, _ in first }
        let result = try await LivePhotoMotionLinks().motions(of: photos, stored: [:], evidence: types) {
            ids, nameIDs, _ in
            var result = answer(ids, nameIDs, types: types, names: selectedNames)
            result.playback = ["ordinary": true, "unmarked": false, "edited": true]
            return result
        }
        #expect(result.motions["ordinary"] == .video("paired"))
        #expect(result.motions["unmarked"] == .video("edited"), "a secondary marker never classifies its parent")
    }

    @Test
    func bothListingPathsPreserveLoopsAndTheLivePhotosTag() throws {
        let entries = [
            PhotosListEntry(linkID: "loop", captureTime: 1, tags: [3], relatedPhotos: [.init(linkID: "edited")])
        ]
        let motions: [String: LivePhotoMotion] = ["loop": .loopingVideo("edited")]
        let direct = DriveSDKBridge.group(entries, volumeID: "v", motions: motions).flatMap(\.items)
        let sdk = DriveSDKBridge.group(
            [PhotoTimelineItem(nodeUid: SDKNodeUid(volumeID: "v", nodeID: "loop"), captureTime: 1)],
            livePhotoMotions: motions
        ).flatMap(\.items)
        for items in [direct, sdk] {
            let item = try #require(items.first)
            #expect(item.isLoopingLivePhoto)
            #expect(item.isLivePhoto)
            #expect(item.relatedVideoID == "edited")
        }
        #expect(direct.first?.tags.contains(.livePhotos) == true)
        #expect(sdk.first?.tags.contains(.motionPhotos) == true)
    }

    @Test
    func anAOnlyStoredMotionRereadsOnceUnderTheLoopingRule() async throws {
        #expect(LivePhotoMotionLinks.rule == "liveMotion.editedOrFirstVideo.4")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("a-motion-upgrade-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(TimelineMetadataStore(url: directory.appendingPathComponent("timeline.sqlite")))
        defer { store.close() }
        let uid = PhotoUID(volumeID: "v", nodeID: "loop")
        #expect(
            store.save([
                PhotoItem(
                    uid: uid, captureTime: .distantPast, mediaType: "image/heic",
                    isLivePhoto: true, relatedVideoID: "edited")
            ]).succeeded)
        #expect(store.markRelatedVideosChosen(by: "liveMotion.editedOrFirstVideo.3"))
        let photos = ["loop": ["paired", "edited"]]
        var requests = 0
        let first = try await LivePhotoMotionLinks().motions(
            of: photos, stored: LivePhotoMotionLinks.storedMotions(of: photos, volumeID: "v", in: store),
            evidence: types
        ) { ids, nameIDs, mainIDs in
            requests += 1
            #expect(mainIDs == ["loop"])
            var result = answer(ids, nameIDs, types: types, names: names)
            result.playback = ["loop": true]
            return result
        }
        #expect(first.motions["loop"] == .loopingVideo("edited"))
        #expect(requests == 1)
        let motion = try #require(first.motions["loop"])
        #expect(
            store.save([
                PhotoItem(
                    uid: uid, captureTime: .distantPast, mediaType: "image/heic", isLivePhoto: motion.isLivePhoto,
                    isLoopingLivePhoto: motion.isLooping, relatedVideoID: motion.linkID)
            ]).succeeded)
        #expect(store.markRelatedVideosChosen(by: LivePhotoMotionLinks.rule))
        let again = try await LivePhotoMotionLinks().motions(
            of: photos, stored: LivePhotoMotionLinks.storedMotions(of: photos, volumeID: "v", in: store), evidence: [:]
        ) { _, _, _ in
            requests += 1
            return .init(files: [:])
        }
        #expect(again.motions["loop"] == .loopingVideo("edited"))
        #expect(requests == 1, "the rule upgrade does not repeat the metadata read")
    }

    @Test
    func aStoredLoopSurvivesReopenWithoutAnotherMetadataRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stored-loop-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try #require(TimelineMetadataStore(url: url))
        let loop = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "loop"), captureTime: .distantPast, mediaType: "image/heic",
            isLivePhoto: true, isLoopingLivePhoto: true, relatedVideoID: "edited")
        #expect(store.save([loop]).succeeded)
        #expect(store.markRelatedVideosChosen(by: LivePhotoMotionLinks.rule))
        store.close()
        let reopened = try #require(TimelineMetadataStore(url: url))
        defer { reopened.close() }
        let photos = ["loop": ["paired", "edited"]]
        let stored = LivePhotoMotionLinks.storedMotions(of: photos, volumeID: "v", in: reopened)
        let result = try await LivePhotoMotionLinks().motions(of: photos, stored: stored, evidence: [:]) { _, _, _ in
            Issue.record("a current stored loop needs no metadata")
            throw URLError(.notConnectedToInternet)
        }
        #expect(result.motions["loop"] == .loopingVideo("edited"))
    }

    @Test
    func nativeHTTPRequestsKeepTheBatchBoundaryAndDoNotRepeatCachedReads() async throws {
        let server = try MotionMetadataServer()
        defer { server.close() }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("motion-http-\(UUID())")
        defer { try? FileManager.default.removeItem(at: cache) }
        let session = DriveSession(
            session: ProtonSession(uid: "fixture", accessToken: "at", refreshToken: "rt", keyPassword: "kp"),
            store: SessionKeychainStore(service: "tests.motion-metadata.never-used"),
            config: ProtonAPIConfig(baseURL: server.url), accountCacheDirectory: cache)
        let fetch: ([String], Set<String>, Set<String>) async throws -> LivePhotoMotionLinks.Answer = {
            ids, nameIDs, mainIDs in
            let batches = try await DriveSDKBridge.concurrentMetadataBatches(ids) {
                try await session.fetchPhotoLinksMetadata(shareID: "fixture", linkIDs: $0)
            }
            return try await LivePhotoMotionLinks.answer(
                links: batches.flatMap { $0 }, nameLinkIDs: nameIDs, rootKey: { 0 }, decrypt: { name, _ in name },
                playbackPhotoIDs: mainIDs,
                decryptPlayback: { link, _ in
                    let xattr = try #require(LivePhotoMotionLinks.playbackXAttr(of: link))
                    return LivePhotoMotionLinks.isLoopingPlayback(in: Data(xattr.utf8))
                })
        }
        for (count, looping) in [
            (0, true), (49, true), (50, true), (51, true), (100, true), (150, false), (151, false),
        ] {
            var links = LivePhotoMotionLinks()
            let photos = Dictionary(
                uniqueKeysWithValues: (0..<count).map { index in
                    let prefix = "\(index)"
                    return (
                        prefix + "-main", looping ? [prefix + "-original", prefix + "-render"] : [prefix + "-original"]
                    )
                })
            let evidence =
                looping
                ? Dictionary(uniqueKeysWithValues: photos.values.flatMap { $0 }.map { ($0, "video/quicktime") }) : [:]
            let before = try await server.requests().count
            let result = try await links.motions(of: photos, stored: [:], evidence: evidence, fetch: fetch)
            let requests = Array(try await server.requests().dropFirst(before))
            let expectedIDs = count * (looping ? 3 : 1)
            #expect(requests.count == (expectedIDs + 149) / 150)
            #expect(requests.allSatisfy { $0.count <= 150 })
            #expect(requests.flatMap { $0 }.count == expectedIDs)
            #expect(Set(requests.flatMap { $0 }).count == expectedIDs, "each link is sent once")
            #expect(result.motions.count == count)
            #expect(result.motions.values.filter(\.isLooping).count == (looping ? count : 0))
            links.record(result.read)
            let again = try await links.motions(of: photos, stored: [:], evidence: evidence, fetch: fetch)
            #expect(again.motions == result.motions)
            #expect(try await server.requests().count == before + requests.count)
            print(
                "[LiveMotionHTTP] photos=\(count) looping=\(looping) ids=\(expectedIDs) requests=\(requests.count) repeat=0"
            )
        }
    }

    @Test
    func aLivePhotoWithOneRelatedFileTakesItAsMotionOnlyWhenItIsAVideo() async throws {
        #expect(LivePhotoMotionLinks.motion(among: [], mimeTypes: [:], names: [:]) == .unknown)
        var reads: [[String]] = []
        var nameReads: [Set<String>] = []
        let answer = try await LivePhotoMotionLinks().motions(
            of: ["video": ["motion"], "edited": ["plist"], "none": []], stored: [:], evidence: [:]
        ) { linkIDs, nameLinkIDs, _ in
            reads.append(linkIDs)
            nameReads.append(nameLinkIDs)
            return self.answer(linkIDs, nameLinkIDs, types: types, names: names)
        }
        #expect(reads == [["plist", "motion"]], "one read, also for a single related file")
        #expect(nameReads == [[]], "a photo with one related file reads no name")
        #expect(answer.motions == ["video": .video("motion"), "edited": .noVideo, "none": .unknown])
        #expect(!LivePhotoMotion.noVideo.isLivePhoto, "only adjustment data: no Live control")
        #expect(LivePhotoMotion.video("motion").isLivePhoto)
    }

    @Test
    func anEditedLivePhotoPlaysItsEditedMotionWhereverTheListingNamesIt() {
        #expect(
            LivePhotoMotionLinks.motion(
                among: ["paired", "plist", "edited", "original"], mimeTypes: types, names: names)
                == .video("edited"))
        let upperCase = LivePhotoMotionLinks.motion(
            among: ["edited", "paired", "original"], mimeTypes: types, names: ["edited": "FULLSIZERENDER.MOV"])
        #expect(upperCase == .video("edited"), "the name compares without case")
    }

    @Test
    func aLivePhotoWithoutAnEditedMotionPlaysItsFirstVideoInsteadOfItsNewestRelatedFile() {
        #expect(
            LivePhotoMotionLinks.motion(among: ["other", "plist", "paired", "original"], mimeTypes: types, names: [:])
                == .video("paired"), "one video needs no name")
        #expect(
            LivePhotoMotionLinks.motion(
                among: ["plist", "paired", "motion", "original"], mimeTypes: types,
                names: ["paired": "IMG_2000.MOV", "motion": "IMG_2000 (1).MOV"]) == .video("paired"))
        #expect(
            LivePhotoMotionLinks.motion(among: ["plist", "other", "original"], mimeTypes: types, names: [:])
                == .noVideo, "a Live Photo without a video has no motion")
    }

    @Test
    func anImageNamedLikeTheEditedRenderIsNeverTheMotion() {
        #expect(
            LivePhotoMotionLinks.motion(
                among: ["render", "paired", "motion"], mimeTypes: types,
                names: ["render": "FullSizeRender.heic", "paired": "IMG_2000.MOV", "motion": "IMG_2000 (1).MOV"])
                == .video("paired"))
    }

    @Test
    func theEditedMotionWinsAmongThreeVideosInTheMiddleOrAtTheEnd() {
        let three = ["paired": "IMG_2000.MOV", "motion": "IMG_2000 (1).MOV", "edited": "FullSizeRender.mov"]
        #expect(
            LivePhotoMotionLinks.motion(among: ["paired", "edited", "motion"], mimeTypes: types, names: three)
                == .video("edited"))
        #expect(
            LivePhotoMotionLinks.motion(among: ["paired", "motion", "plist", "edited"], mimeTypes: types, names: three)
                == .video("edited"))
    }

    /// Photos lists one rendered motion per Live Photo. Two videos named like the render are not documented; the first
    /// in listing order, the newest upload, plays.
    @Test
    func twoVideosNamedLikeTheRenderPlayTheFirstInListingOrderAsUndocumentedBehavior() {
        #expect(
            LivePhotoMotionLinks.motion(
                among: ["paired", "motion", "edited"], mimeTypes: types,
                names: ["paired": "IMG_2000.MOV", "motion": "FullSizeRender.MOV", "edited": "FullSizeRender.mov"])
                == .video("motion"))
    }

    @Test
    func aNameWithAPathSeparatorIsNeverTheRender() {
        // The backup never uploads such a name: Proton name correction removes path separators.
        #expect(
            LivePhotoMotionLinks.motion(
                among: ["paired", "edited"], mimeTypes: types,
                names: ["paired": "IMG_2000.MOV", "edited": "Edits/FullSizeRender.mov"]) == .video("paired"))
    }

    @Test
    func aReadWithoutNamesKeepsItsTypesAndLeavesOnlyThePhotosThatNeedANameUndecided() async throws {
        var links = LivePhotoMotionLinks()
        let photos = ["edited": ["paired", "plist", "edited"], "single": ["motion"]]
        let first = try await links.motions(of: photos, stored: [:], evidence: [:]) { linkIDs, nameLinkIDs, _ in
            var answer = self.answer(linkIDs, [], types: types, names: names)
            answer.namesRead = false
            return answer
        }
        links.record(first.read)
        #expect(first.read.names.isEmpty)
        #expect(
            first.read.types == [
                "paired": "video/quicktime", "plist": "application/xml", "edited": "video/quicktime",
                "motion": "video/quicktime",
            ])
        #expect(first.motions == ["edited": .unknown, "single": .video("motion")])

        var reads: [[String]] = []
        let second = try await links.motions(of: photos, stored: [:], evidence: [:]) { linkIDs, nameLinkIDs, mainIDs in
            reads.append(linkIDs)
            var result = self.answer(linkIDs, nameLinkIDs, types: types, names: names)
            result.playback = Dictionary(uniqueKeysWithValues: mainIDs.map { ($0, false) })
            return result
        }
        #expect(reads == [["paired", "edited"]], "only the names; the types stay read for the session")
        #expect(second.motions == ["edited": .video("edited"), "single": .video("motion")])
    }

    @Test
    func aNameThatDoesNotDecryptPlaysTheFirstVideoAndAnUnreadNameLeavesTheMotionUnknown() {
        // An empty name is a read whose name did not decrypt: the read is final, so the first video plays.
        #expect(
            LivePhotoMotionLinks.motion(
                among: ["paired", "edited"], mimeTypes: types, names: ["paired": "", "edited": ""])
                == .video("paired"))
        // A name that was not read yet can be the edited motion.
        #expect(
            LivePhotoMotionLinks.motion(
                among: ["paired", "edited"], mimeTypes: types, names: ["paired": "IMG_2000.MOV"]) == .unknown)
    }

    @Test
    func anUnknownTypeLeavesTheMotionUnknownBecauseItCanBeTheEditedMotion() {
        #expect(
            LivePhotoMotionLinks.motion(among: ["plist", "unknown", "paired"], mimeTypes: types, names: names)
                == .unknown)
        #expect(
            LivePhotoMotionLinks.motion(among: ["paired", "unknown"], mimeTypes: types, names: names) == .unknown)
    }

    @Test
    func oneReadAsksForTheNamesOfThePossibleVideosOfPhotosWithTwoOrMore() async throws {
        let evidence = [
            "plist": "application/xml", "paired": "video/quicktime", "edited": "video/quicktime",
            "plist-3": "application/xml", "paired-3": "video/quicktime",
        ]
        var links = LivePhotoMotionLinks()
        var reads: [[String]] = []
        var nameReads: [Set<String>] = []
        let photos = [
            "edited": ["paired", "plist", "edited"], "one-video": ["plist-3", "paired-3"], "single": ["motion"],
            "unread": ["x", "y"],
        ]
        let allTypes = types.merging(["x": "video/quicktime", "y": "image/heic"]) { first, _ in first }
        let first = try await links.motions(of: photos, stored: [:], evidence: evidence) {
            linkIDs, nameLinkIDs, mainIDs in
            reads.append(linkIDs)
            nameReads.append(nameLinkIDs)
            let allNames = names.merging(["x": "x.mov"]) { name, _ in name }
            var result = self.answer(linkIDs, nameLinkIDs, types: allTypes, names: allNames)
            result.playback = Dictionary(uniqueKeysWithValues: mainIDs.map { ($0, false) })
            return result
        }
        links.record(first.read)
        #expect(
            reads == [["paired", "edited", "motion", "x", "y", "unread"]],
            "one read includes candidate primaries and known video types")
        #expect(
            nameReads == [["paired", "edited", "x", "y"]],
            "names only of the files that are or can be videos, in photos with two or more of them")
        #expect(first.read.names == ["paired": "IMG_2000.MOV", "edited": "FullSizeRender.mov", "x": "x.mov", "y": ""])
        #expect(
            first.motions == [
                "edited": .video("edited"), "one-video": .video("paired-3"), "single": .video("motion"),
                "unread": .video("x"),
            ])

        let second = try await links.motions(of: photos, stored: [:], evidence: evidence) { linkIDs, nameLinkIDs, _ in
            reads.append(linkIDs)
            return .init(files: [:])
        }
        #expect(reads.count == 1, "read names stay valid for the session")
        #expect(second.motions == first.motions)
    }

    @Test
    func aMotionThatTheEarlierRuleStoredIsNotTrustedAndOneMarkedSaveTrustsTheNewRule() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-motion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(TimelineMetadataStore(url: directory.appendingPathComponent("library.sqlite")))
        defer { store.close() }
        let photos = ["live": ["paired", "plist", "edited"]]

        // The earlier rule played the first video, the original motion of an edited Live Photo.
        #expect(store.save(items(["live": "paired"])).succeeded)
        #expect(store.markRelatedVideosChosen(by: "liveMotion.firstRelatedVideo.2"))
        #expect(LivePhotoMotionLinks.rule != "liveMotion.firstRelatedVideo.2")
        #expect(!store.relatedVideosChosen(by: LivePhotoMotionLinks.rule), "the next load lists once")
        #expect(LivePhotoMotionLinks.storedMotions(of: photos, volumeID: "v", in: store).isEmpty)

        // The load that saves its timeline marks the new rule; later loads trust it and do not list for it.
        #expect(store.save(items(["live": "edited"])).succeeded)
        #expect(store.markRelatedVideosChosen(by: LivePhotoMotionLinks.rule))
        #expect(store.relatedVideosChosen(by: LivePhotoMotionLinks.rule))
        #expect(LivePhotoMotionLinks.storedMotions(of: photos, volumeID: "v", in: store) == ["live": .video("edited")])
    }

    @Test
    func readsUnknownRelatedFilesAndCandidatePrimariesOnce() async throws {
        var links = LivePhotoMotionLinks()
        let photos = ["a": ["motion"], "b": ["plist", "paired"], "c": ["paired", "edited", "plist"]]
        let evidence = ["plist": "application/xml"]
        var reads: [[String]] = []

        let first = try await links.motions(of: photos, stored: [:], evidence: evidence) { linkIDs, _, _ in
            reads.append(linkIDs)
            return self.answer(
                linkIDs, [], types: ["motion": "video/quicktime", "paired": "video/quicktime", "plist": "text/plain"],
                names: [:])
        }
        links.record(first.read)
        #expect(reads == [["motion", "paired", "edited", "c"]])
        #expect(first.read.types == ["motion": "video/quicktime", "paired": "video/quicktime", "edited": ""])
        #expect(first.motions == ["a": .video("motion"), "b": .video("paired"), "c": .video("paired")])

        let second = try await links.motions(of: photos, stored: [:], evidence: evidence) { linkIDs, _, _ in
            reads.append(linkIDs)
            return .init(files: [:])
        }
        #expect(reads.count == 1, "a read type stays valid for the session")
        #expect(second.motions == first.motions)
    }

    @Test
    func aFailedReadLeavesTheMotionUnknownAndReadsAgainNextTime() async throws {
        struct Offline: Error {}
        var links = LivePhotoMotionLinks()
        let photos = ["live": ["plist", "paired"]]

        let failed = try await links.motions(of: photos, stored: [:], evidence: [:]) { _, _, _ in throw Offline() }
        links.record(failed.read)
        #expect(failed.read == .init())
        #expect(failed.motions == ["live": .unknown])

        var reads = 0
        let retried = try await links.motions(of: photos, stored: [:], evidence: [:]) { linkIDs, nameLinkIDs, _ in
            reads += 1
            return self.answer(linkIDs, nameLinkIDs, types: types, names: names)
        }
        #expect(reads == 1, "the next refresh reads the failed files again")
        #expect(retried.motions == ["live": .video("paired")])

        await #expect(throws: CancellationError.self) {
            _ = try await LivePhotoMotionLinks().motions(of: photos, stored: [:], evidence: [:]) { _, _, _ in
                throw CancellationError()
            }
        }
    }

    @Test
    func aLaterLaunchReadsNothingForUnchangedLivePhotosAndReadsAChangedOneAgain() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-motion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        var photos = [
            "one": ["plist-1", "paired-1", "original-1"], "three": ["paired-3"], "two": ["other-2", "paired-2"],
        ]

        // An earlier build stored the first related file as the motion and never marked its rule.
        var store = try #require(TimelineMetadataStore(url: url))
        #expect(store.save(items(photos.mapValues { $0[0] })).succeeded)
        let first = try await launch(photos, store: store)
        #expect(
            first.reads == ["plist-1", "paired-1", "original-1", "paired-3", "other-2", "paired-2", "one", "two"],
            "rows before the mark, also of a Live Photo with one related file")
        #expect(first.motions == ["one": .video("paired-1"), "three": .video("paired-3"), "two": .video("paired-2")])
        #expect(store.save(items(first.motions.compactMapValues(\.linkID))).succeeded)
        #expect(store.markRelatedVideosChosen(by: LivePhotoMotionLinks.rule))
        store.close()

        store = try #require(TimelineMetadataStore(url: url))
        let second = try await launch(photos, store: store)
        #expect(second.reads.isEmpty, "unchanged Live Photos read nothing on a later launch")
        #expect(second.motions == first.motions)

        // A changed related list without the stored video reads again, for that photo only.
        photos["two"] = ["other-2", "edited-2"]
        let third = try await launch(photos, store: store)
        #expect(third.reads == ["other-2", "edited-2", "two"])
        #expect(third.motions == ["one": .video("paired-1"), "three": .video("paired-3"), "two": .video("edited-2")])

        // A later save that does not mark the rule, for example by an earlier build, voids the mark.
        #expect(store.save(items(["one": "plist-1", "three": "paired-3", "two": "other-2"])).succeeded)
        #expect(try await launch(photos, store: store).reads.count == 8)
        store.close()
    }

    @Test
    func aFailedReadStillCommitsTheTimelineAndTheNextRefreshReadsOnlyThosePhotos() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-motion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(TimelineMetadataStore(url: directory.appendingPathComponent("library.sqlite")))
        defer { store.close() }
        let photos = ["known": ["paired-1"], "failed": ["plist-2", "paired-2"]]

        // The read of "failed" fails: its motion stays unknown, and the timeline and its token are still saved.
        let motions = try await LivePhotoMotionLinks().motions(
            of: photos, stored: ["known": .video("paired-1")], evidence: [:]
        ) { _, _, _ in throw URLError(.timedOut) }
        #expect(motions.motions == ["known": .video("paired-1"), "failed": .unknown])
        let saved = photos.keys.sorted().enumerated().map { index, linkID in
            PhotoItem(
                uid: PhotoUID(volumeID: "v", nodeID: linkID), captureTime: Date(timeIntervalSince1970: Double(index)),
                mediaType: "image/heic", isLivePhoto: motions.motions[linkID]!.isLivePhoto,
                relatedVideoID: motions.motions[linkID]?.linkID)
        }
        #expect(store.save(saved, validationToken: "token").succeeded)
        #expect(store.markRelatedVideosChosen(by: LivePhotoMotionLinks.rule))
        #expect(store.validationToken() == "token")

        #expect(try await launch(photos, store: store).reads == ["plist-2", "paired-2", "failed"])
    }

    @Test(arguments: [false, true])
    @MainActor
    func failedEvidenceRefreshKeepsPhotosUsableWithoutExtraMIMERequests(partial: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try #require(TimelineMetadataStore(url: url))
        defer { store.close() }
        let saved = [
            PhotoItem(
                uid: .init(volumeID: "v", nodeID: "known"), captureTime: .distantPast,
                mediaType: "image/heic", isLivePhoto: true, relatedVideoID: "paired"),
            PhotoItem(
                uid: .init(volumeID: "v", nodeID: "video"), captureTime: .distantPast,
                mediaType: "video/mp4"),
            PhotoItem(
                uid: .init(volumeID: "other", nodeID: "video"), captureTime: .distantPast,
                mediaType: "image/jpeg"),
        ]
        #expect(store.save(saved, validationToken: "token").succeeded)
        #expect(store.markRelatedVideosChosen(by: LivePhotoMotionLinks.rule))
        #expect(store.recordMediaTypeEvidence([saved[0].uid: "image/heic", saved[1].uid: "video/mp4"]).succeeded)
        var handle: OpaquePointer?
        try #require(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        let fault =
            partial
            ? """
            ALTER TABLE media_type_evidence RENAME TO fixture_evidence;
            CREATE VIEW media_type_evidence AS SELECT vol, node,
                CASE WHEN node='video' THEN abs(-9223372036854775808) ELSE mime END AS mime
            FROM fixture_evidence;
            """ : "ALTER TABLE media_type_evidence RENAME TO fixture_evidence;"
        #expect(sqlite3_exec(handle, fault, nil, nil, nil) == SQLITE_OK)
        // Refresh this connection's schema before testing preparation, not a deferred step error.
        #expect(try store.load().map(\.uid) == saved.sorted(by: TimelineOrder.areInIncreasingOrder).map(\.uid))
        #expect(store.mediaTypeEvidence(volumeID: "v") == nil)
        let evidence = store.mediaTypeEvidenceForDisplay(volumeID: "v")
        #expect(!evidence.canRefine)
        let photos = ["known": ["plist", "paired"], "new": ["unread", "new-motion"]]
        let stored = LivePhotoMotionLinks.storedMotions(of: photos, volumeID: "v", in: store)
        var requests = 0
        let answer = try await LivePhotoMotionLinks().motions(
            of: photos, stored: stored, evidence: evidence.types, allowFetch: evidence.canRefine
        ) { _, _, _ in
            requests += 1
            throw URLError(.timedOut)
        }
        #expect(requests == 0)
        #expect(answer.read == .init(), "the skipped refinement reads nothing and keeps nothing")
        #expect(answer.motions["known"] == .video("paired"))
        let entries = [
            PhotosListEntry(
                linkID: "known", captureTime: 500, tags: [ProtonDriveSDK.PhotoTag.livePhotos.rawValue],
                relatedPhotos: [.init(linkID: "plist"), .init(linkID: "paired")]),
            PhotosListEntry(linkID: "video", captureTime: 501, tags: [], relatedPhotos: []),
            PhotosListEntry(
                linkID: "new", captureTime: 502, tags: [ProtonDriveSDK.PhotoTag.livePhotos.rawValue],
                relatedPhotos: [.init(linkID: "unread"), .init(linkID: "new-motion")]),
        ]
        // Both authoritative/filtered listings and the SDK timeline finish with usable photos.
        let filtered = DriveSDKBridge.group(
            entries, volumeID: "v", mediaTypeOverrides: evidence.types, motions: answer.motions
        ).flatMap(\.items)
        let timeline = DriveSDKBridge.group(
            entries.map {
                PhotoTimelineItem(nodeUid: SDKNodeUid(volumeID: "v", nodeID: $0.linkID), captureTime: $0.captureTime)
            },
            mediaTypeOverrides: evidence.types, livePhotoMotions: answer.motions
        ).flatMap(\.items)
        for displayed in [filtered, timeline] {
            #expect(displayed.map(\.uid.nodeID) == ["known", "video", "new"])
            #expect(displayed[0].isLivePhoto)
            #expect(displayed[0].relatedVideoID == "paired")
            #expect(displayed[1].isVideo, "the stored video must remain playable as a video")
            #expect(displayed[2].isLivePhoto, "unknown refinement must not hide the new photo or its Live control")
        }
        #expect(try store.load().map(\.uid) == saved.sorted(by: TimelineOrder.areInIncreasingOrder).map(\.uid))
        #expect(store.validationToken() == "token")
    }

    /// One refresh of a new session: the stored motions, then one read of the files that still need a type.
    private func launch(
        _ photos: [String: [String]], store: TimelineMetadataStore
    ) async throws -> (motions: [String: LivePhotoMotion], reads: [String]) {
        var reads: [String] = []
        let stored = LivePhotoMotionLinks.storedMotions(of: photos, volumeID: "v", in: store)
        let answer = try await LivePhotoMotionLinks().motions(of: photos, stored: stored, evidence: [:]) {
            linkIDs, nameLinkIDs, _ in
            reads += linkIDs
            let videos = linkIDs.filter { $0.hasPrefix("paired") || $0.hasPrefix("edited") }
            return self.answer(
                linkIDs, nameLinkIDs,
                types: Dictionary(
                    uniqueKeysWithValues: linkIDs.map { ($0, videos.contains($0) ? "video/quicktime" : "image/heic") }),
                names: Dictionary(uniqueKeysWithValues: linkIDs.map { ($0, "\($0).mov") }))
        }
        return (answer.motions, reads)
    }

    private func items(_ motions: [String: String]) -> [PhotoItem] {
        motions.keys.sorted().enumerated().map { index, linkID in
            PhotoItem(
                uid: PhotoUID(volumeID: "v", nodeID: linkID), captureTime: Date(timeIntervalSince1970: Double(index)),
                mediaType: "image/heic", isLivePhoto: true, relatedVideoID: motions[linkID])
        }
    }

    @Test
    func metadataBatchesRunAFewAtATimeAndKeepTheirOrder() async throws {
        let linkIDs = (0..<1_000).map { "link-\($0)" }
        let gauge = InFlightGauge()
        let answers = try await DriveSDKBridge.concurrentMetadataBatches(linkIDs) { batch in
            await gauge.enter()
            try await Task.sleep(for: .milliseconds(20))
            await gauge.leave()
            return batch
        }
        #expect(answers.count == 7)
        #expect(answers.allSatisfy { $0.count <= 150 })
        #expect(answers.flatMap { $0 } == linkIDs)
        let peak = await gauge.peak
        #expect(peak <= ProtonUploadDedupeService.remoteMetadataRequestConcurrency)
        #expect(peak > 1, "the batches overlap")
    }

    @Test
    func theTimelineShowsTheVideoAsTheMotionAndNoLiveControlWithoutAVideo() async throws {
        let live = PhotosCore.PhotoTag.livePhotos.rawValue
        let entries = try JSONDecoder().decode(
            [PhotosListEntry].self,
            from: Data(
                #"""
                [{"LinkID":"live","CaptureTime":1,"Tags":[3],"RelatedPhotos":[{"LinkID":"plist"},{"LinkID":"paired"},{"LinkID":"original"}]},
                {"LinkID":"novideo","CaptureTime":2,"Tags":[3],"RelatedPhotos":[{"LinkID":"plist"},{"LinkID":"original"}]},
                {"LinkID":"single","CaptureTime":3,"Tags":[3],"RelatedPhotos":[{"LinkID":"motion"}]},
                {"LinkID":"unread","CaptureTime":4,"Tags":[3],"RelatedPhotos":[{"LinkID":"x"},{"LinkID":"y"}]},
                {"LinkID":"adjusted","CaptureTime":5,"Tags":[3],"RelatedPhotos":[{"LinkID":"plist"}]}]
                """#
                .utf8))
        #expect(entries.allSatisfy { $0.tags == [live] })

        let motions = try await LivePhotoMotionLinks().motions(
            of: [
                "live": ["plist", "paired", "original"], "novideo": ["plist", "original"], "single": ["motion"],
                "unread": ["x", "y"], "adjusted": ["plist"],
            ],
            stored: [:], evidence: types
        ) { _, _, _ in throw URLError(.notConnectedToInternet) }
        let items = DriveSDKBridge.group(entries, volumeID: "v", motions: motions.motions).flatMap(\.items)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.uid.nodeID, $0) })

        #expect(byID["live"]?.isLivePhoto == true)
        #expect(byID["live"]?.relatedVideoID == "paired")
        #expect(byID["novideo"]?.isLivePhoto == false)
        #expect(byID["novideo"]?.relatedVideoID == nil)
        #expect(byID["single"]?.relatedVideoID == "motion")
        #expect(byID["unread"]?.isLivePhoto == true, "an unread type keeps the Live tag without a motion")
        #expect(byID["unread"]?.relatedVideoID == nil)
        #expect(byID["adjusted"]?.isLivePhoto == false, "only adjustment data: no Live control")
        #expect(byID["adjusted"]?.relatedVideoID == nil)

        // The SDK timeline shows every Live Photo like the photos listing, an unknown motion included.
        let sdkItems = DriveSDKBridge.group(
            entries.map {
                PhotoTimelineItem(nodeUid: SDKNodeUid(volumeID: "v", nodeID: $0.linkID), captureTime: $0.captureTime)
            },
            livePhotoMotions: motions.motions
        ).flatMap(\.items)
        #expect(sdkItems.map(\.uid) == items.map(\.uid))
        #expect(sdkItems.map(\.isLivePhoto) == items.map(\.isLivePhoto))
        #expect(sdkItems.map(\.relatedVideoID) == items.map(\.relatedVideoID))
    }
}

private actor InFlightGauge {
    private var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() { current -= 1 }
}

/// Runs only this test's loopback fixture. Reuses the maintained server's backlog and bind policy.
private final class MotionMetadataServer {
    let url: URL
    private let process: Process
    private let input: Pipe
    private let errors: Pipe
    private var closed = false

    init() throws {
        let process = Process()
        let input = Pipe()
        let errors = Pipe()
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", "-u", "-c", Self.script, root.appendingPathComponent("scripts/upgrade-test").path,
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: line), parsed.host == "127.0.0.1", parsed.port != nil else {
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw FixtureFailure.start(detail)
        }
        self.process = process
        self.input = input
        self.errors = errors
        url = parsed
    }

    func requests() async throws -> [[String]] {
        let (data, response) = try await URLSession.shared.data(from: url.appendingPathComponent("requests"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FixtureFailure.response }
        return try JSONDecoder().decode([[String]].self, from: data)
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    deinit { close() }
    private enum FixtureFailure: Error {
        case start(String)
        case response
    }

    private static let script = #"""
        import sys, json, threading
        from http.server import BaseHTTPRequestHandler
        sys.path.insert(0, sys.argv[1])
        from server import BurstHTTPServer
        rows, lock = [], threading.Lock()
        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *_): pass
            def send(self, value):
                data = json.dumps(value).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            def do_POST(self):
                if self.path != '/drive/shares/fixture/links/fetch_metadata':
                    self.send_error(404); return
                ids = json.loads(self.rfile.read(int(self.headers['Content-Length'])))['LinkIDs']
                with lock: rows.append(ids)
                links = []
                for value in ids:
                    main = value.endswith('-main')
                    name = 'IMG.HEIC' if main else ('FullSizeRender.mov' if value.endswith('-render') else 'IMG.MOV')
                    link = {'LinkID': value, 'State': 1, 'MIMEType': 'image/heic' if main else 'video/quicktime', 'Name': name}
                    if main: link['XAttr'] = json.dumps({'iOS.photos': {'PlaybackStyle': 'videoLooping'}})
                    links.append(link)
                self.send({'Code': 1000, 'Links': links})
            def do_GET(self):
                if self.path != '/requests': self.send_error(404); return
                with lock: self.send(rows)
        server = BurstHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        print('http://127.0.0.1:' + str(server.server_port), flush=True)
        sys.stdin.buffer.read()
        server.shutdown()
        server.server_close()
        """#
}
