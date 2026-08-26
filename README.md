# Encrypted Memories

Encrypted Memories is an independent photo client for Proton Drive. It requires an existing Proton account and does not create accounts.

The app uses Proton Drive's end-to-end encrypted storage and browser-based session fork authentication. Shared feature modules implement library, backup, albums, search, map, cache, and viewer behavior once for macOS, iOS, and iPadOS. Platform targets provide native AppKit or UIKit presentation around those modules.

Encrypted Memories is not affiliated with or endorsed by Proton AG.

## Support Encrypted Memories

Encrypted Memories is free and open source. Every feature remains available without payment.

**[Sponsor Encrypted Memories through GitHub Sponsors](https://github.com/sponsors/traktuner)**

GitHub Sponsors supports one-time and monthly contributions. App Store releases also offer optional, repeatable StoreKit tips. Sponsorship does not purchase features, priority support, or influence over the project.

Financial support helps cover Apple membership, test devices, infrastructure, and release work.

## Features

- End-to-end encrypted Proton Drive photo library.
- Metal timeline with responsive grid densities, selection, transitions, and viewport-aware loading.
- Full-screen image, video, Live Photo, and burst viewing.
- Albums, trash, restore, sharing, and original-format export.
- Photo Library backup on macOS, iOS, and iPadOS with persistent queues, streamed hashing, duplicate detection, crash recovery, album synchronization, and OS-scheduled background catch-up.
- MapKit browsing with encrypted location metadata and adaptive clustering.
- Encrypted thumbnail, preview, original, and offline caches.
- Optional on-device Smart Search using Core ML. Model artifacts and the local search index stay on the device, and photos and search queries are not sent to a search service.
- Shared network request governance for foreground interactions and background work.

## Platform Status

macOS, iOS, and iPadOS use the same shared feature cores and provide the same primary library, viewer, album, backup, map, and Smart Search capabilities. Library loading, connectivity, and background-work status use shared presentation policy, while navigation, controls, gestures, and system integrations remain platform native.

`Vendor/sdk-swift` is used as a local path dependency for the Proton Drive SDK.

## User Documentation

The [Encrypted Memories Wiki](https://github.com/OnCloud-at/encrypted-memories/wiki) contains the Quick Start, one guide for each app area, troubleshooting, and the current device and feature support matrix.

GitHub Issues are for reproducible bugs and concrete feature proposals. Do not open an issue for a how-to question; use the Wiki first.

The reviewed Wiki source lives in [`Wiki`](Wiki). GitHub stores the visible Wiki in the separate Git endpoint attached to this repository. Maintainers can preview a Wiki sync or publish it with:

```bash
./scripts/publish-wiki.sh
./scripts/publish-wiki.sh --publish
```

## Technology

- Swift, SwiftUI, AppKit, UIKit, MapKit, AVFoundation, Core ML, CryptoKit, and SQLite.
- Metal-based timeline rendering with shared layout, transition, composition, and residency policies.
- Swift Package Manager modules under `Packages/EncryptedMemoriesKit`.
- Xcode project generation from `project.yml` with XcodeGen.
- The official open-source Proton Drive SDK 0.24.0, distributed under the MIT License and restored at `Vendor/sdk-swift`.

## Security

- Sign-in uses Proton's web flow. The app does not collect the user's Proton password.
- Session credentials are stored in the platform Keychain with device-only accessibility.
- The SDK's unified cache is account-scoped and encrypted with a dedicated 32-byte derived key.
  Legacy plaintext SDK databases are removed during launch.
- Local thumbnails, previews, originals, account metadata, location data, and ML vectors are encrypted at rest.
- Video playback stores Proton-encrypted blocks on disk and decrypts requested ranges in memory.
- Decrypted originals are written only when the user exports or shares them.
- Release builds do not write file debug logs. Runtime-gated unified logging is disabled unless explicitly enabled for a local investigation.
- The macOS app uses App Sandbox, outgoing network access, and user-selected file access. Hardened Runtime remains enabled without JIT or unsigned executable memory.

## Requirements

- macOS 26, iOS 26, or iPadOS 26 on a Metal 3 device. See the [device support matrix](https://github.com/OnCloud-at/encrypted-memories/wiki/Device-and-Feature-Support).
- Xcode 26 or newer installed at `/Applications/Xcode.app`.
- XcodeGen available on `PATH`.
- An Apple development team is required only for signed device installation.
- Git access to the Proton Drive SDK repository if `Vendor/sdk-swift` is not present.

Select the full Xcode toolchain:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## Bootstrap

```bash
git clone https://github.com/OnCloud-at/encrypted-memories.git
cd encrypted-memories
./scripts/update-proton-sdk.sh 0.24.0
./scripts/proton-sdk-current-version.sh
xcodegen generate
```

The SDK checkout is reproducible: the bootstrap script applies the versioned fixes tracked under
`VendorPatches/sdk-swift/0.24.0` after checking out the upstream tag. The updater fails before
changing the checkout when the requested tag has no reviewed patch set.

## Build

Build macOS without installing the app:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export ENCRYPTED_MEMORIES_BUILD_ROOT="$HOME/Developer/xcode/EncryptedMemories"
xcodebuild build \
  -project EncryptedMemories.xcodeproj \
  -scheme EncryptedMemories \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$ENCRYPTED_MEMORIES_BUILD_ROOT/DD.noindex" \
  -clonedSourcePackagesDirPath "$ENCRYPTED_MEMORIES_BUILD_ROOT/SourcePackages.noindex" \
  -packageCachePath "$ENCRYPTED_MEMORIES_BUILD_ROOT/XcodePackageCache.noindex" \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO
```

Build the iOS/iPadOS target without signing:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export ENCRYPTED_MEMORIES_BUILD_ROOT="$HOME/Developer/xcode/EncryptedMemories"
xcodebuild build \
  -project EncryptedMemories.xcodeproj \
  -scheme EncryptedMemoriesMobile \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$ENCRYPTED_MEMORIES_BUILD_ROOT/DD.ios.noindex" \
  -clonedSourcePackagesDirPath "$ENCRYPTED_MEMORIES_BUILD_ROOT/SourcePackages.noindex" \
  -packageCachePath "$ENCRYPTED_MEMORIES_BUILD_ROOT/XcodePackageCache.noindex" \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO
```

For local development, the rebuild script generates the project, builds and launches the signed macOS app, and installs the iOS app when a configured device is connected. Set `ENCRYPTED_MEMORIES_IOS_DEVICE_NAME` to select a specific device. The macOS app is accepted only when its signature, TeamIdentifier, and signed entitlement blob validate before and after installation:

```bash
./scripts/rebuild.sh
```

The rebuild script does not run tests.

All scripts share package downloads below `ENCRYPTED_MEMORIES_BUILD_ROOT`; do not create per-worktree
DerivedData or SwiftPM scratch directories. Use `./scripts/report-build-storage.sh` to inspect the
canonical root and detect ad-hoc Proton build trees under `/private/tmp`.

## Tests

Run the complete Swift package suite:

```bash
./scripts/verify-tests.sh
```

This runs both `EncryptedMemoriesKit` and the vendored SDK's own tests. A dependency's test targets are
not executed when it is consumed as a local SwiftPM package.

Run the iOS app-shell tests on a simulator:

```bash
./scripts/verify-ios-app-tests.sh
```

Override `IOS_TEST_DESTINATION` when the default iPhone simulator is not installed.

Run the fast shared-core and platform-boundary gate:

```bash
./scripts/verify-universal-core.sh fast
```

Run the complete shared-core verification or the iOS shell build:

```bash
./scripts/verify-universal-core.sh
./scripts/verify-ios-app-shell.sh
```

The test targets cover module and import boundaries, encrypted persistence, media caching and decoding, backup deduplication and recovery, grid layout and rendering, viewer and map behavior, Smart Search model and index lifecycle, localization, and production route guards.

## Repository Layout

- `App` contains the macOS app and AppKit/SwiftUI composition.
- `iOSApp` contains the iOS/iPadOS app and UIKit/SwiftUI composition.
- `Packages/EncryptedMemoriesKit` contains shared core, feature, renderer, cache, backend, and platform-adapter modules.
- `Branding` contains app icons and product assets.
- `Tools` contains development utilities.
- `Vendor/sdk-swift` contains the local Proton Drive SDK checkout.
- `project.yml` is the source of truth for generated Xcode project settings.
- `scripts` contains build, verification, SDK, and release helpers.

## License

Encrypted Memories is available under the permissive [MIT License](LICENSE). You may use, copy, modify, distribute, sublicense, and sell the original project source under its terms.

The software is provided without warranty or a support obligation. Dependencies and optional model artifacts retain their respective license terms.
