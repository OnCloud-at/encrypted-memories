import Testing

@testable import ProtonDriveBackend

@Suite("Account info generation")
struct AccountInfoGenerationTests {
    @Test @MainActor func lateOldAccountUpdatesCannotRepopulateReplacementSettings() {
        let info = AccountInfo()
        info.beginSession(accountUID: "account-a")
        info.updateDriveStorage(usedBytes: 10, maxBytes: 100, accountUID: "account-a")
        info.update(primaryEmail: "a@example.test", accountUID: "account-a")

        info.beginSession(accountUID: "account-b")
        info.updateDriveStorage(usedBytes: 20, maxBytes: 200, accountUID: "account-a")
        info.update(primaryEmail: "stale@example.test", accountUID: "account-a")

        #expect(info.driveUsedSpaceBytes == nil)
        #expect(info.driveMaxSpaceBytes == nil)
        #expect(info.primaryEmail == nil)

        info.updateDriveStorage(usedBytes: 30, maxBytes: 300, accountUID: "account-b")
        info.update(primaryEmail: "b@example.test", accountUID: "account-b")
        #expect(info.driveUsedSpaceBytes == 30)
        #expect(info.driveMaxSpaceBytes == 300)
        #expect(info.primaryEmail == "b@example.test")

        info.clear()
        info.update(primaryEmail: "late@example.test", accountUID: "account-b")
        #expect(info.primaryEmail == nil)
    }
}
