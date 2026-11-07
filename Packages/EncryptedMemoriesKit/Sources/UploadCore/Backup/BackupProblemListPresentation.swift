/// What either native backup problem sheet shows.
public enum BackupProblemListPresentation: Equatable, Sendable {
    case list
    case loading
    case unavailable
    /// Only this one says that nothing needs attention.
    case empty
}

public extension BackupProblemListSession {
    func presentation(expectsItems: Bool) -> BackupProblemListPresentation {
        if !rows.isEmpty { return .list }
        if isUnavailable { return .unavailable }
        if !hasRead || isReading { return .loading }
        return expectsItems ? .unavailable : .empty
    }
}
