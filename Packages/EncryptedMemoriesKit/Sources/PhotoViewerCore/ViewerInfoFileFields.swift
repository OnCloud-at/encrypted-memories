import Foundation
import PhotosCore

/// The file rows of the viewer's Info, with one set of guards on every platform. A field that fails its guard is nil
/// and its row stays out.
public struct ViewerInfoFileFields {
    /// The file name, when it is not empty.
    public let filename: String?
    /// "<width> × <height> (<megapixels> MP)", when both sides are above 0.
    public let dimensions: String?
    /// The size in bytes, when it is 0 or more.
    public let fileSize: Int64?
    /// The capture device, when it is not empty.
    public let device: String?
    /// "m:ss" from metadata, else the item; nil unless the value is positive, finite and below Int.max.
    public let duration: String?

    public init(metadata: PhotoMetadata, fallbackDuration: Double?) {
        filename = metadata.filename.flatMap { $0.isEmpty ? nil : $0 }
        if let width = metadata.pixelWidth, let height = metadata.pixelHeight, width > 0, height > 0 {
            let megapixels = String(format: "%.1f", (Double(width) * Double(height)) / 1_000_000)
            dimensions = "\(width) × \(height) (\(megapixels) MP)"
        } else {
            dimensions = nil
        }
        fileSize = metadata.fileSize.flatMap { $0 >= 0 ? Int64($0) : nil }
        device = metadata.device.flatMap { $0.isEmpty ? nil : $0 }
        let total =
            PhotoDuration.roundedSeconds(metadata.durationSeconds) ?? PhotoDuration.roundedSeconds(fallbackDuration)
        if let total {
            duration = String(format: "%d:%02d", total / 60, total % 60)
        } else {
            duration = nil
        }
    }

    /// Uses the metadata type when present, then the item's type.
    public static func mediaType(mimeType: String?, fallback: String?) -> String? {
        if let mimeType, !mimeType.isEmpty { return mimeType }
        return fallback.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The capture date and time formats of the viewer's Info on every platform.
public enum ViewerInfoCaptureFormat {
    public static let date = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide).year()
    public static let time = Date.FormatStyle.dateTime.hour().minute()
}
