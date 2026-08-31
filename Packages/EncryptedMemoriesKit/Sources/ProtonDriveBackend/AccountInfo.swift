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
    private var activeAccountUID: String?

    init() {}

    /// Starts one account-owned publication generation. A late response from an older Drive session cannot
    /// repopulate Settings after sign-out or overwrite the replacement account.
    public func beginSession(accountUID: String) {
        guard activeAccountUID != accountUID else { return }
        activeAccountUID = accountUID
        clearSnapshot()
    }

    public func updateDriveStorage(usedBytes: Int64, maxBytes: Int64, accountUID: String) {
        guard activeAccountUID == accountUID else { return }
        driveUsedSpaceBytes = usedBytes
        driveMaxSpaceBytes = maxBytes
    }

    public func update(primaryEmail: String?, accountUID: String) {
        guard activeAccountUID == accountUID else { return }
        guard let primaryEmail, !primaryEmail.isEmpty else { return }
        self.primaryEmail = primaryEmail
    }

    /// Removes the last account snapshot immediately when an explicit sign-out begins.
    public func clear() {
        activeAccountUID = nil
        clearSnapshot()
    }

    private func clearSnapshot() {
        driveUsedSpaceBytes = nil
        driveMaxSpaceBytes = nil
        primaryEmail = nil
    }
}
