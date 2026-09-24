import PhotosCore
import UIKit
import VisionKit
import os

/// On-device Live Text for the photo viewer. Only text and machine-readable codes are requested. Visual Look Up and
/// subject lifting stay off, so recognizing text never sends image content to a service.
@MainActor
enum MobileLiveText {
    /// Symbol of the viewer action that shows or hides the recognized text.
    static let systemImage = "text.viewfinder"

    /// Grid thumbnails are too small for reliable text; the viewer analyzes its sharper display image instead.
    static let minimumLongestPixelSide: CGFloat = 1_024

    private static let analyzer = ImageAnalyzer()
    private static let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])

    static func isUsable(_ image: UIImage) -> Bool {
        max(image.size.width, image.size.height) * image.scale >= minimumLongestPixelSide
    }

    /// Analyzes one displayed still. Returns `nil` when the device has no Live Text support, the analysis fails,
    /// or the image contains neither text nor a code.
    static func analyze(_ image: UIImage) async -> ImageAnalysis? {
        guard ImageAnalyzer.isSupported else { return nil }
        do {
            let analysis = try await analyzer.analyze(
                image, orientation: image.imageOrientation, configuration: configuration)
            return analysis.hasResults(for: [.text, .machineReadableCode]) ? analysis : nil
        } catch {
            if MobileViewerLog.isEnabled, !(error is CancellationError) {
                MobileViewerLog.logger.notice("[LiveText] analysis unavailable")
            }
            return nil
        }
    }
}

/// Restarts Live Text when the page becomes current or its displayed image changes.
struct MobileLiveTextTaskID: Equatable {
    let uid: PhotoUID
    let isCurrent: Bool
    let image: ObjectIdentifier?
}
