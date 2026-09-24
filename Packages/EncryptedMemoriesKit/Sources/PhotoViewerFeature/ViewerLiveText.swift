import AppKit
import PhotosCore
import VisionKit

/// On-device Live Text for the Mac viewer. Only text and machine-readable codes are requested. Visual Look Up and
/// subject lifting stay off, so recognizing text never sends image content to a service.
@MainActor
enum ViewerLiveText {
    /// Symbol of the viewer action that shows or hides the recognized text.
    static let systemImage = "text.viewfinder"

    private static let analyzer = ImageAnalyzer()

    /// Analyzes one displayed still. Returns `nil` when the Mac has no Live Text support, the analysis fails, or the
    /// image contains neither text nor a code.
    static func analyze(_ image: NSImage) async -> ImageAnalysis? {
        guard ImageAnalyzer.isSupported else { return nil }
        // A fresh configuration per request: the value is not Sendable, so it cannot live in shared state.
        let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])
        guard
            let analysis = try? await analyzer.analyze(image, orientation: .up, configuration: configuration),
            analysis.hasResults(for: [.text, .machineReadableCode])
        else { return nil }
        return analysis
    }
}

/// Restarts Live Text when the photo, its displayed image, or its sharpness changes.
struct ViewerLiveTextTaskID: Equatable {
    let uid: PhotoUID
    let image: ObjectIdentifier
    let isSharp: Bool
}
