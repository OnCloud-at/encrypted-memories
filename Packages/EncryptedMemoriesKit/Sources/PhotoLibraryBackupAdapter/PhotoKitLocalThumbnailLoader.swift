import CoreGraphics
import Foundation
import MediaDecodingCore
import MediaFeedCore
import Photos
import PhotosCore

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Grid thumbnails of pending Apple Photos assets, straight from PhotoKit. No Proton request and no
/// encrypted disk copy: PhotoKit already caches its own thumbnails. Network access is allowed so an
/// iCloud-optimized library still shows its photos.
public struct PhotoKitLocalThumbnailLoader: LocalThumbnailLoading {
    private static let maxConcurrentRequests = 4

    public init() {}

    public func thumbnails(for uids: [PhotoUID], maxPixelSize: CGFloat) async -> [PhotoUID: DecodedThumbnail] {
        let identifiers = uids.compactMap { uid -> String? in
            uid.localPendingNamespace == .photoLibrary ? uid.nodeID : nil
        }
        guard !identifiers.isEmpty else { return [:] }
        let assets = await Task.detached(priority: .userInitiated) { () -> [PHAsset] in
            let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            var assets: [PHAsset] = []
            assets.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in assets.append(asset) }
            return assets
        }.value
        let side = max(1, maxPixelSize)
        return await withTaskGroup(of: (PhotoUID, DecodedThumbnail?).self) { group in
            var result: [PhotoUID: DecodedThumbnail] = [:]
            var next = 0
            func addNext() {
                guard next < assets.count, !Task.isCancelled else { return }
                let asset = assets[next]
                next += 1
                group.addTask {
                    let image = await Self.image(for: asset, side: side)
                    return (PhotoUID(localPending: .photoLibrary, identifier: asset.localIdentifier), image)
                }
            }
            for _ in 0..<min(Self.maxConcurrentRequests, assets.count) { addNext() }
            for await (uid, image) in group {
                if let image { result[uid] = image }
                addNext()
            }
            return result
        }
    }

    private static func image(for asset: PHAsset, side: CGFloat) async -> DecodedThumbnail? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        return await PhotoKitRequest.perform { finish in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: side, height: side),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                // `.highQualityFormat` calls back exactly once.
                finish(image.flatMap(cgImage(from:)).map(DecodedThumbnail.init(image:)))
            }
        }
    }

    #if canImport(UIKit)
        private static func cgImage(from image: UIImage) -> CGImage? { image.cgImage }
    #elseif canImport(AppKit)
        private static func cgImage(from image: NSImage) -> CGImage? {
            image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
    #endif
}
