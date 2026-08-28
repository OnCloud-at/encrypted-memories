import CoreMotion
import Foundation
import Observation

/// Feeds the shared confetti overlay with the device's current left/right attitude.
@MainActor
@Observable
final class MobileConfettiMotion {
    static let shared = MobileConfettiMotion()

    private let manager = CMMotionManager()
    private let updatesQueue: OperationQueue
    private var isRunning = false

    private(set) var horizontalBias: CGFloat = 0

    init() {
        let queue = OperationQueue()
        queue.name = "at.oncloud.encryptedmemories.confetti-motion"
        queue.qualityOfService = .userInteractive
        queue.maxConcurrentOperationCount = 1
        updatesQueue = queue
    }

    func start() {
        guard !isRunning, manager.isDeviceMotionAvailable else { return }

        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        isRunning = true
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: updatesQueue) { [weak self] motion, _ in
            guard let roll = motion?.attitude.roll else { return }
            Task { @MainActor [weak self] in
                self?.apply(roll: roll)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        manager.stopDeviceMotionUpdates()
        isRunning = false
        horizontalBias = 0
    }

    private func apply(roll: Double) {
        guard isRunning else { return }
        let normalizedRoll = CGFloat(max(-1, min(1, roll / (Double.pi / 4))))
        horizontalBias = horizontalBias * 0.84 + normalizedRoll * 0.16
    }
}
