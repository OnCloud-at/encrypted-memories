import Foundation

/// Where one of the owner's photos appears.
///
/// Two independent account-wide choices decide it: hidden, and "Nur für mich" (personal). Hidden wins over personal,
/// and personal wins over sharing. Because the choices are independent, showing a hidden photo again returns it to
/// what it was before it was hidden.
public enum PhotoVisibility: Sendable, Equatable {
    /// In the owner's library, and shared while the shared library is on.
    case normal
    /// In the owner's library, never shared.
    case personal
    /// Only in the hidden collection; never shared.
    case hidden

    public init(isHidden: Bool, isPersonal: Bool) {
        if isHidden {
            self = .hidden
        } else if isPersonal {
            self = .personal
        } else {
            self = .normal
        }
    }

    /// Whether the photo appears in the owner's library, collections, search, and map.
    public var isInLibrary: Bool { self != .hidden }

    /// Whether the shared library may contain the photo.
    public var isShareable: Bool { self == .normal }
}
