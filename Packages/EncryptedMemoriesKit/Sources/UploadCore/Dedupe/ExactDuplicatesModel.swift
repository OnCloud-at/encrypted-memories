import Foundation
import Observation
import PhotosCore

/// The reads and the merge that the Duplicates screens need. `ExactDuplicateFinder` serves the signed-in account;
/// tests and the offline UI-test account supply their own.
public protocol ExactDuplicateMerging: Sendable {
    /// The groups, read from the content index. Reports how many candidate photos the visibility read covered.
    func duplicateGroups(
        progress: @escaping @Sendable (ExactDuplicateScanProgress) async -> Void
    ) async throws -> ExactDuplicateScan
    /// Builds the content index when none exists, or brings it up to date, and reports the progress of the build.
    /// True when the index changed.
    func prepareIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws -> Bool
    /// The members of each group in an order that needs no request.
    func fallbackMembers(of groups: [ExactDuplicateGroup]) async -> [String: [PhotoUID]]
    /// The capture dates of `members` that the device already knows, without a request. Unknown photos are left out.
    func captureDates(of members: [PhotoUID]) async -> [PhotoUID: Date]
    /// Ranks the members of each group, page by page. A group whose facts cannot be read is not in its page.
    func rankMembers(
        of groups: [ExactDuplicateGroup], ranked: @escaping @Sendable (ExactDuplicateRankingPage) async -> Void
    ) async
    /// Merges each group, keeping its photo. One result for each group, in order. After a cancellation, the groups
    /// without an outcome fail with `CancellationError`.
    func merge(
        _ requests: [(group: ExactDuplicateGroup, kept: PhotoUID)]
    ) async -> [Result<ExactDuplicateMergeOutcome, any Error>]
}

extension ExactDuplicateFinder: ExactDuplicateMerging {}

extension ExactDuplicateMerging {
    /// Without a local timeline, no date is known.
    public func captureDates(of members: [PhotoUID]) async -> [PhotoUID: Date] { [:] }
}

/// A fact of one copy that the screens show as a small badge, in the order of the ranking.
public enum ExactDuplicateBadge: CaseIterable, Equatable, Sendable {
    case shared
    /// In one of the person's own albums.
    case album
    case favorite
    /// A local source of this device counts the copy as its backup.
    case backedUpHere

    /// The spoken name of the badge.
    public var title: String {
        switch self {
        case .shared: L10n.string("duplicates.badge_shared")
        case .album: L10n.string("duplicates.badge_album")
        case .favorite: L10n.string("duplicates.badge_favorite")
        case .backedUpHere: L10n.string("duplicates.badge_backed_up_here")
        }
    }

    func applies(to facts: ExactDuplicateKeepFacts) -> Bool {
        switch self {
        case .shared: facts.isShared
        case .album: facts.isInOwnAlbum
        case .favorite: facts.isFavorite
        case .backedUpHere: facts.isNamedByManifest
        }
    }
}

/// Why the copy that a merge keeps stays instead of another copy.
public enum ExactDuplicateStayReason: Equatable, Sendable {
    /// The kept copy has this fact and another copy has not.
    case badge(ExactDuplicateBadge)
    /// No other copy is older, and another copy is newer.
    case oldest
    /// No fact sets the kept copy apart.
    case identical

    public var text: String {
        switch self {
        case .badge(.shared): L10n.string("duplicates.stays_shared")
        case .badge(.album): L10n.string("duplicates.stays_album")
        case .badge(.favorite): L10n.string("duplicates.stays_favorite")
        case .badge(.backedUpHere): L10n.string("duplicates.stays_backed_up_here")
        case .oldest: L10n.string("duplicates.stays_oldest")
        case .identical: L10n.string("duplicates.stays_any")
        }
    }
}

/// One short message after a merge that did not move every duplicate to Recently Deleted.
public enum ExactDuplicateMergeNotice: Equatable, Sendable {
    /// `count` duplicates stayed in the library. `reason` is the first of their reasons in a fixed order.
    case keptDuplicates(count: Int, reason: ExactDuplicateKeepReason)
    /// The server did not return the complete photo to keep.
    case keptPhotoUnreadable
    /// A merge failed, for example without a connection.
    case failed

    public var title: String {
        switch self {
        case .keptDuplicates(let count, _): L10n.string("duplicates.kept_title \(count)")
        case .keptPhotoUnreadable: L10n.string("duplicates.not_merged_title")
        case .failed: L10n.string("duplicates.merge_failed_title")
        }
    }

    public var message: String {
        switch self {
        case .keptDuplicates(_, .relatedFileWithoutTwin): L10n.string("duplicates.kept_reason_related_file")
        case .keptDuplicates(_, .pendingEditReplacement): L10n.string("duplicates.kept_reason_pending_edit")
        case .keptDuplicates(_, .neededByLocalSource): L10n.string("duplicates.kept_reason_needed_here")
        case .keptDuplicates(_, .shared): L10n.string("duplicates.kept_reason_shared")
        case .keptDuplicates(_, .unreadable): L10n.string("duplicates.kept_reason_unreadable")
        case .keptDuplicates(_, .differentDetails): L10n.string("duplicates.kept_reason_different_details")
        case .keptPhotoUnreadable: L10n.string("duplicates.kept_photo_unreadable")
        case .failed: L10n.string("duplicates.merge_failed_message")
        }
    }
}

/// The shared state of the Duplicates screens on iOS, iPadOS, and macOS: the groups, the photo to keep in each
/// group, and the merges. The platform views only render it and forward taps.
///
/// A load shows the groups as soon as the scan returns, in an order that needs no request. The ranking then reads the
/// facts of the groups page by page, and the content index builds or refreshes at the same time.
@MainActor
@Observable
public final class ExactDuplicatesModel {
    /// One group as the screens show it.
    public struct Group: Identifiable, Equatable, Sendable {
        public var id: String { scanGroup.id }
        public internal(set) var scanGroup: ExactDuplicateGroup
        /// The members, the photo that the ranking keeps first.
        public internal(set) var members: [PhotoUID]
        /// The photo that a merge keeps. The ranking chooses it until the person taps another member.
        public internal(set) var kept: PhotoUID
        /// Why the last merge of this group left duplicates in the library. Nil before a merge.
        public internal(set) var keptReason: ExactDuplicateKeepReason?
        /// False while `members` holds the fallback order, before the ranking read the facts of the group.
        public internal(set) var isRanked = false
        /// The person tapped the photo to keep, so the ranking no longer changes it.
        public internal(set) var isKeptChosen = false
        /// The size of one copy in bytes. Nil until the manifest or a node read of the ranking knows it.
        public internal(set) var byteSize: Int64?
        /// The members that the person shares, as the ranking read them. Empty before the ranking.
        public internal(set) var sharedMembers: Set<PhotoUID> = []
        /// The facts of each member, as the ranking read them. Empty before the ranking.
        public internal(set) var memberFacts: [PhotoUID: ExactDuplicateKeepFacts] = [:]
        /// The size of a member in bytes where its own node states one. Copies of other bytes can differ in size.
        public internal(set) var memberByteSizes: [PhotoUID: Int64] = [:]
        /// The capture dates that the device knows, without a request.
        public internal(set) var captureDates: [PhotoUID: Date] = [:]
        /// The photos that a merge moves to Recently Deleted.
        public var duplicateCount: Int { members.count - 1 }

        /// The size of `member` in bytes: its own size, else the size of one copy. Nil while unknown.
        public func byteSize(of member: PhotoUID) -> Int64? { memberByteSizes[member] ?? byteSize }

        /// The space that the merge frees: the sizes of every member except the kept one. Nil while one is unknown.
        public var freedBytes: Int64? {
            var total: Int64 = 0
            for member in members where member != kept {
                guard let size = byteSize(of: member) else { return nil }
                total += size
            }
            return total
        }

        /// The short text of `freedBytes`, for example "Merge frees 4.2 MB". Nil while the size is unknown.
        public var freedText: String? {
            freedBytes.map { L10n.string("duplicates.group_frees \(ExactDuplicatesModel.byteText($0))") }
        }

        /// The short text of `keptReason`, for example below the group.
        public var keptReasonMessage: String? {
            keptReason.map { ExactDuplicateMergeNotice.keptDuplicates(count: duplicateCount, reason: $0).message }
        }

        /// The badges of `member`, in the order of the ranking. Empty before the ranking read its facts.
        public func badges(of member: PhotoUID) -> [ExactDuplicateBadge] {
            guard let facts = memberFacts[member] else { return [] }
            return ExactDuplicateBadge.allCases.filter { $0.applies(to: facts) }
        }

        /// Why the kept member stays: the first fact in the order of the ranking that it has and another member
        /// has not, then the oldest capture date. Nil before the ranking read the facts of the kept member.
        public var stayReason: ExactDuplicateStayReason? {
            guard isRanked, let keptFacts = memberFacts[kept] else { return nil }
            let others = members.filter { $0 != kept }.map { memberFacts[$0] }
            for badge in ExactDuplicateBadge.allCases where badge.applies(to: keptFacts) {
                if others.contains(where: { other in !(other.map { badge.applies(to: $0) } ?? false) }) {
                    return .badge(badge)
                }
            }
            if let date = keptFacts.captureDate {
                let dates = others.compactMap { $0?.captureDate }
                if !dates.contains(where: { $0 < date }), dates.contains(where: { $0 > date }) { return .oldest }
            }
            return .identical
        }

        /// One line below the group: why the kept member stays and what the merge frees. Before the ranking only
        /// the freed space; nil while neither is known.
        public var footerText: String? {
            let parts = [stayReason?.text, freedText].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        /// The capture day of the group in the system's numeric date format, or the first and the last day joined
        /// when the members differ. Nil while no date is known.
        public var dateText: String? {
            let days = Set(members.compactMap { captureDates[$0] }.map { Calendar.current.startOfDay(for: $0) })
            guard let first = days.min(), let last = days.max() else { return nil }
            let text = { (day: Date) in day.formatted(date: .numeric, time: .omitted) }
            return first == last ? text(first) : L10n.string("duplicates.dates \(text(first)) \(text(last))")
        }

        /// The title above the group: its date, else its number of copies.
        public var title: String { dateText ?? L10n.string("duplicates.group_title \(members.count)") }

        /// The title of the action that keeps `member`: "Keep This Copy", or "Kept" when a merge keeps it already.
        public func keepTitle(for member: PhotoUID) -> String {
            kept == member ? L10n.string("duplicates.kept") : L10n.string("duplicates.keep_this_copy")
        }

        /// The spoken label of `member`: its position, whether it is kept, its badges, and its size.
        public func accessibilityLabel(of member: PhotoUID) -> String {
            guard let position = members.firstIndex(of: member) else { return "" }
            var parts = [L10n.string("duplicates.member_label \(position + 1) \(members.count)")]
            if member == kept { parts.append(L10n.string("duplicates.member_kept")) }
            parts += badges(of: member).map(\.title)
            if let size = byteSize(of: member) { parts.append(ExactDuplicatesModel.byteText(size)) }
            return parts.joined(separator: ", ")
        }

        /// Drops the photos that a merge moved to Recently Deleted. False when fewer than two members remain.
        mutating func remove(_ trashed: [PhotoUID], keptReason reason: ExactDuplicateKeepReason?) -> Bool {
            let remaining = members.filter { !trashed.contains($0) }
            guard remaining.count > 1 else { return false }
            members = remaining
            scanGroup = scanGroup.keeping(remaining)
            if !remaining.contains(kept) { kept = remaining[0] }
            keptReason = reason
            return true
        }

        /// The parts of this group whose members have equal metadata, two or more, as `ExactDuplicateGroup.split`
        /// forms them. The part with the photo shown as kept comes first and keeps the ID and the person's choice.
        /// Every other part keeps its first member until the ranking orders it.
        func parts(by fingerprints: [PhotoUID: ExactDuplicateFingerprint], avoiding taken: Set<String>) -> [Group] {
            let split = scanGroup.split(by: fingerprints, keepingIDWith: kept, avoiding: taken)
            return (split.filter { $0.id == id } + split.filter { $0.id != id }).map { part in
                var group = self
                group.scanGroup = part
                // Mostly every copy has the same metadata, and the group stays whole.
                guard part.members.count < members.count else { return group }
                let current = Set(part.members)
                group.members = members.filter(current.contains)
                group.sharedMembers = sharedMembers.intersection(current)
                group.memberFacts = memberFacts.filter { current.contains($0.key) }
                group.memberByteSizes = memberByteSizes.filter { current.contains($0.key) }
                group.captureDates = captureDates.filter { current.contains($0.key) }
                if part.id != id { group.keptReason = nil }
                if !current.contains(kept) {
                    group.kept = group.members[0]
                    group.isKeptChosen = false
                }
                return group
            }
        }

        /// Takes the ranked order. The photo to keep follows it unless the person chose one. With `keepsShown`, the
        /// photo that the screen already shows as kept stays, unless another member is shared and it is not: a merge
        /// keeps every shared member, so the shared one is kept and shown.
        mutating func rank(
            _ order: [PhotoUID], shared: Set<PhotoUID>, facts: [PhotoUID: ExactDuplicateKeepFacts] = [:],
            sizes: [PhotoUID: Int64] = [:], keepsShown: Bool
        ) {
            let current = Set(members)
            let ranked = order.filter(current.contains)
            members = ranked + members.filter { !ranked.contains($0) }
            sharedMembers = shared.intersection(current)
            memberFacts = facts.filter { current.contains($0.key) }
            memberByteSizes.merge(sizes.filter { current.contains($0.key) }) { _, new in new }
            for (member, fact) in memberFacts {
                if let date = fact.captureDate { captureDates[member] = date }
            }
            isRanked = true
            guard !isKeptChosen else { return }
            if !keepsShown {
                kept = members[0]
            } else if !sharedMembers.contains(kept), let firstShared = members.first(where: sharedMembers.contains) {
                kept = firstShared
            }
        }
    }

    public enum Content: Equatable, Sendable {
        case loading
        case failed(String)
        case noDuplicates
        /// No group yet, and the content index still builds.
        case stillChecking
        case groups
    }

    /// How far the library check has come while the content index builds.
    public enum CheckProgress: Equatable, Sendable {
        /// The build reads the library and knows no total yet.
        case indeterminate
        case counted(completed: Int, total: Int)
    }

    /// One titled progress line: a short title, a count line when the total is known, and the completed fraction.
    public struct ProgressLine: Equatable, Sendable {
        public let title: String
        public let detail: String?
        /// Nil while the total is unknown.
        public let fraction: Double?
    }

    private enum Phase: Equatable {
        case idle, loading, loaded
        case failed
    }

    /// The groups shown. Each write publishes one change to the screens, so work that changes many groups, such as a
    /// ranked page or a merge, changes a copy and writes it back once.
    public private(set) var groups: [Group] {
        get {
            access(keyPath: \.groups)
            return groupStorage
        }
        set {
            withMutation(keyPath: \.groups) { groupStorage = newValue }
            groupChanges &+= 1
        }
    }
    @ObservationIgnored private var groupStorage: [Group] = []
    /// How many changes `groups` published. Tests read it.
    @ObservationIgnored private(set) var groupChanges = 0
    /// How much of the library the content index covered at the last scan.
    public private(set) var coverage = ExactDuplicateCoverage.complete
    public private(set) var isMerging = false
    /// The progress of the content index build. Nil while no build runs.
    public private(set) var checkProgress: CheckProgress?
    /// The visibility read of the scan while the screen loads. Nil outside a scan.
    public private(set) var scanProgress: ExactDuplicateScanProgress?
    /// The groups that the ranking has covered, of all groups that it ranks. Nil while no ranking runs.
    public private(set) var rankingProgress: ExactDuplicateScanProgress?
    /// The message of the last merge, until the person dismisses it.
    public private(set) var notice: ExactDuplicateMergeNotice?
    /// A merge waits for the facts of groups that nobody scrolled to. Only this ranking shows its progress; the
    /// ranking of the groups on screen runs silently, and its facts simply appear.
    private var isRankingForMerge = false
    /// The groups whose photo to keep a running merge already read. A ranking that lands meanwhile never moves their
    /// checkmark, so the screen shows the photo that the merge keeps.
    @ObservationIgnored private var mergingGroupIDs: Set<String> = []
    private var phase = Phase.idle
    /// The last build failed, or it finished without an index.
    private var buildFailed = false
    /// The service stopped the last build, for example for a full refresh. The check restarts, after a merge at once.
    @ObservationIgnored private var checkInterrupted = false
    /// The check restarted after an interruption in this load. A further interruption waits for a merge or a load.
    @ObservationIgnored private var restartedAfterInterruption = false
    /// The build finished during a merge with a changed index; the screen reads the groups again after the merge.
    @ObservationIgnored private var rescanAfterMerge = false
    private var scannedDuplicateCount: Int?
    private var loadGeneration = 0
    /// The one build of this model. A load while it runs waits for it, and a closed screen leaves it running: the
    /// backup uses the same build, and the build resumes from its checkpoint.
    @ObservationIgnored private var indexBuild: Task<Bool, any Error>?
    /// The ranking of the last load. A new load cancels it.
    @ObservationIgnored private var ranking: Task<Void, Never>?
    /// The groups that wait for the ranking, in the order the screen showed them.
    @ObservationIgnored private var rankingQueue: [String] = []
    /// The metadata of each copy that a ranking read. A screen that opens again splits its groups at once by them.
    /// A merge that finds other metadata drops those of its group.
    @ObservationIgnored private var knownFingerprints: [PhotoUID: ExactDuplicateFingerprint] = [:]
    /// The groups that the ranking of this load has read or queued. A failed group waits for the next load or a merge.
    @ObservationIgnored private var rankingRequested: Set<String> = []
    /// The groups that the screen showed since the last pause, until the pause after them ranks their pages.
    @ObservationIgnored private var appearedGroupIDs: Set<String> = []
    /// Counts the groups shown, so the pause restarts while the screen keeps showing groups.
    @ObservationIgnored private var appearances = 0
    /// Waits for the pause after the last group shown. One at a time.
    @ObservationIgnored private var appearanceFollower: Task<Void, Never>?
    /// Identifies the running scroll ranking. A merge shows its own progress, so it never owns this ranking.
    @ObservationIgnored private var rankingWorkerToken: UUID?
    /// Identifies the ranking whose progress the screen shows.
    @ObservationIgnored private var rankingToken = UUID()
    @ObservationIgnored private let finder: any ExactDuplicateMerging
    /// Called with the photos that a merge moved to Recently Deleted, so the library stops showing them.
    @ObservationIgnored private let didTrash: @MainActor ([PhotoUID]) async -> Void

    public init(
        finder: any ExactDuplicateMerging, didTrash: @escaping @MainActor ([PhotoUID]) async -> Void = { _ in }
    ) {
        self.finder = finder
        self.didTrash = didTrash
    }

    /// False while the content index misses photos, so more duplicates can appear later.
    public var isComplete: Bool { coverage.isComplete }

    private var isBuilding: Bool { checkProgress != nil }

    public var content: Content {
        switch phase {
        case .idle, .loading: groups.isEmpty ? .loading : .groups
        case .failed: groups.isEmpty ? .failed(L10n.string("duplicates.load_failed")) : .groups
        case .loaded:
            if !groups.isEmpty {
                .groups
            } else if case .indexing = coverage {
                .stillChecking
            } else if !isComplete, isBuilding {
                .stillChecking
            } else {
                // A finished check never waits: photos that could not be read get one line instead.
                .noDuplicates
            }
        }
    }

    /// The text of `.noDuplicates` and `.stillChecking`.
    public var emptyStateCopy: PhotoFilterEmptyStateCopy {
        switch content {
        case .stillChecking:
            PhotoFilterEmptyStateCopy(
                title: L10n.string("duplicates.checking_title"), description: L10n.string("duplicates.checking_wait"),
                systemImage: "hourglass")
        case .noDuplicates where uncheckedNote != nil:
            PhotoFilterEmptyStateCopy(
                title: PhotoFilter.duplicates.emptyStateCopy.title, description: uncheckedNote ?? "",
                systemImage: PhotoFilter.duplicates.emptyStateCopy.systemImage)
        default:
            PhotoFilter.duplicates.emptyStateCopy
        }
    }

    /// The title of `.loading`.
    public var loadingTitle: String { L10n.string("duplicates.loading") }

    /// The line of `.loading`: the visibility read of the scan, counted when its total is known.
    public var loadingLine: ProgressLine {
        guard let scanProgress, scanProgress.total > 0 else {
            return ProgressLine(title: loadingTitle, detail: nil, fraction: nil)
        }
        return ProgressLine(
            title: loadingTitle,
            detail: Self.photoCount(scanProgress.completed, of: scanProgress.total),
            fraction: Double(scanProgress.completed) / Double(scanProgress.total))
    }

    /// The counted progress of the library check, for example "1,234 of 15,000 photos". Nil without a total.
    public var checkProgressText: String? {
        guard case .counted(let completed, let total) = checkProgress else { return nil }
        return Self.photoCount(completed, of: total)
    }

    /// The line of a running library check. Nil while no build runs, and for a quick refresh of a complete index.
    public var checkLine: ProgressLine? {
        switch checkProgress {
        case .counted(let completed, let total):
            ProgressLine(
                title: L10n.string("duplicates.checking_title"), detail: checkProgressText,
                fraction: Double(completed) / Double(total))
        case .indeterminate where !isComplete:
            ProgressLine(title: L10n.string("duplicates.checking_title"), detail: nil, fraction: nil)
        case .indeterminate, nil:
            nil
        }
    }

    /// The line of the ranking that a merge waits for, for example "40 of 1,545 groups". Nil while no merge waits.
    public var rankingLine: ProgressLine? {
        guard isRankingForMerge, let rankingProgress, rankingProgress.total > 0 else { return nil }
        let completed = rankingProgress.completed.formatted()
        let total = rankingProgress.total.formatted()
        return ProgressLine(
            title: L10n.string("duplicates.ranking_title"),
            detail: L10n.string("duplicates.ranking_progress \(completed) \(total)"),
            fraction: Double(rankingProgress.completed) / Double(rankingProgress.total))
    }

    /// The note while the library is still being checked and groups are shown. Nil once the check finished.
    public var stillCheckingNote: String? {
        phase == .loaded && !isComplete && isBuilding ? L10n.string("duplicates.still_checking") : nil
    }

    /// One line after a finished check that could not read some photos. A retry cannot read them, so it has none.
    public var uncheckedNote: String? {
        guard phase == .loaded, !isBuilding, case .incomplete(let count) = coverage, count > 0 else { return nil }
        return L10n.string("duplicates.unchecked \(count)")
    }

    /// The check stopped without an index while groups are shown. A retry can finish it.
    public var checkFailedNote: String? {
        guard phase == .loaded, !isBuilding, buildFailed, case .indexing = coverage else { return nil }
        return L10n.string("duplicates.check_failed")
    }

    /// The space that merging every group shown frees, counting the groups whose size is known. It grows while the
    /// check finds groups and while sizes become known.
    public var totalFreedBytes: Int64 { groups.reduce(0) { $0 + ($1.freedBytes ?? 0) } }

    /// The short text of `totalFreedBytes`. Merged duplicates wait in Recently Deleted, so the line says that the
    /// space is free only after that. Nil while no size is known.
    public var totalFreedText: String? {
        let total = totalFreedBytes
        return total > 0 ? L10n.string("duplicates.total_frees \(Self.byteText(total))") : nil
    }

    /// The system's file byte format, for example "4.2 MB".
    nonisolated public static func byteText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    /// The groups in one page of the ranking. The screen ranks the page that it shows and the page after it.
    nonisolated static let rankingPageSize = 24
    /// The pause after the last group shown before its pages rank. The macOS list shows every section at once.
    nonisolated static let appearancePause: Duration = .milliseconds(150)
    /// The pages that wait for the ranking at most. Older pages that the screen scrolled past wait for their next
    /// appearance.
    nonisolated static let maximumQueuedPages = 4

    /// Every copy of every group shown, kept copies included.
    public var copyCount: Int { groups.reduce(0) { $0 + $1.members.count } }

    /// The number of copies shown, for example "14 identical copies". Nil without a group.
    public var copyCountText: String? {
        groups.isEmpty ? nil : L10n.string("duplicates.copy_count \(copyCount)")
    }

    /// The title and the text of the explanation beside `copyCountText`.
    public var infoTitle: String { L10n.string("duplicates.info_title") }
    public var infoMessage: String { L10n.string("duplicates.info_message") }

    /// The photos that Merge All moves to Recently Deleted.
    public var duplicateCount: Int { groups.reduce(0) { $0 + $1.duplicateCount } }

    /// The count for the Duplicates entry. Nil until a scan has finished.
    public var knownDuplicateCount: Int? {
        phase == .loaded ? duplicateCount : scannedDuplicateCount
    }

    public var canMerge: Bool { !isMerging && phase != .loading && !groups.isEmpty }

    public var mergeAllTitle: String { L10n.string("duplicates.merge_all_title \(copyCount)") }
    public var mergeAllMessage: String { L10n.string("duplicates.merge_all_message \(duplicateCount)") }
    /// The confirming button of the Merge All dialog.
    public var mergeAllConfirmTitle: String { L10n.string("duplicates.merge_all_confirm \(copyCount)") }

    /// The group with `id`. Nil after a merge removed it.
    public func group(withID id: String) -> Group? { groups.first { $0.id == id } }

    // MARK: - The viewer of a group

    /// The group that holds `member` now. A group can split while the viewer shows one of its photos, so every action
    /// of the viewer finds the group of the photo on screen when the person taps it.
    public func group(containing member: PhotoUID) -> Group? {
        groups.first { $0.members.contains(member) }
    }

    /// The title of the action that keeps `member`: "Keep This Copy", or "Kept" when a merge keeps it already.
    public func keepTitle(for member: PhotoUID) -> String {
        group(containing: member)?.keepTitle(for: member) ?? L10n.string("duplicates.keep_this_copy")
    }

    /// The symbol of the action that keeps `member`: a filled checkmark once a merge keeps it.
    public func keepSymbol(for member: PhotoUID) -> String {
        group(containing: member)?.kept == member ? "checkmark.circle.fill" : "checkmark.circle"
    }

    /// The person can keep `member` instead: it is in a group, not kept yet, and no merge runs.
    public func canKeep(_ member: PhotoUID) -> Bool {
        guard !isMerging, let group = group(containing: member) else { return false }
        return group.kept != member
    }

    /// Keeps `member` instead of the photo shown as kept in its group.
    public func keep(_ member: PhotoUID) {
        guard let groupID = group(containing: member)?.id else { return }
        keep(member, inGroup: groupID)
    }

    /// The title and the symbol of the action that merges a group.
    public var mergeTitle: String { L10n.string("duplicates.merge") }
    public var mergeSymbol: String { "arrow.triangle.merge" }

    /// The group of `member` can be merged now: the photo is still in a group, and no merge or load runs.
    public func canMerge(containing member: PhotoUID) -> Bool {
        canMerge && group(containing: member) != nil
    }

    /// Merges the group that holds `member` now, with the photo shown as kept.
    public func merge(containing member: PhotoUID) async {
        guard let groupID = group(containing: member)?.id else { return }
        await merge(groupID: groupID)
    }

    /// The photos to show in the viewer when the person opens `member`: the members of its group that `item` finds,
    /// in the order of the group, and the position of `member` among them. Nil while `item` does not find `member`,
    /// for example right after launch before the library shows it.
    public func viewerItems(
        opening member: PhotoUID, inGroup groupID: String, item: (PhotoUID) -> PhotoItem?
    ) -> (items: [PhotoItem], index: Int)? {
        guard let members = group(withID: groupID)?.members, members.contains(member) else { return nil }
        let items = members.compactMap(item)
        guard let index = items.firstIndex(where: { $0.uid == member }) else { return nil }
        return (items, index)
    }

    /// The person moved photos to Recently Deleted elsewhere, for example in the viewer. They leave their groups at
    /// once; a group with fewer than two copies left leaves the list, and a trashed checked copy hands the checkmark
    /// to the next copy.
    public func didTrashElsewhere(_ uids: [PhotoUID]) {
        let trashed = Set(uids)
        guard groups.contains(where: { group in group.members.contains(where: trashed.contains) }) else { return }
        var updated = groups
        for index in updated.indices.reversed() where updated[index].members.contains(where: trashed.contains) {
            let reason = updated[index].keptReason
            let keptLeft = trashed.contains(updated[index].kept)
            if !updated[index].remove(Array(trashed), keptReason: reason) {
                updated.remove(at: index)
            } else if keptLeft {
                // The chosen photo is gone; the next copy is kept until the person chooses again.
                updated[index].isKeptChosen = false
            }
        }
        groups = updated
    }

    /// Reads the groups and shows them, then ranks the first two pages and builds the content index or brings it up
    /// to date, both at once. Reads the groups again when the index changed. A choice of the person and the ranking of
    /// a group with the same members stay, so a screen that opens again reads nothing for them.
    public func load() async {
        guard !isMerging else { return }
        loadGeneration += 1
        let generation = loadGeneration
        phase = .loading
        restartedAfterInterruption = false
        checkInterrupted = false
        rescanAfterMerge = false
        stopRanking()
        guard await scan(generation: generation) else { return }
        async let ranked: Void = rank(around: 0)
        async let built: Void = buildAndRescan(generation: generation)
        _ = await (ranked, built)
    }

    /// The screen shows the group. After a short pause without another group shown, ranks the pages of the first and
    /// of the last group shown since the last pause, each with the page after it, unless they are ranked. A list that
    /// shows many sections at once, as on macOS, ranks around those two only.
    public func groupAppeared(_ groupID: String) {
        appearedGroupIDs.insert(groupID)
        appearances &+= 1
        guard appearanceFollower == nil else { return }
        appearanceFollower = Task { [weak self] in await self?.followAppearances() }
    }

    private func followAppearances() async {
        var seen: Int?
        while seen != appearances {
            seen = appearances
            try? await Task.sleep(for: Self.appearancePause)
            // A load stopped this follower and may have started the next one.
            if Task.isCancelled { return }
        }
        appearanceFollower = nil
        let shown = groups.indices.filter { appearedGroupIDs.contains(groups[$0].id) }
        appearedGroupIDs = []
        guard let first = shown.first, let last = shown.last else { return }
        _ = requestRanking(around: [first, last])
    }

    /// The screen went away. Stops waiting for the groups shown and stops the scroll ranking; a merge keeps running.
    public func screenDisappeared() {
        stopFollowingAppearances()
        ranking?.cancel()
    }

    private func stopFollowingAppearances() {
        appearanceFollower?.cancel()
        appearanceFollower = nil
        appearedGroupIDs = []
    }

    /// Reads the groups and shows them in the fallback order. A group with the same members keeps its ranking and the
    /// choice of the person. False when the read failed or a newer load replaced this one.
    private func scan(generation: Int) async -> Bool {
        let report: @Sendable (ExactDuplicateScanProgress) async -> Void = { [weak self] progress in
            await self?.showScan(progress, generation: generation)
        }
        defer { if generation == loadGeneration { scanProgress = nil } }
        do {
            let scan = try await finder.duplicateGroups(progress: report)
            let fallback = await finder.fallbackMembers(of: scan.groups)
            let dates = await finder.captureDates(of: scan.groups.flatMap(\.members))
            guard generation == loadGeneration, !isMerging else { return false }
            let earlier = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let earlierByHash = Dictionary(grouping: groups, by: \.scanGroup.contentHash)
            var shown: [Group] = []
            shown.reserveCapacity(scan.groups.count)
            var usedIDs: Set<String> = []
            for scanned in scan.groups {
                let order = fallback[scanned.id] ?? scanned.members
                for part in knownParts(of: scanned, earlier: earlier, avoiding: usedIDs) {
                    let groupDates = Dictionary(
                        part.members.compactMap { member in dates[member].map { (member, $0) } },
                        uniquingKeysWith: { first, _ in first })
                    let size = scan.byteSizes[part.contentHash]
                    // A group keeps its ranking and the person's choice while its members and metadata stay, also when
                    // another part of its bytes took its place meanwhile, for example after that part merged.
                    let isSame = { (earlier: Group) in
                        Set(earlier.members) == Set(part.members) && earlier.scanGroup.fingerprint == part.fingerprint
                    }
                    let same =
                        earlier[part.id].flatMap { isSame($0) ? $0 : nil }
                        ?? earlierByHash[part.contentHash]?.first(where: isSame)
                    let group = Self.unique(part, preferring: same?.id ?? part.id, used: &usedIDs)
                    if let same {
                        var kept = same
                        kept.scanGroup = group
                        kept.byteSize = size ?? same.byteSize
                        kept.captureDates.merge(groupDates) { _, new in new }
                        shown.append(kept)
                        continue
                    }
                    let members =
                        group.members.count == order.count ? order : order.filter(Set(group.members).contains)
                    let choice = earlier[group.id].flatMap {
                        $0.isKeptChosen && members.contains($0.kept) ? $0.kept : nil
                    }
                    var new = Group(scanGroup: group, members: members, kept: choice ?? members[0])
                    new.isKeptChosen = choice != nil
                    new.byteSize = size ?? earlier[group.id]?.byteSize
                    new.captureDates = groupDates
                    shown.append(new)
                }
            }
            groups = shown
            coverage = scan.coverage
            phase = .loaded
            return true
        } catch {
            guard generation == loadGeneration else { return false }
            phase = .failed
            return false
        }
    }

    /// The parts of a scanned group by the metadata that a ranking read already, so a screen that opens again reads
    /// nothing for them. The whole group while the metadata of a member are unknown.
    private func knownParts(
        of scanned: ExactDuplicateGroup, earlier: [String: Group], avoiding used: Set<String>
    ) -> [ExactDuplicateGroup] {
        guard !knownFingerprints.isEmpty, scanned.members.allSatisfy({ knownFingerprints[$0] != nil }) else {
            return [scanned]
        }
        return scanned.split(by: knownFingerprints, keepingIDWith: earlier[scanned.id]?.kept, avoiding: used)
    }

    /// `group` under `preferred`, else under its own ID, else under an ID from its first member, whichever no group in
    /// `used` has. Adds the ID to `used`.
    private static func unique(
        _ group: ExactDuplicateGroup, preferring preferred: String, used: inout Set<String>
    ) -> ExactDuplicateGroup {
        let id = [preferred, group.id].first { !used.contains($0) } ?? "\(group.id)#\(group.members[0].nodeID)"
        used.insert(id)
        return id == group.id ? group : group.withID(id)
    }

    private func showScan(_ progress: ExactDuplicateScanProgress, generation: Int) {
        guard generation == loadGeneration, phase == .loading else { return }
        scanProgress = progress
    }

    /// Ranks the page of the group at `index` and the page after it, and waits for that ranking.
    private func rank(around index: Int) async {
        guard let task = requestRanking(around: [index]) else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Queues the unranked groups of two pages from the page of each of `indices`. Returns the ranking that reads them.
    private func requestRanking(around indices: [Int]) -> Task<Void, Never>? {
        let size = Self.rankingPageSize
        var wanted: [String] = []
        for index in indices {
            let start = index / size * size
            for group in groups[start..<min(start + 2 * size, groups.count)]
            where !group.isRanked && !rankingRequested.contains(group.id) && !wanted.contains(group.id) {
                wanted.append(group.id)
            }
        }
        guard !wanted.isEmpty else { return ranking }
        rankingRequested.formUnion(wanted)
        rankingQueue += wanted
        // The oldest queued groups give way, never those of this request; the screen requests them again when it
        // shows them again.
        let kept = max(Self.maximumQueuedPages * size, wanted.count)
        let dropped = rankingQueue.prefix(max(0, rankingQueue.count - kept))
        rankingRequested.subtract(dropped)
        rankingQueue.removeFirst(dropped.count)
        if let ranking {
            if rankingToken == rankingWorkerToken, let progress = rankingProgress {
                rankingProgress = ExactDuplicateScanProgress(
                    completed: progress.completed, total: progress.total + wanted.count - dropped.count)
            }
            return ranking
        }
        let token = UUID()
        rankingWorkerToken = token
        // During a merge its own progress row stays; the scroll ranking runs without one.
        if !isMerging {
            rankingToken = token
            rankingProgress = ExactDuplicateScanProgress(completed: 0, total: wanted.count)
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.drainRankingQueue(token: token)
        }
        ranking = task
        return task
    }

    /// Ranks the queued groups page by page until the queue is empty or the ranking is cancelled.
    private func drainRankingQueue(token: UUID) async {
        let finder = finder
        while !Task.isCancelled, !rankingQueue.isEmpty {
            let ids = Array(rankingQueue.prefix(Self.rankingPageSize))
            rankingQueue.removeFirst(ids.count)
            let page = ids.compactMap { id in groups.first { $0.id == id && !$0.isRanked }?.scanGroup }
            if page.count < ids.count {
                apply(ExactDuplicateRankingPage(members: [:], groupCount: ids.count - page.count), token: token)
            }
            guard !page.isEmpty else { continue }
            let apply: @Sendable (ExactDuplicateRankingPage) async -> Void = { [weak self] ranked in
                await self?.apply(ranked, token: token)
            }
            await finder.rankMembers(of: page, ranked: apply)
        }
        guard rankingWorkerToken == token else { return }
        if Task.isCancelled {
            // A closed screen stops the ranking. Groups that it did not rank can be requested again.
            let ranked = Set(groups.filter(\.isRanked).map(\.id))
            rankingRequested.formIntersection(ranked)
        }
        ranking = nil
        rankingQueue = []
        rankingWorkerToken = nil
        if rankingToken == token { rankingProgress = nil }
    }

    /// Stops the ranking. A group that it did not read can be requested again.
    private func stopRanking() {
        stopFollowingAppearances()
        ranking?.cancel()
        ranking = nil
        rankingQueue = []
        rankingRequested = []
        rankingWorkerToken = nil
        rankingToken = UUID()
        rankingProgress = nil
    }

    /// Takes the ranked order, the size, and the metadata of each group in `page`. Only copies with equal metadata
    /// stay one group: a group splits in place, and leaves when no two copies match. The part with the photo shown
    /// as kept keeps the group's ID and the person's choice. Only the ranking of `token` counts its progress.
    /// `keepsShown` keeps the photo that the screen shows as kept, as a merge does.
    private func apply(_ page: ExactDuplicateRankingPage, token: UUID?, keepsShown: Bool = false) {
        if let token, token == rankingToken, let progress = rankingProgress {
            rankingProgress = ExactDuplicateScanProgress(
                completed: min(progress.completed + page.groupCount, progress.total), total: progress.total)
        }
        // The whole page is one change of the screen, not one change for each of its groups.
        var updated = groups
        let positions = Self.positions(of: updated)
        var changed = false
        // The sizes first, so the parts of a split group take them.
        for (id, size) in page.byteSizes {
            guard let index = positions[id], updated[index].byteSize == nil else { continue }
            updated[index].byteSize = size
            changed = true
        }
        var replacements: [Int: [Group]] = [:]
        var usedIDs = Set(positions.keys)
        for (id, order) in page.members {
            // Without the metadata of its copies, the group stays whole and unranked, so no merge takes it.
            guard let index = positions[id], let fingerprints = page.fingerprints[id] else { continue }
            let shownKept = updated[index].kept
            knownFingerprints.merge(fingerprints) { _, new in new }
            var parts = updated[index].parts(by: fingerprints, avoiding: usedIDs)
            usedIDs.formUnion(parts.map(\.id))
            for position in parts.indices {
                let showsKept = parts[position].kept == shownKept
                parts[position].rank(
                    order, shared: page.shared[id] ?? [], facts: page.facts[id] ?? [:],
                    sizes: page.memberByteSizes[id] ?? [:], keepsShown: keepsShown && showsKept)
                if showsKept, mergingGroupIDs.contains(parts[position].id) { parts[position].kept = shownKept }
            }
            replacements[index] = parts
            changed = true
        }
        if !replacements.isEmpty { updated = updated.indices.flatMap { replacements[$0] ?? [updated[$0]] } }
        if changed { groups = updated }
    }

    /// The position of each group by its ID.
    private static func positions(of groups: [Group]) -> [String: Int] {
        Dictionary(groups.indices.map { (groups[$0].id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func buildAndRescan(generation: Int) async {
        let changed: Bool
        do {
            changed = try await buildIndex()
            buildFailed = false
            checkInterrupted = false
        } catch is CancellationError where !Task.isCancelled {
            // The service stopped the build; nothing failed. The check starts again: after a merge, or now once.
            guard generation == loadGeneration else { return }
            checkInterrupted = true
            if !isMerging, !restartedAfterInterruption {
                restartedAfterInterruption = true
                await buildAndRescan(generation: generation)
            }
            return
        } catch {
            guard generation == loadGeneration else { return }
            buildFailed = true
            // The groups already shown stay. Without them, the person can try again.
            if !isMerging, groups.isEmpty, !isComplete { phase = .failed }
            return
        }
        guard generation == loadGeneration else { return }
        if changed {
            guard !isMerging, await scan(generation: generation) else {
                // A merge holds the list; the groups are read again after it.
                if isMerging { rescanAfterMerge = true }
                return
            }
            await rank(around: 0)
        } else if isMerging {
            return
        } else if case .indexing = coverage {
            // The build finished and left no index: waiting longer cannot help, a retry can.
            buildFailed = true
            if groups.isEmpty { phase = .failed }
        }
    }

    /// Runs the build of the content index, or waits for the build that already runs.
    private func buildIndex() async throws -> Bool {
        if let indexBuild { return try await indexBuild.value }
        let finder = finder
        let report: @Sendable (UploadRemoteIndexPreparationProgress) async -> Void = { [weak self] progress in
            await self?.show(progress)
        }
        let build = Task { try await finder.prepareIndex(progress: report) }
        indexBuild = build
        checkProgress = .indeterminate
        defer {
            indexBuild = nil
            checkProgress = nil
        }
        return try await build.value
    }

    private func show(_ progress: UploadRemoteIndexPreparationProgress) {
        guard indexBuild != nil, progress.phase != .ready else { return }
        if let total = progress.total, total > 0 {
            checkProgress = .counted(completed: min(progress.completed, total), total: total)
        } else {
            checkProgress = .indeterminate
        }
    }

    private static func photoCount(_ completed: Int, of total: Int) -> String {
        L10n.string("duplicates.checking_progress \(completed.formatted()) \(total.formatted())")
    }

    /// Counts the duplicates for the entry without ranking them, once, before the screen has loaded.
    public func loadCountIfNeeded() async {
        guard phase == .idle, scannedDuplicateCount == nil else { return }
        guard let scan = try? await finder.duplicateGroups(progress: { _ in }), phase == .idle else { return }
        scannedDuplicateCount = scan.groups.reduce(0) { $0 + $1.members.count - 1 }
    }

    /// Keeps `uid` instead of the ranked photo when the group is merged.
    public func keep(_ uid: PhotoUID, inGroup groupID: String) {
        guard !isMerging, let index = groups.firstIndex(where: { $0.id == groupID }),
            groups[index].members.contains(uid)
        else { return }
        var group = groups[index]
        group.kept = uid
        group.isKeptChosen = true
        groups[index] = group
    }

    /// Merges one group and keeps exactly the photo that the screen shows as kept.
    public func merge(groupID: String) async {
        guard canMerge, let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].isKeptChosen = true
        await merge([groups[index]], all: false)
    }

    public func mergeAll() async {
        guard canMerge else { return }
        await merge(groups, all: true)
    }

    public func dismissNotice() {
        notice = nil
    }

    /// Merges `requested`. Every group reads the metadata of its copies first, because only copies with equal
    /// metadata merge. With `all`, every part of a requested group merges; otherwise a group that split or changed
    /// its kept photo meanwhile stays, so the person sees it first. A group whose metadata could not be read stays,
    /// and the merge reports a failure.
    private func merge(_ requested: [Group], all: Bool) async {
        isMerging = true
        notice = nil
        // The groups that nobody scrolled to rank page by page, with progress. The photo that the screen shows as kept
        // stays, unless only another member is shared.
        let unranked = requested.filter { !$0.isRanked }.map(\.scanGroup)
        if !unranked.isEmpty {
            let token = UUID()
            rankingToken = token
            rankingProgress = ExactDuplicateScanProgress(completed: 0, total: unranked.count)
            isRankingForMerge = true
            let apply: @Sendable (ExactDuplicateRankingPage) async -> Void = { [weak self] page in
                await self?.apply(page, token: token, keepsShown: true)
            }
            await finder.rankMembers(of: unranked, ranked: apply)
            isRankingForMerge = false
            if rankingToken == token { rankingProgress = nil }
        }
        let requestedHashes = Set(requested.map(\.scanGroup.contentHash))
        let requestedByID = Dictionary(requested.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = groups.filter { group in
            if all { return requestedHashes.contains(group.scanGroup.contentHash) }
            guard let request = requestedByID[group.id] else { return false }
            return Set(request.members) == Set(group.members) && request.kept == group.kept
        }
        // Never a group whose metadata are unknown.
        let selected = candidates.filter { $0.isRanked && $0.scanGroup.fingerprint != nil }
        mergingGroupIDs = Set(selected.map(\.id))
        var trashed: [PhotoUID] = []
        var kept: [PhotoUID: ExactDuplicateKeepReason] = [:]
        var keptPhotoUnreadable = false
        var failed = selected.count < candidates.count
        var stale = false
        let results = await finder.merge(selected.map { ($0.scanGroup, $0.kept) })
        // The outcome of every group is one change of the screen.
        var updated = groups
        for (group, result) in zip(selected, results) {
            do {
                switch try result.get() {
                case .merged(_, let moved, let keptDuplicates):
                    trashed += moved
                    kept.merge(keptDuplicates) { first, _ in first }
                    if keptDuplicates.values.contains(.differentDetails) {
                        // The metadata changed since the ranking read them; a new scan reads them again.
                        forgetFingerprints(of: group)
                        stale = true
                    }
                    // A group with a duplicate left keeps its reason, so the person can keep another photo instead.
                    if let index = updated.firstIndex(where: { $0.id == group.id }),
                        !updated[index].remove(moved, keptReason: Self.firstReason(in: keptDuplicates.values))
                    {
                        updated.remove(at: index)
                    }
                case .skipped(.keptUnreadable):
                    keptPhotoUnreadable = true
                case .skipped:
                    // The library changed since the scan; a new scan shows what is left.
                    forgetFingerprints(of: group)
                    stale = true
                }
            } catch is CancellationError {
                break
            } catch {
                failed = true
            }
        }
        if updated != groups { groups = updated }
        if !trashed.isEmpty { await didTrash(trashed) }
        mergingGroupIDs = []
        isMerging = false
        notice = Self.notice(kept: kept, keptPhotoUnreadable: keptPhotoUnreadable, failed: failed)
        if stale {
            await load()
            return
        }
        let generation = loadGeneration
        if rescanAfterMerge {
            rescanAfterMerge = false
            if await scan(generation: generation) { await rank(around: 0) }
        }
        if checkInterrupted, !isComplete, indexBuild == nil {
            // The check was stopped while the merge ran. It starts again and shows its progress.
            checkInterrupted = false
            Task { await self.buildAndRescan(generation: generation) }
        }
    }

    private func forgetFingerprints(of group: Group) {
        for member in group.scanGroup.members { knownFingerprints[member] = nil }
    }

    /// One reason only: a failure first, then the unreadable photo to keep, then the kept duplicates.
    private static func notice(
        kept: [PhotoUID: ExactDuplicateKeepReason], keptPhotoUnreadable: Bool, failed: Bool
    ) -> ExactDuplicateMergeNotice? {
        if failed { return .failed }
        if keptPhotoUnreadable { return .keptPhotoUnreadable }
        guard let reason = firstReason(in: kept.values) else { return nil }
        return .keptDuplicates(count: kept.count, reason: reason)
    }

    /// The first of `reasons` in a fixed order. Nil when `reasons` is empty.
    private static func firstReason(
        in reasons: some Collection<ExactDuplicateKeepReason>
    ) -> ExactDuplicateKeepReason? {
        let order: [ExactDuplicateKeepReason] = [
            .differentDetails, .relatedFileWithoutTwin, .pendingEditReplacement, .neededByLocalSource, .shared,
            .unreadable,
        ]
        return order.first(where: reasons.contains)
    }
}
