import Foundation
import ProtonCoreCryptoGoInterface
import ProtonCoreCryptoPatchedGoImplementation
import Testing

@testable import ProtonDriveBackend

/// The parent ring of a run of links gives the answers of the per-call path, builds the parent key once, and is
/// cleared when the run ends.
@Suite(.serialized)
struct DriveParentKeyRingTests {
    private struct Fixture {
        let probe: ParentRingProbe
        let crypto: DriveCrypto
        let root: UnlockableKey
        let other: UnlockableKey
        /// Links that the root key can open, one that only the other key can open, and one that is no message.
        let passphrases: [String]
        let names: [String]
        let nodeKeys: [String]

        init(links: Int = 12) throws {
            injectDefaultCryptoImplementation()
            let probe = ParentRingProbe()
            self.probe = probe
            self.crypto = DriveCrypto(
                addressKeys: [], signers: [], buildParentRing: probe.build, clearParentRing: probe.clear)
            let crypto = DriveCrypto(addressKeys: [], signers: [])
            root = UnlockableKey(
                armored: try crypto.generateLockedNodeKey(passphrase: "root-pass"), passphrase: "root-pass")
            other = UnlockableKey(
                armored: try crypto.generateLockedNodeKey(passphrase: "other-pass"), passphrase: "other-pass")
            var passphrases: [String] = []
            var names: [String] = []
            var nodeKeys: [String] = []
            for index in 0..<links {
                let node = UnlockableKey(
                    armored: try crypto.generateLockedNodeKey(passphrase: "node-pass-\(index)"),
                    passphrase: "node-pass-\(index)")
                nodeKeys.append(node.armored)
                passphrases.append(try crypto.encrypt(text: node.passphrase, to: root))
                names.append(try crypto.encrypt(text: "IMG_\(index).HEIC", to: root))
            }
            // Index `links`: opens only with the other key. Index `links + 1`: not an armored message.
            nodeKeys.append(nodeKeys[0])
            passphrases.append(try crypto.encrypt(text: "foreign", to: other))
            names.append(try crypto.encrypt(text: "foreign.HEIC", to: other))
            nodeKeys.append(nodeKeys[0])
            passphrases.append("not an armored message")
            names.append("not an armored message")
            self.passphrases = passphrases
            self.names = names
            self.nodeKeys = nodeKeys
        }
    }

    /// What a call answers: the value, or the error in a form that two calls can be compared by.
    private enum Answer: Equatable {
        case value(String)
        case failure(String)

        init(_ operation: () throws -> String) {
            do { self = .value(try operation()) } catch { self = .failure(Self.describe(error)) }
        }

        private static func describe(_ error: any Error) -> String {
            let bridged = error as NSError
            return "\(type(of: error)) \(bridged.domain) \(bridged.code) \(String(describing: error))"
        }
    }

    private func packed(_ key: UnlockableKey) -> String { key.armored + "|" + key.passphrase }

    @Test func unlockNodeAnswersLikeThePerCallPathForEveryLinkIncludingFailures() throws {
        let fixture = try Fixture()
        let crypto = fixture.crypto

        crypto.withParentRing(fixture.root) { ring in
            for index in fixture.passphrases.indices {
                let expected = Answer {
                    packed(
                        try crypto.unlockNode(
                            key: fixture.nodeKeys[index], passphrase: fixture.passphrases[index], parent: fixture.root)
                    )
                }
                let actual = Answer {
                    packed(try ring.unlockNode(key: fixture.nodeKeys[index], passphrase: fixture.passphrases[index]))
                }
                #expect(actual == expected, "link \(index)")
            }
        }
    }

    @Test func decryptNameAnswersLikeThePerCallPathForEveryNameIncludingFailures() throws {
        let fixture = try Fixture()
        let crypto = fixture.crypto

        crypto.withParentRing(fixture.root) { ring in
            for (index, name) in fixture.names.enumerated() {
                let expected = Answer { try crypto.decryptName(name, parent: fixture.root) }
                let actual = Answer { try ring.decryptName(name) }
                #expect(actual == expected, "name \(index)")
            }
        }
    }

    @Test func aLinkThatDoesNotUnlockDoesNotPoisonTheLaterLinksOfTheRun() throws {
        let fixture = try Fixture(links: 3)
        let crypto = fixture.crypto
        let foreign = fixture.passphrases.count - 2
        let garbage = fixture.passphrases.count - 1

        crypto.withParentRing(fixture.root) { ring in
            #expect((try? ring.decryptName(fixture.names[0])) == "IMG_0.HEIC")
            #expect((try? ring.decryptName(fixture.names[foreign])) == nil)
            #expect((try? ring.decryptName(fixture.names[garbage])) == nil)
            #expect((try? ring.decryptName(fixture.names[1])) == "IMG_1.HEIC")
            #expect((try? ring.decryptName(fixture.names[foreign])) == nil)
            #expect((try? ring.decryptName(fixture.names[2])) == "IMG_2.HEIC")
        }
    }

    @Test func aParentKeyThatDoesNotUnlockFailsEveryLinkWithTheErrorOfThePerCallPath() throws {
        let fixture = try Fixture(links: 3)
        let crypto = fixture.crypto
        let broken = UnlockableKey(armored: fixture.root.armored, passphrase: "wrong passphrase")

        crypto.withParentRing(broken) { ring in
            for index in 0..<3 {
                let expected = Answer { try crypto.decryptName(fixture.names[index], parent: broken) }
                let actual = Answer { try ring.decryptName(fixture.names[index]) }
                guard case .failure = expected else {
                    Issue.record("the per-call path accepted a parent key with a wrong passphrase")
                    return
                }
                #expect(actual == expected, "name \(index)")
            }
            #expect(fixture.probe.builds == 1, "the failed unlock is kept, not retried for every link")
        }
    }

    @Test func theParentKeyIsUnlockedOnceForTheWholeRunAndEachRunHasItsOwnRing() throws {
        let fixture = try Fixture()
        let crypto = fixture.crypto
        var first: DriveParentKeyRing?
        var second: DriveParentKeyRing?

        crypto.withParentRing(fixture.root) { ring in
            first = ring
            #expect(fixture.probe.builds == 0, "nothing is unlocked before the first link")
            for name in fixture.names { _ = try? ring.decryptName(name) }
            #expect(fixture.probe.builds == 1)
        }
        crypto.withParentRing(fixture.root) { ring in
            second = ring
            _ = try? ring.decryptName(fixture.names[0])
            #expect(fixture.probe.builds == 2)
        }

        #expect(first !== second, "a run never reuses the ring of another run")
    }

    @Test func theRingIsClearedWhenTheRunEndsAndWhenItThrows() throws {
        struct Stop: Error {}
        let fixture = try Fixture(links: 2)
        let crypto = fixture.crypto
        var kept: [DriveParentKeyRing] = []

        crypto.withParentRing(fixture.root) { ring in
            kept.append(ring)
            _ = try? ring.decryptName(fixture.names[0])
        }
        #expect(throws: Stop.self) {
            try crypto.withParentRing(fixture.root) { ring in
                kept.append(ring)
                _ = try ring.decryptName(fixture.names[0])
                throw Stop()
            }
        }
        #expect(throws: CancellationError.self) {
            try crypto.withParentRing(fixture.root) { ring in
                kept.append(ring)
                _ = try ring.decryptName(fixture.names[0])
                throw CancellationError()
            }
        }

        #expect(
            kept.count == 3 && kept.allSatisfy { (try? $0.decryptName(fixture.names[0])) == nil },
            "every ring is cleared after its run")
        #expect(fixture.probe.clears == 3, "each unlocked ring is cleared once with clearPrivateParams")
        #expect((try? kept[0].decryptName(fixture.names[0])) == nil, "a cleared ring answers nothing")

        crypto.withParentRing(fixture.root) { _ in }
        #expect(fixture.probe.clears == 3, "a run that unlocked nothing has no key to clear")
    }

    @Test func theAsyncRunClearsTheRingAfterAThrowAndAfterCancellation() async throws {
        struct Stop: Error {}
        let fixture = try Fixture(links: 2)
        let crypto = fixture.crypto
        let kept = KeptRings()

        await #expect(throws: Stop.self) {
            try await crypto.withOptionalParentRing(fixture.root) { ring in
                kept.append(ring)
                await Task.yield()
                _ = try ring?.decryptName(fixture.names[0])
                throw Stop()
            }
        }
        let task = Task {
            try await crypto.withOptionalParentRing(fixture.root) { ring in
                kept.append(ring)
                _ = try ring?.decryptName(fixture.names[0])
                try await Task.sleep(for: .seconds(30))
            }
        }
        while kept.count < 2 { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await crypto.withOptionalParentRing(nil) { ring in
            #expect(ring == nil, "without a parent key there is no ring")
        }

        let rings = kept.rings
        #expect(
            rings.count == 2
                && rings.allSatisfy { ring in
                    guard let ring else { return false }
                    return (try? ring.decryptName(fixture.names[0])) == nil
                })
        #expect(fixture.probe.clears == 2, "each unlocked ring is cleared once with clearPrivateParams")
    }

    /// The rings that the runs handed to their bodies, recorded under a lock.
    private final class KeptRings: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [DriveParentKeyRing?] = []
        var count: Int { lock.withLock { kept.count } }
        var rings: [DriveParentKeyRing?] { lock.withLock { kept } }
        func append(_ ring: DriveParentKeyRing?) { lock.withLock { kept.append(ring) } }
    }
}

final class ParentRingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var buildCount = 0
    private var clearCount = 0
    var builds: Int { lock.withLock { buildCount } }
    var clears: Int { lock.withLock { clearCount } }

    func build(_ crypto: DriveCrypto, _ key: UnlockableKey) throws -> CryptoKeyRing {
        lock.withLock { buildCount += 1 }
        return try crypto.ring([key])
    }

    func clear(_ ring: CryptoKeyRing) {
        ring.clearPrivateParams()
        lock.withLock { clearCount += 1 }
    }
}
