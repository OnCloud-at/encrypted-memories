import Foundation

/// The owner's sharing choice. One setting applies to every person the library is shared with.
public struct SharedLibrarySettings: Sendable, Equatable, Codable {
    /// Which part of the library is shared.
    public enum Scope: Sendable, Equatable, Codable {
        /// Every photo and video.
        case everything
        /// Photos and videos taken on or after the date.
        case since(Date)
    }

    public var isEnabled: Bool
    public var scope: Scope

    public init(isEnabled: Bool, scope: Scope) {
        self.isEnabled = isEnabled
        self.scope = scope
    }

    /// Sharing is off until the owner turns it on.
    public static let off = SharedLibrarySettings(isEnabled: false, scope: .everything)

    /// Whether a photo taken at `captureTime` falls into the shared part of the library.
    public func includes(captureTime: Date) -> Bool {
        switch scope {
        case .everything: true
        case .since(let date): captureTime >= date
        }
    }
}
