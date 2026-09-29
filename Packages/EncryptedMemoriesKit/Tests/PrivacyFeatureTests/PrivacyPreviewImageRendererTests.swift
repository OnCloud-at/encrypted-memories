import CoreGraphics
import PrivacyFeature
import XCTest

final class PrivacyPreviewImageRendererTests: XCTestCase {
    @MainActor func testBlurSoftensEdgesAndPreservesBroadContrastAndBrightness() throws {
        let source = try makeImage { context in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
        }
        let result = try XCTUnwrap(PrivacyPreviewImageRenderer.render(source))
        let original = try pixels(source)
        let blurred = try pixels(result)
        XCTAssertEqual(result.width, source.width)
        XCTAssertEqual(result.height, source.height)
        func brightness(_ bytes: [UInt8], x: Int) -> Double { Double(bytes[(100 * 200 + x) * 4]) / 255 }
        XCTAssertGreaterThan(brightness(original, x: 90) - brightness(original, x: 110), 0.95)
        XCTAssertLessThan(brightness(blurred, x: 90) - brightness(blurred, x: 110), 0.75)
        XCTAssertGreaterThan(brightness(blurred, x: 25) - brightness(blurred, x: 175), 0.9)
        let average =
            stride(from: 0, to: blurred.count, by: 4).reduce(0.0) { $0 + Double(blurred[$1]) / 255 }
            / Double(result.width * result.height)
        XCTAssertEqual(average, 0.5, accuracy: 0.05)
        XCTAssertTrue(stride(from: 3, to: blurred.count, by: 4).allSatisfy { blurred[$0] == 255 })
    }

    @MainActor func testBlurDoesNotAddAWhiteOrBlackTintToColor() throws {
        let source = try makeImage { context in
            context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        }
        let original = try pixels(source)
        let blurred = try pixels(XCTUnwrap(PrivacyPreviewImageRenderer.render(source)))
        for offset in [0, (100 * 200 + 100) * 4, (200 * 200 - 1) * 4] {
            for channel in 0..<4 {
                XCTAssertEqual(Double(blurred[offset + channel]), Double(original[offset + channel]), accuracy: 2)
            }
        }
    }

    private func makeImage(draw: (CGContext) -> Void) throws -> CGImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(context)
        return try XCTUnwrap(context.makeImage())
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(
                CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
