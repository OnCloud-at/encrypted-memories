import Foundation
import ProtonCoreCryptoGoInterface

/// A parent key unlocked once for a run of links that ONE task works through, such as the links of a fetched chunk.
///
/// `DriveCrypto.unlockNode` and `decryptName` build a ring from the parent key on every call, and almost all of
/// their time is spent unlocking that key. Inside `DriveCrypto.withParentRing` the ring is built at the first use
/// and reused by the following links of the run. `DriveCrypto` still holds no shared mutable crypto state: the ring
/// belongs to the run, it is never stored in a property, and the scope clears it when the run ends, also when the
/// run throws or is cancelled. The class is not `Sendable`, but the compiler does not enforce that in the current
/// language mode (a probe that captured a ring in `Task { }` and in `group.addTask` gave no diagnostic), so the
/// rule that no other task takes the ring is held by four scope calls: index rows, unresolved name repair,
/// media-type names, and media-type order metadata. Each works through its links in one task.
///
/// The answers equal those of the per-call path: the same parent key value gives the same keys and the same errors.
/// A link whose passphrase or name does not decrypt throws its own error and leaves the ring usable for the next
/// link. A parent key that cannot be unlocked throws the same error for every link, like the per-call path.
final class DriveParentKeyRing {
    private let crypto: DriveCrypto
    private let parent: UnlockableKey
    private var built: Result<CryptoKeyRing, any Error>?
    /// True once the scope has cleared the ring; a later use throws.
    private var isCleared = false

    fileprivate init(crypto: DriveCrypto, parent: UnlockableKey) {
        self.crypto = crypto
        self.parent = parent
    }

    deinit { clear() }

    func unlockNode(key: String, passphrase: String) throws -> UnlockableKey {
        UnlockableKey(armored: key, passphrase: try decrypt(passphrase).getString())
    }

    func decryptName(_ armored: String) throws -> String {
        try decrypt(armored).getString()
    }

    private func decrypt(_ armored: String) throws -> CryptoPlainMessage {
        let ring = try parentRing()
        var error: NSError?
        guard let message = CryptoGo.CryptoNewPGPMessageFromArmored(armored, &error), error == nil else {
            throw DriveCryptoError.badMessage
        }
        return try ring.decrypt(message, verifyKey: nil, verifyTime: 0)
    }

    private func parentRing() throws -> CryptoKeyRing {
        guard !isCleared else { throw DriveCryptoError.keyRing }
        if built == nil {
            built = Result { try crypto.buildParentRing(crypto, parent) }
        }
        return try built!.get()
    }

    fileprivate func clear() {
        if case .success(let ring)? = built { crypto.clearParentRing(ring) }
        built = nil
        isCleared = true
    }
}

extension DriveCrypto {
    /// Runs `body` with a ring of `parent` that lives only for this call. Use it for the links that one task works
    /// through one after the other; never hand the ring to another task.
    func withParentRing<T>(_ parent: UnlockableKey, _ body: (DriveParentKeyRing) throws -> T) rethrows -> T {
        let ring = DriveParentKeyRing(crypto: self, parent: parent)
        defer { ring.clear() }
        return try body(ring)
    }

    /// The same for a run that suspends between links. Without a parent key there is no ring.
    func withOptionalParentRing<T>(
        _ parent: UnlockableKey?, isolation: isolated (any Actor)? = #isolation,
        _ body: (DriveParentKeyRing?) async throws -> T
    ) async rethrows -> T {
        guard let parent else { return try await body(nil) }
        let ring = DriveParentKeyRing(crypto: self, parent: parent)
        defer { ring.clear() }
        return try await body(ring)
    }
}
