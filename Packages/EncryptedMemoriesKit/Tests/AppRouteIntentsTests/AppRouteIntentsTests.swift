import AppIntents
import AppRouteIntents
import Foundation
import PhotosCore
import XCTest

@MainActor
final class AppRouteIntentsTests: XCTestCase {
    private static var inbox: AppRouteInbox { AppRoutes.inbox }

    override func setUp() async throws {
        Self.inbox.update(session: .signedOut)
        Self.inbox.update(session: .usable)
    }

    func testOpenLibraryPostsOnlyTheLibraryRouteForTheActiveWindow() async throws {
        _ = try await OpenLibraryIntent().perform()
        XCTAssertEqual(Self.inbox.pending?.route, .library)
        XCTAssertEqual(Self.inbox.pending?.target, .activeWindow)
    }

    func testOpenCollectionPostsTheMatchingCollectionRoute() async throws {
        for collection in AppRouteCollection.allCases {
            _ = try await OpenCollectionIntent(target: collection).perform()
            XCTAssertEqual(Self.inbox.pending?.route, .collection(collection.tag))
            XCTAssertEqual(Self.inbox.pending?.target, .activeWindow)
        }
    }

    func testAnIntentWhileSignedOutPostsNothing() async throws {
        Self.inbox.update(session: .signedOut)
        _ = try await OpenLibraryIntent().perform()
        _ = try await OpenCollectionIntent(target: .favorites).perform()
        XCTAssertNil(Self.inbox.pending)
    }

    func testALinkPostsItsRouteForTheReceivingWindowAndAnUnknownLinkPostsNothing() throws {
        let window = UUID()
        AppRoutes.receive(try XCTUnwrap(URL(string: "encryptedmemories://collection/raw")), for: .window(window))
        XCTAssertEqual(Self.inbox.pending?.route, .collection(.raw))
        XCTAssertEqual(Self.inbox.pending?.target, .window(window))

        Self.inbox.update(session: .signedOut)
        Self.inbox.update(session: .usable)
        let arrivals = Self.inbox.arrivals
        AppRoutes.receive(try XCTUnwrap(URL(string: "encryptedmemories://album/x")), for: .window(window))
        AppRoutes.receive(try XCTUnwrap(URL(string: "encryptedmemories://settings")), for: .activeWindow)
        XCTAssertNil(Self.inbox.pending)
        XCTAssertEqual(Self.inbox.arrivals, arrivals + 2, "an ignored link still brings the app forward")
    }

    func testEveryCollectionMapsToOneSmartCollectionAndItsLinkSlug() {
        XCTAssertEqual(AppRouteCollection.allCases.map(\.tag), PhotoTag.allCases)
        for collection in AppRouteCollection.allCases {
            XCTAssertEqual(collection.rawValue, AppRouteURL.slug(for: collection.tag))
        }
    }
}

/// The intent texts live in `Shared/AppIntents.xcstrings`, which both apps compile into their main bundle, because
/// App Intents resolve `LocalizedStringResource` against the app's main bundle. These checks read the shipped
/// catalogs from the source tree, like `LocalizationTests`, so they do not depend on the host language.
final class AppRouteIntentsCatalogTests: XCTestCase {
    private var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    private func values(_ path: String) throws -> [String: [String: String]] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(path))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: [String: Any]])
        return strings.mapValues { entry in
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            return localizations.compactMapValues { ($0["stringUnit"] as? [String: Any])?["value"] as? String }
        }
    }

    private var intentResources: [LocalizedStringResource] {
        var resources = [
            OpenLibraryIntent.title, OpenCollectionIntent.title, AppRouteCollection.typeDisplayRepresentation.name,
        ]
        for representation in AppRouteCollection.caseDisplayRepresentations.values {
            resources.append(representation.title)
            resources += representation.synonyms
        }
        return resources
    }

    func testEveryIntentTextIsInTheSharedTableInEnglishAndGerman() throws {
        let catalog = try values("Shared/AppIntents.xcstrings")
        for resource in intentResources {
            XCTAssertEqual(resource.table, "AppIntents", resource.key)
            let entry = try XCTUnwrap(catalog[resource.key], resource.key)
            XCTAssertEqual(entry["en"], resource.key)
            XCTAssertFalse(entry["de", default: ""].isEmpty, resource.key)
        }
    }

    func testCollectionTitlesEqualTheSmartCollectionTitlesInEnglishAndGerman() throws {
        let intents = try values("Shared/AppIntents.xcstrings")
        let package = try values("Packages/EncryptedMemoriesKit/Sources/PhotosCore/Resources/Localizable.xcstrings")
        let tagKeys: [PhotoTag: String] = [
            .favorites: "tag.favorites", .screenshots: "tag.screenshots", .videos: "tag.videos",
            .livePhotos: "tag.live_photos", .motionPhotos: "tag.motion", .selfies: "tag.selfies",
            .portraits: "tag.portraits", .bursts: "tag.bursts", .panoramas: "tag.panoramas", .raw: "tag.raw",
        ]
        for collection in AppRouteCollection.allCases {
            let title = try XCTUnwrap(AppRouteCollection.caseDisplayRepresentations[collection]).title
            let tagKey = try XCTUnwrap(tagKeys[collection.tag])
            XCTAssertEqual(PhotoTag.allCases.count, tagKeys.count)
            for language in ["en", "de"] {
                XCTAssertEqual(
                    intents[title.key]?[language], package[tagKey]?[language], "\(collection) \(language)")
            }
        }
    }
}
