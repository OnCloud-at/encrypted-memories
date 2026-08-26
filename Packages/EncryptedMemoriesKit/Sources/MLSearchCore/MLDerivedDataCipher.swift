import Foundation
import PhotosCore

public struct MLDerivedDataCipherContext: Equatable, Sendable {
    public let accountIdentifier: String
    public let uid: PhotoUID
    public let artifactNamespace: String

    public init(accountIdentifier: String, uid: PhotoUID, artifactNamespace: String) {
        self.accountIdentifier = accountIdentifier
        self.uid = uid
        self.artifactNamespace = artifactNamespace
    }
}

/// Authenticated encryption plus deterministic, account-keyed token lookup for private derived
/// search data. Persistent stores have no plaintext fallback.
public protocol MLDerivedDataCipher: Sendable {
    func seal(_ plaintext: Data, context: MLDerivedDataCipherContext) throws -> Data
    func open(_ ciphertext: Data, context: MLDerivedDataCipherContext) throws -> Data
    func tokenDigest(
        normalizedToken: String,
        accountIdentifier: String,
        artifactNamespace: String
    ) throws -> Data
}
