import CoreGraphics

/// Returns a channel swizzle only when verbatim upload preserves pixel values. Callers use normalization
/// for resampling, color conversion, alpha conversion, or unsupported formats.
package enum CGImageDirectUpload {
    /// Maps an output channel to a stored source channel.
    /// `one` supplies opaque alpha for skip-alpha formats.
    package enum Channel: Equatable, Sendable {
        case red, green, blue, alpha, one
    }

    /// Maps stored bytes to sampled RGBA channels.
    package struct Swizzle: Equatable, Sendable {
        package let red: Channel
        package let green: Channel
        package let blue: Channel
        package let alpha: Channel

        package init(red: Channel, green: Channel, blue: Channel, alpha: Channel) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        package static let identity = Swizzle(red: .red, green: .green, blue: .blue, alpha: .alpha)
        package var isIdentity: Bool { self == .identity }
    }

    /// Returns a safe direct-upload swizzle or `nil` when normalization is required.
    ///
    /// - Parameters:
    ///   - colorSpaceModel: `image.colorSpace?.model` (`.rgb` required).
    ///   - colorSpacePassesThroughDeviceRGB: Whether conversion to Device RGB preserves the pixel values.
    package static func swizzle(
        bitsPerComponent: Int,
        bitsPerPixel: Int,
        alphaInfo: CGImageAlphaInfo,
        byteOrder: CGImageByteOrderInfo,
        isFloat: Bool,
        colorSpaceModel: CGColorSpaceModel,
        colorSpacePassesThroughDeviceRGB: Bool,
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ) -> Swizzle? {
        // Direct upload cannot resample.
        guard sourceWidth == targetWidth, sourceHeight == targetHeight else { return nil }
        // Only 8-bit, 32bpp, non-float RGB maps onto rgba8Unorm.
        guard bitsPerComponent == 8, bitsPerPixel == 32, !isFloat else { return nil }
        guard colorSpaceModel == .rgb, colorSpacePassesThroughDeviceRGB else { return nil }
        // Direct upload supports only defined 32-bit byte orders.
        switch byteOrder {
        case .orderDefault, .order32Big, .order32Little: break
        default: return nil
        }

        // Straight alpha requires normalization because the renderer expects premultiplied alpha.
        let opaque: Bool  // A skip byte must sample as opaque alpha.
        let alphaFirst: Bool  // The logical order is ARGB when true and RGBA when false.
        switch alphaInfo {
        case .premultipliedLast:
            opaque = false
            alphaFirst = false
        case .premultipliedFirst:
            opaque = false
            alphaFirst = true
        case .noneSkipLast:
            opaque = true
            alphaFirst = false
        case .noneSkipFirst:
            opaque = true
            alphaFirst = true
        default: return nil  // Normalize unsupported alpha layouts.
        }

        // In-memory byte positions (index 0 = lowest address = the texture's `.red` channel, 1 = `.green`,
        // 2 = `.blue`, 3 = `.alpha`). The logical component order is serialized big-endian for
        // default/32Big (as written) and reversed for 32Little.
        let logical: [Symbol] = alphaFirst ? [.a, .r, .g, .b] : [.r, .g, .b, .a]
        let memory: [Symbol] = (byteOrder == .order32Little) ? logical.reversed() : logical

        func storedChannel(of symbol: Symbol) -> Channel {
            switch memory.firstIndex(of: symbol)! {
            case 0: return .red
            case 1: return .green
            case 2: return .blue
            default: return .alpha
            }
        }

        return Swizzle(
            red: storedChannel(of: .r),
            green: storedChannel(of: .g),
            blue: storedChannel(of: .b),
            alpha: opaque ? .one : storedChannel(of: .a)
        )
    }

    private enum Symbol { case r, g, b, a }
}

#if canImport(CoreGraphics)
    extension CGImageDirectUpload {
        /// Extracts bitmap properties from an image and returns its direct-upload swizzle.
        package static func swizzle(for image: CGImage, targetWidth: Int, targetHeight: Int) -> Swizzle? {
            guard let colorSpace = image.colorSpace else { return nil }
            let byteOrder = image.byteOrderInfo
            let isFloat = image.bitmapInfo.contains(.floatComponents)
            return swizzle(
                bitsPerComponent: image.bitsPerComponent,
                bitsPerPixel: image.bitsPerPixel,
                alphaInfo: image.alphaInfo,
                byteOrder: byteOrder,
                isFloat: isFloat,
                colorSpaceModel: colorSpace.model,
                colorSpacePassesThroughDeviceRGB: colorSpacePassesThroughDeviceRGB(colorSpace),
                sourceWidth: image.width,
                sourceHeight: image.height,
                targetWidth: targetWidth,
                targetHeight: targetHeight
            )
        }

        /// Returns whether Device RGB conversion preserves the source pixel values.
        private static func colorSpacePassesThroughDeviceRGB(_ colorSpace: CGColorSpace) -> Bool {
            if CFEqual(colorSpace, deviceRGB) { return true }
            if let sRGB = sRGB, CFEqual(colorSpace, sRGB) { return true }
            return false
        }

        private static let deviceRGB = CGColorSpaceCreateDeviceRGB()
        private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
    }
#endif
