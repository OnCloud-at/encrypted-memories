import Foundation
import MetricKit
import PhotosCore

/// Local-only MetricKit bridge. TestFlight/App Store own collection; Encrypted Memories records only
/// aggregate payload counts for an explicit support export and never forwards payload contents.
final class MobileMetricKitCollector: NSObject, MXMetricManagerSubscriber {
    static let shared = MobileMetricKitCollector()

    private let lock = NSLock()
    private var installed = false

    func install() {
        let shouldInstall = lock.withLock { () -> Bool in
            guard !installed else { return false }
            installed = true
            return true
        }
        guard shouldInstall else { return }
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        PhotoDiagnostics.shared.increment("metrickit.metricPayloads", by: payloads.count)
        PhotoDiagnostics.shared.emit("MetricKit", ["metricPayloads": "\(payloads.count)"])
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        PhotoDiagnostics.shared.increment("metrickit.diagnosticPayloads", by: payloads.count)
        PhotoDiagnostics.shared.emit("MetricKit", ["diagnosticPayloads": "\(payloads.count)"])
    }
}
