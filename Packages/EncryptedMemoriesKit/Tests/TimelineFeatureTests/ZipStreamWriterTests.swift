import Foundation
import PhotosCore
import Testing

struct ZipStreamWriterTests {
    /// Writes a real archive to /tmp so an external `unzip -t` can confirm it's a valid, extractable zip
    /// (the byte layout is what matters; this just exercises + leaves the artifact).
    @Test func writesAStoreZip() throws {
        let url = URL(fileURLWithPath: "/tmp/proton-ziptest.zip")
        try? FileManager.default.removeItem(at: url)
        let w = try ZipStreamWriter(url: url)
        try w.addFile(name: "hello.txt", data: Data("hello world".utf8))
        try w.addFile(name: "folder/blob.bin", data: Data((0..<200_000).map { UInt8($0 & 0xFF) }))
        try w.finish()
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func streamsFileEntryInBoundedChunks() throws {
        let archive = URL(fileURLWithPath: "/tmp/proton-ziptest-streamed.zip")
        let source = URL(fileURLWithPath: "/tmp/proton-ziptest-streamed.bin")
        defer {
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: source)
        }
        let bytes = Data((0..<2_000_000).map { UInt8($0 & 0xFF) })
        try bytes.write(to: source)
        try? FileManager.default.removeItem(at: archive)

        let writer = try ZipStreamWriter(url: archive)
        try writer.addFile(name: "streamed.bin", fileURL: source, bufferSize: 32_768)
        try writer.finish()

        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect((try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > bytes.count)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-t", archive.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0)
    }

    @Test func productionExportsUseBoundedFileTransferPath() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let mobile = try String(
            contentsOf: repo.appendingPathComponent("iOSApp/MobileSelectionSupport.swift"), encoding: .utf8
        )
        let mac = try String(
            contentsOf: repo.appendingPathComponent("App/Views/MainView.swift"), encoding: .utf8
        )
        let backend = try String(
            contentsOf: repo.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/DriveSDKBridge.swift"
            ),
            encoding: .utf8
        )

        #expect(mobile.contains("backend.writeOriginal(for: item.uid, to: staging)"))
        #expect(!mobile.contains("provider.originalData(for: item.uid)"))
        #expect(mac.contains("for: .itemReplacementDirectory"))
        #expect(mac.contains("appropriateFor: destination"))
        #expect(mac.contains("dest.startAccessingSecurityScopedResource()"))
        #expect(mac.contains("backend.writeOriginal(for: item.uid, to: stagedFile"))
        #expect(mac.contains("writer.addFile(name: uniqueName(base, used: &used), fileURL: sidecar)"))
        #expect(!mac.contains("destDir.appendingPathComponent(\".encryptedmemories-export-"))
        #expect(backend.contains("original file completed with verification warning"))
        #expect(!backend.contains("if let verificationIssue { throw verificationIssue }"))
        #expect(!mac.contains("export.verification_warning"))
        #expect(!mac.contains("private static func fetchOriginal"))
    }

    /// Known-answer test for the CRC-32 implementation (zip requires IEEE CRC-32).
    @Test func crc32MatchesKnownAnswer() {
        #expect(ZipStreamWriter.crc32(Data("hello world".utf8)) == 0x0D4A_1185)
        #expect(ZipStreamWriter.crc32(Data()) == 0)
    }
}
