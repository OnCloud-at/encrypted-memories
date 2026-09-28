import CryptoKit
import DeviceRootCore
import Foundation

/// A signed child folder carries this name. The digest binds its claim to one container.
enum DeviceRootMarker {
    static let prefix = "em-root-v1-"

    private struct Context: Encodable {
        let version = 1
        let location: DeviceRootLocation
        let deviceUID: String
        let rootFolderUID: String
        let incarnation: String
    }

    static func name(for device: DeviceRootSDKListedDevice, incarnation: String) -> String? {
        guard validIncarnation(incarnation), !device.deviceUID.isEmpty,
            !device.rootFolderUID.isEmpty
        else { return nil }
        let context = Context(
            location: device.location, deviceUID: device.deviceUID,
            rootFolderUID: device.rootFolderUID, incarnation: incarnation)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(context) else { return nil }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return "\(prefix)\(incarnation)-\(digest)"
    }

    static func incarnation(
        from name: String?, for device: DeviceRootSDKListedDevice
    ) -> String? {
        guard let name, name.hasPrefix(prefix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let remaining = name[start...]
        guard remaining.count == 36 + 1 + 64 else { return nil }
        let incarnation = String(remaining.prefix(36))
        guard let expected = self.name(for: device, incarnation: incarnation), expected == name
        else { return nil }
        return incarnation
    }

    private static func validIncarnation(_ value: String) -> Bool {
        guard value.count == 36, let uuid = UUID(uuidString: value),
            uuid.uuidString.lowercased() == value
        else { return false }
        let characters = Array(value)
        return characters[14] == "4" && "89ab".contains(characters[19])
    }
}
