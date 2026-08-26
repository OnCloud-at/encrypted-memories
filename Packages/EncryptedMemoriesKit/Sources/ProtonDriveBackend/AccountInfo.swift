import Foundation
import Observation

/// Account info surfaced in Settings: the Drive-specific storage quota and the primary address. Populated from
/// the `/core/v4/users` + `/addresses` responses that `DriveSession.fetchAccountData()` already fetches (and
/// caches), so it's available offline too (last-known values from the encrypted account cache). No extra
/// network call.
@MainActor
@Observable
public final class AccountInfo {
    public static let shared = AccountInfo()

    public private(set) var driveUsedSpaceBytes: Int64?
    public private(set) var driveMaxSpaceBytes: Int64?
    /// The account's primary email address, shown in the Settings account section. Nil until the address list
    /// has been decoded (live or cached).
    public private(set) var primaryEmail: String?

    private init() {}

    public func updateDriveStorage(usedBytes: Int64, maxBytes: Int64) {
        driveUsedSpaceBytes = usedBytes
        driveMaxSpaceBytes = maxBytes
    }

    public func update(primaryEmail: String?) {
        guard let primaryEmail, !primaryEmail.isEmpty else { return }
        self.primaryEmail = primaryEmail
    }

    /// Removes the last account snapshot immediately when an explicit sign-out begins.
    public func clear() {
        driveUsedSpaceBytes = nil
        driveMaxSpaceBytes = nil
        primaryEmail = nil
    }
}
