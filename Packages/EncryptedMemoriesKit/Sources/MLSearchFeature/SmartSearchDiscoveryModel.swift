import Foundation
import MLSearchCore
import Observation
import PhotosCore
import TimelineCore

/// Library-aware search suggestions shared by the iOS search landing and the macOS search menu.
///
/// Stages run off the main actor and check cancellation:
/// 1. The sensitive gate, when visual search can answer. It fails closed: if it cannot complete, no suggestion
///    carries a preview and no visual concept is offered.
/// 2. Metadata families (dates, trips, seasons, favorites, media types), published immediately.
/// 3. Places from the existing location index, named by the host-provided resolver.
/// 4. Curated visual concepts.
/// Gate and concept evidence are cached per library revision, model and coarse indexing progress, so a
/// cancelled refresh (for example when the user starts typing) resumes cheaply.
@MainActor
@Observable
public final class SmartSearchDiscoveryModel {
    public typealias PlaceNameResolver = @Sendable (_ latitude: Double, _ longitude: Double) async -> String?

    public private(set) var forYou: [TimelineSearchSuggestion] = []
    public private(set) var chips: [TimelineSearchSuggestion] = []
    public private(set) var hasComputed = false
    /// Visual search is on but still indexing, so concept suggestions can still appear.
    public private(set) var showsIndexingNote = false
    /// No on-device analysis is enabled, so only metadata suggestions exist.
    public private(set) var showsSmartSearchHint = false

    @ObservationIgnored private let placeName: PlaceNameResolver
    @ObservationIgnored private var metadata = TimelineSearchDiscoveryResult()
    @ObservationIgnored private var places: [TimelineSearchSuggestion] = []
    @ObservationIgnored private var concepts: [TimelineSearchSuggestion] = []
    @ObservationIgnored private var placeNames: [String: String] = [:]
    @ObservationIgnored private var gateKey: String?
    @ObservationIgnored private var sensitiveUIDs: Set<PhotoUID> = []
    @ObservationIgnored private var conceptKey: String?
    @ObservationIgnored private var conceptEvidence: [MLSearchConceptEvidence] = []

    public init(placeName: @escaping PlaceNameResolver) {
        self.placeName = placeName
    }

    /// A short text list for menu-style hosts: the most specific rows first, then media types.
    public func textSuggestions(limit: Int = 8) -> [TimelineSearchSuggestion] {
        Array((forYou + chips).prefix(limit))
    }

    /// The structured suggestion whose title the search text still shows, if any.
    public func structuredSuggestion(owning text: String) -> TimelineSearchSuggestion? {
        (forYou + chips).first { $0.matchingUIDs != nil && $0.owns(searchText: text) }
    }

    /// Identity of every input that can change the suggestions. Hosts restart `refresh` when it changes.
    public static func revisionKey(
        timelineRevision: UInt64,
        favoriteCount: Int,
        coordinateCount: Int,
        snapshot: MLSmartSearchSnapshot?,
        now: Date = Date()
    ) -> String {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: now) ?? 0
        return [
            "\(timelineRevision)",
            "\(favoriteCount)",
            "\(coordinateCount / 250)",
            "\(snapshot?.isEnabled == true)",
            "\(snapshot?.isVisualSearchEnabled == true)",
            snapshot?.selectedModelID.map { "\($0)" } ?? "-",
            indexingBucket(snapshot),
            "\(day)",
        ].joined(separator: "|")
    }

    /// Coarse indexing progress: evidence is recomputed at most once per 10 % of coverage gained.
    private static func indexingBucket(_ snapshot: MLSmartSearchSnapshot?) -> String {
        switch snapshot?.indexingState {
        case .indexing(let progress), .waiting(let progress):
            "i\(Int((progress.fraction ?? 0) * 10))"
        case .ready: "r"
        default: "-"
        }
    }

    public func refresh(
        sections: [TimelineSection],
        timelineRevision: UInt64,
        favoriteUIDs: Set<PhotoUID>,
        coordinates: [PhotoCoordinate],
        smartSearch: MLSmartSearchController?
    ) async {
        let snapshot = smartSearch?.snapshot
        let lifecycle = smartSearch?.lifecycleActor
        showsSmartSearchHint = snapshot?.isEnabled != true
        showsIndexingNote = {
            guard snapshot?.isVisualSearchEnabled == true else { return false }
            switch snapshot?.indexingState {
            case .indexing, .waiting: return true
            default: return false
            }
        }()

        // Stage 1: the sensitive gate must finish before any preview is chosen.
        var covered = 0
        var gatePassed = true
        if snapshot?.isVisualSearchEnabled == true, let lifecycle {
            covered = await lifecycle.semanticIndexedAssetCount()
            guard !Task.isCancelled else { return }
            if covered > 0 {
                let key = evidenceKey(timelineRevision: timelineRevision, snapshot: snapshot)
                if gateKey != key {
                    do {
                        sensitiveUIDs = try await MLSearchConceptDiscovery.sensitiveUIDs { prompt, limit in
                            try await lifecycle.search(prompt, limit: limit, intent: .automatic).results.map(\.uid)
                        }
                        gateKey = key
                    } catch {
                        guard !Task.isCancelled else { return }
                        gatePassed = false
                        sensitiveUIDs = []
                        gateKey = nil
                    }
                }
            }
        } else {
            sensitiveUIDs = []
            gateKey = nil
        }
        let context = TimelineSearchDiscoveryContext(
            favoriteUIDs: favoriteUIDs,
            excludedRepresentativeUIDs: sensitiveUIDs,
            suppressesRepresentatives: !gatePassed
        )

        // Stage 2: metadata. It needs no network and no further ML.
        metadata = await Task.detached(priority: .utility) {
            TimelineSearchDiscovery.librarySuggestions(sections: sections, context: context)
        }.value
        guard !Task.isCancelled else { return }
        publish()

        // Stage 3: places. Only centroids of photo clusters are named.
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
        for candidate in candidates where placeNames[candidate.id] == nil {
            guard !Task.isCancelled else { return }
            if let name = await placeName(candidate.latitude, candidate.longitude) {
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
                context: context
            )
        }.value
        guard !Task.isCancelled else { return }
        publish()

        // Stage 4: curated visual concepts, only behind a passed gate.
        guard gatePassed, covered > 0, let lifecycle else {
            concepts = []
            conceptEvidence = []
            conceptKey = nil
            publish()
            return
        }
        let key = evidenceKey(timelineRevision: timelineRevision, snapshot: snapshot)
        if conceptKey != key {
            let sensitive = sensitiveUIDs
            let evidence = await MLSearchConceptDiscovery.evaluate(
                coveredAssetCount: covered,
                sensitiveUIDs: sensitive
            ) { prompt, limit in
                try await lifecycle.search(prompt, limit: limit, intent: .automatic).results.map(\.uid)
            }
            guard !Task.isCancelled else { return }
            conceptEvidence = evidence
            conceptKey = key
        }
        let evidence = conceptEvidence
        concepts = await Task.detached(priority: .utility) {
            evidence.map { entry in
                let matches = entry.rankedUIDs.compactMap { itemsByUID[$0] }
                // The best-ranked matches make the most convincing previews.
                let previews = TimelineSearchDiscovery.representatives(
                    for: Array(matches.prefix(12)),
                    context: context
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

    private func evidenceKey(timelineRevision: UInt64, snapshot: MLSmartSearchSnapshot?) -> String {
        [
            "\(timelineRevision)",
            snapshot?.selectedModelID.map { "\($0)" } ?? "-",
            Self.indexingBucket(snapshot),
        ].joined(separator: "|")
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
