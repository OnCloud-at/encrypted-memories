import Foundation

/// Runs one account-scoped status measurement away from the caller's actor and coalesces refresh demand.
///
/// A synchronous filesystem walk may ignore cancellation. The single live work handle therefore remains
/// observable until completion, and a newer session waits for that reader before starting another measurement.
public final class OfflineLibraryStatsCoordinator: @unchecked Sendable {
    public typealias Read = @Sendable () async -> OfflineCacheStatus?

    public struct Session: Sendable, Equatable {
        fileprivate let id: UInt64
    }

    public struct Demand: Sendable, Equatable {
        fileprivate let sessionID: UInt64
        fileprivate let revision: UInt64
    }

    public struct Measurement: Sendable, Equatable {
        public let status: OfflineCacheStatus
        public let demand: Demand

        fileprivate init(status: OfflineCacheStatus, demand: Demand) {
            self.status = status
            self.demand = demand
        }
    }

    private struct SessionState {
        let id: UInt64
        var demandRevision: UInt64
        var completedRevision: UInt64
        var completedStatus: OfflineCacheStatus?
    }

    private struct Work {
        let id: UInt64
        let sessionID: UInt64
        let demandRevision: UInt64
        let task: Task<OfflineCacheStatus?, Never>
    }

    private let lock = NSLock()
    private var nextSessionID: UInt64 = 0
    private var nextWorkID: UInt64 = 0
    private var currentSession: SessionState?
    private var active: Work?

    public init() {}

    /// Starts a new account/configuration lifetime. An older reader remains the sole active work until joined.
    @discardableResult
    public func beginSession() -> Session {
        lock.withLock {
            nextSessionID &+= 1
            let session = Session(id: nextSessionID)
            currentSession = SessionState(id: session.id, demandRevision: 1, completedRevision: 0, completedStatus: nil)
            return session
        }
    }

    /// Invalidates publication for exactly this owner. A stale teardown cannot close a newer session.
    public func invalidate(_ session: Session) {
        lock.withLock {
            guard currentSession?.id == session.id else { return }
            currentSession = nil
        }
    }

    /// Records a mutation that requires a measurement admitted after that mutation.
    @discardableResult
    public func markDirty(in session: Session) -> Demand? {
        lock.withLock {
            guard var state = currentSession, state.id == session.id else { return nil }
            state.demandRevision &+= 1
            currentSession = state
            return Demand(sessionID: session.id, revision: state.demandRevision)
        }
    }

    /// Requests an on-demand measurement. Concurrent callers share the current pending or active demand.
    public func requestRefresh(in session: Session) -> Demand? {
        lock.withLock {
            guard var state = currentSession, state.id == session.id else { return nil }
            let demandAlreadyPending = state.completedRevision < state.demandRevision
            let activeAlreadySatisfiesDemand =
                active?.sessionID == session.id && (active?.demandRevision ?? 0) >= state.demandRevision
            if !demandAlreadyPending && !activeAlreadySatisfiesDemand {
                state.demandRevision &+= 1
                currentSession = state
            }
            return Demand(sessionID: session.id, revision: state.demandRevision)
        }
    }

    public func currentDemand(in session: Session) -> Demand? {
        lock.withLock {
            guard let state = currentSession, state.id == session.id else { return nil }
            return Demand(sessionID: session.id, revision: state.demandRevision)
        }
    }

    public func isCurrent(_ demand: Demand, in session: Session) -> Bool {
        lock.withLock {
            guard let state = currentSession, state.id == session.id else { return false }
            return demand.sessionID == session.id && demand.revision == state.demandRevision
        }
    }

    /// Returns a measurement satisfying both the requested and any newer coalesced demand. A mutation that
    /// overlaps a read produces exactly one follow-up read at the latest revision. Delayed waiters
    /// reuse its completed value; an explicit new refresh or mutation still advances demand.
    public func refresh(
        in session: Session,
        satisfying requestedDemand: Demand,
        read: @escaping Read
    ) async -> Measurement? {
        guard requestedDemand.sessionID == session.id else { return nil }

        while true {
            let (work, completed) = lock.withLock { () -> (Work?, Measurement?) in
                guard let state = currentSession, state.id == session.id else { return (nil, nil) }
                if state.completedRevision >= max(requestedDemand.revision, state.demandRevision),
                    let status = state.completedStatus
                {
                    return (
                        nil,
                        Measurement(
                            status: status,
                            demand: Demand(sessionID: session.id, revision: state.completedRevision)
                        )
                    )
                }
                if let active { return (active, nil) }
                nextWorkID &+= 1
                let newWork = Work(
                    id: nextWorkID,
                    sessionID: session.id,
                    demandRevision: max(requestedDemand.revision, state.demandRevision),
                    task: Task.detached(priority: .utility) { await read() }
                )
                active = newWork
                return (newWork, nil)
            }
            if let completed { return completed }
            guard let work else { return nil }

            let value = await work.task.value
            let stateAfterRead = lock.withLock { () -> SessionState? in
                if active?.id == work.id { active = nil }
                guard var state = currentSession, state.id == session.id else { return nil }
                if work.sessionID == session.id,
                    work.demandRevision >= state.completedRevision,
                    let value
                {
                    state.completedRevision = work.demandRevision
                    state.completedStatus = value
                    currentSession = state
                }
                return state
            }
            guard let stateAfterRead else { return nil }
            guard work.sessionID == session.id,
                work.demandRevision >= requestedDemand.revision,
                work.demandRevision >= stateAfterRead.demandRevision,
                let value
            else { continue }

            return Measurement(
                status: value,
                demand: Demand(sessionID: session.id, revision: work.demandRevision)
            )
        }
    }

    /// Invalidates this owner and joins its reader or an older reader inherited during reconfiguration.
    /// The handle is removed only after the await, so overlapping
    /// join callers both observe and join the same non-cooperative work. Work for a newer session is untouched.
    public func stopAndJoin(_ session: Session) async {
        invalidate(session)
        while true {
            let work = lock.withLock { () -> Work? in
                guard let active, active.sessionID <= session.id else { return nil }
                return active
            }
            guard let work else { return }
            _ = await work.task.value
            lock.withLock {
                if active?.id == work.id { active = nil }
            }
        }
    }
}
