import Foundation
import PhotosCore

@testable import UploadCore

/// One server link table supplies every upload, duplicate, replacement, and album answer.
final class EditScenarioServer: PhotoUploading, UploadDuplicateChecking, EditReplacementRemote,
    SeriesAlbumCarryOver, @unchecked Sendable
{
    enum State: String, Sendable {
        case active
        case trashed
        case deleted
    }

    struct Link: Sendable {
        let linkID: String
        let nameHash: String
        let contentHash: String
        var state: State
        let mainLinkID: String?
        let captureTime: Date
        var favorite = false
        var albums: Set<SeriesAlbumReference> = []
        let assetID: String
        let generation: Int
        let isOriginal: Bool
        var personDeleted = false

        var uid: PhotoUID { PhotoUID(volumeID: "vol", nodeID: linkID) }
        var duplicate: RemotePhotoDuplicate {
            RemotePhotoDuplicate(
                nameHash: nameHash, contentHash: contentHash,
                linkState: state == .active ? .active : state == .trashed ? .trashed : nil,
                linkID: linkID)
        }
    }

    struct Step: Sendable {
        let action: String
        let links: [Link]
        let violations: [String]
        let trashedByBackup: [String]
    }

    let capabilities = UploadBackendCapabilities.sdkUploader
    private let lock = NSLock()
    private var table: [String: Link] = [:]
    private var history: [Step] = []
    private var nextID = 1
    private var failTrash = false
    private let ownAlbumIDs: Set<String> = ["own-album"]

    var links: [Link] { lock.withLock { orderedLinks() } }
    var steps: [Step] { lock.withLock { history } }

    private func orderedLinks() -> [Link] {
        table.values.sorted { $0.linkID < $1.linkID }
    }

    static func contentHash(_ digest: Data) -> String {
        "ch(\(UploadContentSHA1.hexString(digest: digest)))"
    }

    private func record(_ action: String, violations: [String] = [], trashedByBackup: [String] = []) {
        history.append(
            Step(action: action, links: orderedLinks(), violations: violations, trashedByBackup: trashedByBackup))
    }

    func failNextTrash() { lock.withLock { failTrash = true } }

    func upload(
        _ request: PhotoUploadRequest,
        onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        let digest = try UploadContentSHA1.digest(ofFileAt: request.fileURL)
        guard request.expectedSHA1 == digest else {
            throw UploadError.backend("The scenario upload bytes do not match the pipeline identity")
        }
        onProgress(.init(phase: .uploading, fraction: 1))
        return lock.withLock {
            let assetID = request.fileURL.deletingLastPathComponent().lastPathComponent
            let generation = Int(request.fileURL.lastPathComponent.split(separator: "-")[0]) ?? 0
            let id = String(format: "link-%04d", nextID)
            nextID += 1
            let main = request.mainPhotoUID?.nodeID
            var violations: [String] = []
            if main == nil && table.values.contains(where: { $0.assetID == assetID && $0.personDeleted }) {
                violations.append("S5 uploaded \(id) after the person deleted \(assetID)")
            }
            if let main, table[main]?.state != .active {
                violations.append("An upload referenced inactive main \(main)")
            }
            table[id] = Link(
                linkID: id, nameHash: "nh(\(request.name))", contentHash: Self.contentHash(digest),
                state: .active, mainLinkID: main, captureTime: request.captureTime,
                assetID: assetID, generation: generation,
                isOriginal: request.name.hasSuffix(".HEIC") || request.name.hasSuffix(".MOV"))
            record("upload \(id)", violations: violations)
            return PhotoUID(volumeID: "vol", nodeID: id)
        }
    }

    func cancel(token: UUID) async {}
    func nameHash(forCorrectedName name: String) async throws -> String { "nh(\(name))" }
    func contentHash(forSHA1Hex sha1Hex: String) async throws -> String { "ch(\(sha1Hex))" }
    func hashKeyEpoch() async throws -> String { "scenario-epoch" }

    func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate] {
        lock.withLock {
            // Trashed mains and active orphaned related files remain visible to duplicate checks.
            // The seam has no deleted link state. A permanently deleted link is absent remotely.
            orderedLinks().filter { $0.state != .deleted && nameHashes.contains($0.nameHash) }.map(\.duplicate)
        }
    }

    func findDuplicate(contentHash: String) async throws -> RemotePhotoDuplicate? {
        lock.withLock {
            // The content index proves only active content. Name lookup still includes trash.
            orderedLinks().first { $0.state == .active && $0.contentHash == contentHash }?.duplicate
        }
    }

    func findExactActiveDuplicates(correctedName: String, sha1Digest: Data) async -> [PhotoUID] {
        lock.withLock {
            orderedLinks().filter {
                $0.state == .active && $0.nameHash == "nh(\(correctedName))"
                    && $0.contentHash == Self.contentHash(sha1Digest)
            }.map(\.uid)
        }
    }

    func relatedPhotoLinkIDs(ofMainLinkID mainLinkID: String) async throws -> Set<String> {
        try lock.withLock {
            guard let main = table[mainLinkID], main.state != .deleted else {
                throw UploadError.backend("Related photos of the main photo are unavailable")
            }
            return Set(table.values.filter { $0.mainLinkID == mainLinkID && $0.state != .deleted }.map(\.linkID))
        }
    }

    func remoteContentIndexHealth() async throws -> UploadRemoteContentIndexHealth {
        lock.withLock { .complete(indexedCount: table.values.filter { $0.state == .active }.count) }
    }

    func ownPhotosVolumeID() async throws -> String { "vol" }

    func activeUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> {
        lock.withLock { Set(uids.filter { table[$0.nodeID]?.state == .active }) }
    }

    func favoriteUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> {
        lock.withLock { Set(uids.filter { table[$0.nodeID]?.favorite == true }) }
    }

    func markFavorite(_ uids: [PhotoUID]) async throws {
        lock.withLock {
            for uid in uids { table[uid.nodeID]?.favorite = true }
            record("mark favorite")
        }
    }

    func albums(containing uid: PhotoUID) async throws -> [SeriesAlbumReference] {
        lock.withLock {
            (table[uid.nodeID]?.albums ?? []).sorted {
                ($0.volumeID, $0.albumID) < ($1.volumeID, $1.albumID)
            }
        }
    }

    func addPhotos(_ uids: [PhotoUID], toOwnAlbum albumID: String) async throws {
        try lock.withLock {
            guard ownAlbumIDs.contains(albumID) else {
                throw UploadError.backend("The scenario album is not a known own-volume album")
            }
            for uid in uids {
                table[uid.nodeID]?.albums.insert(.init(volumeID: "vol", albumID: albumID))
            }
            record("carry album \(albumID)")
        }
    }

    func decorate(_ uid: PhotoUID) {
        lock.withLock {
            table[uid.nodeID]?.favorite = true
            table[uid.nodeID]?.albums = [
                .init(volumeID: "vol", albumID: "own-album"),
                .init(volumeID: "shared-vol", albumID: "shared-album"),
            ]
            record("person favorites and files \(uid.nodeID)")
        }
    }

    func trash(_ uids: [PhotoUID]) async throws {
        try lock.withLock {
            if failTrash {
                failTrash = false
                record("failed backup trash")
                throw UploadError.backend("The scenario trash write failed once")
            }
            var violations: [String] = []
            let targets = Set(uids.map(\.nodeID))
            for uid in uids {
                guard let target = table[uid.nodeID], target.state == .active else { continue }
                let replacements = table.values.filter {
                    $0.mainLinkID == nil && $0.state == .active && $0.assetID == target.assetID
                        && !targets.contains($0.linkID)
                }
                if target.mainLinkID != nil || replacements.isEmpty {
                    violations.append("S6 backup trash targeted something other than an earlier asset main")
                }
                let originals = table.values.filter {
                    ($0.linkID == target.linkID || $0.mainLinkID == target.linkID) && $0.isOriginal
                        && $0.state == .active
                }
                for original in originals {
                    let preserved = table.values.contains { copy in
                        guard copy.state == .active, copy.contentHash == original.contentHash,
                            copy.assetID == target.assetID
                        else { return false }
                        let holderID = copy.mainLinkID ?? copy.linkID
                        return !targets.contains(holderID) && table[holderID]?.state == .active
                            && table[holderID]?.mainLinkID == nil
                    }
                    if !preserved {
                        violations.append("S2 backup trash lost original resource \(original.linkID)")
                    }
                }
                // Service rule: only the main changes state. No related-file event exists.
                table[uid.nodeID]?.state = .trashed
            }
            record("backup trash \(uids.map(\.nodeID))", violations: violations, trashedByBackup: uids.map(\.nodeID))
        }
    }

    func personTrash(_ uid: PhotoUID) {
        lock.withLock {
            table[uid.nodeID]?.state = .trashed
            table[uid.nodeID]?.personDeleted = true
            record("person trash \(uid.nodeID)")
        }
    }

    func personRestore(_ uid: PhotoUID) {
        lock.withLock {
            guard let restored = table[uid.nodeID], restored.state == .trashed else { return }
            table[uid.nodeID]?.state = .active
            for id in Array(table.keys) where table[id]?.assetID == restored.assetID {
                table[id]?.personDeleted = false
            }
            record("person restore \(uid.nodeID)")
        }
    }

    /// Assumption: emptying trash deletes related files as well as their trashed mains.
    func personEmptyTrash() {
        lock.withLock {
            let mains = Set(table.values.filter { $0.mainLinkID == nil && $0.state == .trashed }.map(\.linkID))
            for id in Array(table.keys) {
                if mains.contains(id) || table[id]?.mainLinkID.map(mains.contains) == true {
                    table[id]?.state = .deleted
                }
            }
            record("person empty trash")
        }
    }

    /// Seeds an earlier device's trashed copy from real uploaded content, without a local journal entry.
    func addHistoricalTrashedCopy(of uid: PhotoUID) throws {
        try lock.withLock {
            guard let original = table[uid.nodeID] else { throw UploadError.backend("Missing historical source") }
            let id = String(format: "link-%04d", nextID)
            nextID += 1
            table[id] = Link(
                linkID: id, nameHash: original.nameHash, contentHash: original.contentHash,
                state: .trashed, mainLinkID: nil, captureTime: original.captureTime,
                assetID: original.assetID, generation: 0, isOriginal: true)
            record("earlier device trashed \(id)")
        }
    }
}
