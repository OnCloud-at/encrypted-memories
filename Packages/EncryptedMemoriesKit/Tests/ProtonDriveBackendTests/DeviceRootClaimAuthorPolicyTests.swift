import ProtonDriveSDK
import Testing

@testable import ProtonDriveBackend

@Suite("Device root claim signer")
struct DeviceRootClaimAuthorPolicyTests {
    private let allowed = Set(["owner@example.test", "alias@example.test"])

    @Test func acceptsVerifiedAccountAddress() {
        #expect(
            DeviceRootClaimAuthorPolicy.accepts(
                .init(emailAddress: "ALIAS@example.test", signatureVerificationError: nil),
                ownerAddresses: allowed))
    }

    @Test func rejectsForeignMissingAndFailedAuthors() {
        #expect(
            !DeviceRootClaimAuthorPolicy.accepts(
                .init(emailAddress: "foreign@example.test", signatureVerificationError: nil),
                ownerAddresses: allowed))
        #expect(
            !DeviceRootClaimAuthorPolicy.accepts(
                .init(emailAddress: nil, signatureVerificationError: nil),
                ownerAddresses: allowed))
        #expect(
            !DeviceRootClaimAuthorPolicy.accepts(
                .init(emailAddress: "owner@example.test", signatureVerificationError: "bad signature"),
                ownerAddresses: allowed))
    }

    @Test func unrelatedClaimFreeFolderDoesNotRequireOwnerSigner() {
        let foreign = Author(emailAddress: "collaborator@example.test", signatureVerificationError: nil)
        #expect(
            DeviceRootClaimFolderPolicy.disposition(
                hasClaim: false, nameAuthor: foreign, keyAuthor: foreign,
                ownerAddresses: allowed) == .missing)
        #expect(
            DeviceRootClaimFolderPolicy.disposition(
                hasClaim: true, nameAuthor: foreign, keyAuthor: foreign,
                ownerAddresses: allowed) == .unverified)
    }
}
