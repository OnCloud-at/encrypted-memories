import CryptoKit
import Foundation
import MLSearchCore

public enum MLSearchKeyDerivation {
    public static func localIndexKey(accountUID: String, keyPassword: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(keyPassword.utf8)),
            salt: Data("EncryptedMemories.ml-index.v1.\(accountUID)".utf8),
            info: Data("semantic-search-vectors".utf8),
            outputByteCount: 32
        )
    }

    public static func localDerivedDataKeys(
        accountUID: String,
        keyPassword: String
    ) -> MLDerivedDataKeys {
        let input = SymmetricKey(data: Data(keyPassword.utf8))
        let salt = Data("EncryptedMemories.ml-index.v1.\(accountUID)".utf8)
        return MLDerivedDataKeys(
            encryption: HKDF<SHA256>.deriveKey(
                inputKeyMaterial: input,
                salt: salt,
                info: Data("native-derived-data-encryption".utf8),
                outputByteCount: 32
            ),
            tokenLookup: HKDF<SHA256>.deriveKey(
                inputKeyMaterial: input,
                salt: salt,
                info: Data("native-derived-data-token-lookup".utf8),
                outputByteCount: 32
            )
        )
    }
}

public struct MLDerivedDataKeys: Sendable {
    public let encryption: SymmetricKey
    public let tokenLookup: SymmetricKey

    public init(encryption: SymmetricKey, tokenLookup: SymmetricKey) {
        self.encryption = encryption
        self.tokenLookup = tokenLookup
    }
}

public struct CryptoKitMLVectorCipher: MLVectorCipher, Sendable {
    private let key: SymmetricKey
    private let accountUID: String

    public init(key: SymmetricKey, accountUID: String) {
        self.key = key
        self.accountUID = accountUID
    }

    public func seal(_ plaintext: Data, context: MLVectorCipherContext) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData(for: context))
        guard let combined = box.combined else { throw MLVectorCipherError.sealFailed }
        return combined
    }

    public func open(_ ciphertext: Data, context: MLVectorCipherContext) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key, authenticating: associatedData(for: context))
    }

    /// AES-GCM combined representation is length-deterministic: 12-byte nonce + payload +
    /// 16-byte tag. Lets the store reject wrong-sized rows before decrypting.
    public func sealedByteCount(forPlaintextByteCount plaintextByteCount: Int) -> Int? {
        plaintextByteCount + 12 + 16
    }

    private func associatedData(for context: MLVectorCipherContext) -> Data {
        let fields = [
            "ns=ml-search",
            "v=1",
            "acct=\(accountUID)",
            "model=\(context.descriptor.identifier)",
            "epoch=\(context.descriptor.version)",
            "dim=\(context.descriptor.embeddingDimension)",
            "vol=\(context.uid.volumeID)",
            "node=\(context.uid.nodeID)",
        ]
        return Data(fields.joined(separator: "\u{1f}").utf8)
    }
}

public enum MLVectorCipherError: Error {
    case sealFailed
}

public struct CryptoKitMLDerivedDataCipher: MLDerivedDataCipher, Sendable {
    private let encryptionKey: SymmetricKey
    private let tokenLookupKey: SymmetricKey

    public init(keys: MLDerivedDataKeys) {
        self.encryptionKey = keys.encryption
        self.tokenLookupKey = keys.tokenLookup
    }

    public func seal(_ plaintext: Data, context: MLDerivedDataCipherContext) throws -> Data {
        let box = try AES.GCM.seal(
            plaintext,
            using: encryptionKey,
            authenticating: associatedData(for: context)
        )
        guard let combined = box.combined else { throw MLVectorCipherError.sealFailed }
        return combined
    }

    public func open(_ ciphertext: Data, context: MLDerivedDataCipherContext) throws -> Data {
        try AES.GCM.open(
            AES.GCM.SealedBox(combined: ciphertext),
            using: encryptionKey,
            authenticating: associatedData(for: context)
        )
    }

    public func tokenDigest(
        normalizedToken: String,
        accountIdentifier: String,
        artifactNamespace: String
    ) throws -> Data {
        let fields = [
            "ns=ml-derived-token",
            "v=1",
            "acct=\(accountIdentifier)",
            "artifact=\(artifactNamespace)",
            "token=\(normalizedToken)",
        ]
        return Data(
            HMAC<SHA256>.authenticationCode(
                for: Data(fields.joined(separator: "\u{1f}").utf8),
                using: tokenLookupKey
            ))
    }

    private func associatedData(for context: MLDerivedDataCipherContext) -> Data {
        let fields = [
            "ns=ml-derived-output",
            "v=1",
            "acct=\(context.accountIdentifier)",
            "artifact=\(context.artifactNamespace)",
            "vol=\(context.uid.volumeID)",
            "node=\(context.uid.nodeID)",
        ]
        return Data(fields.joined(separator: "\u{1f}").utf8)
    }
}
