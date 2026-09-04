/// Result of reconciling encrypted cache contents with a derived-data scope.
public enum MediaCacheReconciliationResult: Sendable, Equatable {
    /// The supplied scope was not complete enough to authorize deletion.
    case deferred
    /// No graph epoch was bound to this consumer.
    case unbound
    /// The scope belongs to another graph epoch or does not advance the accepted revision.
    case staleScope
    /// Reconciliation completed. The value is the number of encrypted files or resource directories removed.
    case reconciled(removedEntries: Int)
    /// Reconciliation could not update every required on-disk location.
    case ioFailure
}
