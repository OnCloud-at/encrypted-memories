import Foundation
import MediaCache
import PhotosCore
import TimelineCore

/// Bridges the production timeline (`TimelineSection`/`PhotoItem` + the shared `ThumbnailFeed`) to the
/// Metal grid's `MetalGridDataSource`. Date markers come from `TimelineDateMarkers`. The production
/// timeline is delivered as a single ordered section, so a flat scan over its items is exact.
enum MetalGridProductionAdapter {
    @MainActor static func makeDataSource(
        sections: [TimelineSection],
        feed: ThumbnailFeed,
        metadataProvider: (any PhotoMetadataProvider)? = nil
    ) -> MetalGridDataSource {
        RealMetalGridDataSource(
            sections: sections,
            feed: feed,
            metadataProvider: metadataProvider
        )
    }

    /// Returns one localized marker for each month boundary.
    static func monthMarkers(sections: [TimelineSection]) -> [(index: Int, text: String)] {
        TimelineDateMarkers.markers(sections: sections, granularity: .month).map { ($0.index, $0.text) }
    }
}
