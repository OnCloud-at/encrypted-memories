#if canImport(MetricKit)
    import PhotosCore
    import XCTest

    @testable import LibraryRuntimeAppleAdapter

    final class AppleMetricKitCollectorTests: XCTestCase {
        /// The payload counts that the support file carried before the collector moved into the package.
        func testThePayloadCountsKeepTheirCounterKeysAndEventFields() {
            let diagnostics = PhotoDiagnostics()

            AppleMetricKitCollector.countMetricPayloads(2, in: diagnostics)
            AppleMetricKitCollector.countDiagnosticPayloads(3, in: diagnostics)
            AppleMetricKitCollector.countDiagnosticPayloads(1, in: diagnostics)

            let snapshot = diagnostics.supportSnapshot()
            XCTAssertEqual(snapshot.counters, ["metrickit.metricPayloads": 2, "metrickit.diagnosticPayloads": 4])
            XCTAssertEqual(snapshot.events.map(\.category), ["MetricKit", "MetricKit", "MetricKit"])
            XCTAssertEqual(
                snapshot.events.map(\.fields),
                [["metricPayloads": "2"], ["diagnosticPayloads": "3"], ["diagnosticPayloads": "1"]])
        }
    }
#endif
