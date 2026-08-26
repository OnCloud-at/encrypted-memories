import XCTest

@testable import PhotosCore

final class SupportDiagnosticsExporterTests: XCTestCase {
    func testDiagnosticsThrottleRetainsOnlyItsFixedKeyBudget() {
        var throttle = BoundedDiagnosticsThrottle(capacity: 3)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(throttle.shouldEmit(key: "a", now: start, interval: 60))
        XCTAssertTrue(throttle.shouldEmit(key: "b", now: start.addingTimeInterval(1), interval: 60))
        XCTAssertTrue(throttle.shouldEmit(key: "c", now: start.addingTimeInterval(2), interval: 60))
        XCTAssertFalse(throttle.shouldEmit(key: "c", now: start.addingTimeInterval(3), interval: 60))

        XCTAssertTrue(throttle.shouldEmit(key: "d", now: start.addingTimeInterval(4), interval: 60))
        XCTAssertEqual(throttle.count, 3)
        XCTAssertTrue(
            throttle.shouldEmit(key: "a", now: start.addingTimeInterval(5), interval: 60),
            "The oldest key must be evicted when the fixed budget is full"
        )
        XCTAssertEqual(throttle.count, 3)
    }

    func testSupportSnapshotAllowsOnlyPrivacySafeResourceFields() {
        let diagnostics = PhotoDiagnostics.shared
        diagnostics.resetForTests()
        defer { diagnostics.resetForTests() }

        diagnostics.emit(
            "ResourcePermit",
            [
                "action": "acquire",
                "workload": "mlInference",
                "uid": "secret-asset",
                "filename": "secret.jpg",
                "query": "private search",
                "hash": "secret-hash",
            ])
        diagnostics.emit("ThumbHealth", ["uid": "secret-asset", "state": "geometryHole"])
        diagnostics.increment("timeline.refresh.applied")
        diagnostics.increment("timeline.refresh.asset-secret")

        let snapshot = diagnostics.supportSnapshot()
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(
            snapshot.events.first?.fields,
            [
                "action": "acquire",
                "workload": "mlInference",
            ])
        XCTAssertEqual(snapshot.counters, ["timeline.refresh.applied": 1])
    }

    func testExportContainsRuntimeAndNeverRejectedFields() async throws {
        let diagnostics = PhotoDiagnostics.shared
        diagnostics.resetForTests()
        defer { diagnostics.resetForTests() }
        diagnostics.emit(
            "ResourceState",
            [
                "thermal": "serious",
                "path": "/private/photo",
                "error": "user content",
            ])
        let runtime = LibraryRuntimeState(
            initial: LibraryRuntimeSnapshot(
                thermalLevel: .serious,
                memoryHeadroom: .constrained,
                isLowPowerMode: true,
                network: LibraryNetworkState(isReachable: false, isConstrained: true, isExpensive: true)
            ))
        let coordinator = LibraryResourceCoordinator(runtimeState: runtime)

        let data = try await SupportDiagnosticsExporter.makeJSONData(
            runtimeState: runtime,
            resourceCoordinator: coordinator,
            diagnostics: diagnostics,
            bundle: Bundle(for: Self.self)
        )
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.contains("\"schemaVersion\" : 1"))
        XCTAssertTrue(text.contains("serious"))
        XCTAssertFalse(text.contains("/private/photo"))
        XCTAssertFalse(text.contains("user content"))
    }

    func testMLIndexQuantumExportsOnlyTechnicalAllowlistedFields() {
        let diagnostics = PhotoDiagnostics.shared
        diagnostics.resetForTests()
        defer { diagnostics.resetForTests() }

        diagnostics.emitSupport(
            "MLIndexQuantum",
            [
                "pipeline": "native",
                "parallelism": "3",
                "assetLimit": "32",
                "processed": "17",
                "durationMs": "2001",
                "waitMs": "4",
                "policyReason": "nominal",
                "yieldReason": "timeSliceCompleted",
                "rampStep": "3",
                "thermalBefore": "nominal",
                "thermalAfter": "fair",
                "memoryBefore": "normal",
                "memoryAfter": "normal",
                "assetID": "secret-asset",
                "filename": "private.jpg",
                "ocrText": "private document",
                "query": "private search",
                "modelInput": "private pixels",
            ])

        let event = diagnostics.supportSnapshot().events.first
        XCTAssertEqual(event?.category, "MLIndexQuantum")
        XCTAssertEqual(event?.fields.count, 13)
        XCTAssertEqual(event?.fields["pipeline"], "native")
        XCTAssertEqual(event?.fields["yieldReason"], "timeSliceCompleted")
        XCTAssertNil(event?.fields["assetID"])
        XCTAssertNil(event?.fields["filename"])
        XCTAssertNil(event?.fields["ocrText"])
        XCTAssertNil(event?.fields["query"])
        XCTAssertNil(event?.fields["modelInput"])
    }
}
