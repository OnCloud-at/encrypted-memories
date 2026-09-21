import Foundation
import MLSearchCore
import MapUIKitAdapter
import PhotosCore
import TimelineCore

/// Library-aware search suggestions for the iOS search landing.
///
/// Families are published in stages so the landing is never blank: metadata first (dates, trips, media types),
/// then places from the existing location index, then curated visual concepts when visual search is ready.
/// Every stage runs off the main actor, checks cancellation and is cached per library revision.
@MainActor
@Observable
final class MobileSearchDiscoveryModel {
    private(set) var forYou: [TimelineSearchSuggestion] = []
    private(set) var chips: [TimelineSearchSuggestion] = []
    private(set) var hasComputed = false
    /// Visual search is on but still indexing, so concept suggestions can still appear.
    private(set) var showsIndexingNote = false
    /// No on-device analysis is enabled, so only metadata suggestions exist.
    private(set) var showsSmartSearchHint = false

    @ObservationIgnored private var metadata = TimelineSearchDiscoveryResult()
    @ObservationIgnored private var places: [TimelineSearchSuggestion] = []
    @ObservationIgnored private var concepts: [TimelineSearchSuggestion] = []
    @ObservationIgnored private var placeNames: [String: String] = [:]
    @ObservationIgnored private var conceptCacheKey: String?
    @ObservationIgnored private var conceptResult = MLSearchConceptDiscoveryResult(evidence: [], sensitiveUIDs: [])

    /// Identity of every input that can change the suggestions. The host restarts `refresh` when it changes.
    static func revisionKey(libraryModel: MobileLibraryModel, now: Date = Date()) -> String {
        let snapshot = libraryModel.smartSearch?.snapshot
        let day = Calendar.current.ordinality(of: .day, in: .era, for: now) ?? 0
        let coordinateBucket = libraryModel.locationIndex.coordinates.count / 250
        let indexing = indexingBucket(snapshot)
        return [
            "\(libraryModel.timelineRevision)",
            "\(libraryModel.favoriteUIDs.count)",
            "\(coordinateBucket)",
            "\(snapshot?.isEnabled == true)",
            "\(snapshot?.isVisualSearchEnabled == true)",
            snapshot?.selectedModelID.map { "\($0)" } ?? "-",
            indexing,
            "\(day)",
        ].joined(separator: "|")
    }

    /// Coarse indexing progress: concept evidence is recomputed at most once per 10 % of coverage gained.
    private static func indexingBucket(_ snapshot: MLSmartSearchSnapshot?) -> String {
        switch snapshot?.indexingState {
        case .indexing(let progress), .waiting(let progress):
            "i\(Int((progress.fraction ?? 0) * 10))"
        case .ready: "r"
        default: "-"
        }
    }

    func refresh(libraryModel: MobileLibraryModel) async {
        let sections = libraryModel.sections
        let favoriteUIDs = libraryModel.favoriteUIDs
        let coordinates = libraryModel.locationIndex.coordinates
        let snapshot = libraryModel.smartSearch?.snapshot
        let lifecycle = libraryModel.smartSearch?.lifecycleActor
        let timelineRevision = libraryModel.timelineRevision

        showsSmartSearchHint = snapshot?.isEnabled != true
        showsIndexingNote = {
            guard snapshot?.isVisualSearchEnabled == true else { return false }
            switch snapshot?.indexingState {
            case .indexing, .waiting: return true
            default: return false
            }
        }()

        // Stage 1: metadata. It needs no network and no ML, so it publishes immediately.
        let baseContext = TimelineSearchDiscoveryContext(
            favoriteUIDs: favoriteUIDs,
            excludedRepresentativeUIDs: conceptResult.sensitiveUIDs
        )
        let metadataResult = await Task.detached(priority: .utility) {
            TimelineSearchDiscovery.librarySuggestions(sections: sections, context: baseContext)
        }.value
        guard !Task.isCancelled else { return }
        metadata = metadataResult
        publish()

        // Stage 2: places. Only centroids of photo clusters are named, and only when the location index
        // already has coordinates (the Map tab owns the crawl).
        let itemsByUID = await Task.detached(priority: .utility) {
            var index: [PhotoUID: PhotoItem] = [:]
            for section in sections {
                for item in section.items { index[item.uid] = item }
            }
            return index
        }.value
        guard !Task.isCancelled else { return }
        let candidates = await Task.detached(priority: .utility) {
            TimelineSearchDiscovery.placeCandidates(coordinates: coordinates)
        }.value
        guard !Task.isCancelled else { return }
        for candidate in candidates where placeNames[candidate.id] == nil {
            guard !Task.isCancelled else { return }
            if let name = await NativePlaceNameResolver.shared.cityName(
                latitude: candidate.latitude,
                longitude: candidate.longitude
            ) {
                placeNames[candidate.id] = name
            }
        }
        guard !Task.isCancelled else { return }
        let names = placeNames
        places = await Task.detached(priority: .utility) {
            TimelineSearchDiscovery.placeSuggestions(
                candidates: candidates,
                names: names,
                itemsByUID: itemsByUID,
                context: baseContext
            )
        }.value
        guard !Task.isCancelled else { return }
        publish()

        // Stage 3: curated visual concepts, only when the visual model can answer.
        guard snapshot?.isVisualSearchEnabled == true, let lifecycle else {
            concepts = []
            conceptResult = MLSearchConceptDiscoveryResult(evidence: [], sensitiveUIDs: [])
            conceptCacheKey = nil
            publish()
            return
        }
        let covered = await lifecycle.semanticIndexedAssetCount()
        guard covered > 0, !Task.isCancelled else { return }
        let key = [
            "\(timelineRevision)",
            snapshot?.selectedModelID.map { "\($0)" } ?? "-",
            Self.indexingBucket(snapshot),
        ].joined(separator: "|")
        if conceptCacheKey != key {
            let result = await MLSearchConceptDiscovery.evaluate(coveredAssetCount: covered) { prompt, limit in
                try await lifecycle.search(prompt, limit: limit, intent: .automatic).results.map(\.uid)
            }
            guard !Task.isCancelled else { return }
            conceptResult = result
            conceptCacheKey = key
        }
        let evidence = conceptResult.evidence
        let conceptContext = TimelineSearchDiscoveryContext(
            favoriteUIDs: favoriteUIDs,
            excludedRepresentativeUIDs: conceptResult.sensitiveUIDs
        )
        concepts = await Task.detached(priority: .utility) {
            evidence.map { entry in
                let matches = entry.rankedUIDs.compactMap { itemsByUID[$0] }
                // The best-ranked matches make the most convincing previews.
                let previews = TimelineSearchDiscovery.representatives(
                    for: Array(matches.prefix(12)),
                    context: conceptContext
                )
                return TimelineSearchSuggestion(
                    id: "concept:\(entry.concept.id)",
                    query: entry.concept.title,
                    title: entry.concept.title,
                    subtitle: TimelineSearchDiscovery.countText(matches.count),
                    systemImage: entry.concept.systemImage,
                    kind: .concept,
                    matchingUIDs: Set(matches.map(\.uid)),
                    representativeUIDs: previews
                )
            }
        }.value
        guard !Task.isCancelled else { return }
        publish()
    }

    private func publish() {
        // Concepts lead when they exist: they are the most library-specific signal. Places and anniversaries
        // follow, then trips, seasons and favorites.
        let byKind = Dictionary(grouping: metadata.forYou, by: \.kind)
        forYou = TimelineSearchDiscovery.rankForYou(
            [
                concepts,
                places,
                byKind[.onThisDay] ?? [],
                byKind[.trip] ?? [],
                byKind[.season] ?? [],
                byKind[.favorites] ?? [],
            ],
            limit: 10,
            perKind: 3
        )
        chips = metadata.chips
        hasComputed = true
    }
}
