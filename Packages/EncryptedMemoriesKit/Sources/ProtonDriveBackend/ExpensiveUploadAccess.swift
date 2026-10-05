import Foundation

/// Lets the system refuse backup upload bytes on cellular data and Personal Hotspot.
///
/// The SDK sends the requests of every upload through one HTTP client and does not say which upload a request
/// serves. The client therefore asks this count: an upload request may use an expensive network unless every
/// running upload must avoid it. An upload that the person starts keeps the expensive network for all uploads
/// while it runs; the backup's own check before each transfer still holds new backup uploads.
final class ExpensiveUploadAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var restrictedUploads = 0
    private var unrestrictedUploads = 0

    /// Registers one running upload. Call `end(allowsExpensiveNetwork:)` with the same value when it settles.
    func begin(allowsExpensiveNetwork: Bool) {
        lock.withLock {
            if allowsExpensiveNetwork { unrestrictedUploads += 1 } else { restrictedUploads += 1 }
        }
    }

    func end(allowsExpensiveNetwork: Bool) {
        lock.withLock {
            if allowsExpensiveNetwork {
                unrestrictedUploads = max(0, unrestrictedUploads - 1)
            } else {
                restrictedUploads = max(0, restrictedUploads - 1)
            }
        }
    }

    /// The value for `URLRequest.allowsExpensiveNetworkAccess` of an upload request.
    var allowsExpensiveNetworkAccess: Bool {
        lock.withLock { restrictedUploads == 0 || unrestrictedUploads > 0 }
    }
}
