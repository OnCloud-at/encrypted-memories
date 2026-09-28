import Foundation

/// Paths are relative to the selected device root. Feature modules never name a Drive location.
public struct DeviceRootPath: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let bytes = Array(rawValue.utf8)
        guard !bytes.isEmpty, bytes.count <= 1_024,
            bytes.allSatisfy({ byte in
                (65...90).contains(byte) || (97...122).contains(byte)
                    || (48...57).contains(byte) || byte == 45 || byte == 46
                    || byte == 95 || byte == 47
            })
        else { throw DeviceRootPathError.invalid }

        let parts = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.first == "State" || parts.first == "Index",
            parts.allSatisfy({ !$0.isEmpty && $0.count <= 255 && $0 != "." && $0 != ".." })
        else { throw DeviceRootPathError.invalid }

        self.rawValue = rawValue
    }

    public var components: [String] {
        rawValue.split(separator: "/").map(String.init)
    }

    public func appending(_ component: String) throws -> DeviceRootPath {
        try DeviceRootPath(rawValue + "/" + component)
    }
}

public enum DeviceRootPathError: Error, Equatable {
    case invalid
}
