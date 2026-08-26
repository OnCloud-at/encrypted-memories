import Foundation

/// Builds a scrubbed support report without account, asset, query, path, or error content.
public enum SupportDiagnosticsExporter {
    private struct Report: Codable {
        struct Runtime: Codable {
            let thermal: String
            let memoryPressure: String
            let memoryBudget: String
            let memoryHeadroom: String
            let lowPowerMode: Bool
            let networkReachable: Bool
            let networkConstrained: Bool
            let networkExpensive: Bool
            let executionOpportunity: String
            let visibleMediaDemand: Bool
            let activeUserInteraction: Bool
            let activeUserTransfers: Int
            let generation: UInt64
        }

        struct Resources: Codable {
            let permitsAcquired: Int
            let permitsReleased: Int
            let cancelledWaiters: Int
            let policyPauses: Int
            let recoveries: Int
            let maximumConcurrentPermits: Int
            let maximumWaitMilliseconds: UInt64
        }

        let schemaVersion: Int
        let generatedAt: Date
        let appVersion: String
        let appBuild: String
        let operatingSystem: String
        let runtime: Runtime
        let resources: Resources
        let diagnostics: PhotoDiagnosticsSupportSnapshot
    }

    public static func makeJSONData(
        runtimeState: LibraryRuntimeState = .shared,
        resourceCoordinator: LibraryResourceCoordinator = .shared,
        diagnostics: PhotoDiagnostics = .shared,
        bundle: Bundle = .main
    ) async throws -> Data {
        let snapshot = runtimeState.snapshot()
        let metrics = await resourceCoordinator.metrics()
        let buildInfo = AppBuildInfo(bundle: bundle)
        let report = Report(
            schemaVersion: 1,
            generatedAt: Date(),
            appVersion: buildInfo.version ?? "unknown",
            appBuild: buildInfo.build ?? "unknown",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            runtime: Report.Runtime(
                thermal: String(describing: snapshot.thermalLevel),
                memoryPressure: String(describing: snapshot.memoryPressure),
                memoryBudget: String(describing: snapshot.memoryBudgetTier),
                memoryHeadroom: String(describing: snapshot.memoryHeadroom),
                lowPowerMode: snapshot.isLowPowerMode,
                networkReachable: snapshot.network.isReachable,
                networkConstrained: snapshot.network.isConstrained,
                networkExpensive: snapshot.network.isExpensive,
                executionOpportunity: String(describing: snapshot.executionOpportunity),
                visibleMediaDemand: snapshot.hasVisibleMediaDemand,
                activeUserInteraction: snapshot.hasActiveUserInteraction,
                activeUserTransfers: snapshot.activeUserTransferCount,
                generation: snapshot.generation
            ),
            resources: Report.Resources(
                permitsAcquired: metrics.permitsAcquired,
                permitsReleased: metrics.permitsReleased,
                cancelledWaiters: metrics.cancelledWaiters,
                policyPauses: metrics.policyPauses,
                recoveries: metrics.recoveries,
                maximumConcurrentPermits: metrics.maximumConcurrentPermits,
                maximumWaitMilliseconds: metrics.maximumWaitMilliseconds
            ),
            diagnostics: diagnostics.supportSnapshot()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }
}
