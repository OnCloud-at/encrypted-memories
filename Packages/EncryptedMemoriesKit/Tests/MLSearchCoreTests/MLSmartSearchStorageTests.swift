import Foundation
import Testing

@testable import MLSearchCore

@Suite struct MLSmartSearchStorageTests {
    @Test func oneRefreshClassifiesSQLiteSidecarsModelsPartialsAndOtherData() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLSmartSearchStorageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        try FileManager.default.createDirectory(at: layout.modelsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layout.temporaryDirectory, withIntermediateDirectories: true)

        try bytes(10).write(to: layout.derivedIndexDatabaseURL)
        try bytes(3).write(to: URL(fileURLWithPath: layout.derivedIndexDatabaseURL.path + "-wal"))
        try bytes(7).write(to: layout.indexDatabaseURL)
        try bytes(2).write(to: URL(fileURLWithPath: layout.indexDatabaseURL.path + "-shm"))
        try bytes(11).write(to: layout.modelsDirectory.appendingPathComponent("weights.bin"))
        try bytes(5).write(to: layout.temporaryDirectory.appendingPathComponent("partial.download"))
        try bytes(4).write(to: layout.stateFileURL)

        let result = await MLSmartSearchStorageMeter(layout: layout).measure()

        #expect(result.appleVisionIndexBytes == 13)
        #expect(result.semanticVectorIndexBytes == 9)
        #expect(result.installedVisualModelsBytes == 11)
        #expect(result.partialModelDownloadsBytes == 5)
        #expect(result.otherMLDataBytes == 4)
        #expect(result.totalBytes == 42)
        #expect(layout.derivedIndexDatabaseFileURLs.count == 3)
    }

    @Test func countsModelPackageContentsWithoutFollowingSymbolicLinks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLSmartSearchStorageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let compiledWeights = layout.modelsDirectory.appendingPathComponent("visual.mlmodelc/weights/weight.bin")
        let packageWeights = layout.modelsDirectory.appendingPathComponent("text.mlpackage/Data/weights.bin")
        for url in [compiledWeights, packageWeights] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try bytes(17).write(to: compiledWeights)
        try bytes(23).write(to: packageWeights)
        try FileManager.default.createSymbolicLink(
            at: layout.modelsDirectory.appendingPathComponent("alias.mlmodelc"),
            withDestinationURL: compiledWeights.deletingLastPathComponent().deletingLastPathComponent()
        )

        let result = await MLSmartSearchStorageMeter(layout: layout).measure()

        #expect(result.installedVisualModelsBytes == 40)
        #expect(result.totalBytes == 40)
    }

    private func bytes(_ count: Int) -> Data {
        Data(repeating: 0x5a, count: count)
    }
}
