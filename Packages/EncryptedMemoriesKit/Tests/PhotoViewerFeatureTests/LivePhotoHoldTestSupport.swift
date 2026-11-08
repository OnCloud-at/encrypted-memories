import AppKit

@testable import PhotoViewerFeature

@MainActor
final class LivePhotoHoldProbe {
    let press: AppKitLivePhotoHoldAdapter
    var calls: [String] = []

    var onStart: () -> Void { { [weak self] in self?.calls.append("start") } }
    var onStop: () -> Void { { [weak self] in self?.calls.append("stop") } }

    init(press: AppKitLivePhotoHoldAdapter? = nil, began: Bool = false) {
        self.press = press ?? AppKitLivePhotoHoldAdapter()
        self.press.updateCallbacks(start: onStart, stop: onStop)
        if began { self.press.consume(.began, at: .zero) }
    }

    func finishViewUpdates() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
