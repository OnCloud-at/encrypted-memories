import Foundation
import Testing

@testable import ProtonDriveBackend

@Suite("Series frames")
struct BurstFrameVerdictsTests {
    private struct ReadFailure: Error {}

    /// The bursts listing lists only the main photo; the frame and the adjustment data of an edit are related files.
    private let members = ["main", "frame", "edit-data"]
    private let listed: Set<String> = ["main"]

    @Test("the adjustment data of an edit is no frame of its series")
    func adjustmentDataIsHidden() async {
        var requested: [[String]] = []
        let result = await BurstFrameVerdicts.frames(of: members, listed: listed, verdicts: BurstFrameVerdicts()) {
            requested.append($0)
            return ["frame": "image/heic", "edit-data": "application/xml"]
        }
        #expect(result.frames == ["main", "frame"])
        #expect(requested == [["frame", "edit-data"]])
    }

    @Test("a related file of an unknown type stays a frame")
    func unknownTypeStays() async {
        let result = await BurstFrameVerdicts.frames(
            of: ["main", "frame", "untyped", "edit-data"], listed: listed, verdicts: BurstFrameVerdicts()
        ) { _ in
            ["untyped": "", "edit-data": "application/xml"]
        }
        #expect(result.frames == ["main", "frame", "untyped"])
    }

    @Test("a failed type read keeps every member and reads again on the next open")
    func failedReadKeepsEveryMember() async {
        let failed = await BurstFrameVerdicts.frames(of: members, listed: listed, verdicts: BurstFrameVerdicts()) { _ in
            throw ReadFailure()
        }
        #expect(failed.frames == members)

        var requested: [[String]] = []
        let retried = await BurstFrameVerdicts.frames(of: members, listed: listed, verdicts: failed.verdicts) {
            requested.append($0)
            return ["frame": "image/heic", "edit-data": "application/xml"]
        }
        #expect(requested == [["frame", "edit-data"]])
        #expect(retried.frames == ["main", "frame"])
    }

    @Test("a second open of the series reads no metadata")
    func secondOpenReadsNothing() async {
        var requested: [[String]] = []
        let first = await BurstFrameVerdicts.frames(of: members, listed: listed, verdicts: BurstFrameVerdicts()) {
            requested.append($0)
            return ["edit-data": "application/xml"]
        }
        var cached = BurstFrameVerdicts()
        cached.merge(first.verdicts)

        let second = await BurstFrameVerdicts.frames(of: members, listed: listed, verdicts: cached) {
            requested.append($0)
            return [:]
        }
        #expect(requested == [["frame", "edit-data"]])
        #expect(second.frames == ["main", "frame"])
    }
}
