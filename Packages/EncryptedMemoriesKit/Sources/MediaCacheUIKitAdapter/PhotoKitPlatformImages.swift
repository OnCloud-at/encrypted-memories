#if canImport(UIKit)
    import CoreGraphics
    import Photos
    import UIKit

    /// PhotoKit image requests answered as `CGImage`, for the UI-free PhotoKit adapter.
    public enum PhotoKitPlatformImages {
        public static let request:
            @Sendable (
                PHAsset, CGSize, PHImageContentMode, PHImageRequestOptions, @escaping @Sendable (CGImage?) -> Void
            ) -> PHImageRequestID = { asset, targetSize, contentMode, options, resultHandler in
                PHImageManager.default().requestImage(
                    for: asset, targetSize: targetSize, contentMode: contentMode, options: options
                ) { image, _ in
                    resultHandler(image?.cgImage)
                }
            }
    }
#endif
