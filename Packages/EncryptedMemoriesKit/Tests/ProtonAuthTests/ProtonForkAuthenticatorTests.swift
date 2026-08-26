import CryptoKit
import Foundation
import PhotosCore
import Testing

@testable import ProtonAuth

@Suite("Proton fork authentication")
struct ProtonForkAuthenticatorTests {
    @Test func sharedProgressPresentationUsesCoreCopy() {
        #expect(
            ProtonAuthProgressPresentation.status(for: .requestingLink)
                == L10n.string("auth.progress_requesting_link")
        )
        #expect(
            ProtonAuthProgressPresentation.status(for: .waitingForBrowser)
                == L10n.string("auth.progress_waiting_for_browser")
        )
        #expect(
            ProtonAuthProgressPresentation.status(for: .finalizing)
                == L10n.string("auth.progress_finalizing")
        )
    }

    @Test func defaultProtonAPIConfigUsesOfficialExternalDriveIdentifierShape() {
        let config = ProtonAPIConfig()

        #expect(config.appVersion == "external-drive-encryptedmemories@1.0.0-stable")
        #expect(config.authClientID == "external-drive")
    }

    @Test func sharedClientConfigUsesProtonDocumentedExternalDriveNamespace() {
        #expect(
            ProtonAPIConfig.externalDriveEncryptedMemories.appVersion == "external-drive-encryptedmemories@1.0.0-stable"
        )
        #expect(ProtonAPIConfig.externalDriveEncryptedMemories.authClientID == "external-drive")
    }

    @Test func defaultSignInPayloadIdentifiesEncryptedMemoriesClient() async throws {
        let authenticator = ProtonForkAuthenticator()
        let key = SymmetricKey(data: Data(repeating: 0, count: 32))

        let url = await authenticator.signInURL(userCode: "USER-CODE", encryptionKey: key)
        let fragment = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment)
        let encodedPayload = try #require(fragment.split(separator: "payload=").last.map(String.init))
        let payload = try #require(encodedPayload.removingPercentEncoding)

        #expect(url.absoluteString.hasPrefix("https://account.proton.me/desktop/login?app=drive&pv=3#payload="))
        #expect(payload.hasPrefix("0:USER-CODE:"))
        #expect(payload.hasSuffix(":external-drive"))
    }
}
