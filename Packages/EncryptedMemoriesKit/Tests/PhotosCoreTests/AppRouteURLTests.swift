import Foundation
import PhotosCore
import XCTest

final class AppRouteURLTests: XCTestCase {
    private func route(_ text: String) -> AppRoute? {
        guard let url = URL(string: text) else { return nil }
        return AppRouteURL.route(from: url)
    }

    func testParsesEveryRoute() {
        XCTAssertEqual(route("encryptedmemories://library"), .library)
        XCTAssertEqual(route("encryptedmemories://collection/favorites"), .collection(.favorites))
    }

    func testSchemeIsCaseInsensitiveButRouteIsExact() {
        XCTAssertEqual(route("EncryptedMemories://library"), .library)
        XCTAssertNil(route("encryptedmemories://Library"))
        XCTAssertNil(route("encryptedmemories://LIBRARY"))
        XCTAssertNil(route("encryptedmemories://collection/Favorites"))
        XCTAssertNil(route("encryptedmemories://Collection/favorites"))
    }

    func testEverySmartCollectionHasADistinctStableSlug() {
        let expected: [PhotoTag: String] = [
            .favorites: "favorites", .screenshots: "screenshots", .videos: "videos", .livePhotos: "live-photos",
            .motionPhotos: "motion-photos", .selfies: "selfies", .portraits: "portraits", .bursts: "bursts",
            .panoramas: "panoramas", .raw: "raw",
        ]
        XCTAssertEqual(Set(expected.keys), Set(PhotoTag.allCases))
        for tag in PhotoTag.allCases {
            XCTAssertEqual(AppRouteURL.slug(for: tag), expected[tag])
            XCTAssertEqual(route("encryptedmemories://collection/\(expected[tag]!)"), .collection(tag))
        }
    }

    func testFormatsLinksThatParseBack() {
        let routes = [AppRoute.library] + PhotoTag.allCases.map(AppRoute.collection)
        for route in routes {
            let url = AppRouteURL.url(for: route)
            XCTAssertEqual(AppRouteURL.route(from: url), route, url.absoluteString)
        }
        XCTAssertEqual(AppRouteURL.url(for: .library).absoluteString, "encryptedmemories://library")
        XCTAssertEqual(
            AppRouteURL.url(for: .collection(.livePhotos)).absoluteString,
            "encryptedmemories://collection/live-photos"
        )
    }

    func testIgnoresOtherSchemesAndForms() {
        for text in [
            "photos://library", "encryptedmemoriesx://library", "xencryptedmemories://library",
            "encryptedmemories:library", "encryptedmemories:/library", "encryptedmemories:///library",
            "encryptedmemories://", "https://example.com/library",
        ] {
            XCTAssertNil(route(text), text)
        }
    }

    func testIgnoresUnknownRoutes() {
        for host in [
            "onthisday", "search", "trash", "map", "duplicates", "settings", "delete", "upload", "share", "album",
        ] {
            XCTAssertNil(route("encryptedmemories://\(host)"), host)
        }
        XCTAssertNil(route("encryptedmemories://album/" + String(repeating: "aB3-_", count: 17) + "Z=="))
        XCTAssertNil(route("encryptedmemories://collection/unknown"))
        XCTAssertNil(route("encryptedmemories://collection/trash"))
    }

    func testIgnoresLookalikeHostsAndSlugs() {
        // Cyrillic "і" (U+0456) and "о" (U+043E) instead of Latin letters.
        for text in ["encryptedmemories://l\u{0456}brary", "encryptedmemories://collection/fav\u{043E}rites"] {
            XCTAssertNil(route(text), text)
        }
    }

    func testCompatibilityFormsOfTheHostMeanTheExactASCIIRoute() {
        // Foundation's IDNA host mapping turns a fullwidth letter (U+FF4C "ｌ", U+FF43 "ｃ") into ASCII and removes a
        // zero-width space (U+200B) before the parser sees the link. These links therefore name the exact ASCII
        // route and nothing else.
        XCTAssertEqual(route("encryptedmemories://library\u{200B}"), .library)
        XCTAssertEqual(route("encryptedmemories://\u{FF4C}ibrary"), .library)
        XCTAssertEqual(route("encryptedmemories://\u{FF43}ollection/favorites"), .collection(.favorites))
    }

    func testIgnoresWrongPathShapes() {
        for text in [
            "encryptedmemories://library/", "encryptedmemories://library/extra", "encryptedmemories://library//",
            "encryptedmemories://collection", "encryptedmemories://collection/", "encryptedmemories://collection//",
            "encryptedmemories://collection/favorites/", "encryptedmemories://collection/favorites/x",
            "encryptedmemories://collection//favorites", "encryptedmemories://collection/../library",
            "encryptedmemories://library/..", "encryptedmemories://../library", "encryptedmemories://./library",
        ] {
            XCTAssertNil(route(text), text)
        }
    }

    func testIgnoresQueryFragmentUserPortAndPercentEncoding() {
        for text in [
            "encryptedmemories://library?x=1", "encryptedmemories://library?", "encryptedmemories://library#top",
            "encryptedmemories://user@library", "encryptedmemories://user:secret@library",
            "encryptedmemories://library:80", "encryptedmemories://lib%72ary",
            "encryptedmemories://collection/live%2Dphotos", "encryptedmemories://collection/f\u{00E4}vorites",
        ] {
            XCTAssertNil(route(text), text)
        }
    }

    func testIgnoresOversizedInput() {
        XCTAssertNil(route("encryptedmemories://collection/" + String(repeating: "a", count: 100_000)))
        XCTAssertNil(route("encryptedmemories://library" + String(repeating: "/", count: 100_000)))
        XCTAssertNil(route(String(repeating: "e", count: 100_000) + "://library"))
    }

    func testResolvesTheLibraryFilter() {
        XCTAssertEqual(AppRoute.library.photoFilter, .all)
        for tag in PhotoTag.allCases {
            XCTAssertEqual(AppRoute.collection(tag).photoFilter, .tag(tag))
        }
    }
}
