import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ProtonDriveBackend

/// Uploaded thumbnails and previews are plain 8-bit SDR JPEGs that every Proton client shows correctly,
/// also one that ignores embedded colour profiles (#269).
@Suite("Upload thumbnail colour")
struct UploadMediaProcessorTests {
    private struct Source {
        let name: String
        let space: CGColorSpace
        let bitsPerComponent: Int
        let bitmapInfo: UInt32
    }

    private static let halfFloat =
        CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.floatComponents.rawValue
        | CGBitmapInfo.byteOrder16Little.rawValue
    private static let opaque8 = CGImageAlphaInfo.noneSkipLast.rawValue

    /// Sources whose colour space a viewer must understand to show the right colour: HDR photos (HLG, PQ),
    /// the BT.2020 frames that AVAssetImageGenerator returns for HDR videos, and linear light.
    private static let convertedSources: [Source] = [
        source("HLG", CGColorSpace.itur_2100_HLG, halfFloat: true),
        source("PQ", CGColorSpace.itur_2100_PQ, halfFloat: true),
        source("BT.2020", CGColorSpace.itur_2020, halfFloat: true),
        source("8-bit BT.2020", CGColorSpace.itur_2020, halfFloat: false),
        source("linear sRGB", CGColorSpace.extendedLinearSRGB, halfFloat: true),
    ]

    private static func source(_ name: String, _ spaceName: CFString, halfFloat: Bool) -> Source {
        Source(
            name: name,
            space: CGColorSpace(name: spaceName)!,
            bitsPerComponent: halfFloat ? 16 : 8,
            bitmapInfo: halfFloat ? Self.halfFloat : opaque8
        )
    }

    @Test(arguments: convertedSources.map(\.name))
    func hdrAndWideGamutSourcesUploadSRGBJPEGs(_ name: String) async throws {
        let source = try #require(Self.convertedSources.first { $0.name == name })
        let image = try Self.image(in: source)
        let thumbnails = try await Self.thumbnails(of: image)
        let expected = try Self.managedSRGBColor(of: image)
        #expect(thumbnails.count == 2)
        for thumbnail in thumbnails {
            let decoded = try Self.decode(thumbnail.data)
            #expect(decoded.bitsPerComponent == 8, "\(name) \(thumbnail.type)")
            #expect(decoded.colorSpace?.name == CGColorSpace.sRGB, "\(name) \(thumbnail.type)")
            // A viewer that ignores the embedded profile shows the raw bytes as sRGB.
            let shown = try Self.rawColor(of: decoded)
            #expect(Self.isClose(shown, expected), "\(name) \(thumbnail.type): shown \(shown), expected \(expected)")
        }
    }

    @Test func sRGBAndDisplayP3SourcesKeepTheirColourSpace() async throws {
        for (spaceName, sourceName) in [(CGColorSpace.sRGB, "sRGB"), (CGColorSpace.displayP3, "Display P3")] {
            let image = try Self.image(in: Self.source(sourceName, spaceName, halfFloat: false))
            let thumbnails = try await Self.thumbnails(of: image)
            let expected = try Self.managedSRGBColor(of: image)
            #expect(thumbnails.count == 2)
            for thumbnail in thumbnails {
                let decoded = try Self.decode(thumbnail.data)
                #expect(decoded.bitsPerComponent == 8, "\(sourceName) \(thumbnail.type)")
                #expect(decoded.colorSpace?.name == spaceName, "\(sourceName) \(thumbnail.type)")
                let shown = try Self.managedSRGBColor(of: decoded)
                #expect(Self.isClose(shown, expected), "\(sourceName) \(thumbnail.type): \(shown) vs \(expected)")
            }
        }
    }

    // MARK: - Helpers

    /// A 2,400 x 1,600 source of one colour, so the thumbnail is downscaled and the preview is not.
    private static func image(in source: Source) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil, width: 2_400, height: 1_600, bitsPerComponent: source.bitsPerComponent, bytesPerRow: 0,
                space: source.space, bitmapInfo: source.bitmapInfo))
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let red = try #require(CGColor(colorSpace: sRGB, components: [0.78, 0.18, 0.18, 1]))
        context.setFillColor(red)
        context.fill(CGRect(x: 0, y: 0, width: 2_400, height: 1_600))
        return try #require(context.makeImage())
    }

    /// Writes `image` as a TIFF with its colour profile and runs the production upload thumbnail path on it.
    private static func thumbnails(of image: CGImage) async throws -> [(type: String, data: Data)] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-thumbnail-colour-\(UUID().uuidString).tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return await UploadMediaProcessor.thumbnails(for: url, isVideo: false).map { ("\($0.type)", $0.data) }
    }

    private static func decode(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// The colour CoreGraphics shows for `image` on an sRGB display, as 8-bit components.
    private static func managedSRGBColor(of image: CGImage) throws -> [Int] {
        let context = try #require(
            CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: opaque8))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<3).map { Int(pixel[$0]) }
    }

    /// The stored 8-bit components of the centre pixel, without any colour conversion.
    private static func rawColor(of image: CGImage) throws -> [Int] {
        let bytes = try #require(image.dataProvider?.data) as Data
        let offset = (image.height / 2) * image.bytesPerRow + (image.width / 2) * (image.bitsPerPixel / 8)
        return (0..<3).map { Int(bytes[offset + $0]) }
    }

    private static func isClose(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        zip(lhs, rhs).allSatisfy { abs($0 - $1) <= 6 }
    }
}
