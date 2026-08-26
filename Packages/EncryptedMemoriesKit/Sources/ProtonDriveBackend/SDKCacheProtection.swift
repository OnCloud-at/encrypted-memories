import CryptoKit
import Foundation

/// Account-scoped protection for sdk-swift 0.20+'s unified cache. The SDK may persist decrypted
/// node material in this store, so a disk path is only valid together with a stable 32-byte key.
enum SDKCacheProtection {
    static func fileName(accountUID: String) -> String {
        "sdk-cache-v1-\(accountUID).sqlite"
    }

    static func encryptionKey(accountUID: String, keyPassword: String) -> Data {
        let input = SymmetricKey(data: Data(keyPassword.utf8))
        let salt = Data("EncryptedMemories.sdk-cache.v1.\(accountUID)".utf8)
        let info = Data("proton-drive-sdk-unified-cache".utf8)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: input,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }
}
