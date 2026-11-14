import Foundation

/// The type and the decrypted name of each link of a `fetch_metadata` answer. Photos are children of the photos root,
/// whose key decrypts their names.
enum RelatedFileRead {
    /// Each link of `links` by link ID with its type, and with its name when `decryptsName` admits the link. `rootKey`
    /// runs only when an admitted link has a name, and at most once; its failure throws. A name that does not decrypt
    /// stays nil.
    static func files<Key>(
        in links: [AlbumPhotoLinkBody],
        decryptingNamesWhere decryptsName: (AlbumPhotoLinkBody) -> Bool = { _ in true },
        rootKey: () async throws -> Key,
        decrypt: (_ armoredName: String, _ rootKey: Key) throws -> String
    ) async throws -> [String: BurstFrameVerdicts.RelatedFile] {
        let key = links.contains { $0.name != nil && decryptsName($0) } ? try await rootKey() : nil
        var files: [String: BurstFrameVerdicts.RelatedFile] = [:]
        for link in links {
            guard let linkID = link.linkID, files[linkID] == nil else { continue }
            var name: String?
            if let key, let armored = link.name, decryptsName(link) { name = try? decrypt(armored, key) }
            files[linkID] = .init(mimeType: link.mimeType, name: name)
        }
        return files
    }
}
