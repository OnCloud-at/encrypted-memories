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
    private func links(
        _ rows: [(id: String, mime: String?, name: String?)], xattrs: [String: String] = [:]
    ) throws -> [AlbumPhotoLinkBody] {
        let body = rows.map { row -> [String: Any] in
            var link: [String: Any] = ["LinkID": row.id, "State": 1]
            if let mime = row.mime { link["MIMEType"] = mime }
            if let name = row.name { link["Name"] = name }
            if let xattr = xattrs[row.id] {
                link["FileProperties"] = ["ActiveRevision": ["XAttr": xattr]]
                link["NodeKey"] = "sealed-key"
                link["NodePassphrase"] = "sealed-passphrase"
            }
            return link
        }
        return try JSONDecoder().decode(
            [AlbumPhotoLinkBody].self, from: JSONSerialization.data(withJSONObject: body))
    }

    @Test func playbackIgnoresUnrelatedIdentityAndDateFields() throws {
        let data = Data(
            #"{"Camera":{"CaptureTime":123},"iOS.photos":{"ICloudID":4,"ModificationTime":[],"PlaybackStyle":"videoLooping"}}"#
                .utf8)
        #expect(try LivePhotoMotionLinks.isLoopingPlayback(in: data))
        #expect(
            try !LivePhotoMotionLinks.isLoopingPlayback(
                in: Data(#"{"iOS.photos":{"PlaybackStyle":"futureStyle"}}"#.utf8)))
        #expect(try !LivePhotoMotionLinks.isLoopingPlayback(in: Data("{}".utf8)))
    }

    @Test func aMalformedPlaybackMarkerIsNotKnownAbsence() {
        #expect(throws: (any Error).self) {
            try LivePhotoMotionLinks.isLoopingPlayback(in: Data(#"{"iOS.photos":{"PlaybackStyle":true}}"#.utf8))
        }
    }

    @Test func mainPlaybackAndVideoNamesShareOneKeyRead() async throws {
        let crypto = Crypto()
        let payload = #"{"iOS.photos":{"PlaybackStyle":"videoLooping"}}"#
        var decrypted: [String] = []
        let result = try await LivePhotoMotionLinks.answer(
            links: try links(
                [
                    ("main", "image/heic", "sealed:IMG.HEIC"),
                    ("video", "video/quicktime", "sealed:FullSizeRender.mov"),
                    ("other", "image/heic", "sealed:Other.HEIC"),
                ], xattrs: ["main": payload, "other": payload]),
            nameLinkIDs: ["video"], rootKey: crypto.rootKey, decrypt: crypto.decrypt,
            playbackPhotoIDs: ["main"],
            decryptPlayback: { link, key in
                #expect(key == "root")
                decrypted.append(link.linkID ?? "")
                return try LivePhotoMotionLinks.isLoopingPlayback(
                    in: Data((LivePhotoMotionLinks.playbackXAttr(of: link) ?? "").utf8))
            })
        #expect(result.playback == ["main": true])
        #expect(result.unreadPlayback.isEmpty)
        #expect(crypto.keyReads == 1)
        #expect(crypto.decrypted == ["FullSizeRender.mov"])
        #expect(decrypted == ["main"])
    }

    @Test func aMainWithoutXattrIsKnownAbsenceWithoutReadingAKey() async throws {
        let crypto = Crypto()
        let result = try await LivePhotoMotionLinks.answer(
            links: try links([("main", "image/heic", nil)]), nameLinkIDs: [],
            rootKey: crypto.rootKey, decrypt: crypto.decrypt, playbackPhotoIDs: ["main"],
            decryptPlayback: { _, _ in
                Issue.record("no encrypted metadata to decrypt")
                return true
            })
        #expect(result.playback == ["main": false])
        #expect(result.unreadPlayback.isEmpty)
        #expect(crypto.keyReads == 0)
    }

    @Test func aMissingMainStaysUnread() async throws {
        let crypto = Crypto()
        let result = try await LivePhotoMotionLinks.answer(
            links: [], nameLinkIDs: [], rootKey: crypto.rootKey, decrypt: crypto.decrypt,
            playbackPhotoIDs: ["main"], decryptPlayback: { _, _ in true })
        #expect(result.playback.isEmpty)
        #expect(result.unreadPlayback == ["main"])
        #expect(crypto.keyReads == 0)
    }

    @Test func aFailedPlaybackKeyOrDecryptionStaysUnread() async throws {
        for keyFails in [true, false] {
            let crypto = Crypto()
            crypto.keyFails = keyFails
            let result = try await LivePhotoMotionLinks.answer(
                links: try links([("main", "image/heic", nil)], xattrs: ["main": "sealed-xattr"]),
                nameLinkIDs: [], rootKey: crypto.rootKey, decrypt: crypto.decrypt,
                playbackPhotoIDs: ["main"], decryptPlayback: { _, _ in throw KeyUnavailable() })
            #expect(result.playback.isEmpty)
            #expect(result.unreadPlayback == ["main"])
            #expect(crypto.keyReads == 1)
        }
    }

    @Test func playbackCancellationEndsTheRead() async throws {
        let crypto = Crypto()
        await #expect(throws: CancellationError.self) {
            _ = try await LivePhotoMotionLinks.answer(
                links: try links([("main", "image/heic", nil)], xattrs: ["main": "sealed-xattr"]),
                nameLinkIDs: [], rootKey: crypto.rootKey, decrypt: crypto.decrypt,
                playbackPhotoIDs: ["main"], decryptPlayback: { _, _ in throw CancellationError() })
        }
    }

    @Test func anInactiveMainNeverSuppliesPlaybackEvidence() async throws {
        let crypto = Crypto()
        let inactive = try JSONDecoder().decode(
            AlbumPhotoLinkBody.self,
            from: Data(
                #"{"LinkID":"main","State":0,"XAttr":"sealed-xattr"}"#.utf8))
        let result = try await LivePhotoMotionLinks.answer(
            links: [inactive], nameLinkIDs: [], rootKey: crypto.rootKey, decrypt: crypto.decrypt,
            playbackPhotoIDs: ["main"],
            decryptPlayback: { _, _ in
                Issue.record("inactive main")
                return true
            })
        #expect(result.playback.isEmpty)
        #expect(result.unreadPlayback == ["main"])
        #expect(crypto.keyReads == 0)
    }

    @Test func theActiveRevisionPrecedesAStaleTopLevelXattr() throws {
        let link = try JSONDecoder().decode(
            AlbumPhotoLinkBody.self,
            from: Data(
                #"{"LinkID":"main","XAttr":"stale","FileProperties":{"ActiveRevision":{"XAttr":"active"}}}"#.utf8))
        #expect(LivePhotoMotionLinks.playbackXAttr(of: link) == "active")
        let absent = try JSONDecoder().decode(
            AlbumPhotoLinkBody.self,
            from: Data(
                #"{"LinkID":"main","XAttr":"stale","FileProperties":{"ActiveRevision":{}}}"#.utf8))
        #expect(LivePhotoMotionLinks.playbackXAttr(of: absent) == nil)
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
