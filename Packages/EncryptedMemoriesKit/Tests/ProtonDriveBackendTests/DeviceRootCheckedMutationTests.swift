import Foundation
import Testing

@testable import ProtonDriveBackend

private actor PausedRootLookup {
    private var lookupContinuation: CheckedContinuation<Int, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private(set) var mutations = 0

    func lookup() async -> Int {
        await withCheckedContinuation { continuation in
            lookupContinuation = continuation
            enteredContinuation?.resume()
            enteredContinuation = nil
        }
    }

    func waitUntilEntered() async {
        if lookupContinuation != nil { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func release() {
        lookupContinuation?.resume(returning: 1)
        lookupContinuation = nil
    }

    func mutate(_ root: Int) -> Int {
        mutations += 1
        return root
    }
}

@Suite("Device root remote mutation boundary")
struct DeviceRootCheckedMutationTests {
    @Test func cancellationDuringLookupDoesNotStartFolderCreation() async {
        let probe = PausedRootLookup()
        let task = Task {
            try await DeviceRootCheckedMutation.afterLookup(
                lookup: { await probe.lookup() },
                mutate: { await probe.mutate($0) })
        }
        await probe.waitUntilEntered()
        task.cancel()
        await probe.release()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await probe.mutations == 0)
    }
}
