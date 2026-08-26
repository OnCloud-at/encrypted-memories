import Foundation
import ImageIO
import MediaByteCache
import MediaCache
import MediaDecodingCore
import PhotosCore
import TimelineCore

/// One progressively loaded temporal-cover image and whether it can fill the
/// rendered card without interpolation above its native pixel dimensions.
public struct TimelineTemporalCoverImageCandidate: Sendable {
    public let decoded: DecodedThumbnail
    public let fillsTargetWithoutUpscaling: Bool

    public init(decoded: DecodedThumbnail, fillsTargetWithoutUpscaling: Bool) {
        self.decoded = decoded
        self.fillsTargetWithoutUpscaling = fillsTargetWithoutUpscaling
    }
}

/// Loads the higher-quality stages for macOS Years and Months cards.
///
/// The grid thumbnail remains the instant first frame. This loader then reads the
/// encrypted preview cache or Proton preview. It fetches an original only when the
/// preview's real pixel dimensions cannot fill the rendered card on the current
/// display. Original bytes stay in RAM unless an existing encrypted offline-cache
/// entry is already available.
public actor TimelineTemporalCoverImageLoader {
    private let media: any FullMediaProvider
    private let previewCache: ThumbnailCache?
    private let previewSessionLease: CacheWriterGeneration.SessionToken?
    private let originalProvider: EncryptedOriginalProvider

    public init(
        media: any FullMediaProvider,
        previewCache: ThumbnailCache? = nil,
        originalsCache: ThumbnailCache? = nil
    ) {
        self.media = media
        self.previewCache = previewCache
        self.previewSessionLease = previewCache?.captureSessionLease()
        self.originalProvider = EncryptedOriginalProvider(
            media: media,
            cache: originalsCache,
            policy: .readOnly
        )
    }

    public func previewCandidate(
        for item: PhotoItem,
        targetPixelSize: TimelineTemporalPixelSize
    ) async -> TimelineTemporalCoverImageCandidate? {
        guard !item.isVideo, !Task.isCancelled,
            let data = await previewData(for: item.uid),
            !Task.isCancelled
        else { return nil }

        return Self.candidate(from: data, targetPixelSize: targetPixelSize)
    }

    public func originalCandidate(
        for item: PhotoItem,
        targetPixelSize: TimelineTemporalPixelSize
    ) async -> TimelineTemporalCoverImageCandidate? {
        guard !item.isVideo, !Task.isCancelled,
            let data = try? await originalProvider.originalData(for: item.uid),
            !Task.isCancelled
        else { return nil }

        return Self.candidate(from: data, targetPixelSize: targetPixelSize)
    }

    private func previewData(for uid: PhotoUID) async -> Data? {
        guard previewSessionIsCurrent() else { return nil }

        if let previewCache {
            let readGeneration = previewCache.captureWriterGeneration()
            let cached = await Task.detached(priority: .userInitiated) { () -> Data? in
                guard previewCache.isCurrentWriterGeneration(readGeneration) else { return nil }
                return previewCache.diskData(for: uid)
            }.value
            if let cached,
                previewSessionIsCurrent(),
                previewCache.isCurrentWriterGeneration(readGeneration)
            {
                _ = previewCache.touch(uid, ifCurrent: readGeneration)
                return cached
            }
        }

        let writeGeneration = previewCache?.captureWriterGeneration()
        guard let data = try? await media.preview(for: uid),
            !Task.isCancelled,
            previewSessionIsCurrent()
        else { return nil }

        if let previewCache, let writeGeneration {
            _ = await Task.detached(priority: .utility) {
                previewCache.storeToDisk(data, for: uid, ifCurrent: writeGeneration)
            }.value
            guard previewSessionIsCurrent(),
                previewCache.isCurrentWriterGeneration(writeGeneration)
            else { return nil }
        }
        return data
    }

    private func previewSessionIsCurrent() -> Bool {
        guard let previewCache, let previewSessionLease else { return true }
        return previewCache.isCurrentSessionLease(previewSessionLease)
    }

    private nonisolated static func candidate(
        from data: Data,
        targetPixelSize: TimelineTemporalPixelSize
    ) -> TimelineTemporalCoverImageCandidate? {
        guard let sourceSize = sourcePixelSize(data) else { return nil }
        let fills = TimelineTemporalCoverResolutionPolicy.sourceFillsTargetWithoutUpscaling(
            source: sourceSize,
            target: targetPixelSize
        )
        let decodeEdge = TimelineTemporalCoverResolutionPolicy.requiredDecodeLongestEdge(
            source: sourceSize,
            target: targetPixelSize
        )
        guard
            let decoded = ThumbnailImageDecoder.downsample(
                data,
                maxPixelSize: CGFloat(decodeEdge)
            )
        else { return nil }
        return TimelineTemporalCoverImageCandidate(
            decoded: decoded,
            fillsTargetWithoutUpscaling: fills
        )
    }

    private nonisolated static func sourcePixelSize(_ data: Data) -> TimelineTemporalPixelSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let swapsAxes = (5...8).contains(orientation)
        return TimelineTemporalPixelSize(
            width: swapsAxes ? height : width,
            height: swapsAxes ? width : height
        )
    }
}
