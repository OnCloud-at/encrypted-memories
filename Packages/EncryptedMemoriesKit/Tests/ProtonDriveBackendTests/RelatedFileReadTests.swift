import Foundation
import Testing

@testable import ProtonDriveBackend

/// The read of related files from one metadata answer: their types, and the names that the caller admits. The fake
/// armors a name as `sealed:<name>` and counts the key reads and the decryptions.
@Suite
struct RelatedFileReadTests {
    private struct KeyUnavailable: Error {}

    private final class Crypto: @unchecked Sendable {
        var keyReads = 0
        var decrypted: [String] = []
        var keyFails = false

        func rootKey() throws -> String {
            keyReads += 1
            if keyFails { throw KeyUnavailable() }
            return "root"
        }

        func decrypt(_ armored: String, _ key: String) throws -> String {
            #expect(key == "root")
            guard armored.hasPrefix("sealed:") else { throw KeyUnavailable() }
            let name = String(armored.dropFirst("sealed:".count))
            decrypted.append(name)
            return name
        }
    }

    /// Metadata links as the server answers them: link ID, type and armored name, each optional.
    private func links(_ rows: [(id: String, mime: String?, name: String?)]) throws -> [AlbumPhotoLinkBody] {
        let body = rows.map { row -> [String: Any] in
            var link: [String: Any] = ["LinkID": row.id, "State": 1]
            if let mime = row.mime { link["MIMEType"] = mime }
            if let name = row.name { link["Name"] = name }
            return link
        }
        return try JSONDecoder().decode(
            [AlbumPhotoLinkBody].self, from: JSONSerialization.data(withJSONObject: body))
    }

    @Test
    func everyLinkKeepsItsTypeAndOnlyAdmittedNamesDecrypt() async throws {
        let crypto = Crypto()
        let files = try await RelatedFileRead.files(
            in: try links([
                ("video", "video/quicktime", "sealed:FullSizeRender.mov"),
                ("plist", "application/xml", "sealed:Adjustments.plist"),
                ("broken", "video/quicktime", "not-sealed"),
                ("video", "image/heic", "sealed:Duplicate.heic"),
            ]),
            decryptingNamesWhere: { $0.linkID != "plist" }, rootKey: crypto.rootKey, decrypt: crypto.decrypt)

        #expect(files["video"] == .init(mimeType: "video/quicktime", name: "FullSizeRender.mov"), "the first link wins")
        #expect(files["plist"] == .init(mimeType: "application/xml", name: nil), "a name the caller leaves out")
        #expect(files["broken"] == .init(mimeType: "video/quicktime", name: nil), "a name that does not decrypt")
        #expect(crypto.keyReads == 1)
        #expect(crypto.decrypted == ["FullSizeRender.mov"])
    }

    @Test
    func theRootKeyIsReadOnlyWhenAnAdmittedLinkHasAName() async throws {
        let crypto = Crypto()
        let files = try await RelatedFileRead.files(
            in: try links([("unnamed", "video/quicktime", nil), ("left-out", "image/heic", "sealed:IMG_1.HEIC")]),
            decryptingNamesWhere: { $0.linkID == "unnamed" }, rootKey: crypto.rootKey, decrypt: crypto.decrypt)

        #expect(crypto.keyReads == 0)
        #expect(files.mapValues(\.mimeType) == ["unnamed": "video/quicktime", "left-out": "image/heic"])
        #expect(files.values.allSatisfy { $0.name == nil })
    }

    @Test
    func aFailedKeyReadThrows() async throws {
        let crypto = Crypto()
        crypto.keyFails = true
        await #expect(throws: KeyUnavailable.self) {
            _ = try await RelatedFileRead.files(
                in: try links([("video", "video/quicktime", "sealed:IMG_1.MOV")]), rootKey: crypto.rootKey,
                decrypt: crypto.decrypt)
        }
    }

    @Test
    func theMotionReadDecryptsOnlyTheRequestedNamesOfVideos() async throws {
        let crypto = Crypto()
        let answer = try await LivePhotoMotionLinks.answer(
            links: try links([
                ("paired", "video/quicktime", "sealed:IMG_1.MOV"),
                ("edited", "video/quicktime", "sealed:FullSizeRender.mov"),
                ("plist", "application/xml", "sealed:Adjustments.plist"),
                ("original", "image/heic", "sealed:IMG_1.HEIC"),
                ("other-photo", "video/quicktime", "sealed:IMG_2.MOV"),
            ]),
            nameLinkIDs: ["paired", "edited", "plist", "original"], rootKey: crypto.rootKey, decrypt: crypto.decrypt)

        #expect(answer.namesRead)
        #expect(
            crypto.decrypted.sorted() == ["FullSizeRender.mov", "IMG_1.MOV"], "no plist, image or unrequested name")
        #expect(answer.files["edited"]?.name == "FullSizeRender.mov")
        #expect(answer.files["original"] == .init(mimeType: "image/heic", name: nil))
        #expect(answer.files["other-photo"] == .init(mimeType: "video/quicktime", name: nil))
    }

    @Test
    func theMotionReadReadsNoKeyWhenNoRequestedVideoHasAName() async throws {
        let crypto = Crypto()
        let answer = try await LivePhotoMotionLinks.answer(
            links: try links([("plist", "application/xml", "sealed:Adjustments.plist"), ("motion", "video/mp4", nil)]),
            nameLinkIDs: ["plist", "motion"], rootKey: crypto.rootKey, decrypt: crypto.decrypt)

        #expect(answer.namesRead)
        #expect(crypto.keyReads == 0)
    }

    @Test
    func aKeyFailureKeepsTheTypesAndLeavesTheNamesUnread() async throws {
        let crypto = Crypto()
        crypto.keyFails = true
        let answer = try await LivePhotoMotionLinks.answer(
            links: try links([
                ("paired", "video/quicktime", "sealed:IMG_1.MOV"),
                ("edited", "video/quicktime", "sealed:FullSizeRender.mov"),
                ("single", "video/quicktime", "sealed:IMG_2.MOV"),
            ]),
            nameLinkIDs: ["paired", "edited"], rootKey: crypto.rootKey, decrypt: crypto.decrypt)

        #expect(!answer.namesRead)
        #expect(
            answer.files.mapValues(\.mimeType) == [
                "paired": "video/quicktime", "edited": "video/quicktime", "single": "video/quicktime",
            ])
        #expect(answer.files.values.allSatisfy { $0.name == nil })
    }

    @Test
    func aCancelledKeyReadEndsTheMotionRead() async throws {
        await #expect(throws: CancellationError.self) {
            _ = try await LivePhotoMotionLinks.answer(
                links: try links([("paired", "video/quicktime", "sealed:IMG_1.MOV")]), nameLinkIDs: ["paired"],
                rootKey: { () async throws -> String in throw CancellationError() },
                decrypt: { name, _ in name })
        }
    }
}
