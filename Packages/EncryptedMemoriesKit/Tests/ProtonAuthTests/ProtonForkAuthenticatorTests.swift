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

    @Test func defaultProtonAPIConfigUsesOfficialExternalDriveIdentifierShape() throws {
        let config = ProtonAPIConfig()

        #expect(config.appVersion == ProtonAppVersionHeader.current())
        let pattern = /external-drive-encryptedmemories@\d+\.\d+\.\d+-(stable|beta|alpha)(\+[0-9a-f]{7,12})?/
        #expect(try pattern.wholeMatch(in: config.appVersion) != nil)
        #expect(config.authClientID == "external-drive")
    }

    @Test func sharedClientConfigUsesProtonDocumentedExternalDriveNamespace() {
        #expect(ProtonAPIConfig.externalDriveEncryptedMemories.appVersion == ProtonAppVersionHeader.current())
        #expect(ProtonAPIConfig.externalDriveEncryptedMemories.authClientID == "external-drive")
    }

    @Test func appVersionHeaderDescribesReleaseBuildsHonestly() {
        #expect(
            ProtonAppVersionHeader.value(version: "1.0.3", channel: "beta", buildCommit: "289e494abcdef0123456789")
                == "external-drive-encryptedmemories@1.0.3-beta+289e494abcde"
        )
        #expect(
            ProtonAppVersionHeader.value(version: "1.0.3", channel: "stable", buildCommit: nil)
                == "external-drive-encryptedmemories@1.0.3-stable"
        )
        #expect(
            ProtonAppVersionHeader.value(version: " 2.1 ", channel: "BETA", buildCommit: "ABC123F")
                == "external-drive-encryptedmemories@2.1.0-beta+abc123f"
        )
    }

    @Test func appVersionHeaderNeverClaimsAReleaseForUnknownBuilds() {
        #expect(
            ProtonAppVersionHeader.value(version: nil, channel: nil, buildCommit: "unknown")
                == "external-drive-encryptedmemories@0.0.0-alpha"
        )
        #expect(
            ProtonAppVersionHeader.value(
                version: "1.0.3-beta.15",
                channel: "rc",
                buildCommit: "$(ENCRYPTED_MEMORIES_BUILD_COMMIT)"
            ) == "external-drive-encryptedmemories@0.0.0-alpha"
        )
        #expect(ProtonAppVersionHeader.semanticVersion("01.002.3") == "1.2.3")
        #expect(ProtonAppVersionHeader.semanticVersion("1.2.3.4") == "0.0.0")
        #expect(ProtonAppVersionHeader.buildMetadata("abc12") == nil)
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
