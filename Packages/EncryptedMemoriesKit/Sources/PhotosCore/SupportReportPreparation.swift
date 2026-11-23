import Foundation
import Observation

/// The preparation of the support report behind the bug-report sheet. The Mac and the iPhone sheet show a spinner
/// while `isPreparing` is true and one failure line when `prepare` returns `.failed`; each sheet hands in how it
/// delivers the file (a save panel on the Mac, a share sheet on iPhone and iPad).
@MainActor
@Observable
public final class SupportReportPreparation {
    /// How the delivery of the prepared report ended.
    public enum Delivery: Equatable, Sendable {
        /// The report reached the person: it was saved or handed to the share sheet.
        case delivered
        /// The person closed the save panel. This is not a failure and shows no message.
        case dismissed
        /// The report could not be built or delivered.
        case failed
    }

    public private(set) var isPreparing = false

    @ObservationIgnored private let makeData: @Sendable () async throws -> Data

    public init(
        makeData: @escaping @Sendable () async throws -> Data = { try await SupportDiagnosticsExporter.makeJSONData() }
    ) {
        self.makeData = makeData
    }

    /// Builds the report and passes it to `deliver`. Returns nil without doing anything while a report is still being
    /// prepared; `onStart` runs only for a request that is accepted, so a refused request leaves what the sheet shows
    /// as it is. A report that cannot be built and a delivery that throws both end as `.failed`.
    public func prepare(onStart: () -> Void = {}, deliver: (Data) async throws -> Delivery) async -> Delivery? {
        guard !isPreparing else { return nil }
        isPreparing = true
        defer { isPreparing = false }
        onStart()
        do {
            return try await deliver(try await makeData())
        } catch {
            return .failed
        }
    }
}
