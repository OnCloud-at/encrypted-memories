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

    private func bytes(_ count: Int) -> Data {
        Data(repeating: 0x5a, count: count)
    }
}
