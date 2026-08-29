// swift-tools-version: 6.0
import PackageDescription

// Xcode 26.6 can crash on the Live Photo playback path during dynamic isolation checks.
// Keep this setting until physical-device tests prove that removal is safe.
let disableDynamicActorIsolation: [SwiftSetting] = [
    .unsafeFlags(["-Xfrontend", "-disable-dynamic-actor-isolation"])
]

let sdkBackendSwiftSettings: [SwiftSetting] =
    disableDynamicActorIsolation + [
        // ProtonCore exposes process-global crypto state that Swift 6 language mode rejects.
        .swiftLanguageMode(.v5)
    ]

let package = Package(
    name: "EncryptedMemoriesKit",
    // SwiftPM requires a default before a target can contain localized resources.
    defaultLocalization: "en",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "PhotosCore", targets: ["PhotosCore"]),
        .library(name: "LibraryRuntimeAppleAdapter", targets: ["LibraryRuntimeAppleAdapter"]),
        .library(name: "AppleSecurityCore", targets: ["AppleSecurityCore"]),
        .library(name: "DesignSystemCore", targets: ["DesignSystemCore"]),
        .library(name: "DesignSystemAppKitAdapter", targets: ["DesignSystemAppKitAdapter"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "ProtonAuth", targets: ["ProtonAuth"]),
        .library(name: "ProtonDriveBackend", targets: ["ProtonDriveBackend"]),
        .library(name: "MediaByteCache", targets: ["MediaByteCache"]),
        .library(name: "MediaDecodingCore", targets: ["MediaDecodingCore"]),
        .library(name: "MediaFeedCore", targets: ["MediaFeedCore"]),
        .library(name: "MediaLocationCore", targets: ["MediaLocationCore"]),
        .library(name: "MediaCacheCore", targets: ["MediaCacheCore"]),
        .library(name: "MediaCacheAppKitAdapter", targets: ["MediaCacheAppKitAdapter"]),
        .library(name: "MediaCacheUIKitAdapter", targets: ["MediaCacheUIKitAdapter"]),
        .library(name: "GridCore", targets: ["GridCore"]),
        .library(name: "MetalRenderingCore", targets: ["MetalRenderingCore"]),
        .library(name: "MetalGridTextureCore", targets: ["MetalGridTextureCore"]),
        .library(name: "MetalGridTextureAppKitAdapter", targets: ["MetalGridTextureAppKitAdapter"]),
        .library(name: "MetalGridTextureUIKitAdapter", targets: ["MetalGridTextureUIKitAdapter"]),
        .library(name: "MetalGridComposeCore", targets: ["MetalGridComposeCore"]),
        .library(name: "MediaCache", targets: ["MediaCache"]),
        .library(name: "TimelineCore", targets: ["TimelineCore"]),
        .library(name: "TimelineUIKitAdapter", targets: ["TimelineUIKitAdapter"]),
        .library(name: "TimelineUIKitFeature", targets: ["TimelineUIKitFeature"]),
        .library(name: "TimelineFeature", targets: ["TimelineFeature"]),
        .library(name: "PhotoViewerCore", targets: ["PhotoViewerCore"]),
        .library(name: "PhotoViewerUIKitAdapter", targets: ["PhotoViewerUIKitAdapter"]),
        .library(name: "PhotoViewerFeature", targets: ["PhotoViewerFeature"]),
        .library(name: "AlbumCore", targets: ["AlbumCore"]),
        .library(name: "AlbumsFeature", targets: ["AlbumsFeature"]),
        .library(name: "AlbumSyncCore", targets: ["AlbumSyncCore"]),
        .library(name: "UploadCore", targets: ["UploadCore"]),
        .library(name: "UploadFeature", targets: ["UploadFeature"]),
        .library(name: "PhotoLibraryBackupAdapter", targets: ["PhotoLibraryBackupAdapter"]),
        .library(name: "MapCore", targets: ["MapCore"]),
        .library(name: "MapUIKitAdapter", targets: ["MapUIKitAdapter"]),
        .library(name: "MapFeature", targets: ["MapFeature"]),
        .library(name: "MLSearchCore", targets: ["MLSearchCore"]),
        .library(name: "MLSearchAppleAdapter", targets: ["MLSearchAppleAdapter"]),
        .library(name: "MLSearchFeature", targets: ["MLSearchFeature"]),
    ],
    dependencies: [
        .package(name: "ProtonDriveSDK", path: "../../Vendor/sdk-swift"),
        .package(url: "https://github.com/ProtonMail/protoncore_ios.git", exact: "37.3.0"),
    ],
    targets: [
        // PhotosCore owns the package-wide localization catalog.
        .target(name: "PhotosCore", resources: [.process("Resources")], swiftSettings: disableDynamicActorIsolation),
        .testTarget(name: "PhotosCoreTests", dependencies: ["PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        // AppleSecurityCore is the package boundary for Security.framework.
        .target(name: "AppleSecurityCore", swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "AppleSecurityCoreTests", dependencies: ["AppleSecurityCore"],
            swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "LibraryRuntimeAppleAdapter", dependencies: ["PhotosCore"],
            swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "LibraryRuntimeAppleAdapterTests", dependencies: ["LibraryRuntimeAppleAdapter", "PhotosCore"],
            swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "DesignSystemCore", dependencies: ["PhotosCore"], resources: [.process("Resources")],
            swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "DesignSystemCoreTests", dependencies: ["DesignSystemCore"],
            swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "DesignSystemAppKitAdapter", dependencies: ["DesignSystemCore"],
            swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "DesignSystemAppKitAdapterTests", dependencies: ["DesignSystemAppKitAdapter"],
            swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "DesignSystem", dependencies: ["DesignSystemCore", "DesignSystemAppKitAdapter"],
            swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "ProtonAuth", dependencies: ["AppleSecurityCore", "PhotosCore"],
            swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "ProtonAuthTests", dependencies: ["AppleSecurityCore", "PhotosCore", "ProtonAuth"],
            swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "ProtonDriveBackend",
            dependencies: [
                "PhotosCore",
                "MediaByteCache",
                "ProtonAuth",
                "AlbumCore",
                "AlbumSyncCore",
                "UploadCore",
                .product(name: "ProtonDriveSDK", package: "ProtonDriveSDK"),
                .product(name: "ProtonCoreDataModel", package: "protoncore_ios"),
                .product(name: "ProtonCoreCrypto", package: "protoncore_ios"),
                .product(name: "ProtonCoreCryptoGoInterface", package: "protoncore_ios"),
            ],
            swiftSettings: sdkBackendSwiftSettings
        ),
        .testTarget(
            name: "ProtonDriveBackendTests",
            dependencies: [
                "ProtonDriveBackend", "ProtonAuth", "PhotosCore", "AlbumSyncCore", "UploadCore",
                .product(name: "ProtonDriveSDK", package: "ProtonDriveSDK"),
                .product(name: "ProtonCoreCryptoGoInterface", package: "protoncore_ios"),
                // Crypto round-trip tests require the implementation injected by the app.
                .product(name: "ProtonCoreCryptoPatchedGoImplementation", package: "protoncore_ios"),
            ],
            swiftSettings: sdkBackendSwiftSettings
        ),
        .target(name: "MediaByteCache", dependencies: ["PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "MediaByteCacheTests", dependencies: ["MediaByteCache", "PhotosCore"],
            swiftSettings: disableDynamicActorIsolation),
        .target(name: "MediaDecodingCore", swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "MediaDecodingCoreTests", dependencies: ["MediaDecodingCore"],
            swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "MediaFeedCore", dependencies: ["PhotosCore", "MediaByteCache", "MediaDecodingCore"],
            swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "MediaFeedCoreTests",
            dependencies: ["MediaFeedCore", "PhotosCore", "MediaByteCache", "MediaDecodingCore"],
            swiftSettings: disableDynamicActorIsolation),
        .target(name: "MediaLocationCore", dependencies: ["PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "MediaLocationCoreTests", dependencies: ["MediaLocationCore", "PhotosCore"],
            swiftSettings: disableDynamicActorIsolation),
        .target(name: "MediaCacheCore", dependencies: ["PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "GridCore", swiftSettings: disableDynamicActorIsolation),
        .testTarget(name: "GridCoreTests", dependencies: ["GridCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "MetalRenderingCore", swiftSettings: disableDynamicActorIsolation),
        .target(name: "MetalGridTextureCore", dependencies: ["GridCore"], swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "MetalGridTextureCoreTests", dependencies: ["MetalGridTextureCore"],
            swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "MetalGridTextureAppKitAdapter", dependencies: ["MetalGridTextureCore", "GridCore"],
            swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "MetalGridTextureUIKitAdapter", dependencies: ["MetalGridTextureCore", "GridCore"],
            swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "MetalGridComposeCore", dependencies: ["GridCore", "MetalGridTextureCore", "MetalRenderingCore"],
            swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "MediaCacheAppKitAdapter",
            dependencies: ["PhotosCore", "MediaByteCache", "MediaDecodingCore", "MediaFeedCore", "MediaCacheCore"],
            swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "MediaCacheUIKitAdapter",
            dependencies: [
                "PhotosCore", "LibraryRuntimeAppleAdapter", "MediaByteCache", "MediaDecodingCore", "MediaFeedCore",
                "MediaCacheCore",
            ], swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "MediaCacheUIKitAdapterTests",
            dependencies: [
                "MediaCacheUIKitAdapter", "MediaCacheCore", "MediaByteCache", "MediaFeedCore", "PhotosCore",
            ], swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "MediaCacheCoreTests", dependencies: ["MediaCacheCore", "PhotosCore"],
            swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "MediaCache", dependencies: ["MediaCacheCore", "MediaCacheAppKitAdapter"],
            swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "TimelineCore", dependencies: ["PhotosCore", "GridCore", "MediaFeedCore", "MediaLocationCore"],
            resources: [.process("Resources")], swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "TimelineCoreTests",
            dependencies: ["TimelineCore", "PhotosCore", "MediaFeedCore", "MediaLocationCore"],
            swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "TimelineUIKitAdapter", dependencies: ["GridCore", "TimelineCore", "MetalRenderingCore"],
            swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "TimelineUIKitFeature",
            dependencies: [
                "PhotosCore", "GridCore", "TimelineCore", "TimelineUIKitAdapter", "MetalRenderingCore",
                "MetalGridTextureCore", "MetalGridTextureUIKitAdapter", "MetalGridComposeCore",
                "MediaCacheUIKitAdapter", "MediaFeedCore",
            ], swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "TimelineUIKitFeatureTests", dependencies: ["TimelineUIKitFeature", "GridCore", "PhotosCore"],
            swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "TimelineFeature",
            dependencies: [
                "PhotosCore", "DesignSystem", "MediaCache", "MediaByteCache", "MediaDecodingCore", "MediaFeedCore",
                "GridCore", "TimelineCore", "MetalRenderingCore", "MetalGridTextureCore",
                "MetalGridTextureAppKitAdapter", "MetalGridComposeCore",
            ],
            swiftSettings: disableDynamicActorIsolation
        ),
        .target(name: "PhotoViewerCore", dependencies: ["PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "PhotoViewerUIKitAdapter", dependencies: ["PhotoViewerCore", "PhotosCore", "MediaCacheCore"],
            swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "PhotoViewerFeature",
            dependencies: [
                "PhotosCore", "AlbumCore", "DesignSystem", "MediaCache", "MediaByteCache", "PhotoViewerCore",
            ],
            swiftSettings: disableDynamicActorIsolation
        ),
        .testTarget(
            name: "PhotoViewerFeatureTests", dependencies: ["PhotoViewerFeature", "PhotoViewerCore", "MediaByteCache"],
            swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "TimelineFeatureTests",
            dependencies: [
                "TimelineFeature", "TimelineCore", "GridCore", "MetalRenderingCore", "MetalGridTextureCore",
                "MetalGridTextureAppKitAdapter", "MetalGridTextureUIKitAdapter", "MetalGridComposeCore", "MediaCache",
                "MediaByteCache", "PhotosCore",
            ],
            swiftSettings: disableDynamicActorIsolation
        ),
        .target(name: "AlbumCore", dependencies: ["PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "AlbumsFeature", dependencies: ["AlbumCore", "PhotosCore"],
            swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "AlbumsFeatureTests", dependencies: ["AlbumCore", "AlbumsFeature", "PhotosCore"],
            swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "AlbumSyncCore", dependencies: ["AlbumCore", "UploadCore", "PhotosCore"],
            swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "AlbumSyncCoreTests", dependencies: ["AlbumSyncCore", "AlbumCore", "UploadCore", "PhotosCore"],
            swiftSettings: disableDynamicActorIsolation),
        .target(name: "UploadCore", dependencies: ["PhotosCore"]),
        .target(name: "UploadFeature", dependencies: ["UploadCore", "PhotosCore"]),
        // PhotoLibraryBackupAdapter is the package boundary for PhotoKit.
        .target(name: "PhotoLibraryBackupAdapter", dependencies: ["UploadCore", "PhotosCore", "AlbumSyncCore"]),
        .testTarget(
            name: "UploadFeatureTests", dependencies: ["UploadCore", "PhotosCore", "PhotoLibraryBackupAdapter"]),
        .target(
            name: "MapCore", dependencies: ["PhotosCore", "MediaLocationCore"],
            swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "MapCoreTests", dependencies: ["MapCore", "PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "MapUIKitAdapter", dependencies: ["PhotosCore", "MediaLocationCore", "MapCore"],
            swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "MapUIKitAdapterTests", dependencies: ["MapUIKitAdapter", "MapCore", "PhotosCore"],
            swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "MapFeature", dependencies: ["PhotosCore", "MediaLocationCore", "MapCore", "DesignSystem"],
            swiftSettings: disableDynamicActorIsolation),
        .target(name: "MLSearchCore", dependencies: ["PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "MLSearchCoreTests", dependencies: ["MLSearchCore", "PhotosCore"],
            swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "MLSearchAppleAdapter", dependencies: ["MLSearchCore", "MediaFeedCore", "PhotosCore"],
            resources: [.process("Resources")], swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "MLSearchAppleAdapterTests", dependencies: ["MLSearchAppleAdapter", "MLSearchCore", "PhotosCore"],
            swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "MLSearchFeature", dependencies: ["MLSearchCore", "PhotosCore"],
            swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "MLSearchFeatureTests", dependencies: ["MLSearchFeature"], swiftSettings: disableDynamicActorIsolation
        ),
    ]
)
