import Foundation

@testable import PhotosCore

/// Fixtures for the MetricKit diagnostic tests: the call stack tree JSON that `MXCallStackTree.jsonRepresentation()`
/// returns (keys as the public MetricKit samples show them; Apple does not document the schema) and a diagnostic input.
enum MetricKitDiagnosticFixtures {
    /// 2027-01-15T08:00:00Z.
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    struct Frame {
        var name: String
        var offset: Int
        var sampleCount: Int = 1
        var subFrames: [Frame] = []

        var json: [String: Any] {
            [
                "binaryUUID": "00000000-0000-0000-0000-000000000000", "binaryName": name,
                "offsetIntoBinaryTextSegment": offset, "sampleCount": sampleCount, "address": offset + 4096,
                "subFrames": subFrames.map(\.json),
            ]
        }
    }

    /// One chain from the outermost caller (first name) to the innermost frame (last name). A frame's offset is
    /// `1000 + its index`.
    static func chain(_ names: [String]) -> Frame {
        var frame: Frame?
        for (index, name) in names.enumerated().reversed() {
            frame = Frame(name: name, offset: 1000 + index, subFrames: frame.map { [$0] } ?? [])
        }
        return frame ?? Frame(name: "empty", offset: 0)
    }

    /// A tree with one stack per thread; `attributed` marks the thread that caused the event.
    static func tree(_ stacks: [(roots: [Frame], attributed: Bool)]) -> Data {
        let object: [String: Any] = [
            "callStackPerThread": true,
            "callStacks": stacks.map {
                ["threadAttributed": $0.attributed, "callStackRootFrames": $0.roots.map(\.json)] as [String: Any]
            },
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func input(
        _ kind: MetricKitDiagnosticInput.Kind = .crash, seconds: Double = 0, label: String = "",
        callStackTreeJSON: Data? = nil
    ) -> MetricKitDiagnosticInput {
        MetricKitDiagnosticInput(
            kind: kind, rangeStart: start.addingTimeInterval(seconds),
            rangeEnd: start.addingTimeInterval(seconds + 3600), appVersion: "1.2.0", appBuild: "345",
            osVersion: "iPhone OS 27.1 (24B91)", exceptionType: 1, signal: 11,
            terminationReason: "Namespace SIGNAL, Code 11\(label)", callStackTreeJSON: callStackTreeJSON)
    }
}
