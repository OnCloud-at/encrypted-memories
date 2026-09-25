import AppKit
import CoreGraphics
import Photos

/// PhotoKit image requests answered as `CGImage`, for the UI-free PhotoKit adapter.
public enum PhotoKitPlatformImages {
    public static let request:
        @Sendable (
            PHAsset, CGSize, PHImageContentMode, PHImageRequestOptions, @escaping @Sendable (CGImage?, Bool) -> Void
        ) -> PHImageRequestID = { asset, targetSize, contentMode, options, resultHandler in
            PHImageManager.default().requestImage(
                for: asset, targetSize: targetSize, contentMode: contentMode, options: options
            ) { image, info in
                resultHandler(
                    image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                    (info?[PHImageResultIsDegradedKey] as? Bool) == true)
            }
        }
}
