import ProtonCoreCryptoGoInterface
import Testing

@testable import ProtonDriveBackend

struct ProtonRuntimeTests {
    /// The hosts call `prepareProcess()` once at launch; ProtonCore's CryptoGo stays unset until then.
    /// The CryptoGo global cannot be reset and other tests in this target also inject it, so this test
    /// guards the call only when it runs alone (with a filter).
    @Test func preparingTheProcessWiresTheCryptoImplementation() {
        ProtonRuntime.prepareProcess()

        #expect(CryptoGo != nil)
    }
}
