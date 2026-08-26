import Foundation
import UploadCore

/// Composes catalog discovery and queue reconciliation for platform execution windows. This is not
/// user-visible backup progress: discovery owns a bounded quarter of the range, while durable queue
/// work owns the remainder. Keeping the phases on one scale prevents a completed identifier scan
/// from looking like a completed backup while uploads are still outstanding.
public enum PhotoLibraryBackupExecutionProgress {
    private static let scale: Int64 = 1_000_000
    private static let catalogWeight = 0.25

    public static func combined(
        catalog: BackupExecutionProgress?,
        queue: BackupExecutionProgress?,
        isScanning: Bool
    ) -> BackupExecutionProgress? {
        let catalogFraction = fraction(catalog)
        let queueFraction = fraction(queue)

        let combinedFraction: Double?
        switch (catalogFraction, queueFraction) {
        case (let catalog?, let queue?):
            combinedFraction = catalogWeight * catalog + (1 - catalogWeight) * queue
        case (let catalog?, nil):
            combinedFraction = isScanning ? catalogWeight * catalog : catalog
        case (nil, let queue?):
            combinedFraction = queue
        case (nil, nil):
            combinedFraction = nil
        }

        guard let combinedFraction else { return nil }
        return BackupExecutionProgress(
            completedUnitCount: Int64((combinedFraction * Double(scale)).rounded(.down)),
            totalUnitCount: scale
        )
    }

    private static func fraction(_ progress: BackupExecutionProgress?) -> Double? {
        guard let progress, progress.totalUnitCount > 0 else { return nil }
        return min(1, max(0, Double(progress.completedUnitCount) / Double(progress.totalUnitCount)))
    }
}
