import CoreML
import Foundation
import Vision

enum AppleVisionComputePolicy {
    struct UnavailableInBackground: Error {}

    /// Never let a background request fall back silently to GPU. A request with no CPU path
    /// remains pending for foreground execution; that is not an unsupported feature or bad photo.
    static func prepare<Request: VisionRequest>(
        _ original: Request,
        requiresCPUOnly: Bool = CoreMLComputePolicy.requiresCPUOnly
    ) throws -> Request {
        try Task.checkCancellation()
        guard requiresCPUOnly else { return original }
        var request = original
        let supported = request.supportedComputeStageDevices
        guard !supported.isEmpty else { throw UnavailableInBackground() }
        for (stage, devices) in supported {
            guard
                let cpu = devices.first(where: {
                    if case .cpu = $0 { return true }
                    return false
                })
            else { throw UnavailableInBackground() }
            request.setComputeDevice(cpu, for: stage)
        }
        return request
    }
}
