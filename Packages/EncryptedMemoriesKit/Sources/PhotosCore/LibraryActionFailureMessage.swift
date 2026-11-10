import Foundation

/// Selects the message of a library action while the native app supplies its localized text.
public enum LibraryActionFailureMessage {
    public enum Action: Sendable {
        case albumCover
        case export
        case saveToLibrary
    }

    public enum Text: Equatable, Sendable {
        case albumCover
        case export
        case lowDisk
        case exportTitle
        case lowDiskTitle
    }

    /// Selects the export alert's title from the same failure classification as its body.
    public static func exportTitle(for error: any Error) -> Text {
        if (error as? OriginalExportWriter.Failure) == .lowDisk { return .lowDiskTitle }
        return .exportTitle
    }

    /// A nil body suppresses the alert; an empty body keeps a title-only alert visible.
    /// A reported album outcome takes priority over an underlying cancellation.
    public static func message(
        for error: any Error,
        action: Action,
        specificAlbumReason: String? = nil,
        underlyingError: (any Error)? = nil,
        text: (Text) -> String
    ) -> String? {
        if case .albumCover = action {
            if let specificAlbumReason { return specificAlbumReason }
            if let underlyingError, FailureCancellation.isCancellation(underlyingError) { return nil }
        }
        if FailureCancellation.isCancellation(error) { return nil }
        switch action {
        case .albumCover:
            return text(.albumCover)
        case .export:
            if exportTitle(for: error) == .lowDiskTitle { return text(.lowDisk) }
            return text(.export)
        case .saveToLibrary:
            return ""
        }
    }
}
