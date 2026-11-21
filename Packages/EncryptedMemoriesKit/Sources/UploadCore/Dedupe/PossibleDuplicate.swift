import Foundation
import PhotosCore

/// How closely the details of two different files must agree before the screen lists them as possibly the same photo.
/// Every rule needs the same capture second, the same kind (photo or video) and a known camera, and leaves out a copy
/// whose details are unknown. A video also needs the same length within `PossibleDuplicatePolicy.durationTolerance`.
public enum PossibleDuplicateRule: Sendable, CaseIterable {
    /// The same camera and the same dimensions in either orientation. A place may be missing on one copy.
    case strict
    /// The same camera and the same aspect ratio in either orientation, within
    /// `PossibleDuplicatePolicy.aspectTolerance`, so a smaller copy counts. A place may be missing on one copy.
    case sameShape
    /// Nothing more: copies of another camera, place or size count too.
    case sameSecond
}

/// The rule and the kinds of copies that the check of possibly identical photos takes.
public struct PossibleDuplicatePolicy: Sendable, Equatable {
    public let rule: PossibleDuplicateRule
    public let includesVideos: Bool

    /// The largest difference of the aspect ratio, as a share of the first copy's ratio.
    public static let aspectTolerance = 0.01
    /// The largest difference of a video's length, in seconds.
    public static let durationTolerance = 0.5

    public init(rule: PossibleDuplicateRule, includesVideos: Bool) {
        self.rule = rule
        self.includesVideos = includesVideos
    }

    /// The groups of copies that match the first copy of their group, from candidate groups and the details that the
    /// reads found. A copy without read details, or with a detail that the rule needs unknown, is left out. The copies
    /// that do not match the first copy form the next group in the same way.
    public func groups(
        of candidates: [[PhotoUID]], fingerprints: [PhotoUID: ExactDuplicateFingerprint]
    ) -> [PossibleDuplicateGroup] {
        candidates.flatMap { candidate in
            var rest = candidate.compactMap { uid in
                fingerprints[uid].flatMap { isComparable($0) ? (uid: uid, details: $0) : nil }
            }
            var groups: [PossibleDuplicateGroup] = []
            while let first = rest.first {
                let others = rest.dropFirst()
                let matching = others.filter { matches(first.details, $0.details) }
                rest = others.filter { !matches(first.details, $0.details) }
                guard !matching.isEmpty else { continue }
                let differences = ExactDuplicateDetail.allCases.filter { detail in
                    matching.contains { !first.details.equals($0.details, in: detail) }
                }
                groups.append(
                    PossibleDuplicateGroup(members: [first.uid] + matching.map(\.uid), differences: differences))
            }
            return groups
        }
    }

    /// The details that every comparison needs are known.
    private func isComparable(_ details: ExactDuplicateFingerprint) -> Bool {
        guard !details.matchesOnlyItsNode, details.captureTime != nil, let isVideo = Self.isVideo(details),
            details.device?.isEmpty == false
        else { return false }
        if isVideo, !includesVideos || details.durationSeconds == nil { return false }
        return rule == .sameSecond || Self.sides(details) != nil
    }

    private func matches(_ first: ExactDuplicateFingerprint, _ other: ExactDuplicateFingerprint) -> Bool {
        guard first.captureTime == other.captureTime, Self.isVideo(first) == Self.isVideo(other) else { return false }
        if Self.isVideo(first) == true,
            let length = first.durationSeconds, let otherLength = other.durationSeconds,
            abs(length - otherLength) > Self.durationTolerance
        {
            return false
        }
        switch rule {
        case .sameSecond:
            return true
        case .strict:
            return first.device == other.device && Self.placesAgree(first, other)
                && Self.sides(first).map { [$0.short, $0.long] } == Self.sides(other).map { [$0.short, $0.long] }
        case .sameShape:
            guard first.device == other.device, Self.placesAgree(first, other),
                let sides = Self.sides(first), let otherSides = Self.sides(other)
            else { return false }
            let ratio = Double(sides.long) / Double(sides.short)
            let otherRatio = Double(otherSides.long) / Double(otherSides.short)
            return abs(ratio - otherRatio) <= Self.aspectTolerance * ratio
        }
    }

    /// Nil while the file type is unknown.
    private static func isVideo(_ details: ExactDuplicateFingerprint) -> Bool? {
        guard let type = details.mimeType, !type.isEmpty else { return nil }
        return type.hasPrefix("video/")
    }

    /// The shorter and the longer side, so the orientation does not count. Nil while a side is unknown or zero.
    private static func sides(_ details: ExactDuplicateFingerprint) -> (short: Int, long: Int)? {
        guard let width = details.pixelWidth, let height = details.pixelHeight, width > 0, height > 0 else {
            return nil
        }
        return (min(width, height), max(width, height))
    }

    /// The places are equal, or one copy has none.
    private static func placesAgree(_ first: ExactDuplicateFingerprint, _ other: ExactDuplicateFingerprint) -> Bool {
        guard let latitude = first.latitude, let longitude = first.longitude,
            let otherLatitude = other.latitude, let otherLongitude = other.longitude
        else { return true }
        return latitude == otherLatitude && longitude == otherLongitude
    }
}

/// Different files whose details say that they may show the same photo. The person compares them and moves the copy
/// that they do not need to the trash in the viewer; no merge takes them.
public struct PossibleDuplicateGroup: Sendable, Equatable, Identifiable {
    /// The first member, which every other member matches.
    public var id: String { members.first.map { "\($0.volumeID)/\($0.nodeID)" } ?? "" }
    public let members: [PhotoUID]
    /// The details that are not equal for every member, in `ExactDuplicateDetail` order.
    public let differences: [ExactDuplicateDetail]

    public init(members: [PhotoUID], differences: [ExactDuplicateDetail]) {
        self.members = members
        self.differences = differences
    }
}

/// The result of the check of possibly identical photos.
public struct PossibleDuplicateScan: Sendable, Equatable {
    public let groups: [PossibleDuplicateGroup]
    /// The file size of each member that its node states.
    public let byteSizes: [PhotoUID: Int64]
    /// The details of each member, so the groups can follow a copy that leaves without a new read.
    public let fingerprints: [PhotoUID: ExactDuplicateFingerprint]

    public init(
        groups: [PossibleDuplicateGroup] = [], byteSizes: [PhotoUID: Int64] = [:],
        fingerprints: [PhotoUID: ExactDuplicateFingerprint] = [:]
    ) {
        self.groups = groups
        self.byteSizes = byteSizes
        self.fingerprints = fingerprints
    }
}

/// The candidates of the check of possibly identical photos, from the library alone, without a request.
public enum PossibleDuplicateCandidates {
    /// Groups of two or more library items with the same capture second and the same kind, in the order of `items`.
    /// Leaves out burst photos, the paired videos of Live Photos, videos unless `includesVideos`, and every copy of
    /// `sameBytes` after its first one, because the lists of identical copies already hold those pairs. Every member
    /// of a group has the same known moment within the second, or none.
    public static func groups(of items: [PhotoItem], sameBytes: [[PhotoUID]], includesVideos: Bool) -> [[PhotoUID]] {
        let pairedVideos = Set(items.compactMap(\.relatedVideoUID))
        let laterCopies = Set(sameBytes.flatMap { $0.dropFirst() })
        var keys: [SecondAndKind] = []
        var itemsByKey: [SecondAndKind: [PhotoItem]] = [:]
        for item in items
        where !item.isBurstCandidate && !pairedVideos.contains(item.uid) && !laterCopies.contains(item.uid)
            && (includesVideos || !item.isVideo)
        {
            let key = SecondAndKind(
                second: Int64(item.captureTime.timeIntervalSince1970.rounded(.down)), isVideo: item.isVideo)
            if itemsByKey[key] == nil { keys.append(key) }
            itemsByKey[key, default: []].append(item)
        }
        return keys.flatMap { moments(of: itemsByKey[$0] ?? []) }.filter { $0.count > 1 }
    }

    private struct SecondAndKind: Hashable {
        let second: Int64
        let isVideo: Bool
    }

    /// Splits the items of one second into groups whose members have the same known moment or none.
    private static func moments(of items: [PhotoItem]) -> [[PhotoUID]] {
        var rest = items
        var groups: [[PhotoUID]] = []
        while let first = rest.first {
            var group = [first]
            var left: [PhotoItem] = []
            for item in rest.dropFirst() {
                if group.allSatisfy({ sameMoment($0, item) }) { group.append(item) } else { left.append(item) }
            }
            groups.append(group.map(\.uid))
            rest = left
        }
        return groups
    }

    /// The moments within the second agree to the millisecond, or one item has none.
    private static func sameMoment(_ first: PhotoItem, _ other: PhotoItem) -> Bool {
        guard let moment = first.timelineOrder?.exactCaptureTime,
            let otherMoment = other.timelineOrder?.exactCaptureTime
        else { return true }
        return abs(moment.timeIntervalSince(otherMoment)) < 0.001
    }
}
