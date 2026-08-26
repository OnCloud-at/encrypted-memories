import Foundation
import Testing

@testable import ProtonDriveBackend

@Suite("Media type reconciliation")
struct MediaTypeReconciliationTests {
    @Test("standalone videos are tagged while Live Photo resources stay hidden")
    func uploadTagNormalization() {
        #expect(
            DriveSDKBridge.normalizedUploadTags(
                requested: [5],
                mediaType: "video/quicktime",
                isRelatedResource: false
            ) == [2, 5])
        #expect(
            DriveSDKBridge.normalizedUploadTags(
                requested: [2, 3],
                mediaType: "video/quicktime",
                isRelatedResource: true
            ) == [3])
        #expect(
            DriveSDKBridge.normalizedUploadTags(
                requested: [2, 4],
                mediaType: "image/heic",
                isRelatedResource: false
            ) == [4])
    }

    @Test("batched link metadata decodes the authoritative MIME type")
    func metadataMIMEDecode() throws {
        let data = Data(#"{"LinkID":"node-video","State":1,"Type":2,"MIMEType":"video/quicktime"}"#.utf8)
        let link = try JSONDecoder().decode(AlbumPhotoLinkBody.self, from: data)
        #expect(link.linkID == "node-video")
        #expect(link.mimeType == "video/quicktime")
    }
}
