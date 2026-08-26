import Foundation

/// Stable shutdown phases for one authenticated library session.
///
/// Platform composition must invalidate its session generation and block new UI starts before
/// calling the coordinator. Feature modules remain responsible for their own idempotent shutdown;
/// this Core type owns only ordering, failure collection, and exactly-once orchestration.
public enum AccountTeardownStage: Int, Sendable, CaseIterable, Comparable {
    case platformTasks
    case smartSearch
    case locationCrawl
    case folderBackup
    case photoBackup
    case albumSync
    case facade
    case caches
    case logs
    case purgeClaims

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One typed owner in the account shutdown graph. Core imports no platform or feature module;
/// composition roots inject the concrete shutdown operation instead.
public struct AccountTeardownOwner: Sendable {
    public let id: String
    public let stage: AccountTeardownStage
    public let shutdown: @MainActor @Sendable () async throws -> Void

    public init(
        id: String,
        stage: AccountTeardownStage,
        shutdown: @escaping @MainActor @Sendable () async throws -> Void
    ) {
        self.id = id
        self.stage = stage
        self.shutdown = shutdown
    }
}

public enum AccountTeardownConfigurationError: Error, Sendable, Equatable {
    case duplicateOwnerID(String)
}

/// Privacy-safe failure evidence. Error descriptions are deliberately excluded because an injected
/// feature error can contain account paths or server identifiers.
public struct AccountTeardownFailure: Sendable, Equatable {
    public let ownerID: String
    public let stage: AccountTeardownStage

    public init(ownerID: String, stage: AccountTeardownStage) {
        self.ownerID = ownerID
        self.stage = stage
    }
}

public struct AccountTeardownReport: Sendable, Equatable {
    public let completedOwnerIDs: [String]
    public let failures: [AccountTeardownFailure]

    public var succeeded: Bool { failures.isEmpty }

    public init(completedOwnerIDs: [String], failures: [AccountTeardownFailure]) {
        self.completedOwnerIDs = completedOwnerIDs
        self.failures = failures
    }
}

/// Executes account shutdown exactly once. Concurrent and repeated callers share the same result;
/// a failed owner never prevents later owners (especially cache, log, and purge owners) from running.
public actor AccountTeardownCoordinator {
    private let owners: [AccountTeardownOwner]
    private var inFlight: Task<AccountTeardownReport, Never>?
    private var completedReport: AccountTeardownReport?

    public init(owners: [AccountTeardownOwner]) throws {
        var ownerIDs = Set<String>()
        for owner in owners {
            guard ownerIDs.insert(owner.id).inserted else {
                throw AccountTeardownConfigurationError.duplicateOwnerID(owner.id)
            }
        }

        self.owners = owners.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.stage == rhs.element.stage {
                    return lhs.offset < rhs.offset
                }
                return lhs.element.stage < rhs.element.stage
            }
            .map(\.element)
    }

    public func teardown() async -> AccountTeardownReport {
        if let completedReport { return completedReport }
        if let inFlight { return await inFlight.value }

        let owners = self.owners
        let task = Task { @MainActor in
            var completedOwnerIDs: [String] = []
            var failures: [AccountTeardownFailure] = []
            completedOwnerIDs.reserveCapacity(owners.count)

            for owner in owners {
                do {
                    try await owner.shutdown()
                    completedOwnerIDs.append(owner.id)
                } catch {
                    failures.append(AccountTeardownFailure(ownerID: owner.id, stage: owner.stage))
                }
            }

            return AccountTeardownReport(
                completedOwnerIDs: completedOwnerIDs,
                failures: failures
            )
        }
        inFlight = task
        let report = await task.value
        completedReport = report
        inFlight = nil
        return report
    }
}
