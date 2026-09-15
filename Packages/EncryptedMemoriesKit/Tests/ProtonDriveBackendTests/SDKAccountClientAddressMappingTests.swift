import Foundation
import ProtonCoreDataModel
import Testing

@testable import ProtonDriveBackend

@Suite("SDKAccountClient address and key-flag mapping")
struct SDKAccountClientAddressMappingTests {
    // MARK: - Key-flag capability mapping

    @Test func keyFlagsSignupDefaultAllowsEncryptionAndVerification() {
        let descriptor = descriptor(forKeyFlags: 3)

        #expect(descriptor.isAllowedForEncryption)
        #expect(descriptor.isAllowedForVerification)
    }

    @Test func individualCapabilityBitsMapIndependently() {
        #expect(!descriptor(forKeyFlags: 1).isAllowedForEncryption)
        #expect(descriptor(forKeyFlags: 1).isAllowedForVerification)

        #expect(descriptor(forKeyFlags: 2).isAllowedForEncryption)
        #expect(!descriptor(forKeyFlags: 2).isAllowedForVerification)

        #expect(!descriptor(forKeyFlags: 0).isAllowedForEncryption)
        #expect(!descriptor(forKeyFlags: 0).isAllowedForVerification)
    }

    @Test func externalAddressFlagsDoNotGrantCapabilities() {
        // 12 = cannotEncryptEmail (4) + dontExpectSignedEmails (8): external-address bits only.
        #expect(!descriptor(forKeyFlags: 12).isAllowedForEncryption)
        #expect(!descriptor(forKeyFlags: 12).isAllowedForVerification)

        // 15 = all low-byte bits set, including both capability bits.
        #expect(descriptor(forKeyFlags: 15).isAllowedForEncryption)
        #expect(descriptor(forKeyFlags: 15).isAllowedForVerification)
    }

    @Test func keyFlagsAboveTheLowByteTruncateLikeTheSDKDid() {
        // 259 = 0x103: high bits above 0xFF must be ignored; behaves like 3.
        let descriptor = descriptor(forKeyFlags: 259)

        #expect(descriptor.isAllowedForEncryption)
        #expect(descriptor.isAllowedForVerification)
    }

    // MARK: - Activation flag

    @Test func activeFlagMapsToIsActive() {
        #expect(descriptor(forKeyFlags: 0, active: 1).isActive)
        #expect(!descriptor(forKeyFlags: 0, active: 0).isActive)
    }

    // MARK: - Primary key selection

    @Test func primaryKeyIndexSelectsFirstPrimaryFlaggedKey() {
        let keys = [
            makeKey(keyID: "k0", keyFlags: 0, active: 1, primary: 0),
            makeKey(keyID: "k1", keyFlags: 0, active: 1, primary: 1),
            makeKey(keyID: "k2", keyFlags: 0, active: 1, primary: 0),
        ]

        #expect(SDKAddressDescriptor.primaryKeyIndex(of: keys) == 1)
        #expect(SDKAddressDescriptor.primaryKey(of: keys)?.keyID == "k1")
    }

    @Test func primaryKeyIndexFallsBackToZeroWithoutPrimaryFlag() {
        let keys = [
            makeKey(keyID: "k0", keyFlags: 0, active: 1, primary: 0),
            makeKey(keyID: "k1", keyFlags: 0, active: 1, primary: 0),
        ]

        #expect(SDKAddressDescriptor.primaryKeyIndex(of: keys) == 0)
        #expect(SDKAddressDescriptor.primaryKey(of: keys)?.keyID == "k0")
    }

    @Test func primaryKeyIndexIsEmptyForNoKeys() {
        #expect(SDKAddressDescriptor.primaryKeyIndex(of: []) == 0)
        #expect(SDKAddressDescriptor.primaryKey(of: []) == nil)
    }

    // MARK: - Address status mapping

    @Test func addressStatusMapsToDescriptorStatus() {
        #expect(descriptor(forStatus: .disabled).status == .disabled)
        #expect(descriptor(forStatus: .enabled).status == .enabled)
    }

    // MARK: - Verbatim field copying

    @Test func addressFieldsAreCopiedVerbatim() {
        let keys = [
            makeKey(keyID: "key-a", keyFlags: 3, active: 1, primary: 1),
            makeKey(keyID: "key-b", keyFlags: 1, active: 0, primary: 0),
        ]
        let descriptor = SDKAddressDescriptor(
            address: makeAddress(
                addressID: "addr-1",
                email: "user@example.test",
                order: 7,
                status: .enabled,
                keys: keys
            )
        )

        #expect(descriptor.addressID == "addr-1")
        #expect(descriptor.emailAddress == "user@example.test")
        #expect(descriptor.order == 7)
        #expect(descriptor.keys.count == 2)
        #expect(descriptor.keys[0].addressID == "addr-1")
        #expect(descriptor.keys[0].keyID == "key-a")
        #expect(descriptor.keys[1].addressID == "addr-1")
        #expect(descriptor.keys[1].keyID == "key-b")
    }

    // MARK: - SDKAccountClient address lookup

    @Test func getDefaultAddressReturnsLowestOrderAddress() {
        let lower = makeAddress(
            addressID: "lower", email: "low@example.test", order: 0,
            status: .enabled, keys: [makeKey(keyID: "lower-key", keyFlags: 3, active: 1, primary: 1)]
        )
        let higher = makeAddress(
            addressID: "higher", email: "high@example.test", order: 2,
            status: .enabled, keys: [makeKey(keyID: "higher-key", keyFlags: 3, active: 1, primary: 1)]
        )
        let client = SDKAccountClient(addresses: [higher, lower], unlockedByKeyID: [:])

        #expect(client.defaultCoreAddress()?.addressID == "lower")
        #expect(client.getDefaultAddress() != nil)
        #expect(client.getAddress(addressId: "missing") == nil)
    }

    // MARK: - Private key access

    @Test func getAddressPrimaryPrivateKeyPrefersPrimaryFlaggedKey() {
        let primaryData = Data("primary-data".utf8)
        let secondaryData = Data("secondary-data".utf8)
        let address = makeAddress(
            addressID: "addr-1", email: "user@example.test", order: 0, status: .enabled,
            keys: [
                makeKey(keyID: "k-secondary", keyFlags: 3, active: 1, primary: 0),
                makeKey(keyID: "k-primary", keyFlags: 3, active: 1, primary: 1),
            ]
        )
        let client = SDKAccountClient(
            addresses: [address],
            unlockedByKeyID: ["k-secondary": secondaryData, "k-primary": primaryData]
        )

        #expect(client.getAddressPrimaryPrivateKey(addressId: "addr-1") == primaryData)
    }

    @Test func getAddressPrimaryPrivateKeyFallsBackToFirstKeyWithoutPrimaryFlag() {
        let firstData = Data("first-data".utf8)
        let secondData = Data("second-data".utf8)
        let address = makeAddress(
            addressID: "addr-1", email: "user@example.test", order: 0, status: .enabled,
            keys: [
                makeKey(keyID: "k-first", keyFlags: 3, active: 1, primary: 0),
                makeKey(keyID: "k-second", keyFlags: 3, active: 1, primary: 0),
            ]
        )
        let client = SDKAccountClient(
            addresses: [address],
            unlockedByKeyID: ["k-first": firstData, "k-second": secondData]
        )

        #expect(client.getAddressPrimaryPrivateKey(addressId: "addr-1") == firstData)
    }

    @Test func getAddressPrimaryPrivateKeyReturnsNilForUnknownAddress() {
        let client = SDKAccountClient(addresses: [], unlockedByKeyID: [:])

        #expect(client.getAddressPrimaryPrivateKey(addressId: "nope") == nil)
    }

    @Test func getAddressPrivateKeysReturnsActiveUnlockedKeysInOrder() {
        let keyAData = Data("key-a-data".utf8)
        let keyCData = Data("key-c-data".utf8)
        let address = makeAddress(
            addressID: "addr-1", email: "user@example.test", order: 0, status: .enabled,
            keys: [
                makeKey(keyID: "key-a", keyFlags: 3, active: 1, primary: 0),  // active + unlocked
                makeKey(keyID: "key-b", keyFlags: 3, active: 0, primary: 0),  // inactive: excluded
                makeKey(keyID: "key-c", keyFlags: 3, active: 1, primary: 0),  // active, unlocked
                makeKey(keyID: "key-d", keyFlags: 3, active: 1, primary: 0),  // active, never unlocked
            ]
        )
        let client = SDKAccountClient(
            addresses: [address],
            unlockedByKeyID: ["key-a": keyAData, "key-c": keyCData]
        )

        #expect(client.getAddressPrivateKeys(addressId: "addr-1") == [keyAData, keyCData])
    }

    @Test func getAddressPrivateKeysReturnsNilWhenNothingIsAvailable() {
        // No key is unlocked: the result must be nil, not an empty array.
        let lockedOnly = makeAddress(
            addressID: "addr-1", email: "user@example.test", order: 0, status: .enabled,
            keys: [makeKey(keyID: "key-a", keyFlags: 3, active: 1, primary: 1)]
        )
        let inactiveOnly = makeAddress(
            addressID: "addr-2", email: "other@example.test", order: 0, status: .enabled,
            keys: [makeKey(keyID: "key-b", keyFlags: 3, active: 0, primary: 1)]
        )
        let unlockedData = Data("unlocked".utf8)
        let client = SDKAccountClient(
            addresses: [lockedOnly, inactiveOnly],
            unlockedByKeyID: ["key-b": unlockedData]
        )

        #expect(client.getAddressPrivateKeys(addressId: "addr-1") == nil)
        #expect(client.getAddressPrivateKeys(addressId: "addr-2") == nil)
        #expect(client.getAddressPrivateKeys(addressId: "unknown") == nil)
    }

    // MARK: - Fixtures

    private func makeKey(keyID: String, keyFlags: Int, active: Int, primary: Int) -> Key {
        Key(
            keyID: keyID,
            privateKey: "armored-\(keyID)",
            keyFlags: keyFlags,
            token: nil,
            signature: nil,
            activation: nil,
            active: active,
            version: 0,
            primary: primary
        )
    }

    private func makeAddress(
        addressID: String,
        email: String,
        order: Int,
        status: Address.AddressStatus,
        keys: [Key]
    ) -> Address {
        Address(
            addressID: addressID,
            domainID: nil,
            email: email,
            send: .active,
            receive: .active,
            status: status,
            type: .protonDomain,
            order: order,
            displayName: "",
            signature: "",
            hasKeys: keys.isEmpty ? 0 : 1,
            keys: keys
        )
    }

    /// Builds a single-key address and returns its first mapped key descriptor.
    private func descriptor(forKeyFlags keyFlags: Int, active: Int = 1) -> SDKAddressDescriptor.KeyDescriptor {
        let address = makeAddress(
            addressID: "flag-address",
            email: "flags@example.test",
            order: 0,
            status: .enabled,
            keys: [makeKey(keyID: "flag-key", keyFlags: keyFlags, active: active, primary: 0)]
        )
        let descriptor = SDKAddressDescriptor(address: address)
        #expect(descriptor.keys.count == 1)
        return descriptor.keys[0]
    }

    private func descriptor(forStatus status: Address.AddressStatus) -> SDKAddressDescriptor {
        SDKAddressDescriptor(
            address: makeAddress(
                addressID: "status-address",
                email: "status@example.test",
                order: 0,
                status: status,
                keys: []
            )
        )
    }
}
