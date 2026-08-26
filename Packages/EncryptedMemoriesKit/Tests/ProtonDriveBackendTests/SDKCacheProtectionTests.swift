import Testing

@testable import ProtonDriveBackend

@Suite("SDK cache protection")
struct SDKCacheProtectionTests {
    @Test func keyIsStableAccountBoundAndExactly32Bytes() {
        let first = SDKCacheProtection.encryptionKey(accountUID: "account-a", keyPassword: "secret-a")

        #expect(first.count == 32)
        #expect(first == SDKCacheProtection.encryptionKey(accountUID: "account-a", keyPassword: "secret-a"))
        #expect(first != SDKCacheProtection.encryptionKey(accountUID: "account-b", keyPassword: "secret-a"))
        #expect(first != SDKCacheProtection.encryptionKey(accountUID: "account-a", keyPassword: "secret-b"))
    }

    @Test func fileNameIsAccountScopedAndVersioned() {
        #expect(SDKCacheProtection.fileName(accountUID: "uid-a") == "sdk-cache-v1-uid-a.sqlite")
        #expect(SDKCacheProtection.fileName(accountUID: "uid-a") != SDKCacheProtection.fileName(accountUID: "uid-b"))
    }
}
