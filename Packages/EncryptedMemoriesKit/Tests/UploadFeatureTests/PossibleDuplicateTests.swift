import PhotosCore
import UploadCore
import XCTest

final class PossibleDuplicateTests: XCTestCase {
    private let second = Date(timeIntervalSince1970: 1_700_000_000)

    private func uid(_ node: String) -> PhotoUID { PhotoUID(volumeID: "v", nodeID: node) }

    private func photo(
        _ node: String, at time: Date? = nil, type: String = "image/jpeg", exact: Double? = nil,
        relatedVideo: String? = nil, burst: [String] = [], tags: Set<PhotoTag> = []
    ) -> PhotoItem {
        PhotoItem(
            uid: uid(node), captureTime: time ?? second, mediaType: type, isLivePhoto: relatedVideo != nil,
            relatedVideoID: relatedVideo, tags: tags, burstMemberIDs: burst,
            timelineOrder: exact.map { TimelineOrderMetadata(exactCaptureTime: Date(timeIntervalSince1970: $0)) })
    }

    /// The shared details with a place, which most of these tests compare.
    private func details(
        camera: String? = "Camera", width: Int? = 4000, height: Int? = 3000, latitude: Double? = 47.0,
        longitude: Double? = 15.0, type: String = "image/jpeg", duration: Double? = nil
    ) -> ExactDuplicateFingerprint {
        .possiblePhoto(
            type: type, camera: camera, width: width, height: height, latitude: latitude, longitude: longitude,
            duration: duration)
    }

    // MARK: - Candidates from the library, before any request

    func testCandidatesShareTheCaptureSecondAndTheKind() {
        let items = [
            photo("a"), photo("b", type: "image/heic"), photo("c", at: second.addingTimeInterval(1)),
            photo("v1", type: "video/quicktime"), photo("v2", type: "video/mp4"),
            photo("alone-video", at: second.addingTimeInterval(5), type: "video/mp4"),
        ]
        XCTAssertEqual(
            PossibleDuplicateCandidates.groups(of: items, sameBytes: [], includesVideos: true),
            [[uid("a"), uid("b")], [uid("v1"), uid("v2")]])
        XCTAssertEqual(
            PossibleDuplicateCandidates.groups(of: items, sameBytes: [], includesVideos: false),
            [[uid("a"), uid("b")]], "without videos only the photos stay candidates")
    }

    func testCandidatesLeaveOutBurstsPairedVideosAndKeepKnownMomentsApart() {
        let items = [
            photo("live", relatedVideo: "paired"), photo("paired", type: "video/quicktime"),
            photo("other-video", type: "video/quicktime"),
            photo("burst1", burst: ["burst1", "burst2"]), photo("tagged", tags: [.bursts]),
            photo("early", exact: 1_700_000_000.2), photo("late", exact: 1_700_000_000.7),
            photo("unknown-moment"),
        ]
        XCTAssertEqual(
            PossibleDuplicateCandidates.groups(of: items, sameBytes: [], includesVideos: true), [],
            "two known moments keep their photos apart and leave out the photos without a moment")
        let oneMoment = [photo("a", exact: 1_700_000_000.2), photo("b"), photo("c", exact: 1_700_000_000.2)]
        XCTAssertEqual(
            PossibleDuplicateCandidates.groups(of: oneMoment, sameBytes: [], includesVideos: true),
            [[uid("a"), uid("b"), uid("c")]], "one known moment takes the photos without a moment")
        let twoMoments = [
            photo("x", exact: 1_700_000_000.1), photo("y", exact: 1_700_000_000.6), photo("z"),
            photo("w", exact: 1_700_000_000.6),
        ]
        for order in [twoMoments, twoMoments.reversed()] {
            XCTAssertEqual(
                Set(PossibleDuplicateCandidates.groups(of: order, sameBytes: [], includesVideos: true).map(Set.init)),
                [[uid("y"), uid("w")]], "the order of the photos changes nothing")
        }
    }

    func testCopiesWithTheSameBytesCountOnceAndAGroupNeedsTwoFiles() {
        let items = [
            photo("a1"), photo("a2"), photo("b"), photo("x1", at: second.addingTimeInterval(9)),
            photo("x2", at: second.addingTimeInterval(9)),
        ]
        XCTAssertEqual(
            PossibleDuplicateCandidates.groups(
                of: items, sameBytes: [[uid("a1"), uid("a2")], [uid("x1"), uid("x2")]], includesVideos: true),
            [[uid("a1"), uid("b")]],
            "the identical list already holds a2, and x1 and x2 are one file twice")
    }

    // MARK: - The decision after the reads

    func testTheStrictRuleNeedsTheSameCameraAndDimensionsInEitherOrientation() {
        let policy = PossibleDuplicatePolicy(rule: .strict, includesVideos: true)
        let fingerprints = [
            uid("a"): details(type: "image/heic"), uid("b"): details(width: 3000, height: 4000),
            uid("small"): details(width: 2000, height: 1500), uid("other-camera"): details(camera: "Other"),
        ]
        XCTAssertEqual(
            policy.groups(of: [[uid("a"), uid("b"), uid("small"), uid("other-camera")]], fingerprints: fingerprints),
            [PossibleDuplicateGroup(members: [uid("a"), uid("b")], differences: [.dimensions, .fileType])])
    }

    func testTheShapeRuleTakesASmallerCopyWithinOnePercentAndAMissingPlace() {
        let policy = PossibleDuplicatePolicy(rule: .sameShape, includesVideos: true)
        let fingerprints = [
            uid("a"): details(), uid("small"): details(width: 2000, height: 1500, latitude: nil, longitude: nil),
            uid("nearly"): details(width: 4000, height: 3029), uid("cropped"): details(width: 4000, height: 3100),
            uid("elsewhere"): details(latitude: 48.0),
        ]
        XCTAssertEqual(
            policy.groups(
                of: [[uid("a"), uid("small"), uid("nearly"), uid("cropped"), uid("elsewhere")]],
                fingerprints: fingerprints),
            [
                PossibleDuplicateGroup(
                    members: [uid("a"), uid("small"), uid("nearly")], differences: [.place, .dimensions])
            ],
            "a ratio 0.96 % off still counts; 3.2 % off and another place do not")
    }

    func testTheSecondRuleNeedsOnlyAKnownCamera() {
        let policy = PossibleDuplicatePolicy(rule: .sameSecond, includesVideos: true)
        let fingerprints = [
            uid("a"): details(), uid("b"): details(camera: "Other", width: 100, height: 900, latitude: 1),
            uid("no-camera"): details(camera: nil),
        ]
        XCTAssertEqual(
            policy.groups(of: [[uid("a"), uid("b"), uid("no-camera")]], fingerprints: fingerprints),
            [PossibleDuplicateGroup(members: [uid("a"), uid("b")], differences: [.place, .camera, .dimensions])])
    }

    func testEveryRuleLeavesOutUnknownDetailsAndCopiesWithoutPhotoDetails() {
        for rule in PossibleDuplicateRule.allCases {
            let policy = PossibleDuplicatePolicy(rule: rule, includesVideos: true)
            let fingerprints = [
                uid("a"): details(),
                uid("no-time"): ExactDuplicateFingerprint(
                    device: "Camera", pixelWidth: 4000, pixelHeight: 3000, mimeType: "image/jpeg"),
                uid("no-type"): details(type: ""),
                uid("plain"): .matchingOnly(uid("plain")), uid("b"): details(type: "image/png"),
            ]
            XCTAssertEqual(
                policy.groups(
                    of: [[uid("unread"), uid("a"), uid("no-time"), uid("no-type"), uid("plain"), uid("b")]],
                    fingerprints: fingerprints),
                [PossibleDuplicateGroup(members: [uid("a"), uid("b")], differences: [.fileType])], "\(rule)")
        }
    }

    func testVideosNeedTheSameLengthWithinHalfASecond() {
        let video = { (duration: Double?) in self.details(type: "video/quicktime", duration: duration) }
        let fingerprints = [
            uid("a"): video(10.0), uid("b"): video(10.4), uid("long"): video(11.0), uid("no-length"): video(nil),
        ]
        let candidates = [[uid("a"), uid("b"), uid("long"), uid("no-length")]]
        XCTAssertEqual(
            PossibleDuplicatePolicy(rule: .sameShape, includesVideos: true).groups(
                of: candidates, fingerprints: fingerprints),
            [PossibleDuplicateGroup(members: [uid("a"), uid("b")], differences: [.duration])])
        XCTAssertEqual(
            PossibleDuplicatePolicy(rule: .sameShape, includesVideos: false).groups(
                of: candidates, fingerprints: fingerprints), [])
    }

    func testTheBoundariesOfTheShapeLengthAndMomentCount() {
        let shape = PossibleDuplicatePolicy(rule: .sameShape, includesVideos: true)
        let square = [uid("a"): details(width: 100, height: 100)]
        XCTAssertEqual(
            shape.groups(
                of: [[uid("a"), uid("b")]],
                fingerprints: square.merging([uid("b"): details(width: 101, height: 100)]) { $1 }
            )
            .count, 1, "a ratio exactly 1 % off counts")
        XCTAssertEqual(
            shape.groups(
                of: [[uid("a"), uid("b")]],
                fingerprints: square.merging([uid("b"): details(width: 102, height: 100)]) { $1 }),
            [], "2 % off does not")
        let video = { (duration: Double) in self.details(type: "video/mp4", duration: duration) }
        XCTAssertEqual(
            shape.groups(of: [[uid("a"), uid("b")]], fingerprints: [uid("a"): video(10), uid("b"): video(10.5)]).count,
            1,
            "a length exactly half a second off counts")
        XCTAssertEqual(
            shape.groups(of: [[uid("a"), uid("b")]], fingerprints: [uid("a"): video(10), uid("b"): video(10.51)]), [],
            "more than half a second does not")
        let sameMillisecond = [photo("p", exact: 1_700_000_000.2001), photo("q", exact: 1_700_000_000.2004)]
        XCTAssertEqual(
            PossibleDuplicateCandidates.groups(of: sameMillisecond, sameBytes: [], includesVideos: true),
            [[uid("p"), uid("q")]], "moments within the same millisecond are one moment")
        let nextMillisecond = [
            photo("p", exact: 1_700_000_000.2004), photo("q", exact: 1_700_000_000.2006),
            photo("r", exact: 1_700_000_000.2006),
        ]
        XCTAssertEqual(
            PossibleDuplicateCandidates.groups(of: nextMillisecond, sameBytes: [], includesVideos: true),
            [[uid("q"), uid("r")]], "the next millisecond is another moment")
    }

    func testAPhotoAndAVideoOfTheSameSecondAreNoPair() {
        let policy = PossibleDuplicatePolicy(rule: .sameSecond, includesVideos: true)
        let fingerprints = [uid("a"): details(), uid("v"): details(type: "video/mp4", duration: 3)]
        XCTAssertEqual(policy.groups(of: [[uid("a"), uid("v")]], fingerprints: fingerprints), [])
    }

    func testTheGroupComparesEachCopyWithItsFirstCopyAndKeepsTheRestApart() {
        let policy = PossibleDuplicatePolicy(rule: .strict, includesVideos: true)
        let fingerprints = [
            uid("a"): details(), uid("x"): details(camera: "Other"), uid("b"): details(type: "image/heic"),
            uid("y"): details(camera: "Other", type: "image/png"),
        ]
        XCTAssertEqual(
            policy.groups(of: [[uid("a"), uid("x"), uid("b"), uid("y")]], fingerprints: fingerprints),
            [
                PossibleDuplicateGroup(members: [uid("a"), uid("b")], differences: [.fileType]),
                PossibleDuplicateGroup(members: [uid("x"), uid("y")], differences: [.fileType]),
            ])
    }
}
