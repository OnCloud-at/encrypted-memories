import Foundation
import ProtonAuth
import ProtonCoreCryptoGoInterface
import ProtonCoreCryptoPatchedGoImplementation
import Testing

@testable import ProtonDriveBackend

private let photosBootstrapCryptoReady: Void = {
    injectDefaultCryptoImplementation()
}()

private func makePhotosBootstrapSession() -> DriveSession {
    DriveSession(
        session: ProtonSession(uid: "test-uid", accessToken: "at", refreshToken: "rt", keyPassword: "kp"),
        store: SessionKeychainStore(service: "at.oncloud.encryptedmemories.tests.never-used"),
        accountCacheDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("photos-bootstrap-tests-\(UUID().uuidString)"),
        urlProtocolClasses: [StubURLProtocol.self]
    )
}

private func photosBootstrapBody(_ request: StubURLProtocol.Recorded) throws -> [String: Any] {
    let data = try #require(request.body)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

extension DriveSessionStubSuite {
    @Suite struct PhotosVolumeBootstrapServiceTests {
        @Test func existingPhotosShareIsReturnedWithoutCreatingAVolume() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.route(
                "GET /drive/shares",
                json: #"""
                    {"Code":1000,"Shares":[
                        {"ShareID":"share1","VolumeID":"vol1","LinkID":"root1","State":1,"Locked":false}
                    ]}
                    """#)
            let service = PhotosVolumeBootstrapService(
                session: makePhotosBootstrapSession(),
                crypto: DriveCrypto(addressKeys: [], signers: [])
            )

            let context = try await service.resolve()

            #expect(context == PhotosShareContext(volumeID: "vol1", shareID: "share1", rootLinkID: "root1"))
            let requests = StubURLProtocol.requests()
            #expect(requests.count == 1)
            #expect(requests.first?.path == "/drive/shares?ShareType=4")
        }

        @Test func freshAccountCreatesOfficialEncryptedPhotoVolumeOnce() async throws {
            _ = photosBootstrapCryptoReady
            StubURLProtocol.reset()
            StubURLProtocol.route("GET /drive/shares", json: #"{"Code":1000,"Shares":[]}"#)
            StubURLProtocol.route(
                "POST /drive/photos/volumes",
                json: #"""
                    {"Code":1000,"Volume":{
                        "VolumeID":"new-volume","Share":{"ShareID":"new-share","LinkID":"new-root"}
                    }}
                    """#)

            let boot = DriveCrypto(addressKeys: [], signers: [])
            let addressPassphrase = try boot.randomBase64Token()
            let addressKey = UnlockableKey(
                armored: try boot.generateLockedNodeKey(passphrase: addressPassphrase),
                passphrase: addressPassphrase
            )
            let signer = DriveCryptoSigner(
                addressID: "address-1",
                addressKeyID: "address-key-1",
                email: "owner@proton.me",
                key: addressKey
            )
            let crypto = DriveCrypto(addressKeys: [addressKey], signers: [signer])
            let service = PhotosVolumeBootstrapService(session: makePhotosBootstrapSession(), crypto: crypto)

            async let first = service.resolve()
            async let second = service.resolve()
            let contexts = try await [first, second]

            #expect(
                contexts
                    == Array(
                        repeating: PhotosShareContext(
                            volumeID: "new-volume",
                            shareID: "new-share",
                            rootLinkID: "new-root"
                        ), count: 2))
            let requests = StubURLProtocol.requests()
            #expect(requests.filter { $0.path == "/drive/shares?ShareType=4" }.count == 1)
            let createRequest = try #require(requests.first { $0.path == "/drive/photos/volumes" })
            #expect(requests.filter { $0.path == "/drive/photos/volumes" }.count == 1)

            let body = try photosBootstrapBody(createRequest)
            let share = try #require(body["Share"] as? [String: Any])
            let link = try #require(body["Link"] as? [String: Any])
            #expect(share["AddressID"] as? String == "address-1")
            #expect(share["AddressKeyID"] as? String == "address-key-1")
            #expect(!(try #require(share["PassphraseSignature"] as? String)).isEmpty)
            #expect(!(try #require(link["NodePassphraseSignature"] as? String)).isEmpty)

            let sharePassphrase = try crypto.decryptArmored(
                try #require(share["Passphrase"] as? String),
                with: [addressKey]
            ).getString()
            let shareKey = UnlockableKey(
                armored: try #require(share["Key"] as? String),
                passphrase: sharePassphrase
            )
            let rootPassphrase = try crypto.decryptArmored(
                try #require(link["NodePassphrase"] as? String),
                with: [shareKey]
            ).getString()
            let rootKey = UnlockableKey(
                armored: try #require(link["NodeKey"] as? String),
                passphrase: rootPassphrase
            )
            #expect(
                try crypto.decryptArmored(
                    try #require(link["Name"] as? String),
                    with: [shareKey]
                ).getString() == "PhotosRoot")
            let hashKeyToken = try crypto.decryptArmored(
                try #require(link["NodeHashKey"] as? String),
                with: [rootKey]
            ).getString()
            #expect(Data(base64Encoded: hashKeyToken)?.count == 32)
        }
    }
}
