import CryptoKit
import Foundation
import Testing

@testable import MLSearchAppleAdapter
@testable import MLSearchCore

@Suite struct MLSearchSuggestionCacheTests {
    private let descriptor = MLModelDescriptor(identifier: "fixture", version: 1, embeddingDimension: 3)

    private func identity(generation: UInt64 = 5, revision: String = "r1") -> MLSearchSuggestionCacheIdentity {
        MLSearchSuggestionCacheIdentity(
            descriptor: descriptor, modelRevision: revision, indexGeneration: generation, visualSearchEnabled: true)
    }

    private func cache(
        _ root: URL, account: String = "account", password: String = "fixture-password"
    ) -> MLSearchSuggestionCache {
        MLSearchSuggestionCache(
            layout: MLModelInstallLayout(rootDirectory: root), accountIdentifier: account,
            cipher: CryptoKitMLDerivedDataCipher(
                keys: MLSearchKeyDerivation.localDerivedDataKeys(accountUID: account, keyPassword: password)))
    }

    @Test func completedSnapshotSurvivesAStoreRecreationWithoutPlaintext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("private suggestion title and checked image membership".utf8)
        try cache(root).save(data, identity: identity())
        let disk = try Data(contentsOf: root.appendingPathComponent("suggestions-v1.enc"))
        #expect(disk.range(of: data) == nil)
        #expect(try cache(root).load(identity: identity()) == data)
        #expect(try cache(root).load(identity: identity(generation: 6)) == nil)
        #expect(try cache(root).load(identity: identity(revision: "r2")) == nil)
        #expect(throws: (any Error).self) { try cache(root, account: "other").load(identity: identity()) }
        #expect(throws: (any Error).self) { try cache(root, password: "other").load(identity: identity()) }
    }

    @Test func corruptOrPurgedCacheCannotRestorePrivateRows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = cache(root)
        try store.save(Data("snapshot".utf8), identity: identity())
        let url = root.appendingPathComponent("suggestions-v1.enc")
        var data = try Data(contentsOf: url)
        data[data.count / 2] ^= 1
        try data.write(to: url)
        #expect(throws: (any Error).self) { try store.load(identity: identity()) }
        try FileManager.default.removeItem(at: root)
        #expect(try cache(root).load(identity: identity()) == nil)
    }

    @Test func cancelledSaveKeepsThePreviousCompleteFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = cache(root)
        let stamp = identity()
        let original = Data("completed".utf8)
        try store.save(original, identity: stamp)
        let writer = Task {
            while !Task.isCancelled { await Task.yield() }
            try store.save(Data("cancelled".utf8), identity: stamp)
        }
        writer.cancel()
        do {
            try await writer.value
            Issue.record("cancelled cache write succeeded")
        } catch is CancellationError {}
        #expect(try store.load(identity: stamp) == original)
    }
}
