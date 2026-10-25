import CoreGraphics
import SwiftUI
import Testing

@testable import DesignSystemCore

@Suite struct ProtonLoadingViewTests {
    private static let caption = "Building your library…"

    @MainActor @Test func aCaptionIsDrawnBelowTheSpinner() throws {
        let plain = try Self.inkPixels(ProtonLoadingView())
        let captioned = try Self.inkPixels(ProtonLoadingView(caption: Self.caption))
        // The caption is a line of text: it adds well over a hundred dark pixels and nothing else changes.
        #expect(captioned - plain > 100)
    }

    @MainActor @Test func aLongerCaptionDrawsMoreOfIt() throws {
        let short = try Self.inkPixels(ProtonLoadingView(caption: "Signing out…"))
        let long = try Self.inkPixels(ProtonLoadingView(caption: "Signing out of every window…"))
        #expect(long > short)
    }

    /// Renders the view on white in the light scheme and counts the pixels that are not white.
    @MainActor private static func inkPixels<V: View>(_ view: V) throws -> Int {
        let framed =
            view
            .frame(width: 320, height: 200)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        try #require(drawn)
        return stride(from: 0, to: bytes.count, by: 4).reduce(0) { count, offset in
            count + (bytes[offset] < 200 || bytes[offset + 1] < 200 || bytes[offset + 2] < 200 ? 1 : 0)
        }
    }
}
