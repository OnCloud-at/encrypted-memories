import Foundation
import ProtonDriveSDK

/// Bounded result of one SDK event enumeration. The callback stream can contain any number of
/// events, but the app retains only the cursor and the two invalidation conditions it must act on.
struct SDKEventCursorResult: Sendable, Equatable {
    let cursor: String?
    let requiresAuthoritativeRefresh: Bool
    let scopeAccessLost: Bool
}

enum SDKEventCursorError: LocalizedError {
    case missingCursor

    var errorDescription: String? {
        switch self {
        case .missingCursor:
            "The Proton Drive event enumeration completed without a cursor."
        }
    }
}

/// Thread-safe cursor reducer for the SDK's streamed event callback.
///
/// Cursor callbacks never write SQLite. `DriveSDKBridge` persists the final cursor only with the
/// timeline inventory after its convergence checks succeed.
final class SDKEventCursorAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var cursor: String?
    private var requiresAuthoritativeRefresh = false
    private var scopeAccessLost = false
    private var firstError: (any Error)?

    init(cursor: String?) {
        self.cursor = cursor
    }

    func receive(_ result: Result<SDKDriveEvent, any Error>) {
        lock.withLock {
            guard firstError == nil, !scopeAccessLost else { return }
            switch result {
            case .failure(let error):
                firstError = error
            case .success(let event):
                if requiresAuthoritativeRefresh {
                    // No later ordinary callback belongs to a committable chain after history continuity is
                    // lost. A later scope-loss event remains terminal and must still reach the host.
                    if case .scopeAccessLost = event.kind { scopeAccessLost = true }
                    return
                }
                switch event.kind {
                case .continuityLost:
                    // This event identifies an invalidated history boundary, not a cursor that can be paired
                    // with the current Photos inventory. Keep the last committable cursor and reseed separately.
                    requiresAuthoritativeRefresh = true
                case .scopeAccessLost:
                    // The terminal event invalidates this scope. Keep the last usable cursor only;
                    // callers must stop the monitor and must not persist this event's cursor.
                    scopeAccessLost = true
                case .nodeUpdated, .nodeDeleted, .sharedWithMeUpdated, .cursorAdvanced:
                    cursor = event.eventId
                }
            }
        }
    }

    func result() throws -> SDKEventCursorResult {
        try lock.withLock {
            if let firstError { throw firstError }
            if cursor == nil, !requiresAuthoritativeRefresh, !scopeAccessLost {
                throw SDKEventCursorError.missingCursor
            }
            return SDKEventCursorResult(
                cursor: cursor,
                requiresAuthoritativeRefresh: requiresAuthoritativeRefresh,
                scopeAccessLost: scopeAccessLost
            )
        }
    }
}
