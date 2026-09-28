import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import PhotosCore
import UniformTypeIdentifiers
import XCTest

final class PrivacyExportPolicyTests: XCTestCase {
    func testRemoveLocationDefaultsOffAndReadsSavedPreference() throws {
        let suiteName = "PrivacyExportPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(PrivacyExportPolicy.isEnabled(defaults: defaults))
        defaults.set(true, forKey: AppSettingsKey.removeLocationWhenSharing)
        XCTAssertTrue(PrivacyExportPolicy.isEnabled(defaults: defaults))
        defaults.set(false, forKey: AppSettingsKey.removeLocationWhenSharing)
        XCTAssertFalse(PrivacyExportPolicy.isEnabled(defaults: defaults))
    }

    func testImageCopyDropsGPSWhileStoredOriginalKeepsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // iPhone photos are HEIC; both formats must lose their location and keep everything else.
        for type in [UTType.jpeg, UTType.heic] {
            let ext = try XCTUnwrap(type.preferredFilenameExtension)
            let original = directory.appendingPathComponent("original.\(ext)")
            let shared = directory.appendingPathComponent("shared.\(ext)")
            try makeGPSImage(at: original, type: type)
            let originalBytes = try Data(contentsOf: original)

            try await LocationSanitizedCopy.write(from: original, to: shared)

            XCTAssertNotNil(gpsProperties(at: original), ext)
            XCTAssertNil(gpsProperties(at: shared), ext)
            XCTAssertEqual(lensModel(at: shared), Self.lensModel, ext)
            XCTAssertEqual(try Data(contentsOf: original), originalBytes, ext)
        }
    }

    func testUnsupportedCopyFailsClosedWithoutWritingTheOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("unknown.bin")
        let shared = directory.appendingPathComponent("shared.bin")
        let bytes = Data("possible location metadata".utf8)
        try bytes.write(to: original)

        do {
            try await LocationSanitizedCopy.write(from: original, to: shared)
            XCTFail("Unknown formats must not leave the privacy gate with their bytes intact")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path))
            XCTAssertEqual(try Data(contentsOf: original), bytes)
        }
    }

    func testVideoCopyDropsLocationWhileStoredOriginalKeepsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.mov")
        let shared = directory.appendingPathComponent("shared.mov")
        try await makeGPSVideo(at: original)
        let originalBytes = try Data(contentsOf: original)

        try await LocationSanitizedCopy.write(from: original, to: shared)

        let originalHasLocation = try await hasVideoLocation(at: original)
        let sharedHasLocation = try await hasVideoLocation(at: shared)
        XCTAssertTrue(originalHasLocation)
        XCTAssertFalse(sharedHasLocation)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
    }

    /// A Live Photo pairs its still and its movie by this identifier; a copy without location must keep it.
    func testCopiesKeepTheLivePhotoPairingIdentifier() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let still = directory.appendingPathComponent("IMG_0001.heic")
        let movie = directory.appendingPathComponent("IMG_0001.mov")
        try makeGPSImage(at: still, type: .heic)
        try await makeGPSVideo(at: movie)
        let sharedStill = directory.appendingPathComponent("shared.heic")
        let sharedMovie = directory.appendingPathComponent("shared.mov")

        try await LocationSanitizedCopy.write(from: still, to: sharedStill)
        try await LocationSanitizedCopy.write(from: movie, to: sharedMovie)

        XCTAssertNil(gpsProperties(at: sharedStill))
        XCTAssertEqual(stillContentIdentifier(at: sharedStill), Self.livePhotoContentIdentifier)
        let sharedHasLocation = try await hasVideoLocation(at: sharedMovie)
        let sharedIdentifier = try await movieContentIdentifier(at: sharedMovie)
        XCTAssertFalse(sharedHasLocation)
        XCTAssertEqual(sharedIdentifier, Self.livePhotoContentIdentifier)
    }

    private static let livePhotoContentIdentifier = "6F1C1D2E-0000-4000-8000-00000000A11E"
    private static let lensModel = "Test lens"

    private func lensModel(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        else { return nil }
        return exif[kCGImagePropertyExifLensModel] as? String
    }

    private func stillContentIdentifier(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let apple = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
        else { return nil }
        return apple["17"] as? String
    }

    private func movieContentIdentifier(at url: URL) async throws -> String? {
        let metadata = try await AVURLAsset(url: url).load(.metadata)
        guard let item = metadata.first(where: { $0.identifier == .quickTimeMetadataContentIdentifier }) else {
            return nil
        }
        return try await item.load(.stringValue)
    }

    private func makeGPSImage(at url: URL, type: UTType = .jpeg) throws {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 12.25,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 45.5,
            kCGImagePropertyGPSLongitudeRef: "E",
        ]
        let apple: [String: Any] = ["17": Self.livePhotoContentIdentifier]
        CGImageDestinationAddImage(
            destination, image,
            [
                kCGImagePropertyGPSDictionary: gps, kCGImagePropertyMakerAppleDictionary: apple,
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: Self.lensModel],
            ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertNotNil(gpsProperties(at: url))
        XCTAssertEqual(stillContentIdentifier(at: url), Self.livePhotoContentIdentifier)
    }

    private func gpsProperties(at url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
    }

    private func makeGPSVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let location = AVMutableMetadataItem()
        location.identifier = .quickTimeMetadataLocationISO6709
        location.value = "+12.2500+045.5000/" as NSString
        let pairing = AVMutableMetadataItem()
        pairing.identifier = .quickTimeMetadataContentIdentifier
        pairing.value = Self.livePhotoContentIdentifier as NSString
        writer.metadata = [location, pairing]

        let width = 16
        let height = 16
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let pool = try XCTUnwrap(adaptor.pixelBufferPool)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer), kCVReturnSuccess)
        let frame = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        if let base = CVPixelBufferGetBaseAddress(frame) {
            memset(base, 0, CVPixelBufferGetDataSize(frame))
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        XCTAssertTrue(adaptor.append(frame, withPresentationTime: .zero))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let hasLocation = try await hasVideoLocation(at: url)
        XCTAssertTrue(hasLocation)
    }

    private func hasVideoLocation(at url: URL) async throws -> Bool {
        let metadata = try await AVURLAsset(url: url).load(.metadata)
        return metadata.contains { $0.identifier == .quickTimeMetadataLocationISO6709 }
    }
}
