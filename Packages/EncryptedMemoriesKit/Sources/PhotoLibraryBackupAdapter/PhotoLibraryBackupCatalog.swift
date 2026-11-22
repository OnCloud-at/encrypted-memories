import Foundation
import Photos
import UploadCore

/// Photo-library source for the shared backup engine: streams `UploadBackupAssetCandidate`s from
/// a cheap metadata-only enumeration (no resource bytes are touched). Newest-first so the first
/// backup pass delivers user-visible value immediately; remote timeline placement still follows
/// capture time, which travels on each upload.
public struct PhotoLibraryBackupCatalog: UploadBackupAssetCatalog {
    /// nil = whole library; otherwise a targeted incremental scan (persistent-change results).
    public let localIdentifiers: [String]?
    /// Assets handed to the mapper per autorelease drain - bounds transient PhotoKit memory.
    public let chunkSize: Int

    public init(localIdentifiers: [String]? = nil, chunkSize: Int = 200) {
        self.localIdentifiers = localIdentifiers
        self.chunkSize = max(1, chunkSize)
    }

    public func candidates() -> AsyncThrowingStream<UploadBackupAssetCandidate, any Error> {
        let identifiers = localIdentifiers
        return ChunkedAssetStream.make(
            chunkSize: chunkSize,
            open: { PhotoKitAssetMapper.fetchAssets(identifiers: identifiers) },
            count: { $0.count },
            emit: { fetchResult, range, continuation in
                let assets = range.map { fetchResult.object(at: $0) }
                for info in PhotoKitAssetMapper.infos(for: assets) {
                    if let candidate = PhotoBackupAssetPlanner.candidate(for: info) {
                        continuation.yield(candidate)
                    }
                }
            })
    }
}
