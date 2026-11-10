import Foundation

/// A place in the app that a Shortcuts action or a link opens. Opening a route only changes what the app shows;
/// it never changes data.
public enum AppRoute: Hashable, Sendable {
    case library
    /// A smart collection, identified by its stable slug, never by its localized title.
    case collection(PhotoTag)

    /// The library route this route shows.
    public var photoFilter: PhotoFilter {
        switch self {
        case .library: .all
        case .collection(let tag): .tag(tag)
        }
    }
}

/// The app-specific link format for `AppRoute`. Another app or a web page can open a link, so the parser is
/// strict: anything outside the grammar below is ignored.
///
/// Grammar: `encryptedmemories://library` and `encryptedmemories://collection/<slug>`. The scheme is
/// case-insensitive; everything else is exact. A link has no user, password, port, query, fragment,
/// percent-encoding or empty path component.
public enum AppRouteURL {
    /// The URL scheme both apps register.
    public static let scheme = "encryptedmemories"

    private static let schemeSeparator = "://"
    private static let collectionPrefix = "collection/"
    private static let longestLink =
        "\(scheme)\(schemeSeparator)\(collectionPrefix)".utf8.count
        + PhotoTag.allCases.map { slug(for: $0).utf8.count }.max()!

    public static func route(from url: URL) -> AppRoute? {
        let text = url.absoluteString
        guard text.utf8.count <= longestLink,
            let separator = text.range(of: schemeSeparator),
            text[..<separator.lowerBound].lowercased() == scheme
        else { return nil }
        let path = text[separator.upperBound...]
        if path == "library" { return .library }
        guard path.hasPrefix(collectionPrefix) else { return nil }
        let collection = path.dropFirst(collectionPrefix.count)
        return PhotoTag.allCases.first { slug(for: $0) == collection }.map(AppRoute.collection)
    }

    /// The link that opens `route`.
    public static func url(for route: AppRoute) -> URL {
        let path =
            switch route {
            case .library: "library"
            case .collection(let tag): collectionPrefix + slug(for: tag)
            }
        return URL(string: "\(scheme)\(schemeSeparator)\(path)")!
    }

    /// The stable link name of a smart collection. It never changes with a rename or a translation.
    public static func slug(for tag: PhotoTag) -> String {
        switch tag {
        case .favorites: "favorites"
        case .screenshots: "screenshots"
        case .videos: "videos"
        case .livePhotos: "live-photos"
        case .motionPhotos: "motion-photos"
        case .selfies: "selfies"
        case .portraits: "portraits"
        case .bursts: "bursts"
        case .panoramas: "panoramas"
        case .raw: "raw"
        }
    }
}
