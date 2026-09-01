#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/Packages/EncryptedMemoriesKit"
source "$ROOT/scripts/build-paths.sh"
SPM_SCRATCH="${SPM_SCRATCH_PATH:-$ENCRYPTED_MEMORIES_SPM_SCRATCH}"
DERIVED_DATA_BASE="${DERIVED_DATA_BASE:-$ENCRYPTED_MEMORIES_BUILD_ROOT/core-gate-dd.noindex}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
MODE="${CORE_GATE_MODE:-${1:-full}}"

encryptedmemories_acquire_build_lock "verify-universal-core-$MODE"

case "$MODE" in
  fast|full|build-ios|build-macos) ;;
  *)
    echo "usage: $(basename "$0") [fast|full|build-ios|build-macos]" >&2
    echo "  fast: CoreArchitectureGateTests only" >&2
    echo "  full: architecture tests + iOS/macOS package build proof" >&2
    echo "  build-ios: iOS package build proof without tests" >&2
    echo "  build-macos: macOS package build proof without tests" >&2
    exit 64
    ;;
esac

RUN_ARCHITECTURE_TESTS=false
BUILD_IOS=false
BUILD_MACOS=false

case "$MODE" in
  fast)
    RUN_ARCHITECTURE_TESTS=true
    ;;
  full)
    RUN_ARCHITECTURE_TESTS=true
    BUILD_IOS=true
    BUILD_MACOS=true
    ;;
  build-ios)
    BUILD_IOS=true
    ;;
  build-macos)
    BUILD_MACOS=true
    ;;
esac

CORE_TARGETS=(
  AppleSecurityCore
  PhotosCore
  MediaByteCache
  MediaDecodingCore
  MediaFeedCore
  MediaLocationCore
  MediaCacheCore
  GridCore
  UploadCore
  TimelineCore
  PhotoViewerCore
  MLSearchCore
)

SHARED_UI_TARGETS=(
  DesignSystemCore
  MLSearchFeature
)

RENDERING_CORE_TARGETS=(
  MetalRenderingCore
  MetalGridTextureCore
  MetalGridComposeCore
)

IOS_PLATFORM_ADAPTER_TARGETS=(
  LibraryRuntimeAppleAdapter
  MetalGridTextureUIKitAdapter
  TimelineUIKitAdapter
  TimelineUIKitFeature
  PhotoLibraryBackupAdapter
  MLSearchAppleAdapter
)

MACOS_PLATFORM_ADAPTER_TARGETS=(
  LibraryRuntimeAppleAdapter
  MetalGridTextureAppKitAdapter
  PhotoLibraryBackupAdapter
  MLSearchAppleAdapter
)

PLATFORMS=()
if [[ "$BUILD_IOS" == "true" ]]; then
  PLATFORMS+=("iOS:generic/platform=iOS")
fi
if [[ "$BUILD_MACOS" == "true" ]]; then
  PLATFORMS+=("macOS:generic/platform=macOS")
fi

echo "[core-gate] package: $PACKAGE"
echo "[core-gate] developer dir: $DEVELOPER_DIR"
echo "[core-gate] mode: $MODE"
echo "[core-gate] derived data base: $DERIVED_DATA_BASE"

echo "[core-gate] spm scratch: $SPM_SCRATCH"
if [[ "$RUN_ARCHITECTURE_TESTS" == "true" ]]; then
  echo "[core-gate] running CoreArchitectureGateTests"
  xcrun swift test \
    --package-path "$PACKAGE" \
    --scratch-path "$SPM_SCRATCH" \
    --cache-path "$ENCRYPTED_MEMORIES_SWIFTPM_CACHE" \
    --filter CoreArchitectureGateTests
fi

if [[ "$MODE" == "fast" ]]; then
  echo "[core-gate] fast architecture gate passed"
  exit 0
fi

build_scheme() {
  local scheme="$1"
  local platform_name="$2"
  local destination="$3"
  local label="$4"
  local derived_data="$DERIVED_DATA_BASE/$platform_name"

  echo "[core-gate] building $label$scheme for $platform_name"
  xcrun xcodebuild \
    -scheme "$scheme" \
    -destination "$destination" \
    -derivedDataPath "$derived_data" \
    -clonedSourcePackagesDirPath "$ENCRYPTED_MEMORIES_XCODE_SOURCE_PACKAGES" \
    -packageCachePath "$ENCRYPTED_MEMORIES_XCODE_PACKAGE_CACHE" \
    -disableAutomaticPackageResolution \
    -skipPackagePluginValidation \
    -quiet \
    build
}

pushd "$PACKAGE" >/dev/null

echo "[core-gate] resolving pinned packages into shared cache"
xcrun xcodebuild \
  -resolvePackageDependencies \
  -scheme PhotosCore \
  -clonedSourcePackagesDirPath "$ENCRYPTED_MEMORIES_XCODE_SOURCE_PACKAGES" \
  -packageCachePath "$ENCRYPTED_MEMORIES_XCODE_PACKAGE_CACHE" \
  -packageAuthorizationProvider netrc \
  -onlyUsePackageVersionsFromResolvedFile

for target in "${CORE_TARGETS[@]}"; do
  for platform in "${PLATFORMS[@]}"; do
    name="${platform%%:*}"
    destination="${platform#*:}"
    build_scheme "$target" "$name" "$destination" ""
  done
done

for target in "${SHARED_UI_TARGETS[@]}"; do
  for platform in "${PLATFORMS[@]}"; do
    name="${platform%%:*}"
    destination="${platform#*:}"
    build_scheme "$target" "$name" "$destination" "shared UI "
  done
done

for target in "${RENDERING_CORE_TARGETS[@]}"; do
  for platform in "${PLATFORMS[@]}"; do
    name="${platform%%:*}"
    destination="${platform#*:}"
    build_scheme "$target" "$name" "$destination" ""
  done
done

if [[ "$BUILD_MACOS" == "true" ]]; then
  for target in "${MACOS_PLATFORM_ADAPTER_TARGETS[@]}"; do
    build_scheme "$target" "macOS" "generic/platform=macOS" ""
  done
fi

if [[ "$BUILD_IOS" == "true" ]]; then
  for target in "${IOS_PLATFORM_ADAPTER_TARGETS[@]}"; do
    build_scheme "$target" "iOS" "generic/platform=iOS" ""
  done
fi

popd >/dev/null

echo "[core-gate] $MODE universal Core + shared UI + Metal Core + platform adapter proof passed"
