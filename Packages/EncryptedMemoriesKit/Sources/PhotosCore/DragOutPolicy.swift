import Foundation

// MARK: - Drag-out preflight decision

/// The outcome of a drag-out disk-space preflight. Platform shells read this to decide whether
/// a drag session may start and to explain a refusal.
public struct DragOutPreflightDecision: Sendable, Equatable {
    /// The summed size of every item whose size is known, or `nil` when any item's size is unknown.
    public let totalKnownBytes: Int64?
    /// Free space on the staging volume (0 when the capacity query itself failed).
    public let freeDiskBytes: Int64
    /// Whether the drag-out may proceed.
    public let isAllowed: Bool
    /// Why the drag-out was blocked; `nil` when allowed.
    public let blockReason: DragOutBlockReason?

    public init(
        totalKnownBytes: Int64?,
        freeDiskBytes: Int64,
        isAllowed: Bool,
        blockReason: DragOutBlockReason?
    ) {
        self.totalKnownBytes = totalKnownBytes
        self.freeDiskBytes = freeDiskBytes
        self.isAllowed = isAllowed
        self.blockReason = blockReason
    }
}

/// Why a drag-out was refused before any staging started.
public enum DragOutBlockReason: Sendable, Equatable {
    /// The staged originals plus the safety margin exceed the staging volume's free space.
    case insufficientDiskSpace(requiredIncludingMargin: Int64, available: Int64)
}

/// Pure drag-out preflight decision, shared by the iOS and macOS shells.
public enum DragOutPolicy {
    /// - `totalKnownBytes`: the summed item sizes, or `nil` when any item's size is unknown
    ///   (the drag is allowed and the progress UI owns sizing).
    /// - Blocks only when `totalKnownBytes + safetyMarginBytes > freeDiskBytes`.
    public static func preflight(
        totalKnownBytes: Int64?,
        freeDiskBytes: Int64,
        safetyMarginBytes: Int64
    ) -> DragOutPreflightDecision {
        guard let totalKnownBytes else {
            // Sizes unknown: allow and let the progress UI handle streaming/disk reality.
            return DragOutPreflightDecision(
                totalKnownBytes: nil,
                freeDiskBytes: freeDiskBytes,
                isAllowed: true,
                blockReason: nil
            )
        }
        let requiredIncludingMargin = totalKnownBytes + safetyMarginBytes
        guard requiredIncludingMargin > freeDiskBytes else {
            return DragOutPreflightDecision(
                totalKnownBytes: totalKnownBytes,
                freeDiskBytes: freeDiskBytes,
                isAllowed: true,
                blockReason: nil
            )
        }
        return DragOutPreflightDecision(
            totalKnownBytes: totalKnownBytes,
            freeDiskBytes: freeDiskBytes,
            isAllowed: false,
            blockReason: .insufficientDiskSpace(
                requiredIncludingMargin: requiredIncludingMargin,
                available: freeDiskBytes
            )
        )
    }
}

// MARK: - Drag-out failure kinds

/// User-facing categories for a failed drag-out staging run. Screens map these onto their shared
/// selection-error alert surface; the grid never presents UI itself. Lives in PhotosCore so the
/// macOS Metal grid (TimelineFeature) shares the iOS grid's (TimelineUIKitFeature) failure mapping.
public enum DragOutFailureKind: Equatable, Sendable {
    case insufficientSpace
    case writeFailed
    case cancelled
}

public extension DragOutFailureKind {
    /// Localized alert copy for the failure, resolved through the PhotosCore String Catalog.
    var localizedMessage: String {
        switch self {
        case .insufficientSpace: L10n.string("dragout.error.insufficient_space")
        case .writeFailed: L10n.string("dragout.error.write_failed")
        case .cancelled: L10n.string("dragout.error.title")
        }
    }
}
