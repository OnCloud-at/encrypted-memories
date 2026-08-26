import AppleSecurityCore
import Foundation

/// Device-local installation identity used to distinguish concurrent Proton upload clients. It is
/// not an account credential and never synchronizes through iCloud Keychain. A full app logout removes
/// it together with interrupted upload state; the next authenticated session creates a fresh identity.
public struct DeviceIdentityKeychainStore: Sendable {
    public static let defaultService = "at.oncloud.encryptedmemories.device-identity"
    private let item: AppleKeychainItem
    private let keychain: any AppleKeychainStoring

    public init(
        service: String = Self.defaultService,
        account: String = "installation"
    ) {
        self.init(service: service, account: account, keychain: SystemAppleKeychainStore())
    }

    public init(
        service: String,
        account: String,
        keychain: any AppleKeychainStoring
    ) {
        self.item = AppleKeychainItem(
            service: service,
            account: account,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
        self.keychain = keychain
    }

    public func loadOrCreate() -> String {
        if let existing = load() { return existing }

        let generated = UUID().uuidString
        let durable = try? keychain.dataOrInsert(Data(generated.utf8), for: item)
        return durable.flatMap { String(data: $0, encoding: .utf8) } ?? generated
    }

    func clear() {
        try? keychain.removeData(for: item)
    }

    private func load() -> String? {
        guard let data = try? keychain.data(for: item),
            let value = String(data: data, encoding: .utf8),
            !value.isEmpty
        else {
            return nil
        }
        return value
    }
}
