import CryptoKit
import Foundation

/// Create one helper for each report. Its random salt stays private and is never encoded or persisted.
/// Part 1 exports counts only; later allowlisted identifier fields must use this helper instead of raw values.
public struct SupportReportIdentifierHasher: Sendable {
    private let salt = SymmetricKey(size: .bits256)

    public init() {}

    public func hash(_ identifier: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(identifier.utf8), using: salt)
            .map { String(format: "%02x", $0) }.joined()
    }
}
