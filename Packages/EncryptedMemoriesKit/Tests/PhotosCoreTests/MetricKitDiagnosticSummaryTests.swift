import Foundation
import XCTest

@testable import PhotosCore

/// The support-file summary of each MetricKit diagnostic kind, built from plain values.
final class MetricKitDiagnosticSummaryTests: XCTestCase {
    private typealias Fixtures = MetricKitDiagnosticFixtures

    private func names(_ prefix: String, _ count: Int) -> [String] { (0..<count).map { "\(prefix)\($0)" } }

    private func assertAllowlisted(_ fields: [String: String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            PhotoDiagnostics.sanitizedSupportFields(event: "MetricKitDiagnostic", fields: fields), fields,
            "every key of a summary is on the one support allowlist", file: file, line: line)
    }

    func testCrashSummaryCarriesTheExceptionAndTheEightInnermostFramesOfTheFaultingThread() {
        let faulting = Fixtures.chain(names("f", 12))
        let other = Fixtures.chain(["otherThreadRoot", "otherThreadLeaf"])
        let tree = Fixtures.tree([(roots: [other], attributed: false), (roots: [faulting], attributed: true)])
        var input = Fixtures.input(callStackTreeJSON: tree)
        input.rangeStart = Fixtures.start.addingTimeInterval(30)

        let fields = MetricKitDiagnosticSummary.fields(for: input)

        XCTAssertEqual(
            fields,
            [
                "kind": "crash", "rangeStart": "2027-01-15T08:00:00Z", "rangeEnd": "2027-01-15T09:00:00Z",
                "appVersion": "1.2.0", "appBuild": "345", "osBuild": "24B91", "exceptionType": "1", "signal": "11",
                "terminationNamespace": "SIGNAL", "terminationCode": "11",
                "frame0": "f11+1011", "frame1": "f10+1010", "frame2": "f9+1009", "frame3": "f8+1008",
                "frame4": "f7+1007", "frame5": "f6+1006", "frame6": "f5+1005", "frame7": "f4+1004",
            ])
        assertAllowlisted(fields)
    }

    func testHangSummaryCarriesTheDurationAndTheFrames() {
        let tree = Fixtures.tree([(roots: [Fixtures.chain(["a", "b"])], attributed: true)])
        var input = Fixtures.input(.hang, callStackTreeJSON: tree)
        input.hangSeconds = 2.5
        input.exceptionType = nil
        input.signal = nil
        input.terminationReason = nil

        let fields = MetricKitDiagnosticSummary.fields(for: input)

        XCTAssertEqual(
            fields,
            [
                "kind": "hang", "rangeStart": "2027-01-15T08:00:00Z", "rangeEnd": "2027-01-15T09:00:00Z",
                "appVersion": "1.2.0", "appBuild": "345", "osBuild": "24B91", "hangSeconds": "2.5",
                "frame0": "b+1001", "frame1": "a+1000",
            ])
        assertAllowlisted(fields)
    }

    func testCPUExceptionSummaryCarriesTheCPUTimeAndTheSampledTime() {
        var input = Fixtures.input(.cpuException)
        input.cpuSeconds = 91.3
        input.sampledSeconds = 180
        input.exceptionType = nil
        input.signal = nil
        input.terminationReason = nil

        let fields = MetricKitDiagnosticSummary.fields(for: input)

        XCTAssertEqual(fields["kind"], "cpuException")
        XCTAssertEqual(fields["cpuSeconds"], "91.3")
        XCTAssertEqual(fields["sampledSeconds"], "180.0")
        XCTAssertNil(fields["frame0"], "a diagnostic without a call stack tree has no frames")
        assertAllowlisted(fields)
    }

    func testDiskWriteExceptionSummaryCarriesTheWrittenMegabytes() {
        var input = Fixtures.input(.diskWriteException)
        input.writtenMegabytes = 1024.04
        input.exceptionType = nil
        input.signal = nil
        input.terminationReason = nil

        let fields = MetricKitDiagnosticSummary.fields(for: input)

        XCTAssertEqual(fields["kind"], "diskWriteException")
        XCTAssertEqual(fields["writtenMB"], "1024.0")
        XCTAssertEqual(fields["rangeStart"], "2027-01-15T08:00:00Z", "the duration is the reporting period")
        XCTAssertEqual(fields["rangeEnd"], "2027-01-15T09:00:00Z")
        assertAllowlisted(fields)
    }

    func testAppLaunchSummaryCarriesTheLaunchDuration() {
        var input = Fixtures.input(.appLaunch)
        input.launchSeconds = 7
        input.exceptionType = nil
        input.signal = nil
        input.terminationReason = nil

        let fields = MetricKitDiagnosticSummary.fields(for: input)

        XCTAssertEqual(fields["kind"], "appLaunch")
        XCTAssertEqual(fields["launchSeconds"], "7.0")
        assertAllowlisted(fields)
    }

    // MARK: - Frames

    func testTheFramesFollowTheBranchWithTheMostSamplesAndTheFirstBranchOnATie() {
        let heavy = Fixtures.Frame(name: "heavy", offset: 2, sampleCount: 5)
        let light = Fixtures.Frame(name: "light", offset: 1, sampleCount: 1)
        let root = Fixtures.Frame(name: "root", offset: 0, sampleCount: 6, subFrames: [light, heavy])
        let tieA = Fixtures.Frame(name: "tieA", offset: 3, sampleCount: 2)
        let tieB = Fixtures.Frame(name: "tieB", offset: 4, sampleCount: 2)
        let tieRoot = Fixtures.Frame(name: "tieRoot", offset: 0, sampleCount: 4, subFrames: [tieA, tieB])

        let weighted = MetricKitDiagnosticSummary.fields(
            for: Fixtures.input(.hang, callStackTreeJSON: Fixtures.tree([(roots: [root], attributed: true)])))
        let tie = MetricKitDiagnosticSummary.fields(
            for: Fixtures.input(.hang, callStackTreeJSON: Fixtures.tree([(roots: [tieRoot], attributed: true)])))

        XCTAssertEqual(weighted["frame0"], "heavy+2")
        XCTAssertEqual(weighted["frame1"], "root+0")
        XCTAssertNil(weighted["frame2"])
        XCTAssertEqual(tie["frame0"], "tieA+3")
    }

    func testWithoutAnAttributedThreadTheFirstStackIsUsed() {
        let fields = MetricKitDiagnosticSummary.fields(
            for: Fixtures.input(
                .cpuException,
                callStackTreeJSON: Fixtures.tree([
                    (roots: [Fixtures.chain(["firstRoot", "firstLeaf"])], attributed: false),
                    (roots: [Fixtures.chain(["secondRoot", "secondLeaf"])], attributed: false),
                ])))

        XCTAssertEqual(fields["frame0"], "firstLeaf+1001")
    }

    private func oneFrame(_ frame: String) -> Data {
        Data(#"{"callStacks":[{"callStackRootFrames":[\#(frame)]}]}"#.utf8)
    }

    func testAMalformedCallStackTreeGivesNoFramesAndKeepsTheOtherFields() {
        let malformed: [Data] = [
            Data("not json".utf8), Data(), Data("[]".utf8), Data("{}".utf8), Data(#"{"callStacks":"x"}"#.utf8),
            Data(#"{"callStacks":[]}"#.utf8), Data(#"{"callStacks":[{"callStackRootFrames":[]}]}"#.utf8),
        ]
        for data in malformed {
            let fields = MetricKitDiagnosticSummary.fields(for: Fixtures.input(callStackTreeJSON: data))
            XCTAssertEqual(fields["kind"], "crash")
            XCTAssertEqual(fields["signal"], "11")
            XCTAssertNil(fields["frame0"], String(decoding: data, as: UTF8.self))
        }
    }

    func testAnInvalidOffsetShowsAQuestionMarkInsteadOfDroppingTheFrame() {
        let offsets = ["", ",\"offsetIntoBinaryTextSegment\":-4", ",\"offsetIntoBinaryTextSegment\":1.5"]
        let huge = [",\"offsetIntoBinaryTextSegment\":1e30", ",\"offsetIntoBinaryTextSegment\":\"7\""]
        for suffix in offsets + huge {
            let data = oneFrame(#"{"binaryName":"a"\#(suffix)}"#)
            let fields = MetricKitDiagnosticSummary.fields(for: Fixtures.input(callStackTreeJSON: data))
            XCTAssertEqual(fields["frame0"], "a+?", suffix)
        }
        let valid = MetricKitDiagnosticSummary.fields(
            for: Fixtures.input(
                callStackTreeJSON: oneFrame(#"{"binaryName":"a","offsetIntoBinaryTextSegment":18446744073709549568}"#)))
        XCTAssertEqual(valid["frame0"], "a+18446744073709549568")
    }

    func testARejectedFrameKeepsItsPlaceAndNoOuterFrameMovesUp() {
        let tree = Fixtures.tree([(roots: [Fixtures.chain(["outer", "bad name", "inner"])], attributed: true)])

        let fields = MetricKitDiagnosticSummary.fields(for: Fixtures.input(callStackTreeJSON: tree))

        XCTAssertEqual(fields["frame0"], "inner+1002")
        XCTAssertEqual(fields["frame1"], "?+1001")
        XCTAssertEqual(fields["frame2"], "outer+1000")
        XCTAssertNil(fields["frame3"])
    }

    func testOnlyTheAppsOwnExecutableNameMayHoldASpace() {
        let tree = Fixtures.tree([
            (roots: [Fixtures.chain(["Encrypted Memories", "Evil Name", "VectorKit"])], attributed: true)
        ])
        var input = Fixtures.input(callStackTreeJSON: tree)
        input.appExecutableName = "Encrypted Memories"

        let mac = MetricKitDiagnosticSummary.fields(for: input)
        input.appExecutableName = nil
        let withoutName = MetricKitDiagnosticSummary.fields(for: input)
        input.appExecutableName = "Another App"
        let otherName = MetricKitDiagnosticSummary.fields(for: input)

        XCTAssertEqual(mac["frame0"], "VectorKit+1002")
        XCTAssertEqual(mac["frame1"], "?+1001", "a spaced name that is not the app's own stays rejected")
        XCTAssertEqual(mac["frame2"], "Encrypted Memories+1000")
        XCTAssertEqual(withoutName["frame2"], "?+1000")
        XCTAssertEqual(otherName["frame2"], "?+1000")
    }

    // MARK: - Numbers and tokens

    func testANumberThatIsNotFiniteNegativeOrHugeIsLeftOut() {
        let rejected = [Double.nan, .infinity, -Double.infinity, -0.1, 1e12 + 1e5, .greatestFiniteMagnitude]
        for value in rejected {
            var input = Fixtures.input(.hang)
            input.hangSeconds = value
            input.cpuSeconds = value
            input.sampledSeconds = value
            input.launchSeconds = value
            input.writtenMegabytes = value
            let fields = MetricKitDiagnosticSummary.fields(for: input)
            for key in ["hangSeconds", "cpuSeconds", "sampledSeconds", "launchSeconds", "writtenMB"] {
                XCTAssertNil(fields[key], "\(key) \(value)")
            }
        }
        var edge = Fixtures.input(.hang)
        edge.hangSeconds = 1e12
        edge.cpuSeconds = 0
        let fields = MetricKitDiagnosticSummary.fields(for: edge)
        XCTAssertEqual(fields["hangSeconds"], "1000000000000.0")
        XCTAssertEqual(fields["cpuSeconds"], "0.0")
    }

    func testAVersionAndABuildHoldAtMostTwentyFourCharacters() {
        var input = Fixtures.input(.hang)
        input.appVersion = String(repeating: "1", count: 24)
        input.appBuild = String(repeating: "2", count: 24)
        let atLimit = MetricKitDiagnosticSummary.fields(for: input)
        input.appVersion = String(repeating: "1", count: 25)
        input.appBuild = String(repeating: "2", count: 25)
        let overLimit = MetricKitDiagnosticSummary.fields(for: input)
        input.appVersion = ""
        input.appBuild = ""
        let empty = MetricKitDiagnosticSummary.fields(for: input)

        XCTAssertEqual(atLimit["appVersion"]?.count, 24)
        XCTAssertEqual(atLimit["appBuild"]?.count, 24)
        XCTAssertNil(overLimit["appVersion"])
        XCTAssertNil(overLimit["appBuild"])
        XCTAssertNil(empty["appVersion"])
        XCTAssertNil(empty["appBuild"])
    }

    func testTheOSBuildNeedsBetweenThreeAndTenCharacters() {
        func osBuild(_ version: String) -> String? {
            var input = Fixtures.input(.hang)
            input.osVersion = version
            return MetricKitDiagnosticSummary.fields(for: input)["osBuild"]
        }

        XCTAssertNil(osBuild("iPhone OS 27.1 (24)"))
        XCTAssertEqual(osBuild("iPhone OS 27.1 (24B)"), "24B")
        XCTAssertEqual(osBuild("iPhone OS 27.1 (ABCDEFGHIJ)"), "ABCDEFGHIJ")
        XCTAssertNil(osBuild("iPhone OS 27.1 (ABCDEFGHIJK)"))
        XCTAssertNil(osBuild("iPhone OS 27.1 (24 B)"))
        XCTAssertNil(osBuild("iPhone OS 27.1 24B91"))
    }

    // MARK: - Privacy

    func testNothingOutsideTheAllowlistedShapesReachesTheSummary() {
        let leaky = [
            "/private/var/mobile/Containers/Data/Application/ABC/Documents/Holiday.jpg", "Holiday Photo.jpg",
            "alice@example.com", String(repeating: "a", count: 49), "",
        ]
        let validNames = ["libsystem_kernel.dylib", "VectorKit", "Encrypted-Memories+x", "a"]
        let frames = (leaky + validNames).enumerated().map { Fixtures.Frame(name: $1, offset: $0) }
        let root = Fixtures.Frame(name: "root", offset: 99, subFrames: [])
        let tree = Fixtures.tree([(roots: [chainOf(root: root, frames: frames)], attributed: true)])
        var input = Fixtures.input(callStackTreeJSON: tree)
        input.terminationReason = "Namespace SIGNAL, Code 11 Segmentation fault: /srv/alice/Holiday.jpg"
        input.appVersion = "1.2.0 (alice)"
        input.osVersion = "iPhone OS 27.1"

        let fields = MetricKitDiagnosticSummary.fields(for: input)

        XCTAssertEqual(fields["terminationNamespace"], "SIGNAL")
        XCTAssertEqual(fields["terminationCode"], "11")
        XCTAssertNil(fields["appVersion"], "a version with free text is dropped")
        XCTAssertNil(fields["osBuild"], "an OS version without a build is dropped")
        XCTAssertEqual(
            (0..<8).compactMap { fields["frame\($0)"] },
            ["a+8", "Encrypted-Memories+x+7", "VectorKit+6", "libsystem_kernel.dylib+5", "?+4", "?+3", "?+2", "?+1"],
            "frames with a path, a space, an address, a long or an empty name show `?` and keep their place")
        for value in fields.values {
            XCTAssertFalse(value.contains("alice"))
            XCTAssertFalse(value.contains("Holiday"))
            XCTAssertFalse(value.contains("/srv"))
        }
        assertAllowlisted(fields)
    }

    func testOnlyTheNamespaceAndCodePrefixOfATerminationReasonSurvives() {
        let cases: [(reason: String, namespace: String?, code: String?)] = [
            ("Namespace SIGNAL, Code 11 Segmentation fault: 11", "SIGNAL", "11"),
            ("Namespace FRONTBOARD, Code 0x8badf00d", "FRONTBOARD", "0x8badf00d"),
            ("Namespace SIGNAL, Code 11", "SIGNAL", "11"),
            ("Namespace SIGNAL, Code 11abc", nil, nil),
            ("Namespace signal, Code 11", nil, nil),
            ("Namespace SIGNAL, Code 12345678901", nil, nil),
            ("Crashed while opening Holiday.jpg", nil, nil),
            ("  Namespace SIGNAL, Code 11", nil, nil),
            ("", nil, nil),
        ]
        for item in cases {
            var input = Fixtures.input()
            input.terminationReason = item.reason
            let fields = MetricKitDiagnosticSummary.fields(for: input)
            XCTAssertEqual(fields["terminationNamespace"], item.namespace, item.reason)
            XCTAssertEqual(fields["terminationCode"], item.code, item.reason)
        }
    }

    func testTheReportedPeriodIsRoundedDownToTheMinute() {
        var input = Fixtures.input(.hang)
        input.rangeStart = Fixtures.start.addingTimeInterval(59)
        input.rangeEnd = Fixtures.start.addingTimeInterval(3661)

        let fields = MetricKitDiagnosticSummary.fields(for: input)

        XCTAssertEqual(fields["rangeStart"], "2027-01-15T08:00:00Z")
        XCTAssertEqual(fields["rangeEnd"], "2027-01-15T09:01:00Z")
    }

    /// `root` followed by `frames` as one chain.
    private func chainOf(root: Fixtures.Frame, frames: [Fixtures.Frame]) -> Fixtures.Frame {
        var tail: Fixtures.Frame?
        for frame in frames.reversed() {
            var node = frame
            node.subFrames = tail.map { [$0] } ?? []
            tail = node
        }
        var head = root
        head.subFrames = tail.map { [$0] } ?? []
        return head
    }
}
