import AppIntents
import Foundation
import PhotosCore

/// The one route inbox of the app process. Links and Shortcuts actions post routes here; a window opens them.
@MainActor
public enum AppRoutes {
    public static let inbox = AppRouteInbox()

    /// Posts the route of a link to `target`. A link outside the grammar opens nothing and shows no message; it
    /// still counts as an arrival.
    public static func receive(_ url: URL, for target: AppRouteTarget) {
        guard let route = AppRouteURL.route(from: url) else {
            inbox.noteArrival()
            return
        }
        inbox.receive(route, for: target)
    }
}

/// A smart collection that a Shortcuts action can open. Each case maps to one `PhotoTag`; the raw value is the
/// stable link slug. The titles are constants because App Intents reads them at build time.
public enum AppRouteCollection: String, AppEnum {
    case favorites
    case screenshots
    case videos
    case livePhotos = "live-photos"
    case motionPhotos = "motion-photos"
    case selfies
    case portraits
    case bursts
    case panoramas
    case raw

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Collection", table: "AppIntents"))

    public static let caseDisplayRepresentations: [AppRouteCollection: DisplayRepresentation] = [
        .favorites: DisplayRepresentation(title: LocalizedStringResource("Favorites", table: "AppIntents")),
        .screenshots: DisplayRepresentation(title: LocalizedStringResource("Screenshots", table: "AppIntents")),
        .videos: DisplayRepresentation(title: LocalizedStringResource("Videos", table: "AppIntents")),
        .livePhotos: DisplayRepresentation(title: LocalizedStringResource("Live Photos", table: "AppIntents")),
        .motionPhotos: DisplayRepresentation(
            title: LocalizedStringResource("Motion", table: "AppIntents"),
            synonyms: [LocalizedStringResource("Motion Photos", table: "AppIntents")]),
        .selfies: DisplayRepresentation(title: LocalizedStringResource("Selfies", table: "AppIntents")),
        .portraits: DisplayRepresentation(title: LocalizedStringResource("Portraits", table: "AppIntents")),
        .bursts: DisplayRepresentation(title: LocalizedStringResource("Bursts", table: "AppIntents")),
        .panoramas: DisplayRepresentation(title: LocalizedStringResource("Panoramas", table: "AppIntents")),
        .raw: DisplayRepresentation(
            title: LocalizedStringResource("RAW", table: "AppIntents"),
            synonyms: [LocalizedStringResource("RAW Photos", table: "AppIntents")]),
    ]

    public var tag: PhotoTag {
        switch self {
        case .favorites: .favorites
        case .screenshots: .screenshots
        case .videos: .videos
        case .livePhotos: .livePhotos
        case .motionPhotos: .motionPhotos
        case .selfies: .selfies
        case .portraits: .portraits
        case .bursts: .bursts
        case .panoramas: .panoramas
        case .raw: .raw
        }
    }
}

/// Opens the library. It only navigates; it never changes data.
public struct OpenLibraryIntent: AppIntent {
    public static let title = LocalizedStringResource("Open Library", table: "AppIntents")
    public static let description = IntentDescription(
        LocalizedStringResource("Opens the library.", table: "AppIntents"))
    public static let supportedModes: IntentModes = .foreground(.immediate)

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        AppRoutes.inbox.receive(.library, for: .activeWindow)
        return .result()
    }
}

/// Opens one smart collection. It only navigates; it never changes data.
public struct OpenCollectionIntent: OpenIntent {
    public static let title = LocalizedStringResource("Open Collection", table: "AppIntents")
    public static let description = IntentDescription(
        LocalizedStringResource("Opens a collection, for example Favorites.", table: "AppIntents"))

    @Parameter(title: LocalizedStringResource("Collection", table: "AppIntents"))
    public var target: AppRouteCollection

    public init() {}

    public init(target: AppRouteCollection) {
        self.target = target
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        AppRoutes.inbox.receive(.collection(target.tag), for: .activeWindow)
        return .result()
    }
}
