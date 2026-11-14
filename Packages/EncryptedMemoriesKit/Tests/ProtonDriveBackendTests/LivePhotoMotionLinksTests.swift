import Foundation
import PhotosCore
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
    func aLivePhotoWithOneRelatedFileTakesItAsMotionOnlyWhenItIsAVideo() async throws {
        #expect(LivePhotoMotionLinks.motion(among: [], mimeTypes: [:], names: [:]) == .unknown)
        var reads: [[String]] = []
        var nameReads: [Set<String>] = []
        let answer = try await LivePhotoMotionLinks().motions(
            of: ["video": ["motion"], "edited": ["plist"], "none": []], stored: [:], evidence: [:]
        ) { linkIDs, nameLinkIDs in
            reads.append(linkIDs)
            nameReads.append(nameLinkIDs)
            return self.answer(linkIDs, nameLinkIDs, types: types, names: names)
        }
        #expect(reads == [["plist", "motion"]], "one read, also for a single related file")
        #expect(nameReads == [[]], "a photo with one related file reads no name")
        #expect(answer.motions == ["video": .video("motion"), "edited": .noVideo, "none": .unknown])
        #expect(!LivePhotoMotion.noVideo.showsLiveControl, "only adjustment data: no Live control")
        #expect(LivePhotoMotion.video("motion").showsLiveControl)
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
        let first = try await links.motions(of: photos, stored: [:], evidence: [:]) { linkIDs, nameLinkIDs in
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
        let second = try await links.motions(of: photos, stored: [:], evidence: [:]) { linkIDs, nameLinkIDs in
            reads.append(linkIDs)
            return self.answer(linkIDs, nameLinkIDs, types: types, names: names)
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
        let first = try await links.motions(of: photos, stored: [:], evidence: evidence) { linkIDs, nameLinkIDs in
            reads.append(linkIDs)
            nameReads.append(nameLinkIDs)
            let allNames = names.merging(["x": "x.mov"]) { name, _ in name }
            return self.answer(linkIDs, nameLinkIDs, types: allTypes, names: allNames)
        }
        links.record(first.read)
        #expect(reads == [["paired", "edited", "motion", "x", "y"]], "one read; known types of videos join it")
        #expect(
            nameReads == [["paired", "edited", "x", "y"]],
            "names only of the files that are or can be videos, in photos with two or more of them")
        #expect(first.read.names == ["paired": "IMG_2000.MOV", "edited": "FullSizeRender.mov", "x": "x.mov", "y": ""])
        #expect(
            first.motions == [
                "edited": .video("edited"), "one-video": .video("paired-3"), "single": .video("motion"),
                "unread": .video("x"),
            ])

        let second = try await links.motions(of: photos, stored: [:], evidence: evidence) { linkIDs, nameLinkIDs in
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
        #expect(LivePhotoMotionLinks.storedMotions(of: photos, volumeID: "v", in: store) == ["live": "edited"])
    }

    @Test
    func readsOnlyTheUnknownRelatedFilesOfLivePhotosOnce() async throws {
        var links = LivePhotoMotionLinks()
        let photos = ["a": ["motion"], "b": ["plist", "paired"], "c": ["paired", "edited", "plist"]]
        let evidence = ["plist": "application/xml"]
        var reads: [[String]] = []

        let first = try await links.motions(of: photos, stored: [:], evidence: evidence) { linkIDs, _ in
            reads.append(linkIDs)
            return self.answer(
                linkIDs, [], types: ["motion": "video/quicktime", "paired": "video/quicktime", "plist": "text/plain"],
                names: [:])
        }
        links.record(first.read)
        #expect(reads == [["motion", "paired", "edited"]])
        #expect(first.read.types == ["motion": "video/quicktime", "paired": "video/quicktime", "edited": ""])
        #expect(first.motions == ["a": .video("motion"), "b": .video("paired"), "c": .video("paired")])

        let second = try await links.motions(of: photos, stored: [:], evidence: evidence) { linkIDs, _ in
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

        let failed = try await links.motions(of: photos, stored: [:], evidence: [:]) { _, _ in throw Offline() }
        links.record(failed.read)
        #expect(failed.read == .init())
        #expect(failed.motions == ["live": .unknown])

        var reads = 0
        let retried = try await links.motions(of: photos, stored: [:], evidence: [:]) { linkIDs, nameLinkIDs in
            reads += 1
            return self.answer(linkIDs, nameLinkIDs, types: types, names: names)
        }
        #expect(reads == 1, "the next refresh reads the failed files again")
        #expect(retried.motions == ["live": .video("paired")])

        await #expect(throws: CancellationError.self) {
            _ = try await LivePhotoMotionLinks().motions(of: photos, stored: [:], evidence: [:]) { _, _ in
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
            first.reads == ["plist-1", "paired-1", "original-1", "paired-3", "other-2", "paired-2"],
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
        #expect(third.reads == ["other-2", "edited-2"])
        #expect(third.motions == ["one": .video("paired-1"), "three": .video("paired-3"), "two": .video("edited-2")])

        // A later save that does not mark the rule, for example by an earlier build, voids the mark.
        #expect(store.save(items(["one": "plist-1", "three": "paired-3", "two": "other-2"])).succeeded)
        #expect(try await launch(photos, store: store).reads.count == 6)
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
            of: photos, stored: ["known": "paired-1"], evidence: [:]
        ) { _, _ in throw URLError(.timedOut) }
        #expect(motions.motions == ["known": .video("paired-1"), "failed": .unknown])
        let saved = photos.keys.sorted().enumerated().map { index, linkID in
            PhotoItem(
                uid: PhotoUID(volumeID: "v", nodeID: linkID), captureTime: Date(timeIntervalSince1970: Double(index)),
                mediaType: "image/heic", isLivePhoto: motions.motions[linkID]!.showsLiveControl,
                relatedVideoID: motions.motions[linkID]?.linkID)
        }
        #expect(store.save(saved, validationToken: "token").succeeded)
        #expect(store.markRelatedVideosChosen(by: LivePhotoMotionLinks.rule))
        #expect(store.validationToken() == "token")

        #expect(try await launch(photos, store: store).reads == ["plist-2", "paired-2"])
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
        ) { _, _ in
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
            linkIDs, nameLinkIDs in
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
        ) { _, _ in throw URLError(.notConnectedToInternet) }
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
