import AVFoundation
import Foundation
import Testing

@testable import UploadCore

struct InternetDateParserTests {
    private let parser = InternetDateParser()

    @Test func parserAndCaptureDateReaderKeepTheSamePinnedResults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fallback = Date(timeIntervalSince1970: 1)
        let seedURL = directory.appendingPathComponent("seed.mov")
        let seed = try #require(Data(base64Encoded: Self.tinyMovie, options: .ignoreUnknownCharacters))
        try seed.write(to: seedURL)
        let seedAsset = AVURLAsset(url: seedURL)
        let rows: [(String, TimeInterval?)] = [
            ("2026-01-02T03:04:05Z", 1_767_323_045),
            ("2026-01-02T03:04:05.250Z", 1_767_323_045.25),
            ("2026-01-02T03:04:05.1234567Z", 1_767_323_045.123),
            ("2026-01-02T03:04:05z", 1_767_323_045),
            ("2026-01-02T03:04:05", nil),
            ("2026-01-02 03:04:05Z", nil),
            ("2026-01-02T23:59:60Z", nil),
            ("2026-01-02T04:04:05+0100", 1_767_323_045),
            (" 2026-01-02T03:04:05Z", 1_767_323_045),
            ("2026-01-02T03:04:05Z ", 1_767_323_045),
            ("2026-01-02T04:04:05+01:00", 1_767_323_045),
            ("2026-01-02T04:04:05.250+01:00", 1_767_323_045.25),
            ("2026-01-01T22:04:05-05:00", 1_767_323_045),
            ("", nil), ("yesterday", nil), ("2026-01-02", nil),
        ]
        for (index, row) in rows.enumerated() {
            let expected = row.1.map(Date.init(timeIntervalSince1970:))
            #expect(parser.date(from: row.0) == expected, "parser: \(row.0)")
            let url = directory.appendingPathComponent("iso-\(index).mov")
            let exporter = try #require(
                AVAssetExportSession(asset: seedAsset, presetName: AVAssetExportPresetPassthrough))
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataCreationDate
            item.value = row.0 as NSString
            exporter.metadata = [item]
            try await exporter.export(to: url, as: .mov)
            let metadata = try await AVURLAsset(url: url).load(.metadata)
            let stored = try #require(metadata.first { $0.identifier == .quickTimeMetadataCreationDate })
            let storedValue = try await stored.load(.stringValue)
            #expect(storedValue == row.0, "stored: \(row.0)")
            let actual = await UploadCaptureDateReader.captureDate(for: url, fallback: fallback)
            #expect(actual == (expected ?? fallback), "capture date: \(row.0)")
        }
    }

    /// One black frame. AVFoundation adds each creation-date metadata value for the real reader path.
    private static let tinyMovie = """
        AAAAFGZ0eXBxdCAgAAACAHF0ICAAAALrbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAA+gAAQAAAQAAAAAAAAAAAAAAAAEA
        AAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAld0cmFrAAAAXHRr
        aGQAAAADAAAAAAAAAAAAAAABAAAAAAAAA+gAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABA
        AAAAABAAAAAQAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAPoAAAAAAABAAAAAAHPbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAA
        AABAAAAAQAB//wAAAAAALWhkbHIAAAAAbWhscnZpZGUAAAAAAAAAAAAAAAAMVmlkZW9IYW5kbGVyAAABem1pbmYAAAAUdm1oZAAA
        AAEAAAAAAAAAAAAAACxoZGxyAAAAAGRobHJ1cmwgAAAAAAAAAAAAAAAAC0RhdGFIYW5kbGVyAAAAJGRpbmYAAAAcZHJlZgAAAAAA
        AAABAAAADHVybCAAAAABAAABDnN0YmwAAACqc3RzZAAAAAAAAAABAAAAmmF2YzEAAAAAAAAAAQAAAABGRk1QAAACAAAAAgAAEAAQ
        AEgAAABIAAAAAAAAAAEUTGF2YzYzLjEuMTAyIGxpYngyNjQAAAAAAAAAAAAAAAAY//8AAAA0YXZjQwFkAAr/4QAXZ2QACqzZXsBE
        AAADAAQAAAMACDxIllgBAAZo6+PLIsD9+PgAAAAAEHBhc3AAAAABAAAAAQAAABhzdHRzAAAAAAAAAAEAAAABAABAAAAAABxzdHNj
        AAAAAAAAAAEAAAABAAAAAQAAAAEAAAAUc3RzegAAAAAAAALFAAAAAQAAABRzdGNvAAAAAAAAAAEAAAMPAAAAIHVkdGEAAAAYqXN3
        cgAMVcRMYXZmNjMuMS4xMDIAAAAId2lkZQAAAs1tZGF0AAACrQYF//+p3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSBy
        MzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlk
        ZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTEgcmVmPTMgZGVibG9jaz0xOjA6MCBhbmFseXNlPTB4MzoweDEx
        MyBtZT1oZXggc3VibWU9NyBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0xIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0x
        IHRyZWxsaXM9MSA4eDhkY3Q9MSBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0tMiB0
        aHJlYWRzPTEgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAg
        Ymx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0zIGJfcHlyYW1pZD0yIGJfYWRhcHQ9MSBiX2JpYXM9
        MCBkaXJlY3Q9MSB3ZWlnaHRiPTEgb3Blbl9nb3A9MCB3ZWlnaHRwPTIga2V5aW50PTI1MCBrZXlpbnRfbWluPTEgc2NlbmVjdXQ9
        NDAgaW50cmFfcmVmcmVzaD0wIHJjX2xvb2thaGVhZD00MCByYz1jcmYgbWJ0cmVlPTEgY3JmPTIzLjAgcWNvbXA9MC42MCBxcG1p
        bj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MToxLjAwAIAAAAAQZYiEABX//vfJ78Cm69vfgQ==
        """
}
