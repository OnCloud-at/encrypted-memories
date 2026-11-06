import Foundation
import Synchronization
import XCTest

/// Central architecture gate for universal Core targets.
///
/// Target-local purity tests still exist as focused unit tests, but this file is the
/// shared contract that every universal Core target must pass. Add a target here
/// before treating it as reusable Core.
final class CoreArchitectureGateTests: XCTestCase {
    private struct CoreTargetRule {
        let name: String
        let allowedImports: Set<String>
        let expectedDependencies: Set<String>
        let extraForbiddenTokens: [String]
    }

    private var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    private var packageManifest: URL {
        packageRoot.appendingPathComponent("Package.swift")
    }

    private var sourcesRoot: URL {
        packageRoot.appendingPathComponent("Sources")
    }

    private var repoRoot: URL {
        packageRoot.deletingLastPathComponent().deletingLastPathComponent()
    }

    private static let coreTargets: [CoreTargetRule] = [
        CoreTargetRule(
            name: "AppleSecurityCore",
            allowedImports: ["Foundation", "Security"],
            expectedDependencies: [],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "PhotosCore",
            // PhotosCore uses CryptoKit for timeline digests, OSLog for instrumentation, and SQLite3 for its app-owned metadata store.
            // Observation drives the shared immutable snapshot owner; it adds no platform UI dependency.
            // ImageIO writes location-free copies of outbound photos on every platform.
            allowedImports: [
                "AVFoundation", "CoreGraphics", "CryptoKit", "Foundation", "ImageIO", "Observation", "OSLog",
                "SQLite3",
            ],
            expectedDependencies: [],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "MediaByteCache",
            allowedImports: ["CryptoKit", "Foundation", "PhotosCore"],
            expectedDependencies: ["PhotosCore"],
            extraForbiddenTokens: ["CGImage"]
        ),
        CoreTargetRule(
            name: "MediaDecodingCore",
            allowedImports: ["CoreGraphics", "Foundation", "ImageIO"],
            expectedDependencies: [],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "MediaFeedCore",
            // CryptoKit hashes coverage identifiers before they reach disk; it is universal
            // Apple-platform infrastructure, not platform UI or hardware policy.
            allowedImports: ["CryptoKit", "Foundation", "MediaByteCache", "MediaDecodingCore", "PhotosCore"],
            expectedDependencies: ["MediaByteCache", "MediaDecodingCore", "PhotosCore"],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "MediaLocationCore",
            allowedImports: ["CryptoKit", "Foundation", "Observation", "PhotosCore"],
            expectedDependencies: ["PhotosCore"],
            extraForbiddenTokens: ["MapKit"]
        ),
        CoreTargetRule(
            name: "MediaCacheCore",
            // MediaCacheCore has no Observation dependency; learned dimensions are stored in PhotosCore metadata.
            allowedImports: ["Foundation", "PhotosCore"],
            expectedDependencies: ["PhotosCore"],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "GridCore",
            // QuartzCore is intentionally not allowed: GridCore is pure value geometry
            // that takes injected clocks (never `CACurrentMediaTime`) and uses simd/`CGAffineTransform` (never
            // `CATransform3D`), so it needs no QuartzCore symbol. Excluding QuartzCore structurally closes the
            // render-surface hole where a QuartzCore-sourced `CAMetalDrawable`/`CAMetalLayer`/`CADisplayLink`
            // could otherwise enter Core past both the import allowlist and the token gate. Re-add consciously
            // (with a value-math justification) if a legitimate need ever appears.
            allowedImports: ["CoreGraphics", "simd"],
            expectedDependencies: [],
            // CoreGraphics drawing/surface types - as opposed to the `CGRect`/`CGSize`/`CGPoint`/`CGFloat`
            // value types GridCore legitimately relies on - have no place in pure grid geometry. Scoped to
            // GridCore (not global) because `CGImage` is a legitimate decoded-image type in MediaDecodingCore
            // and MediaFeedCore, so a global ban would wrongly fail those Core targets.
            extraForbiddenTokens: ["CGContext", "CGImage", "CGColorSpace", "CGLayer"]
        ),
        CoreTargetRule(
            name: "UploadCore",
            // UploadCore uses AVFoundation/ImageIO for metadata, CryptoKit for dedupe hashing, and SQLite3 for manifest storage.
            // These dependencies remain platform-neutral so dedupe stays in shared Core.
            allowedImports: [
                "AVFoundation", "CryptoKit", "Foundation", "ImageIO", "Observation", "PhotosCore", "SQLite3",
                "Synchronization",
            ],
            expectedDependencies: ["PhotosCore"],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "AlbumCore",
            allowedImports: ["Foundation", "PhotosCore"],
            expectedDependencies: ["PhotosCore"],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "AccountStateCore",
            allowedImports: ["Foundation", "PhotosCore"],
            expectedDependencies: ["PhotosCore"],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "DeviceRootCore",
            allowedImports: ["Foundation"],
            expectedDependencies: [],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "TimelineCore",
            // UploadCore: photos that the backup has not uploaded yet are part of the timeline (pending grid).
            // Observation: the shared `@Observable` library model (`TimelineViewModel`) for macOS and iOS.
            allowedImports: [
                "CoreGraphics", "Foundation", "GridCore", "MediaFeedCore", "MediaLocationCore", "Observation",
                "PhotosCore", "UploadCore",
            ],
            expectedDependencies: ["GridCore", "MediaFeedCore", "MediaLocationCore", "PhotosCore", "UploadCore"],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "PhotoViewerCore",
            allowedImports: ["AVFoundation", "CoreGraphics", "Foundation", "ImageIO", "Observation", "PhotosCore"],
            expectedDependencies: ["PhotosCore"],
            extraForbiddenTokens: ["PhotoDiagnostics"]
        ),
        // MLSearchCore: pure Swift, platform-neutral. Owns the ML index model, store protocol,
        // in-memory + SQLite stores, packed vector block, planner, progress, query/result types,
        // and vector-scorer protocol. SQLite3: the system C library backing the persistent
        // embedding store (same allowance as PhotosCore/UploadCore stores). CoreML/Vision/
        // UIKit/AppKit/SwiftUI/Photos/SDK are banned so search and indexing stay in shared Core.
        // CryptoKit: streaming SHA-256 verification of downloaded model artifacts (same
        // universal-crypto allowance as MediaByteCache). Observation: the shared @Observable
        // Smart Search controller both platform Settings surfaces bind to (same allowance as
        // MediaLocationCore).
        CoreTargetRule(
            name: "MLSearchCore",
            allowedImports: ["CryptoKit", "Foundation", "Observation", "PhotosCore", "SQLite3"],
            expectedDependencies: ["PhotosCore"],
            extraForbiddenTokens: ["CoreML", "Vision", "NaturalLanguage", "MLModel"]
        ),
    ]

    private static let forbiddenFrameworkImports: Set<String> = [
        "AppKit",
        "UIKit",
        "SwiftUI",
        "MapKit",
        "AVKit",
        // `Metal` itself belongs to renderer/adapter targets; universal Core targets must remain drawable-free.
        "Metal",
        "MetalKit",
    ]

    private static let forbiddenTokens: [String] = [
        "NSImage",
        "UIImage",
        "NSView",
        "UIView",
        "NSWorkspace",
        "NSOpenPanel",
        "UIApplication",
        "NSApplication",
        "MTKView",
        // Ban render-surface and presentation types so universal Core remains drawable-free.
        // Concrete names also catch qualified references and re-exported shims when import checks are bypassed.
        "CAMetalDrawable",
        "CAMetalLayer",
        "CAMetalDisplayLink",
        "CADisplayLink",
        "CALayer",
        "MTLDevice",
        "MTLTexture",
        "MTLBuffer",
        "MTLCommandQueue",
        "MTLCommandBuffer",
        "MTLRenderPassDescriptor",
        "MTLRenderCommandEncoder",
        "ProcessInfo.processInfo.physicalMemory",
        "ProcessInfo.processInfo.activeProcessorCount",
    ]

    private static let adapterAndFeatureModules: Set<String> = [
        "AlbumsFeature",
        "DesignSystem",
        "DesignSystemAppKitAdapter",
        "DesignSystemCore",
        "DesignSystemUIKitAdapter",
        "MapFeature",
        "MapUIKitAdapter",
        "MediaCache",
        "MediaCacheAppKitAdapter",
        "MediaCacheCore",
        "MediaCacheUIKitAdapter",
        "MetalGridTextureAppKitAdapter",
        "MetalGridTextureUIKitAdapter",
        "PhotoViewerFeature",
        "PhotoViewerCore",
        "PhotoViewerUIKitAdapter",
        "PrivacyFeature",
        "ProtonAuth",
        "TimelineFeature",
        "TimelineUIKitAdapter",
        "UploadFeature",
    ]

    private static let renderingCoreAllowedImports: Set<String> = [
        "CoreGraphics",
        "Metal",
        "QuartzCore",
        "simd",
    ]

    private static let renderingCoreForbiddenImports: Set<String> = [
        "AppKit",
        "UIKit",
        "SwiftUI",
        "MapKit",
        "AVKit",
        "MetalKit",
        "PhotosCore",
        "MediaCache",
        "TimelineFeature",
    ]

    private static let renderingCoreForbiddenTokens: [String] = [
        "MTKView",
        "NSView",
        "UIView",
        "NSImage",
        "UIImage",
        "NSScrollView",
        "UIScrollView",
        "NSEvent",
        "UIEvent",
        "NSGestureRecognizer",
        "UIGestureRecognizer",
        "NSAccessibility",
        "NSColor",
        "UIColor",
        "NSFont",
        "UIFont",
        "NSBezierPath",
        "UIBezierPath",
        "PhotoUID",
        "PhotoItem",
        "ThumbnailFeed",
        "MediaCache",
        "CAMetalLayer",
        "CAMetalDisplayLink",
        "CADisplayLink",
        "CALayer",
        "ProcessInfo.processInfo.physicalMemory",
        "ProcessInfo.processInfo.activeProcessorCount",
    ]

    private static let composeCoreAllowedImports: Set<String> = [
        "CoreGraphics",
        "GridCore",
        "Metal",
        "MetalGridTextureCore",
        "MetalRenderingCore",
        "simd",
    ]

    private static let composeCoreForbiddenImports: Set<String> = [
        "AppKit",
        "UIKit",
        "SwiftUI",
        "MapKit",
        "AVKit",
        "MetalKit",
        "PhotosCore",
        "MediaCache",
        "TimelineFeature",
        "TimelineUIKitFeature",
    ]

    private static let composeCoreForbiddenTokens: [String] = [
        "MTKView",
        "NSView",
        "UIView",
        "NSImage",
        "UIImage",
        "NSScrollView",
        "UIScrollView",
        "NSColor",
        "UIColor",
        "NSFont",
        "UIFont",
        "PhotoUID",
        "PhotoItem",
        "ThumbnailFeed",
        "MediaCache",
        "MTKView",
        "CAMetalDrawable",
        "CAMetalLayer",
        "CADisplayLink",
        "CALayer",
        "PhotoDiagnostics",
        "PhotoPerformanceSignposts",
        "ProcessInfo.processInfo.physicalMemory",
        "ProcessInfo.processInfo.activeProcessorCount",
    ]

    private static let textureCoreAllowedImports: Set<String> = [
        "CoreGraphics",
        "GridCore",
        "Metal",
    ]

    private static let textureCoreForbiddenImports: Set<String> = [
        "AppKit",
        "UIKit",
        "SwiftUI",
        "MapKit",
        "AVKit",
        "MetalKit",
        "PhotosCore",
        "MediaCache",
        "TimelineFeature",
        "MetalRenderingCore",
        "DesignSystem",
    ]

    private static let textureCoreForbiddenTokens: [String] = [
        "MTKView",
        "NSView",
        "UIView",
        "NSImage",
        "UIImage",
        "NSScrollView",
        "UIScrollView",
        "NSEvent",
        "UIEvent",
        "NSGestureRecognizer",
        "UIGestureRecognizer",
        "NSAccessibility",
        "NSColor",
        "UIColor",
        "NSFont",
        "UIFont",
        "PhotoUID",
        "PhotoItem",
        "ThumbnailFeed",
        "MediaCache",
        "MetalGridRenderer",
        "MetalGridDrawableTarget",
        "CAMetalDrawable",
        "CAMetalLayer",
        "CAMetalDisplayLink",
        "CADisplayLink",
        "CALayer",
        "MTLCommandQueue",
        "MTLCommandBuffer",
        "MTLRenderPassDescriptor",
        "MTLRenderCommandEncoder",
        "ProcessInfo.processInfo.physicalMemory",
        "ProcessInfo.processInfo.activeProcessorCount",
    ]

    // Rules for the Proton boundary (#1147). Every list below is named in the test that enforces it
    // and is the only place that may admit a new importer; renaming a listed file is a conscious
    // gate update, not a rename the test follows.

    /// Rule: `ProtonDriveSDK` is Proton-internal plumbing. Only files under
    /// `Sources/ProtonDriveBackend` may import it. Entries are repo-relative directory prefixes
    /// with a trailing slash.
    private static let protonDriveSDKImportAllowlist: [String] = [
        "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/"
    ]

    /// Rule: the `ProtonCore*` modules are Proton-internal plumbing. They belong inside
    /// `ProtonDriveBackend` and in the listed host startup files, which assemble the SDK keychain
    /// and session state in the apps. Directories are repo-relative prefixes with a trailing
    /// slash; files are exact repo-relative paths.
    private static let protonCoreImportAllowlist: (directories: [String], files: [String]) = (
        directories: [
            "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/"
        ],
        files: [
            "App/AppModel.swift",
            "iOSApp/EncryptedMemoriesMobileApp.swift",
            "iOSApp/MobileSessionModel.swift",
        ]
    )

    /// Rule: the macOS and iOS apps import `ProtonDriveBackend` only in the listed composition
    /// files, which wire backend services into app models, controllers and screens. Entries are
    /// exact repo-relative paths.
    private static let hostBackendImportAllowlist: Set<String> = [
        "App/AppModel.swift",
        "App/FolderBackupController.swift",
        "App/MacLibraryRefreshController.swift",
        "App/Offline/OfflineLibraryManager.swift",
        "App/Views/MainView.swift",
        "App/Views/SettingsView.swift",
        "iOSApp/MobileAccountRuntime.swift",
        "iOSApp/MobileLibraryModel.swift",
        "iOSApp/MobileSessionModel.swift",
        "iOSApp/MobileSettingsScreen.swift",
        "iOSApp/MobileSignedInFixture.swift",
    ]

    /// Rule: a project.yml extension target must not depend on these modules. Extensions run in
    /// other processes and must not gain Proton transport or credential access.
    private static let extensionTargetForbiddenModules: [String] = [
        "ProtonAuth",
        "ProtonDriveBackend",
    ]

    /// Rule: an extension target may depend only on package products in this list. The list is
    /// empty today because the apps ship no extension target yet. The first extension target
    /// must widen this list ON PURPOSE: a module-name check alone is not enough,
    /// because a product such as LibrarySourceRuntime transitively builds ProtonDriveBackend.
    private static let extensionTargetAllowedProducts: [String] = []

    /// The target `type:` spellings that mark an extension-family target, so a new XcodeGen
    /// spelling does not slip past the extension rules. XcodeGen lowercases these on parse, but
    /// the check compares case-insensitively anyway.
    private static let extensionFamilyTypeMarkers: [String] = [
        "extension",
        "xpc-service",
        "watchapp",
        "messages",
        "on-demand-install-capable",
    ]

    /// The declaration modifiers an SDK-facing file must not use. `public` is a reserved word, so
    /// any occurrence in stripped code is a declaration modifier. `package` and `open` are also
    /// legal identifiers, so they count only in front of a declaration keyword or modifier;
    /// `open actor` and `open init` are not legal Swift and stay off the list.
    private static let prohibitedDeclarationModifiers: [(token: String, pattern: String)] = [
        ("public", #"(?<![.\w])public\b"#),
        (
            "package",
            #"(?<![.\w])package(?=\s+(?:import|class|struct|enum|protocol|extension|func|var|let|typealias|init|subscript|static|final|override|nonisolated|lazy|weak|actor|associatedtype|macro|@))"#
        ),
        (
            "open",
            #"(?<![.\w])open(?=\s+(?:class|func|var|subscript|static|final|override|nonisolated|lazy|weak|unowned|dynamic))"#
        ),
    ]

    /// The source trees the Proton gates scan for imports: the package sources and the two
    /// shipped app trees. Entries are repo-relative directory prefixes with a trailing slash.
    private static let protonGateScannedRoots: [String] = [
        "Packages/EncryptedMemoriesKit/Sources/",
        "App/",
        "iOSApp/",
    ]

    /// Source trees the Proton gates deliberately do not scan: package and app test targets,
    /// developer tools, vendored dependencies and build scripts. A test target that exercises
    /// the backend boundary is their purpose, so it must stay out of the production rules.
    /// Entries are repo-relative directory prefixes with a trailing slash.
    private static let protonGateExcludedSourceTrees: [String] = [
        "Packages/EncryptedMemoriesKit/Tests/",
        "iOSTests/",
        "iOSUITests/",
        "macOSTests/",
        "Tools/",
        "Vendor/",
        "scripts/",
    ]

    func testUniversalCoreImportsStayOnTargetAllowlists() throws {
        var violations: [String] = []

        for rule in Self.coreTargets {
            let files = try swiftFiles(in: sourcesRoot.appendingPathComponent(rule.name))
            XCTAssertFalse(files.isEmpty, "Expected source files for \(rule.name)")

            for file in files {
                let imports = try importedModules(in: file)
                let unexpected = imports.subtracting(rule.allowedImports)
                if !unexpected.isEmpty {
                    violations.append(
                        "\(rule.name)/\(file.lastPathComponent): unexpected imports \(unexpected.sorted())")
                }

                let forbidden = imports.intersection(Self.forbiddenFrameworkImports)
                if !forbidden.isEmpty {
                    violations.append(
                        "\(rule.name)/\(file.lastPathComponent): forbidden platform imports \(forbidden.sorted())")
                }

                let featureImports = imports.intersection(Self.adapterAndFeatureModules)
                if !featureImports.isEmpty {
                    violations.append(
                        "\(rule.name)/\(file.lastPathComponent): Core must not import adapters/features \(featureImports.sorted())"
                    )
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Universal Core import gate failed:
            \(violations.joined(separator: "\n"))

            Add reusable code to the correct Core target and update this shared
            rule only after confirming macOS, iOS, and iPadOS buildability.
            """
        )
    }

    func testUniversalCoreSourcesDoNotReferencePlatformUITypesOrHardwarePolicy() throws {
        var violations: [String] = []

        for rule in Self.coreTargets {
            let forbidden = Self.forbiddenTokens + rule.extraForbiddenTokens
            let files = try swiftFiles(in: sourcesRoot.appendingPathComponent(rule.name))
            XCTAssertFalse(files.isEmpty, "Expected source files for \(rule.name)")

            for file in files {
                let code = try strippedCode(of: file)
                for token in try references(to: forbidden, in: code) {
                    violations.append("\(rule.name)/\(file.lastPathComponent): \(token)")
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Universal Core token gate failed:
            \(violations.joined(separator: "\n"))

            Platform image/view types and hardware sizing policy belong in
            platform adapters, not in reusable Core targets.
            """
        )
    }

    func testPackageManifestKeepsUniversalCoreDependenciesOneWay() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        var violations: [String] = []

        for rule in Self.coreTargets {
            guard let dependencyLine = manifestLine(forTarget: rule.name, in: manifest) else {
                violations.append("\(rule.name): missing Package.swift target declaration")
                continue
            }
            let dependencies = Set(dependencies(inTargetLine: dependencyLine))
            if dependencies != rule.expectedDependencies {
                violations.append(
                    "\(rule.name): dependencies \(dependencies.sorted()) != expected \(rule.expectedDependencies.sorted())"
                )
            }
            let forbidden = dependencies.intersection(Self.adapterAndFeatureModules)
            if !forbidden.isEmpty {
                violations.append("\(rule.name): must not depend on adapters/features \(forbidden.sorted())")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Universal Core dependency gate failed:
            \(violations.joined(separator: "\n"))

            Core dependencies may point only toward lower-level Core targets.
            Adapters and feature/UI targets must depend on Core, never the reverse.
            """
        )
    }

    func testUniversalCoreProductsArePublishedByMatchingTargets() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        let missing = Self.coreTargets
            .map(\.name)
            .filter { target in
                !manifest.contains(".library(name: \"\(target)\", targets: [\"\(target)\"])")
            }

        XCTAssertTrue(
            missing.isEmpty,
            "Universal Core targets must be published as matching library products: \(missing.sorted())"
        )
    }

    func testAllSecItemCallsStayInAppleSecurityCore() throws {
        let allowedRoot = sourcesRoot.appendingPathComponent("AppleSecurityCore").standardizedFileURL
        let tokens = ["SecItemCopyMatching(", "SecItemAdd(", "SecItemUpdate(", "SecItemDelete("]
        var violations: [String] = []

        for file in try swiftFiles(in: sourcesRoot) {
            guard !file.standardizedFileURL.path.hasPrefix(allowedRoot.path + "/") else { continue }
            let code = try strippedCode(of: file)
            for token in tokens where code.contains(token) {
                violations.append("\(file.path): direct \(token) must use AppleSecurityCore")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Keychain transport duplication detected:\n\(violations.joined(separator: "\n"))"
        )
    }

    func testAppTargetsHaveRequiredPrivateKeychainGroups() throws {
        let project = try String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        let macEntitlements = try String(
            contentsOf: repoRoot.appendingPathComponent("App/EncryptedMemories.entitlements"),
            encoding: .utf8
        )

        XCTAssertTrue(project.contains("CODE_SIGN_ENTITLEMENTS: App/EncryptedMemories.entitlements"))
        XCTAssertFalse(project.contains("CODE_SIGN_ENTITLEMENTS: iOSApp/EncryptedMemoriesMobile.entitlements"))
        XCTAssertTrue(macEntitlements.contains("<key>keychain-access-groups</key>"))
        XCTAssertTrue(macEntitlements.contains("$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repoRoot.appendingPathComponent("iOSApp/EncryptedMemoriesMobile.entitlements").path
            )
        )
    }

    func testMetalRenderingCoreHasSeparatePackageBoundary() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        var violations: [String] = []

        if !manifest.contains(".library(name: \"MetalRenderingCore\", targets: [\"MetalRenderingCore\"])") {
            violations.append("MetalRenderingCore: missing matching library product")
        }

        guard let targetLine = manifestLine(forTarget: "MetalRenderingCore", in: manifest) else {
            XCTFail("MetalRenderingCore: missing Package.swift target declaration")
            return
        }

        let dependencies = Set(dependencies(inTargetLine: targetLine))
        if !dependencies.isEmpty {
            violations.append("MetalRenderingCore: dependencies \(dependencies.sorted()) != []")
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            MetalRenderingCore package boundary regressed:
            \(violations.joined(separator: "\n"))

            Shared Metal rendering has its own target and gate; it is not Universal GridCore.
            """
        )
    }

    func testMetalRenderingCoreStaysRenderOnly() throws {
        let sourceRoot = sourcesRoot.appendingPathComponent("MetalRenderingCore")
        let files = try swiftFiles(in: sourceRoot)
        XCTAssertFalse(files.isEmpty, "Expected source files for MetalRenderingCore")

        var violations: [String] = []

        for file in files {
            let imports = try importedModules(in: file)
            let unexpected = imports.subtracting(Self.renderingCoreAllowedImports)
            if !unexpected.isEmpty {
                violations.append(
                    "MetalRenderingCore/\(file.lastPathComponent): unexpected imports \(unexpected.sorted())")
            }

            let forbiddenImports = imports.intersection(Self.renderingCoreForbiddenImports)
            if !forbiddenImports.isEmpty {
                violations.append(
                    "MetalRenderingCore/\(file.lastPathComponent): forbidden imports \(forbiddenImports.sorted())")
            }

            let code = try strippedCode(of: file)
            for token in try references(to: Self.renderingCoreForbiddenTokens, in: code) {
                violations.append("MetalRenderingCore/\(file.lastPathComponent): forbidden token \(token)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            MetalRenderingCore render-only gate failed:
            \(violations.joined(separator: "\n"))

            MetalRenderingCore may own Metal draw primitives and draw targets, but platform views,
            scroll/gesture hosts, glyph rasterization, photo-domain IDs, media feeds, and hardware budgets
            belong in adapters.
            """
        )
    }

    func testMetalGridTextureCoreHasSeparatePackageBoundary() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        var violations: [String] = []

        if !manifest.contains(".library(name: \"MetalGridTextureCore\", targets: [\"MetalGridTextureCore\"])") {
            violations.append("MetalGridTextureCore: missing matching library product")
        }

        guard let targetLine = manifestLine(forTarget: "MetalGridTextureCore", in: manifest) else {
            XCTFail("MetalGridTextureCore: missing Package.swift target declaration")
            return
        }

        let dependencies = Set(dependencies(inTargetLine: targetLine))
        if dependencies != ["GridCore"] {
            violations.append("MetalGridTextureCore: dependencies \(dependencies.sorted()) != [GridCore]")
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            MetalGridTextureCore package boundary regressed:
            \(violations.joined(separator: "\n"))

            Shared Metal texture caching is separate from render command encoding and may depend only on
            GridCore's portable texture policies.
            """
        )
    }

    func testMetalGridTextureCoreStaysTextureOnly() throws {
        let sourceRoot = sourcesRoot.appendingPathComponent("MetalGridTextureCore")
        let files = try swiftFiles(in: sourceRoot)
        XCTAssertFalse(files.isEmpty, "Expected source files for MetalGridTextureCore")

        var violations: [String] = []

        for file in files {
            let imports = try importedModules(in: file)
            let unexpected = imports.subtracting(Self.textureCoreAllowedImports)
            if !unexpected.isEmpty {
                violations.append(
                    "MetalGridTextureCore/\(file.lastPathComponent): unexpected imports \(unexpected.sorted())")
            }

            let forbiddenImports = imports.intersection(Self.textureCoreForbiddenImports)
            if !forbiddenImports.isEmpty {
                violations.append(
                    "MetalGridTextureCore/\(file.lastPathComponent): forbidden imports \(forbiddenImports.sorted())")
            }

            let code = try strippedCode(of: file)
            for token in try references(to: Self.textureCoreForbiddenTokens, in: code) {
                violations.append("MetalGridTextureCore/\(file.lastPathComponent): forbidden token \(token)")
            }
        }

        let cacheFile = sourceRoot.appendingPathComponent("MetalGridTextureCache.swift")
        let glyphFile = sourceRoot.appendingPathComponent("MetalGridGlyphRasterizer.swift")
        for file in [cacheFile, glyphFile] where !FileManager.default.fileExists(atPath: file.path) {
            violations.append("MetalGridTextureCore/\(file.lastPathComponent): missing shared texture-core file")
        }

        if FileManager.default.fileExists(atPath: cacheFile.path) {
            let source = try String(contentsOf: cacheFile, encoding: .utf8)
            // `canAdmitUpload` / `maxUploadBytesPerFrame` / `maxResidentBytes` pin the byte-budget
            // enforcement seam: the cache must gate texture creation on the resident byte budget and
            // bound per-frame upload bytes, not just texture counts.
            for symbol in [
                "package final class MetalGridTextureCache",
                "GridTextureResidencyPolicy<ID>",
                "GridTextureBudget",
                "uploadVisible(wanted: [ID]",
                "canAdmitUpload(",
                "maxUploadBytesPerFrame",
                "maxResidentBytes",
            ] where !source.contains(symbol) {
                violations.append("MetalGridTextureCore/MetalGridTextureCache.swift: missing \(symbol)")
            }
        }

        if FileManager.default.fileExists(atPath: glyphFile.path) {
            let source = try String(contentsOf: glyphFile, encoding: .utf8)
            for symbol in [
                "package struct MetalGridGlyphRequest", "package struct MetalGridGlyphColor",
                "package protocol MetalGridGlyphRasterizing",
            ] where !source.contains(symbol) {
                violations.append("MetalGridTextureCore/MetalGridGlyphRasterizer.swift: missing \(symbol)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            MetalGridTextureCore texture-only gate failed:
            \(violations.joined(separator: "\n"))

            This target may own reusable Metal texture resources and upload/cache mechanics. Platform views,
            glyph rasterization implementations, render command encoding, photo-domain IDs, media feeds, and
            hardware-budget defaults remain outside this target.
            """
        )
    }

    func testMetalGridComposeCoreStaysCompositionOnly() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        let sourceRoot = sourcesRoot.appendingPathComponent("MetalGridComposeCore")
        var violations: [String] = []

        // Package boundary: a matching library product, dependencies only toward lower Metal/Grid Core.
        if !manifest.contains(".library(name: \"MetalGridComposeCore\", targets: [\"MetalGridComposeCore\"])") {
            violations.append("MetalGridComposeCore: missing matching library product")
        }
        if let targetLine = manifestLine(forTarget: "MetalGridComposeCore", in: manifest) {
            let dependencies = Set(dependencies(inTargetLine: targetLine))
            if dependencies != ["GridCore", "MetalGridTextureCore", "MetalRenderingCore"] {
                violations.append(
                    "MetalGridComposeCore: dependencies \(dependencies.sorted()) != [GridCore, MetalGridTextureCore, MetalRenderingCore]"
                )
            }
        } else {
            violations.append("MetalGridComposeCore: missing Package.swift target declaration")
        }

        let files = try swiftFiles(in: sourceRoot)
        XCTAssertFalse(files.isEmpty, "Expected source files for MetalGridComposeCore")

        for file in files {
            let imports = try importedModules(in: file)
            let unexpected = imports.subtracting(Self.composeCoreAllowedImports)
            if !unexpected.isEmpty {
                violations.append(
                    "MetalGridComposeCore/\(file.lastPathComponent): unexpected imports \(unexpected.sorted())")
            }
            let forbiddenImports = imports.intersection(Self.composeCoreForbiddenImports)
            if !forbiddenImports.isEmpty {
                violations.append(
                    "MetalGridComposeCore/\(file.lastPathComponent): forbidden imports \(forbiddenImports.sorted())")
            }
            let code = try strippedCode(of: file)
            for token in try references(to: Self.composeCoreForbiddenTokens, in: code) {
                violations.append("MetalGridComposeCore/\(file.lastPathComponent): forbidden token \(token)")
            }
        }

        // The universal composer must own the settled-frame sequence as a generic, data-in/data-out API.
        let composerFile = sourceRoot.appendingPathComponent("MetalGridFrameComposer.swift")
        if FileManager.default.fileExists(atPath: composerFile.path) {
            let source = try String(contentsOf: composerFile, encoding: .utf8)
            for symbol in [
                "package enum MetalGridFrameComposer",
                "func classifyVisibility",
                "func viewportDrawSlots",
                "func stream",
                "func buildGroups",
                "GridTextureStreamingPolicy.window",
            ] where !source.contains(symbol) {
                violations.append("MetalGridComposeCore/MetalGridFrameComposer.swift: missing \(symbol)")
            }
        } else {
            violations.append("MetalGridComposeCore/MetalGridFrameComposer.swift: missing universal frame composer")
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            MetalGridComposeCore composition-only gate failed:
            \(violations.joined(separator: "\n"))

            The universal frame composer may own the settled-grid streaming + render-group sequence over the
            injected texture cache, generic in the item ID. Platform views, photo-domain IDs, native colours,
            media feeds, and host diagnostics belong in the macOS/iOS hosts that call it.
            """
        )
    }

    func testUIKitGlyphRasterizerStaysInPlatformAdapter() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        let adapterRoot = sourcesRoot.appendingPathComponent("MetalGridTextureUIKitAdapter")
        let adapterFile = adapterRoot.appendingPathComponent("UIKitMetalGridGlyphRasterizer.swift")
        let textureRoot = sourcesRoot.appendingPathComponent("MetalGridTextureCore")
        var violations: [String] = []

        if !manifest.contains(
            ".library(name: \"MetalGridTextureUIKitAdapter\", targets: [\"MetalGridTextureUIKitAdapter\"])")
        {
            violations.append("MetalGridTextureUIKitAdapter: missing matching library product")
        }

        if let targetLine = manifestLine(forTarget: "MetalGridTextureUIKitAdapter", in: manifest) {
            let dependencies = Set(dependencies(inTargetLine: targetLine))
            if dependencies != ["GridCore", "MetalGridTextureCore"] {
                violations.append(
                    "MetalGridTextureUIKitAdapter: dependencies \(dependencies.sorted()) != [GridCore, MetalGridTextureCore]"
                )
            }
        } else {
            violations.append("MetalGridTextureUIKitAdapter: missing Package.swift target declaration")
        }

        guard FileManager.default.fileExists(atPath: adapterFile.path) else {
            XCTFail("MetalGridTextureUIKitAdapter/UIKitMetalGridGlyphRasterizer.swift: missing UIKit glyph adapter")
            return
        }

        let imports = try importedModules(in: adapterFile)
        let expectedImports: Set<String> = ["CoreGraphics", "MetalGridTextureCore", "UIKit"]
        if imports != expectedImports {
            violations.append(
                "MetalGridTextureUIKitAdapter/UIKitMetalGridGlyphRasterizer.swift: imports \(imports.sorted()) != \(expectedImports.sorted())"
            )
        }
        for forbidden in ["AppKit", "SwiftUI", "MetalKit", "PhotosCore", "MediaCache", "TimelineFeature"]
        where imports.contains(forbidden) {
            violations.append(
                "MetalGridTextureUIKitAdapter/UIKitMetalGridGlyphRasterizer.swift: must not import \(forbidden)")
        }

        let source = try String(contentsOf: adapterFile, encoding: .utf8)
        for symbol in [
            "#if canImport(UIKit)",
            "package final class UIKitMetalGridGlyphRasterizer",
            "MetalGridGlyphRasterizing",
            "UIImage.SymbolConfiguration",
            "UIImage(systemName:",
            "UIGraphicsImageRenderer",
            "case .text",
            "NSAttributedString",
            "UIFont.monospacedSystemFont",
            "image.cgImage",
        ] where !source.contains(symbol) {
            violations.append("MetalGridTextureUIKitAdapter/UIKitMetalGridGlyphRasterizer.swift: missing \(symbol)")
        }

        for file in try swiftFiles(in: textureRoot) {
            let code = try strippedCode(of: file)
            for token in try references(
                to: ["UIKitMetalGridGlyphRasterizer", "UIImage", "UIColor", "UIGraphicsImageRenderer"], in: code)
            {
                violations.append(
                    "MetalGridTextureCore/\(file.lastPathComponent): UIKit adapter leaked into texture core via \(token)"
                )
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            UIKit glyph adapter boundary regressed:
            \(violations.joined(separator: "\n"))

            UIKit SF Symbol rasterization belongs in an iOS/iPadOS adapter target. MetalGridTextureCore owns
            only the shared cache and glyph request contract.
            """
        )
    }

    func testPhotoViewerUIKitAdapterStaysPlatformOnlyAndCoreBacked() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        let adapterRoot = sourcesRoot.appendingPathComponent("PhotoViewerUIKitAdapter")
        let imageFile = adapterRoot.appendingPathComponent("UIKitViewerImageAdapter.swift")
        var violations: [String] = []

        if !manifest.contains(".library(name: \"PhotoViewerUIKitAdapter\", targets: [\"PhotoViewerUIKitAdapter\"])") {
            violations.append("PhotoViewerUIKitAdapter: missing matching library product")
        }

        if let targetLine = manifestLine(forTarget: "PhotoViewerUIKitAdapter", in: manifest) {
            let dependencies = Set(dependencies(inTargetLine: targetLine))
            // The shared viewer display store (UIKitViewerImageStore) lives here and needs universal Core:
            // PhotosCore (PhotoUID / FullMediaProvider) and MediaCacheCore (the shared WrapperImageCache with
            // memory-pressure semantics). Both are platform-neutral Core - not the macOS MediaCache umbrella.
            let expected: Set<String> = ["PhotoViewerCore", "PhotosCore", "MediaCacheCore"]
            if dependencies != expected {
                violations.append(
                    "PhotoViewerUIKitAdapter: dependencies \(dependencies.sorted()) != \(expected.sorted())")
            }
        } else {
            violations.append("PhotoViewerUIKitAdapter: missing Package.swift target declaration")
        }

        if !FileManager.default.fileExists(atPath: imageFile.path) {
            violations.append(
                "PhotoViewerUIKitAdapter/\(imageFile.lastPathComponent): missing UIKit viewer adapter file"
            )
        }

        if FileManager.default.fileExists(atPath: imageFile.path) {
            let imports = try importedModules(in: imageFile)
            let expectedImports: Set<String> = ["CoreGraphics", "Foundation", "PhotoViewerCore", "UIKit"]
            if imports != expectedImports {
                violations.append(
                    "PhotoViewerUIKitAdapter/UIKitViewerImageAdapter.swift: imports \(imports.sorted()) != \(expectedImports.sorted())"
                )
            }
            let source = try String(contentsOf: imageFile, encoding: .utf8)
            for symbol in [
                "#if canImport(UIKit)",
                "public enum UIKitViewerImageAdapter",
                "UIImage(cgImage: cgImage",
                // Prefix (no closing paren) so the adapter may pass the optional bounded `maxPixelSize` argument
                // while the gate still proves it stays core-backed - decoding via the shared `ViewerFullImageDecoder`.
                "ViewerFullImageDecoder.decodeCGImage(data",
            ] where !source.contains(symbol) {
                violations.append("PhotoViewerUIKitAdapter/UIKitViewerImageAdapter.swift: missing \(symbol)")
            }
        }

        for file in try swiftFiles(in: adapterRoot) {
            let imports = try importedModules(in: file)
            for forbidden in [
                "AppKit", "SwiftUI", "AVKit", "MediaCache", "PhotoViewerFeature", "TimelineFeature", "MapFeature",
                "ProtonDriveSDK",
            ] where imports.contains(forbidden) {
                violations.append("PhotoViewerUIKitAdapter/\(file.lastPathComponent): must not import \(forbidden)")
            }
            let code = try strippedCode(of: file)
            for forbidden in try references(
                to: ["NSImage", "NSView", "AVPlayerView", "NSViewRepresentable", "ThumbnailFeed", "PhotoViewerModel"],
                in: code)
            {
                violations.append(
                    "PhotoViewerUIKitAdapter/\(file.lastPathComponent): forbidden macOS/feature reference \(forbidden)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            PhotoViewer UIKit adapter boundary regressed:
            \(violations.joined(separator: "\n"))

            iOS/iPadOS viewer adapters may translate PhotoViewerCore decoded images, transition timing, and
            AVPlayer layers into UIKit types, but macOS viewer state/UI and MediaCache stay outside this target.
            """
        )
    }

    func testMLSearchAppleAdapterStaysAppleOnlyAndCoreBacked() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        let adapterRoot = sourcesRoot.appendingPathComponent("MLSearchAppleAdapter")
        var violations: [String] = []

        if !manifest.contains(".library(name: \"MLSearchAppleAdapter\", targets: [\"MLSearchAppleAdapter\"])") {
            violations.append("MLSearchAppleAdapter: missing matching library product")
        }

        if let targetLine = manifestLine(forTarget: "MLSearchAppleAdapter", in: manifest) {
            let dependencies = Set(dependencies(inTargetLine: targetLine))
            if dependencies != ["MLSearchCore", "MediaFeedCore", "PhotosCore"] {
                violations.append(
                    "MLSearchAppleAdapter: dependencies \(dependencies.sorted()) != [MLSearchCore, MediaFeedCore, PhotosCore]"
                )
            }
        } else {
            violations.append("MLSearchAppleAdapter: missing Package.swift target declaration")
        }

        let allowedImports: Set<String> = [
            "CoreML", "Accelerate", "CoreGraphics", "CryptoKit", "Foundation", "ImageIO",
            "MLSearchCore", "MediaFeedCore", "PhotosCore", "Vision",
        ]
        let forbiddenImports: Set<String> = ["UIKit", "AppKit", "SwiftUI", "Photos", "ProtonDriveSDK", "ProtonCore"]

        let files = try swiftFiles(in: adapterRoot)
        XCTAssertFalse(files.isEmpty, "Expected source files for MLSearchAppleAdapter")

        for file in files {
            let imports = try importedModules(in: file)
            let unexpected = imports.subtracting(allowedImports)
            if !unexpected.isEmpty {
                violations.append(
                    "MLSearchAppleAdapter/\(file.lastPathComponent): unexpected imports \(unexpected.sorted())")
            }
            let forbidden = imports.intersection(forbiddenImports)
            if !forbidden.isEmpty {
                violations.append(
                    "MLSearchAppleAdapter/\(file.lastPathComponent): forbidden imports \(forbidden.sorted())")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            MLSearchAppleAdapter boundary regressed:
            \(violations.joined(separator: "\n"))

            The shared Apple adapter may import Apple ML/image frameworks + MLSearchCore + MediaFeedCore + PhotosCore only.
            UIKit/AppKit/SwiftUI/Photos/SDK imports belong in higher-level platform targets.
            """
        )
    }

    func testMLBackgroundAdapterOwnsOnlyOSOpportunities() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        let target = try XCTUnwrap(manifestLine(forTarget: "MLSearchBackgroundAppleAdapter", in: manifest))
        XCTAssertEqual(Set(dependencies(inTargetLine: target)), ["MLSearchCore", "PhotosCore"])
        let allowed: Set<String> = [
            "Foundation", "MLSearchCore", "PhotosCore", "os", "BackgroundTasks", "UIKit", "AppKit",
        ]
        let files = try swiftFiles(in: sourcesRoot.appendingPathComponent("MLSearchBackgroundAppleAdapter"))
        XCTAssertFalse(files.isEmpty)
        for file in files {
            XCTAssertTrue(try importedModules(in: file).isSubset(of: allowed), file.lastPathComponent)
        }
    }

    func testNoTargetOutsideMLSearchAppleAdapterMayImportCoreML() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        var violations: [String] = []

        // CoreML is allowed only in MLSearchAppleAdapter. Every other target is banned from
        // importing it so that inference stays behind the single shared adapter seam.
        let exemptTargets: Set<String> = ["MLSearchAppleAdapter"]

        // Discover every target directory under Sources/.
        let topLevelDirs = try FileManager.default.contentsOfDirectory(
            at: sourcesRoot, includingPropertiesForKeys: [.isDirectoryKey]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

        for dir in topLevelDirs {
            let targetName = dir.lastPathComponent
            if exemptTargets.contains(targetName) { continue }

            let files = try swiftFiles(in: dir)
            for file in files {
                let imports = try importedModules(in: file)
                if imports.contains("CoreML") {
                    violations.append(
                        "\(targetName)/\(file.lastPathComponent): CoreML import is only permitted in MLSearchAppleAdapter"
                    )
                }
                if imports.contains("Vision") {
                    violations.append(
                        "\(targetName)/\(file.lastPathComponent): Vision import is only permitted in MLSearchAppleAdapter (and only if it does not introduce a server-side/CPU-only ML path)"
                    )
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            CoreML/Vision leaked outside MLSearchAppleAdapter:
            \(violations.joined(separator: "\n"))

            CoreML inference must stay behind the single shared Apple adapter seam so a bug in
            inference is fixable once for macOS/iOS/iPadOS. UI/feature/Core targets must not
            import CoreML or Vision directly.
            """
        )

        // Sanity: the manifest must publish the adapter product (this catches accidental removal).
        XCTAssertTrue(
            manifest.contains("\"MLSearchAppleAdapter\""), "MLSearchAppleAdapter must be declared in Package.swift")
    }

    func testNoCommittedMLModelArtifactsUnderSourceTree() throws {
        // Model artifacts are not allowed under Sources or Tests.
        let bannedExtensions: Set<String> = ["mlmodel", "mlmodelc", "mlpackage"]
        var violations: [String] = []

        let enumerator = FileManager.default.enumerator(
            at: packageRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        if let enumerator {
            for case let url as URL in enumerator {
                let ext = url.pathExtension.lowercased()
                if bannedExtensions.contains(ext) {
                    violations.append("\(url.path): ML model artifact must not be committed before license clearance")
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Committed ML model artifact(s) detected:
            \(violations.joined(separator: "\n"))

            Do not ship model weights until the Stage-0 license spike resolves a permissive
            license. Stage 1 ships the architecture skeleton only.
            """
        )
    }

    func testMLSearchAppleAdapterComputePolicyRemainsCentralized() throws {
        // Production sources under MLSearchAppleAdapter must not expose public .all or .cpuOnly.
        // These may only appear behind #if debug guards or in test files.
        let adapterRoot = sourcesRoot.appendingPathComponent("MLSearchAppleAdapter")
        let files = try swiftFiles(in: adapterRoot)
        var violations: [String] = []

        for file in files {
            guard file.lastPathComponent != "CoreMLComputePolicy.swift" else {
                // Policy file itself is checked separately below.
                continue
            }

            let source = try String(contentsOf: file, encoding: .utf8)
            let code = try strippedCode(of: file)

            // No non-policy source may reference .all or .cpuOnly as compute units outside debug guards.
            let hasAllComputeUnitsToken =
                code.range(
                    of: #"(?<![A-Za-z0-9_])\.all(?![A-Za-z0-9_])"#,
                    options: .regularExpression
                ) != nil
            if hasAllComputeUnitsToken && !source.contains("#if DEBUG") {
                violations.append("\(file.lastPathComponent): reference to .all must be behind #if DEBUG guard")
            }
            let hasCPUOnlyComputeUnitsToken =
                code.range(
                    of: #"(?<![A-Za-z0-9_])\.cpuOnly(?![A-Za-z0-9_])"#,
                    options: .regularExpression
                ) != nil
            if hasCPUOnlyComputeUnitsToken && !source.contains("#if DEBUG") {
                violations.append("\(file.lastPathComponent): reference to .cpuOnly must be behind #if DEBUG guard")
            }
        }

        // CoreMLComputePolicy.swift itself must not expose public .all/.cpuOnly as static members,
        // nor a public init taking arbitrary MLComputeUnits (that would allow .all/.cpuOnly in production).
        let policyFile = adapterRoot.appendingPathComponent("CoreMLComputePolicy.swift")
        let policySource = try String(contentsOf: policyFile, encoding: .utf8)
        if policySource.contains("public static let performanceOptimized") {
            violations.append("CoreMLComputePolicy.swift: must not expose public performanceOptimized")
        }
        if policySource.contains("public static let cpuOnly") {
            violations.append("CoreMLComputePolicy.swift: must not expose public cpuOnly")
        }
        if policySource.contains("public init(computeUnits:") {
            violations.append(
                "CoreMLComputePolicy.swift: public init(computeUnits:) would allow arbitrary units in production")
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            ML compute policy hardened incorrectly:
            \(violations.joined(separator: "\n"))

            Foreground inference uses .cpuAndNeuralEngine. The central policy alone may select
            CPU-only for iOS background execution. Arbitrary debug overrides remain internal.
            """
        )
    }

    func testRuntimeStoresNeverUseInPlaceSchemaMigrationDDL() throws {
        let forbiddenPatterns = [
            #"\bALTER\s+TABLE\b"#,
            #"\bRENAME\s+COLUMN\b"#,
            #"\bDROP\s+COLUMN\b"#,
        ]
        let anyPattern = try NSRegularExpression(
            pattern: forbiddenPatterns.map { "(?:\($0))" }.joined(separator: "|"), options: .caseInsensitive)
        var violations: [String] = []

        for file in try swiftFiles(in: sourcesRoot) {
            let source = try String(contentsOf: file, encoding: .utf8)
            // One search rules out the usual file; only a hit names each pattern.
            guard anyPattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil
            else { continue }
            for pattern in forbiddenPatterns
            where source.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                violations.append("\(file.path): contains forbidden migration DDL \(pattern)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Runtime persistence must use an exact schema or a classified reset. It must never mutate an
            existing schema in place:
            \(violations.joined(separator: "\n"))
            """
        )
    }

    /// Rule: only the allowlists in this file may import ProtonDriveSDK or the ProtonCore
    /// modules. Production scope means every package `Sources/` target plus the `App` and
    /// `iOSApp` trees; test targets exercise the backend boundary deliberately and stay out of
    /// scope.
    func testProtonImportsStayOnModuleAllowlists() throws {
        let productionFiles = try protonGateProductionSourceFiles()
        XCTAssertFalse(productionFiles.isEmpty, "Expected production source files for the Proton import gate")

        var violations: [String] = []
        var sdkImporters = 0
        var protonCoreImporters = 0

        for file in productionFiles {
            let code = try strippedCode(of: file)
            let imports = Self.importedModules(inSource: code)
            let path = repoRelativePath(of: file)

            // A re-export leaks the imported module through every importer of this file's
            // module, so it violates the boundary even inside an allowed directory.
            for module in Self.reexportedModules(inSource: code)
            where module == "ProtonDriveSDK" || module.hasPrefix("ProtonCore") {
                violations.append(
                    "\(path): re-exports \(module) with @_exported; a re-export leaks the Proton boundary"
                )
            }

            if imports.contains("ProtonDriveSDK") {
                sdkImporters += 1
                if !Self.protonDriveSDKImportAllowlist.contains(where: { path.hasPrefix($0) }) {
                    violations.append("\(path): imports ProtonDriveSDK outside the allowlist")
                }
            }

            let protonCoreImports = imports.filter { $0.hasPrefix("ProtonCore") }.sorted()
            if !protonCoreImports.isEmpty {
                protonCoreImporters += 1
                let inAllowedDirectories = Self.protonCoreImportAllowlist.directories.contains {
                    path.hasPrefix($0)
                }
                let inAllowedFiles = Self.protonCoreImportAllowlist.files.contains(path)
                if !inAllowedDirectories && !inAllowedFiles {
                    violations.append("\(path): imports ProtonCore modules \(protonCoreImports) outside the allowlist")
                }
            }
        }

        // Empty-input guard: the backend must still wrap the SDK and use ProtonCore. Zero importers
        // means the scan or the architecture drifted; it must not look like a pass.
        XCTAssertGreaterThanOrEqual(sdkImporters, 1, "Expected ProtonDriveBackend to still import ProtonDriveSDK")
        XCTAssertGreaterThanOrEqual(
            protonCoreImporters, 1, "Expected ProtonDriveBackend or a listed host file to still import ProtonCore")

        for listedFile in Self.protonCoreImportAllowlist.files {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(listedFile).path),
                "ProtonCore allowlist entry does not exist anymore: \(listedFile)"
            )
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Proton import allowlist gate failed:
            \(violations.joined(separator: "\n"))

            ProtonDriveSDK and the ProtonCore modules are Proton-internal plumbing. Only
            ProtonDriveBackend may import ProtonDriveSDK, and ProtonCore belongs in ProtonDriveBackend
            or in the listed host startup files. Route other code through the backend module and
            widen the named allowlist only when the maintainers agree.
            """
        )
    }

    /// Rule: an SDK-facing production file (any file the production scan reaches that imports
    /// `ProtonDriveSDK`) declares nothing `public`, `package` or `open`, so no SDK type can leak
    /// through a module's public surface. Rule a confines SDK importers to ProtonDriveBackend
    /// today; this rule still scans every production file, so widening that allowlist later
    /// does not silently widen what may be published here.
    func testProtonSDKFacingBackendFilesDeclareNoPublicSurface() throws {
        let productionFiles = try protonGateProductionSourceFiles()
        XCTAssertFalse(productionFiles.isEmpty, "Expected production source files")

        var violations: [String] = []
        var sdkFacingFiles = 0

        for file in productionFiles {
            guard try importedModules(in: file).contains("ProtonDriveSDK") else { continue }
            sdkFacingFiles += 1

            let code = try strippedCode(of: file)
            for modifier in Self.prohibitedDeclarationModifiers
            where code.range(of: modifier.pattern, options: .regularExpression) != nil {
                violations.append(
                    """
                    \(repoRelativePath(of: file)): declares \(modifier.token) API. Files that import \
                    ProtonDriveSDK must keep the SDK surface internal.
                    """
                )
            }
        }

        // Empty-input guard: zero SDK-facing files means the SDK moved and this rule lost its
        // subject. Update it consciously instead of passing on an empty scan.
        XCTAssertGreaterThanOrEqual(
            sdkFacingFiles, 1, "Expected the production tree to still contain files that import ProtonDriveSDK")

        XCTAssertTrue(
            violations.isEmpty,
            """
            Proton SDK surface gate failed:
            \(violations.joined(separator: "\n"))

            SDK-facing backend files must declare nothing public, package or open. Publish wrappers
            from backend files that do not import ProtonDriveSDK.
            """
        )
    }

    /// Rule: the macOS and iOS apps import `ProtonDriveBackend` only in the composition files the
    /// allowlist names. The check runs in both directions: an unlisted importer fails, and a
    /// listed file that stops importing the backend fails as a stale list entry.
    func testHostAppsImportBackendOnlyInCompositionFiles() throws {
        let macHostFiles = try swiftFiles(in: repoRoot.appendingPathComponent("App"))
        let iOSHostFiles = try swiftFiles(in: repoRoot.appendingPathComponent("iOSApp"))
        let hostFiles = macHostFiles + iOSHostFiles
        XCTAssertFalse(hostFiles.isEmpty, "Expected host app source files")

        for listedFile in Self.hostBackendImportAllowlist {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(listedFile).path),
                "Listed composition file does not exist anymore: \(listedFile)"
            )
        }

        var violations: [String] = []
        var backendImporters: Set<String> = []

        for file in hostFiles {
            let path = repoRelativePath(of: file)
            guard try importedModules(in: file).contains("ProtonDriveBackend") else { continue }
            backendImporters.insert(path)
            if !Self.hostBackendImportAllowlist.contains(path) {
                violations.append("\(path): imports ProtonDriveBackend but is not a listed composition file")
            }
        }

        for listedFile in Self.hostBackendImportAllowlist.sorted()
        where !backendImporters.contains(listedFile) {
            violations.append(
                "\(listedFile): is listed as a composition file but does not import ProtonDriveBackend"
            )
        }

        // A backend re-export inside the package leaks the backend's types (and, through them,
        // the SDK) to every module that imports the re-exporting module, so it bypasses this
        // rule no matter where the file lives.
        for file in try swiftFiles(in: sourcesRoot) {
            for module in Self.reexportedModules(inSource: try strippedCode(of: file))
            where module == "ProtonDriveBackend" {
                violations.append(
                    """
                    \(repoRelativePath(of: file)): re-exports ProtonDriveBackend with @_exported. \
                    A re-export leaks the backend boundary.
                    """
                )
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Host backend import gate failed:
            \(violations.joined(separator: "\n"))

            The macOS and iOS apps import ProtonDriveBackend only in the listed composition files.
            New backend wiring goes through those files, or the list gains a new composition file
            that the maintainers agree on.
            """
        )
    }

    /// Rule: extension-family targets in project.yml must not depend on ProtonDriveBackend or
    /// ProtonAuth, and may not depend on any product outside `extensionTargetAllowedProducts` —
    /// empty today, so the first extension target widens that list on purpose. The
    /// extension family is every target whose `type:` value contains one of
    /// `extensionFamilyTypeMarkers`. When project.yml declares no extension target, this rule
    /// has no dependency to forbid and passes; the parse anchors below keep that pass from
    /// resting on a scan that read nothing, and the parse itself fails closed on manifest shapes
    /// it cannot read.
    func testExtensionTargetsStayWithinAllowedDependencies() throws {
        let projectYAML = try String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        let targets: [ProjectYAMLTarget]
        do {
            targets = try Self.projectTargets(from: projectYAML)
        } catch {
            XCTFail("The project.yml parse failed closed: \(error)")
            return
        }

        // Empty-input guard: the two shipped application targets prove the line-based parse still
        // reads the manifest. Renaming either app is a conscious gate update, not a silent pass.
        XCTAssertFalse(targets.isEmpty, "Could not read any target from project.yml")
        XCTAssertTrue(
            targets.contains { $0.name == "EncryptedMemories" },
            "Expected the macOS application target in project.yml"
        )
        XCTAssertTrue(
            targets.contains { $0.name == "EncryptedMemoriesMobile" },
            "Expected the iOS application target in project.yml"
        )

        var violations: [String] = []
        let extensionTargets = targets.filter { target in
            Self.extensionFamilyTypeMarkers.contains {
                target.type.localizedCaseInsensitiveContains($0)
            }
        }

        for target in extensionTargets {
            violations.append(
                contentsOf: Self.extensionDependencyViolations(
                    targetName: target.name,
                    targetType: target.type,
                    dependenciesBlock: target.dependencies
                )
            )
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Extension target dependency gate failed:
            \(violations.joined(separator: "\n"))

            Extension targets in project.yml must not depend on ProtonDriveBackend or ProtonAuth.
            Extensions run in other processes and must not gain Proton transport or credential
            access. Beyond that, an extension target may depend only on the products listed in
            extensionTargetAllowedProducts; a product that transitively builds ProtonDriveBackend,
            such as LibrarySourceRuntime, must not reach an extension by name. Give the extension
            the narrow data it needs instead.
            """
        )
    }

    /// The dependency violations of one extension-family target: a message per forbidden or
    /// unlisted name, and a message per dependency entry whose shape the gate cannot read. Pure
    /// over the target's name, type and `dependencies:` block text, so the gate's sample tests
    /// can pin each shape.
    private static func extensionDependencyViolations(
        targetName: String,
        targetType: String,
        dependenciesBlock: String
    ) -> [String] {
        var violations: [String] = []

        for dependency in dependencyEntries(inDependenciesBlock: dependenciesBlock) {
            guard !dependency.names.isEmpty else {
                violations.append(
                    """
                    project.yml target \(targetName) (\(targetType)): dependency entry \
                    '\(dependency.entry)' is not a package, product, target or sdk form the gate \
                    understands. Teach the gate this shape instead of skipping it.
                    """
                )
                continue
            }

            for name in dependency.names where !extensionTargetAllowedProducts.contains(name) {
                if extensionTargetForbiddenModules.contains(name) {
                    violations.append(
                        """
                        project.yml target \(targetName) (\(targetType)): extension targets must \
                        not depend on \(name).
                        """
                    )
                } else {
                    violations.append(
                        """
                        project.yml target \(targetName) (\(targetType)): depends on '\(name)', \
                        which is not in extensionTargetAllowedProducts.
                        """
                    )
                }
            }
        }

        return violations
    }

    /// Rule: the Proton gates scan every source tree. A directory that directly holds Swift
    /// files must sit under a scanned root (`protonGateScannedRoots`) or under a documented
    /// exclusion (`protonGateExcludedSourceTrees`); a new unlisted tree fails by name, so
    /// nobody can park production code where the import and publication rules never read it.
    /// When every tree is listed the rule passes; a wiped allowlist cannot produce that pass,
    /// because the non-empty guards below fail first.
    func testProtonGatesCoverEverySourceTree() throws {
        let unlisted = try directoriesWithSwiftFiles()
            .map { repoRelativePath(of: $0) }
            .filter { path in
                // A tree matches a list entry by prefix, or by being the entry itself
                // without the trailing slash (a directory whose Swift files sit at its top).
                !(Self.protonGateScannedRoots + Self.protonGateExcludedSourceTrees)
                    .contains { path.hasPrefix($0) || path == String($0.dropLast()) }
            }

        // Empty-input guards: both lists must hold entries and the two app trees must remain
        // scanned. Wiping a list turns the filter above into a constant `true` or `false`;
        // these anchors keep that from looking like a pass.
        XCTAssertFalse(Self.protonGateScannedRoots.isEmpty, "protonGateScannedRoots is empty")
        XCTAssertFalse(Self.protonGateExcludedSourceTrees.isEmpty, "protonGateExcludedSourceTrees is empty")
        XCTAssertTrue(
            Self.protonGateScannedRoots.contains("App/")
                && Self.protonGateScannedRoots.contains("iOSApp/"),
            "Expected both app trees among the scanned roots"
        )

        XCTAssertTrue(
            unlisted.isEmpty,
            """
            Source tree coverage gate failed:
            \(unlisted.joined(separator: "\n"))

            Every directory that holds Swift files must sit under a scanned root or an excluded
            tree. A new production tree joins the scan by adding it to protonGateScannedRoots;
            a new test or vendored tree goes into protonGateExcludedSourceTrees. Either way the
            listing is a conscious gate update.
            """
        )
    }

    /// Every directory-entry allowlist the Proton gates use must end its entries with `/`:
    /// the coverage checks match by prefix, and without the slash an entry such as
    /// `Sources/ProtonDriveBackend` would also cover `Sources/ProtonDriveBackendSupport`.
    /// File lists and module-name lists are exact-match and are deliberately not checked here.
    func testDirectoryAllowlistEntriesEndWithTrailingSlash() {
        let directoryLists: [(name: String, entries: [String])] = [
            ("protonDriveSDKImportAllowlist", Self.protonDriveSDKImportAllowlist),
            ("protonCoreImportAllowlist.directories", Self.protonCoreImportAllowlist.directories),
            ("protonGateScannedRoots", Self.protonGateScannedRoots),
            ("protonGateExcludedSourceTrees", Self.protonGateExcludedSourceTrees),
        ]

        for list in directoryLists {
            // Empty-input guard: a wiped list would pass the slash check for free; require it
            // to keep at least one entry so wiping it fails the gate instead.
            XCTAssertFalse(list.entries.isEmpty, "\(list.name) is empty; it must list its trees")
            for entry in list.entries where !entry.hasSuffix("/") {
                XCTFail("'\(entry)' in \(list.name) must end with '/': the prefix checks rely on it")
            }
        }
    }

    // MARK: - Import, stripper and modifier samples
    //
    // The boundary rules lean on small parsers (import spellings, comment and string
    // stripping, declaration-modifier matching). These sample tests pin every accepted and
    // rejected shape against fixed source text, so a regression fails with the exact form that
    // regressed instead of a whole-repo scan the whole suite must interpret.

    /// Every import spelling the production scan must recognize. When a new Swift import form
    /// appears, this sample grows first and the scan second.
    func testImportedModulesSamplesCoverEveryAcceptedImportSpelling() {
        let sample = """
            import Plain
            import Tabbed\tAfterTab
            @_implementationOnly import ImplementationOnly
            @testable import Testable
            @preconcurrency import Preconcurrency
            @_spi(Private) import Spi
            @_exported import ExportedFlag
            @_spi(Foo) @_exported import BothAttributes
            import struct Scoped.Struct
            import class Scoped.Klass
            import enum Scoped.Enuhm
            import protocol Scoped.Proto
            import typealias Scoped.Alias
            import func Scoped.function
            import var Scoped.variable
            import let Scoped.constant
            import DotPath.Sub.Deep
            import Semi; import Second
            import Trailing // import NotACount because this is a comment
            let inString = "import NotInString"
            /* import NotInBlockComment */
            """
            + "\n"

        let modules = Self.importedModules(inSource: sample)
        // `import Tabbed\tAfterTab` names only Tabbed: the module token ends at whitespace.
        let expected: Set<String> = [
            "Plain", "Tabbed", "ImplementationOnly", "Testable", "Preconcurrency",
            "Spi", "ExportedFlag", "BothAttributes", "Scoped", "DotPath", "Semi", "Second",
            "Trailing",
        ]
        XCTAssertEqual(modules, expected)
        XCTAssertFalse(modules.contains("NotACount"))
        XCTAssertFalse(modules.contains("NotInString"))
        XCTAssertFalse(modules.contains("NotInBlockComment"))
    }

    /// A re-export is any import carrying `@_exported`, alone or among other attributes, in a
    /// scoped import included. Everything else stays out of the re-export set.
    func testReexportedModulesSamplesFlagOnlyExportedImports() {
        let sample = """
            @_exported import Exported
            @_spi(Foo) @_exported import AlsoExported
            @_exported import struct Scoped.ExportedMember
            import Plain
            @_implementationOnly import NotExported
            """
            + "\n"

        let reexported = Self.reexportedModules(inSource: sample)
        XCTAssertEqual(reexported, ["Exported", "AlsoExported", "Scoped"])
    }

    /// The stripper must blank line comments, nested block comments, plain literals (with
    /// escapes), triple-quoted literals and raw literals (`#`-prefixed, one or two hashes).
    /// The odd `"` inside the multi-line literal must not end it, so the `public func` after
    /// the literal is still visible to the modifier scan.
    func testStrippedSourceSamplesBlankEveryCommentAndStringShape() {
        let sample = """
            let keep = 1 // line comment with "quotes" inside
            /* outer /* nested */ still comment */ let keepMore = 2
            let escaped = "string with \\" escaped quote and // not a comment"
            let multi = \"\"\"
            a lone " is literal text, and // is not a comment
            \"\"\"
            let raw = #"raw string, " quotes stay, \\ stays, \\#(keep) interpolates"#
            let rawRaw = ##"ends only at "# one-hash-quoted "# hash pair"##
            public func visibleAfterStrings() {}
            """
            + "\n"

        let stripped = Self.stripCommentsAndStringLiterals(from: sample)
        XCTAssertTrue(stripped.contains("let keep = 1 "), "the plain code between literals must survive")
        XCTAssertTrue(stripped.contains("let keepMore = 2"), "code after a nested comment must survive")
        XCTAssertTrue(stripped.contains("visibleAfterStrings"), "code after a multi-line literal must survive")
        XCTAssertFalse(stripped.contains("line comment with"), "a line comment must be blanked")
        XCTAssertFalse(stripped.contains("still comment"), "a nested block comment must be blanked")
        XCTAssertFalse(stripped.contains("escaped quote"), "a plain literal must be blanked")
        XCTAssertFalse(stripped.contains("lone"), "a multi-line literal must be blanked")
        XCTAssertFalse(stripped.contains("raw string"), "a raw literal must be blanked")
        XCTAssertFalse(stripped.contains("ends only at"), "a two-hash raw literal must be blanked")
        XCTAssertFalse(stripped.contains("interpolates"), "interpolation content must be blanked")
    }

    /// The modifier scan flags `public` everywhere and `package`/`open` only in front of a
    /// declaration. `package` and `open` as identifiers, and `package`/`open` members reached
    /// through a dot, must stay unflagged.
    func testProhibitedDeclarationModifierSamplesSeparateDeclarationsFromIdentifiers() {
        let identifiers = """
            let package = x
            var open = 1
            func f(package: Int) {}
            let a = other.package
            let b = other.open
            """
            + "\n"
        for modifier in Self.prohibitedDeclarationModifiers {
            XCTAssertFalse(
                identifiers.range(of: modifier.pattern, options: .regularExpression) != nil,
                "'\(modifier.token)' used as an identifier must not be flagged"
            )
        }

        let declarations = """
            public func publicFunction() {}
            package struct PackageStruct {}
            package import SomeModule
            open class OpenClass {}
            open var openVariable = 1
            package @MainActor struct Annotated {}
            open func openMethod() {}
            """
            + "\n"
        for modifier in Self.prohibitedDeclarationModifiers {
            XCTAssertTrue(
                declarations.range(of: modifier.pattern, options: .regularExpression) != nil,
                "a '\(modifier.token)' declaration must be flagged"
            )
        }
    }

    /// The manifest shapes the line parse accepts: target names with trailing comments,
    /// dependency entries at the key's own indentation and deeper, and target-less keys that
    /// carry no dependency information.
    func testProjectTargetsSamplesParseEveryAcceptedManifestShape() throws {
        let manifest = """
            name: EncryptedMemories
            options:
              bundleIdPrefix: at.oncloud
            targets:
              App: # a trailing comment must not hide the name
                type: application
                sources:
                  - App
                settings:
                  base:
                    OTHER_LDFLAGS[sdk=*]: -ObjC
                dependencies:
                  - package: PhotosCore
                    products:
                      - EncryptedMemoriesKit
                - package: SameIndentPackage
              Share:
                type: app-extension
                dependencies: # empty block with a comment
              Empty:
                type: application
            """

        let targets = try Self.projectTargets(from: manifest)
        XCTAssertEqual(targets.map(\.name), ["App", "Share", "Empty"])
        XCTAssertEqual(targets[0].type, "application")
        XCTAssertEqual(targets[1].type, "app-extension")
        XCTAssertTrue(
            targets[0].dependencies.contains("SameIndentPackage"),
            "an entry at the key's own indentation must be collected"
        )
        XCTAssertTrue(
            targets[0].dependencies.contains("EncryptedMemoriesKit"),
            "a nested products entry must be collected"
        )
        XCTAssertEqual(targets[2].dependencies, "", "a target with no dependencies key parses to no entries")
    }

    /// Every manifest shape the parse cannot read must fail closed instead of shrinking the
    /// scan: tabs, odd indentation, `include:`, YAML anchors, aliases and merge keys, target
    /// names away from indentation 2, and inline `targets:`/`type:`/`dependencies:` values.
    /// `OTHER_LDFLAGS[sdk=*]` carries a `*` that is not an alias and must not fail.
    func testProjectTargetsSamplesFailClosedOnUnreadableManifestShapes() {
        let readable = """
            settings:
              base:
                OTHER_LDFLAGS[sdk=*]: -ObjC
            targets:
              App:
                type: application
            """
        XCTAssertNoThrow(try Self.projectTargets(from: readable))

        let unreadable: [(shape: String, manifest: String)] = [
            ("tab", "targets:\n  App:\n\ttype: application"),
            ("odd indentation", "targets:\n   App:\n    type: application"),
            ("include:", "include: shared.yml\ntargets:\n  App:\n    type: application"),
            ("anchor", "targets:\n  App: &anchor\n    type: application"),
            ("alias as value", "targets:\n  App:\n    type: *anchor"),
            ("merge key", "targets:\n  App:\n    <<: *base"),
            ("target name away from indentation 2", "targets:\n    App:\n      type: application"),
            ("inline targets value", "targets: {App: {type: application}}"),
            ("inline dependencies value", "targets:\n  App:\n    dependencies: [PhotosCore]"),
        ]
        for shape in unreadable {
            XCTAssertThrowsError(
                try Self.projectTargets(from: shape.manifest),
                "the \(shape.shape) shape must fail closed"
            ) { error in
                XCTAssertTrue(
                    String(describing: error).contains("project.yml"),
                    "the \(shape.shape) failure must name the manifest"
                )
            }
        }
    }

    /// The extension-family marker decides which targets the dependency rule reads. It matches
    /// the documented spellings, case-insensitively, and does not match a plain application.
    func testExtensionFamilySamplesMatchOnlyExtensionFamilyTargets() {
        let markers = Self.extensionFamilyTypeMarkers
        let manifest = """
            targets:
              ShareExtension:
                type: app-extension
              Share:
                type: extensionKitExtension # note: trailing comment stripped by the parse
              Service:
                type: xpc-service
              Watch:
                type: watchapp2
              Messages:
                type: messages-application
              ODIM:
                type: on-demand-install-capable-view-controller-extension
              App:
                type: application
            """

        let targets = try! Self.projectTargets(from: manifest)
        for target in targets {
            let isFamily = markers.contains {
                target.type.localizedCaseInsensitiveContains($0)
            }
            if target.name == "App" {
                XCTAssertFalse(isFamily, "an application target is not an extension-family target")
            } else {
                XCTAssertTrue(isFamily, "target type '\(target.type)' must count as extension family")
            }
        }
    }

    /// An extension-family target may depend only on the products in
    /// `extensionTargetAllowedProducts` (empty today). A forbidden module, an unlisted product
    /// and an unreadable dependency shape each produce their own message.
    func testExtensionDependencySamplesReportEachViolationShape() {
        let block = """
            dependencies:
                  - package: PhotosCore
                    products:
                      - LibrarySourceRuntime
                  - package: SomeKit
                  - sdk: Pods_SomePods
                  - import: PathFinding
            """

        let violations = Self.extensionDependencyViolations(
            targetName: "Notifications",
            targetType: "app-extension",
            dependenciesBlock: block
        )
        // Entry one contributes two violations: the unlisted package PhotosCore and the
        // unlisted product LibrarySourceRuntime. Every message names its own shape.
        XCTAssertEqual(violations.count, 5)
        let joined = violations.joined(separator: "\n")
        XCTAssertTrue(joined.contains("PhotosCore"), "an unlisted package is named")
        XCTAssertTrue(joined.contains("LibrarySourceRuntime"), "an unlisted product is named")
        XCTAssertTrue(
            joined.contains("is not in extensionTargetAllowedProducts"),
            "an unlisted plain package is named with the list"
        )
        XCTAssertTrue(joined.contains("Pods_SomePods"), "an sdk dependency is named")
        XCTAssertTrue(
            joined.contains("Teach the gate this shape"),
            "an unreadable dependency entry fails closed"
        )

        let direct = Self.extensionDependencyViolations(
            targetName: "Notifications",
            targetType: "app-extension",
            dependenciesBlock: "dependencies:\n      - package: ProtonDriveBackend"
        )
        XCTAssertEqual(direct.count, 1)
        XCTAssertTrue(
            direct[0].contains("must not depend on ProtonDriveBackend"),
            "the direct forbidden-module message names the module and the rule"
        )

        let empty = Self.extensionDependencyViolations(
            targetName: "Notifications",
            targetType: "app-extension",
            dependenciesBlock: "dependencies:"
        )
        XCTAssertTrue(empty.isEmpty, "an extension target with no dependencies is not a violation")
    }

    /// The directories of the repository that directly contain a `.swift` file, sorted by path.
    private func directoriesWithSwiftFiles() throws -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: repoRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        var directories = Set<URL>()
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift", !url.hasDirectoryPath else { continue }
            // A `Package.swift` manifest describes its module; it is not source parked in a
            // tree the gates do not scan, so it must not register its directory here.
            guard url.lastPathComponent != "Package.swift" else { continue }
            directories.insert(url.deletingLastPathComponent().standardizedFileURL)
        }
        return directories.sorted { $0.path < $1.path }
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                !isDirectory.boolValue,
                url.pathExtension == "swift"
            else { continue }
            results.append(url)
        }
        return results.sorted { $0.path < $1.path }
    }

    private func importedModules(in file: URL) throws -> Set<String> {
        Set(Self.imports(inSource: try strippedCode(of: file)).map(\.module))
    }

    /// The modules `source` re-exports through `@_exported import`. A re-export leaks the
    /// imported module through every importer of this file's module, so it bypasses an import
    /// allowlist even when the file itself sits in an allowed directory. Pure over the source
    /// text, so the gate's sample tests can pin the form.
    private static func reexportedModules(inSource source: String) -> Set<String> {
        Set(imports(inSource: source).filter(\.reexported).map(\.module))
    }

    /// The modules `source` imports, as a set of module names. Pure over the source text, so
    /// the gate's sample tests can pin each accepted import spelling.
    ///
    /// Accepts any leading `@` attribute, scoped imports (`import struct Foo.Bar`), `;`
    /// separators, and any whitespace. The module is the text before the first `.`. Imports
    /// that only appear inside comments or string literals do not count: the stripper runs
    /// first.
    private static func importedModules(inSource source: String) -> Set<String> {
        Set(imports(inSource: source).map(\.module))
    }

    /// Every import declaration of `source` as (module, reexported).
    private static func imports(inSource source: String) -> [(module: String, reexported: Bool)] {
        let stripped = stripCommentsAndStringLiterals(from: source)
        var found: [(module: String, reexported: Bool)] = []

        for rawLine in stripped.split(separator: "\n", omittingEmptySubsequences: false) {
            // One line may hold several statements: `import A; import B`.
            for segment in rawLine.split(separator: ";", omittingEmptySubsequences: false) {
                found.append(contentsOf: imports(inSegment: segment))
            }
        }

        return found
    }

    /// The import declarations of one `;`-free segment of stripped source.
    private static func imports(inSegment segment: Substring) -> [(module: String, reexported: Bool)] {
        var rest = segment.drop(while: { $0.isWhitespace })

        // Any number of leading attributes, for example `@_implementationOnly import Foo` or
        // `@_spi(Private) @_exported import Foo`. `@_exported` marks a re-export and is
        // reported by `reexportedModules(inSource:)`.
        var reexported = false
        while rest.hasPrefix("@") {
            let nameStart = rest.index(after: rest.startIndex)
            let nameEnd =
                rest[nameStart...].firstIndex { !($0.isLetter || $0.isNumber || $0 == "_") }
                ?? rest.endIndex
            guard nameEnd != nameStart else { break }
            if rest[nameStart..<nameEnd] == "_exported" { reexported = true }
            var afterName = nameEnd
            if afterName < rest.endIndex, rest[afterName] == "(" {
                // Skip the attribute's argument list, with balanced parentheses.
                var depth = 1
                afterName = rest.index(after: afterName)
                while afterName < rest.endIndex, depth > 0 {
                    if rest[afterName] == "(" { depth += 1 }
                    if rest[afterName] == ")" { depth -= 1 }
                    afterName = rest.index(after: afterName)
                }
            }
            guard afterName < rest.endIndex, rest[afterName].isWhitespace else { break }
            rest = rest[afterName...].drop(while: { $0.isWhitespace })
        }

        guard
            rest.hasPrefix("import"),
            rest.count > "import".count,
            rest[rest.index(rest.startIndex, offsetBy: "import".count)].isWhitespace
        else { return [] }
        var tail = rest.dropFirst("import".count).drop(while: { $0.isWhitespace })

        // A scoped import names what it pulls in before the module: `import class Foo.Bar`.
        for keyword in ["struct", "class", "enum", "protocol", "typealias", "func", "var", "let"] {
            guard
                tail.hasPrefix(keyword),
                tail.count > keyword.count,
                tail[tail.index(tail.startIndex, offsetBy: keyword.count)].isWhitespace
            else { continue }
            tail = tail.dropFirst(keyword.count).drop(while: { $0.isWhitespace })
            break
        }

        // The module name ends at whitespace, `;`, or the `.` of a member path.
        let token = tail.prefix { character in
            character.isLetter || character.isNumber || character == "_" || character == "."
        }
        guard !token.isEmpty else { return [] }
        let moduleName =
            token.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)
            ?? String(token)
        return [(moduleName, reexported)]
    }

    /// Every production Swift file the Proton gates scan: all package `Sources/` targets plus the
    /// two shipped app trees. Test targets (`Tests/`, `macOSTests/`, `iOSTests/`) exercise the
    /// backend boundary deliberately and are not part of these rules.
    private func protonGateProductionSourceFiles() throws -> [URL] {
        try swiftFiles(in: sourcesRoot)
            + swiftFiles(in: repoRoot.appendingPathComponent("App"))
            + swiftFiles(in: repoRoot.appendingPathComponent("iOSApp"))
    }

    /// The path of `file` relative to the repository root, for failure messages that survive a
    /// moved checkout.
    private func repoRelativePath(of file: URL) -> String {
        let root = repoRoot.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    private struct ProjectYAMLTarget {
        let name: String
        let type: String
        let dependencies: String
    }

    /// Why `projectTargets(from:)` stopped: project.yml contains a shape the line parse refuses
    /// to guess about. The message names the offending line, so the failure is actionable.
    private struct ProjectManifestError: Error, CustomStringConvertible {
        let description: String
    }

    /// The targets of project.yml: name, declared type and the comment-stripped text of the
    /// `dependencies:` block including its entries, exactly as the manifest groups them.
    ///
    /// Pure over the manifest text, so the gate's sample tests can pin each accepted shape.
    /// Fails closed with `ProjectManifestError` on shapes the parse cannot read: tab characters,
    /// odd indentation, `include:`, YAML anchors, aliases and merge keys, target names at an
    /// indentation other than 2, and inline values on the `targets:`, `type:` or
    /// `dependencies:` keys. Failing closed is deliberate: a manifest the gate cannot read must
    /// stop the build, not quietly shrink the scan.
    private static func projectTargets(from projectYAML: String) throws -> [ProjectYAMLTarget] {
        var targets: [ProjectYAMLTarget] = []
        var name: String?
        var type: String?
        var dependencies: [String] = []
        var dependenciesKeyIndent: Int?
        var inTargetsSection = false

        func flush() {
            defer {
                name = nil
                type = nil
                dependencies = []
                dependenciesKeyIndent = nil
            }
            guard let name else { return }
            targets.append(
                ProjectYAMLTarget(
                    name: name,
                    type: type ?? "",
                    dependencies: dependencies.joined(separator: "\n")
                )
            )
        }

        for rawLine in projectYAML.split(separator: "\n", omittingEmptySubsequences: false) {
            guard !rawLine.contains("\t") else {
                throw ProjectManifestError(description: "project.yml uses a tab character in: \(rawLine)")
            }
            let line = Self.lineWithoutComment(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indent = line.prefix { $0 == " " }.count

            guard indent % 2 == 0 else {
                throw ProjectManifestError(
                    description: "project.yml line has odd indentation \(indent): \(trimmed)"
                )
            }
            if Self.containsAnchorOrAlias(trimmed) {
                throw ProjectManifestError(
                    description: "project.yml uses a YAML anchor, alias or merge key in: \(trimmed)"
                )
            }

            if indent == 0 {
                flush()
                if trimmed.hasPrefix("include:") {
                    throw ProjectManifestError(
                        description: "project.yml uses include:, which this parse cannot follow"
                    )
                }
                if trimmed.hasPrefix("targets:") {
                    guard trimmed == "targets:" else {
                        throw ProjectManifestError(
                            description:
                                "project.yml targets: has an inline value; this parse only reads block style: \(trimmed)"
                        )
                    }
                    inTargetsSection = true
                } else {
                    inTargetsSection = false
                }
                continue
            }
            guard inTargetsSection else { continue }

            if indent == 2 {
                guard trimmed.hasSuffix(":") else {
                    throw ProjectManifestError(
                        description: "expected a target name at indentation 2, found: \(trimmed)"
                    )
                }
                let key = trimmed.dropLast()
                let allowedName =
                    !key.isEmpty
                    && key.allSatisfy {
                        $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "."
                    }
                guard allowedName else {
                    throw ProjectManifestError(
                        description: "unusual target name at indentation 2, expected `Name:`: \(trimmed)"
                    )
                }
                flush()
                name = String(key)
                continue
            }

            guard name != nil else {
                throw ProjectManifestError(
                    description: "project.yml has content inside targets: before any target name: \(trimmed)"
                )
            }

            // Dependency entries may sit deeper than their key or at the key's own indentation,
            // which YAML also allows. Anything shallower, or a sibling key, ends the block.
            if let keyIndent = dependenciesKeyIndent,
                indent > keyIndent || (indent == keyIndent && trimmed.hasPrefix("-"))
            {
                dependencies.append(line)
                continue
            }
            dependenciesKeyIndent = nil

            if trimmed.hasPrefix("type:") {
                guard indent == 4 else {
                    throw ProjectManifestError(
                        description: "type: of target \(name ?? "?") appears at indentation \(indent)"
                            + " instead of 4; check the target's indentation in: \(trimmed)"
                    )
                }
                let value = trimmed.dropFirst("type:".count).trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else {
                    throw ProjectManifestError(
                        description: "type: of target \(name ?? "?") has no value: \(trimmed)"
                    )
                }
                type = value
            } else if trimmed.hasPrefix("dependencies:") {
                guard indent == 4 else {
                    throw ProjectManifestError(
                        description: "dependencies: of target \(name ?? "?") appears at indentation \(indent)"
                            + " instead of 4; check the target's indentation in: \(trimmed)"
                    )
                }
                let value = trimmed.dropFirst("dependencies:".count).trimmingCharacters(in: .whitespaces)
                guard value.isEmpty else {
                    throw ProjectManifestError(
                        description: "project.yml dependencies: of target \(name ?? "?") has an inline value;"
                            + " this parse only reads block style: \(trimmed)"
                    )
                }
                dependenciesKeyIndent = indent
                dependencies.append(line)
            }
            // Any other key (sources:, settings:, …) and its nested lines carry no dependency
            // information for these rules and are skipped.
        }
        flush()
        return targets
    }

    /// The line without its YAML comment: everything from a `#` that starts the line or follows
    /// a space. Quoted values that merely contain `#` keep it.
    private static func lineWithoutComment(_ line: Substring) -> String {
        var cut = line.endIndex
        var index = line.startIndex
        while index < line.endIndex {
            guard line[index] == "#", index == line.startIndex || line[line.index(before: index)] == " "
            else {
                index = line.index(after: index)
                continue
            }
            cut = index
            break
        }
        return String(line[..<cut])
    }

    /// True when `line` starts with an anchor, alias or merge key, or carries one as its
    /// `key: value` value: `&name`, `*name` or `<<:`. A `*` that is neither the first character
    /// nor a whole leading identifier — for example `OTHER_LDFLAGS[sdk=*]: -ObjC` — is not a
    /// YAML alias and does not trip this check.
    private static func containsAnchorOrAlias(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        if first == "&" || first == "*" || first == "<" { return true }
        guard let colon = line.firstIndex(of: ":") else { return false }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return value.range(of: #"^[&*][A-Za-z0-9_-]+(\s|$)"#, options: .regularExpression) != nil
    }

    /// Each `-` entry of a `dependencies:` block together with the package, product, target or
    /// sdk names it references. Covers flow entries (`- {package: X, product: Y}`), keyed
    /// entries whose value sits on the next line (`- package: X` plus `product: Y`) and keyed
    /// entries with a block list value (`products:` followed by `- Y` lines). Entries with no
    /// recognizable name keep an empty list so the rule can reject shapes the gate does not
    /// understand. Pure over the block text, so the gate's sample tests can pin each shape.
    private static func dependencyEntries(
        inDependenciesBlock block: String
    ) -> [(entry: String, names: [String])] {
        var entries: [(entry: String, names: [String])] = []
        var current: (entry: String, names: [String], indent: Int)?
        var expectingListItem = false

        func flush() {
            defer { current = nil }
            guard let current else { return }
            entries.append((entry: current.entry, names: current.names))
        }

        func names(inValue value: Substring, into entry: inout (entry: String, names: [String], indent: Int)) {
            let tokens = value.split { character in
                !(character.isLetter || character.isNumber || character == "_"
                    || character == "-" || character == ".")
            }
            entry.names.append(contentsOf: tokens.map(String.init))
        }

        for rawLine in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            let indent = rawLine.prefix { $0 == " " }.count

            if trimmed.hasPrefix("-") {
                if expectingListItem, let entry = current, indent > entry.indent {
                    // A `- Name` line under a `products:` (or similar) key belongs to the
                    // current entry.
                    var entry = entry
                    names(inValue: trimmed.dropFirst(), into: &entry)
                    current = entry
                    continue
                }
                flush()
                current = (entry: trimmed, names: [], indent: indent)
                expectingListItem = false
            }
            guard var entry = current else { continue }  // the `dependencies:` key line itself
            defer {
                current = entry
            }

            for match in rawLine.matches(of: #/(?:package|packages|products?|targets?|sdks?)\s*:\s*(\S[^\n]*)/#) {
                names(inValue: match.1, into: &entry)
            }
            if rawLine.firstMatch(of: #/(?:package|packages|products?|targets?|sdks?)\s*:\s*\S/#) != nil {
                // The key carries its value on this line.
                expectingListItem = false
            } else if rawLine.firstMatch(of: #/(?:package|packages|products?|targets?|sdks?)\s*:\s*$/#) != nil {
                // The key carries its value as a block list on the following `- Name` lines.
                expectingListItem = true
            }
        }
        flush()
        return entries
    }

    private func manifestLine(forTarget target: String, in manifest: String) -> String? {
        let escapedTarget = NSRegularExpression.escapedPattern(for: target)
        let pattern = "\\.target\\s*\\(\\s*name\\s*:\\s*\\\"" + escapedTarget + "\\\""
        guard let match = manifest.range(of: pattern, options: .regularExpression),
            let openingParenthesis = manifest[match.lowerBound...].firstIndex(of: "(")
        else { return nil }

        return balancedRegion(
            in: manifest,
            startingAt: openingParenthesis,
            opening: "(",
            closing: ")"
        )
    }

    private func dependencies(inTargetLine line: String) -> [String] {
        guard let label = line.range(of: #"dependencies\s*:"#, options: .regularExpression),
            let openingBracket = line[label.upperBound...].firstIndex(of: "["),
            let dependencies = balancedRegion(
                in: line,
                startingAt: openingBracket,
                opening: "[",
                closing: "]"
            )
        else { return [] }

        let matches = dependencies.matches(of: #/\"([A-Za-z0-9_]+)\"/#)
        return matches.map { String($0.1) }
    }

    private func balancedRegion(
        in source: String,
        startingAt openingIndex: String.Index,
        opening: Character,
        closing: Character
    ) -> String? {
        var depth = 0
        var index = openingIndex
        var isInsideString = false
        var isEscapingString = false

        while index < source.endIndex {
            let character = source[index]
            if isInsideString {
                if isEscapingString {
                    isEscapingString = false
                } else if character == "\\" {
                    isEscapingString = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
            } else if character == opening {
                depth += 1
            } else if character == closing {
                depth -= 1
                if depth == 0 {
                    return String(source[openingIndex...index])
                }
            }
            index = source.index(after: index)
        }

        return nil
    }

    /// The entries of `tokens` that `code` references, in list order. One precompiled search over every plain
    /// token rules out the usual file; only a hit checks each token with `contains(_:in:)`.
    private func references(to tokens: [String], in code: String) throws -> [String] {
        let words = tokens.filter { !$0.contains(".") }
        let anyWord = try Self.alternation(of: words)
        let hasWord = anyWord.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
        return tokens.filter { token in (hasWord || token.contains(".")) && contains(token, in: code) }
    }

    private static let alternations = Mutex<[[String]: NSRegularExpression]>([:])

    private static func alternation(of words: [String]) throws -> NSRegularExpression {
        if let cached = alternations.withLock({ $0[words] }) { return cached }
        let pattern = #"\b(?:"# + words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + #")\b"#
        let regex = try NSRegularExpression(pattern: pattern)
        alternations.withLock { $0[words] = regex }
        return regex
    }

    /// Stripped sources by path, so each file is read and stripped once per test process although several tests
    /// scan it.
    private static let strippedSources = Mutex<[String: String]>([:])

    /// The code of `file` on disk without comments and string literals.
    private func strippedCode(of file: URL) throws -> String {
        let key = file.standardizedFileURL.path
        if let cached = Self.strippedSources.withLock({ $0[key] }) { return cached }
        let code = Self.stripCommentsAndStringLiterals(from: try String(contentsOf: file, encoding: .utf8))
        Self.strippedSources.withLock { $0[key] = code }
        return code
    }

    private func contains(_ token: String, in code: String) -> Bool {
        if token.contains(".") {
            return code.contains(token)
        }

        let pattern = #"\b\#(NSRegularExpression.escapedPattern(for: token))\b"#
        return code.range(of: pattern, options: .regularExpression) != nil
    }

    /// `source` with every comment and string literal blanked out. Newlines are kept so the
    /// result keeps the line layout of the input; everything else inside a comment or literal
    /// becomes a space. In raw strings a backslash is literal and a quote only closes the
    /// literal when the matching number of `#` follows; that is how the Swift compiler parses
    /// them, verified against `swiftc`.
    ///
    /// Pure over the source text, so the gate's sample tests can pin each shape.
    private static func stripCommentsAndStringLiterals(from source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        var index = source.startIndex

        /// The number of `#`s in the run ending just before `quote`, 0 for a plain literal.
        func rawHashes(before quote: String.Index) -> Int {
            var hashes = 0
            var probe = quote
            while probe > source.startIndex, source[source.index(before: probe)] == "#" {
                hashes += 1
                probe = source.index(before: probe)
            }
            return hashes
        }

        func appendBlanked(until endIndex: String.Index) {
            while index < endIndex {
                result.append(source[index] == "\n" ? "\n" : " ")
                index = source.index(after: index)
            }
        }

        /// Blanks the string literal whose opening quote is at `openingQuote`. `hashes` is the
        /// number of `#`s of a raw opening delimiter, 0 for a plain literal.
        func consumeStringLiteral(openingQuote: String.Index, hashes: Int) {
            var triple = false
            let afterOpening = source.index(after: openingQuote)
            if afterOpening < source.endIndex, source[afterOpening] == "\"" {
                let third = source.index(after: afterOpening)
                if third < source.endIndex, source[third] == "\"" { triple = true }
            }
            let openingEnd =
                triple ? source.index(after: source.index(after: afterOpening)) : afterOpening
            appendBlanked(until: openingEnd)

            while index < source.endIndex {
                let character = source[index]
                let after = source.index(after: index)

                if hashes == 0, character == "\\" {
                    // In a plain literal the backslash escapes the next character.
                    result.append("  ")
                    index = after < source.endIndex ? source.index(after: after) : after
                    continue
                }
                if hashes > 0, character == "\\", after < source.endIndex, source[after] == "#" {
                    // In a raw literal only `\#` escapes; it covers the pair plus one character.
                    result.append("   ")
                    let afterPair = source.index(after: after)
                    index = afterPair < source.endIndex ? source.index(after: afterPair) : afterPair
                    continue
                }
                if character == "\"", !triple {
                    var follow = after
                    var followHashes = 0
                    while follow < source.endIndex, source[follow] == "#" {
                        followHashes += 1
                        follow = source.index(after: follow)
                    }
                    if followHashes >= hashes {
                        appendBlanked(until: follow)
                        return
                    }
                }
                if character == "\"", triple {
                    if after < source.endIndex, source[after] == "\"" {
                        let third = source.index(after: after)
                        if third < source.endIndex, source[third] == "\"" {
                            var follow = source.index(after: third)
                            var followHashes = 0
                            while follow < source.endIndex, source[follow] == "#" {
                                followHashes += 1
                                follow = source.index(after: follow)
                            }
                            if followHashes >= hashes {
                                appendBlanked(until: follow)
                                return
                            }
                        }
                    }
                }
                result.append(character == "\n" ? "\n" : " ")
                index = after
            }
        }

        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)

            if character == "/" {
                let after = next
                if after < source.endIndex, source[after] == "/" {
                    // Line comment: blank to end of line.
                    while index < source.endIndex, source[index] != "\n" {
                        result.append(" ")
                        index = source.index(after: index)
                    }
                    continue
                }
                if after < source.endIndex, source[after] == "*" {
                    // Block comment, possibly nested.
                    var depth = 1
                    result.append("  ")
                    index = source.index(after: after)
                    while index < source.endIndex, depth > 0 {
                        let c = source[index]
                        if c == "/", source.index(after: index) < source.endIndex,
                            source[source.index(after: index)] == "*"
                        {
                            depth += 1
                            result.append("  ")
                            index = source.index(after: source.index(after: index))
                        } else if c == "*", source.index(after: index) < source.endIndex,
                            source[source.index(after: index)] == "/"
                        {
                            depth -= 1
                            result.append("  ")
                            index = source.index(after: source.index(after: index))
                        } else {
                            result.append(c == "\n" ? "\n" : " ")
                            index = source.index(after: index)
                        }
                    }
                    continue
                }
                result.append(character)
                index = next
                continue
            }

            if character == "#" {
                // A run of `#`s directly before a `"` opens a raw string literal.
                var hashes = 0
                var probe = index
                while probe < source.endIndex, source[probe] == "#" {
                    hashes += 1
                    probe = source.index(after: probe)
                }
                if probe < source.endIndex, source[probe] == "\"" {
                    appendBlanked(until: probe)  // the `#`s
                    consumeStringLiteral(openingQuote: probe, hashes: hashes)
                    continue
                }
                result.append(character)
                index = next
                continue
            }

            if character == "\"" {
                consumeStringLiteral(openingQuote: index, hashes: 0)
                continue
            }

            result.append(character)
            index = next
        }

        return result
    }
}
