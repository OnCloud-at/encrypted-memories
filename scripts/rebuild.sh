#!/bin/bash
# Build and install the signed macOS release app. A configured device name also enables the iOS build.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."

ROOT="$(pwd)"
source "$ROOT/scripts/build-paths.sh"
BUILD_ROOT="$ENCRYPTED_MEMORIES_BUILD_ROOT"
MAC_DD="$BUILD_ROOT/DD.noindex"
IOS_DD="$BUILD_ROOT/DD.device.noindex"
PROJECT="EncryptedMemories.xcodeproj"
MAC_SCHEME="EncryptedMemories"
MAC_CONFIGURATION="Release"
IOS_SCHEME="EncryptedMemoriesMobile"
IOS_DEVICE_NAME="${ENCRYPTED_MEMORIES_IOS_DEVICE_NAME:-}"
DEVELOPMENT_TEAM="${ENCRYPTED_MEMORIES_DEVELOPMENT_TEAM:-}"
IOS_DEVELOPMENT_TEAM="${ENCRYPTED_MEMORIES_IOS_DEVELOPMENT_TEAM:-$DEVELOPMENT_TEAM}"
IOS_BUNDLE_ID="at.oncloud.encryptedmemories"
SOURCE_BUILD_COMMIT="$(git rev-parse --short=12 HEAD)"
SOURCE_BUILD_NUMBER="$(git rev-list --count HEAD)"

if [[ -z "$DEVELOPMENT_TEAM" ]]; then
    echo "Set ENCRYPTED_MEMORIES_DEVELOPMENT_TEAM to the signing team before running this script." >&2
    exit 64
fi

encryptedmemories_acquire_build_lock "rebuild"

mkdir -p "$BUILD_ROOT"

echo "Generating Xcode project"
xcodegen generate >/dev/null
encryptedmemories_pin_generated_project_packages "$ROOT"

echo "Resolving pinned packages into shared cache"
xcodebuild -resolvePackageDependencies \
    -project "$PROJECT" -scheme "$MAC_SCHEME" \
    -clonedSourcePackagesDirPath "$ENCRYPTED_MEMORIES_XCODE_SOURCE_PACKAGES" \
    -packageCachePath "$ENCRYPTED_MEMORIES_XCODE_PACKAGE_CACHE" \
    -packageAuthorizationProvider netrc \
    -onlyUsePackageVersionsFromResolvedFile

SIGNING_IDENTITY_HASH="${ENCRYPTED_MEMORIES_CODE_SIGN_IDENTITY:-}"
MAC_SIGN_ARGS=(CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
MAC_PROVISIONING_ARGS=()
if [[ -n "$SIGNING_IDENTITY_HASH" ]]; then
    MAC_SIGN_ARGS+=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGNING_IDENTITY_HASH")
    echo "macOS signing: explicit identity override"
else
    MAC_SIGN_ARGS+=(CODE_SIGN_STYLE=Automatic)
    MAC_PROVISIONING_ARGS+=(-allowProvisioningUpdates)
    echo "macOS signing: Xcode automatic"
fi

echo "Building macOS app"
xcodebuild build -project "$PROJECT" -scheme "$MAC_SCHEME" \
    -configuration "$MAC_CONFIGURATION" \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$MAC_DD" \
    -clonedSourcePackagesDirPath "$ENCRYPTED_MEMORIES_XCODE_SOURCE_PACKAGES" \
    -packageCachePath "$ENCRYPTED_MEMORIES_XCODE_PACKAGE_CACHE" \
    -disableAutomaticPackageResolution \
    -skipPackagePluginValidation -skipMacroValidation \
    CURRENT_PROJECT_VERSION="$SOURCE_BUILD_NUMBER" \
    "${MAC_PROVISIONING_ARGS[@]}" "${MAC_SIGN_ARGS[@]}"

MAC_APP="$MAC_DD/Build/Products/$MAC_CONFIGURATION/Encrypted Memories.app"
MAC_DST="/Applications/Encrypted Memories.app"
LEGACY_MAC_DST_COMPACT="/Applications/EncryptedMemories.app"

verify_mac_app() {
    local app="$1"
    local team_id bundle_id entitlement_report
    codesign --verify --deep --strict "$app"
    team_id="$(codesign -dvv "$app" 2>&1 | awk -F= '/^TeamIdentifier=/{ print $2; exit }')"
    if [[ "$team_id" != "$DEVELOPMENT_TEAM" ]]; then
        echo "Refusing to install a macOS app signed for an unexpected team." >&2
        return 1
    fi
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
    entitlement_report="$(codesign -d --entitlements - "$app" 2>&1)"
    if [[ "$entitlement_report" == *"invalid entitlements blob"* ]]; then
        echo "Refusing macOS app whose signed entitlements are invalid." >&2
        return 1
    fi
    if [[ "$entitlement_report" != *"keychain-access-groups"* ]] \
        || [[ "$entitlement_report" != *"$DEVELOPMENT_TEAM.$bundle_id"* ]]; then
        echo "Refusing macOS app without its Team-scoped private Keychain access group." >&2
        return 1
    fi
    echo "Verified the macOS TeamIdentifier and entitlements."
}

verify_mac_app "$MAC_APP"

pkill -9 -f "Encrypted Memories.app/Contents/MacOS" 2>/dev/null || true
pkill -9 -f "EncryptedMemories.app/Contents/MacOS" 2>/dev/null || true
sleep 1
rm -rf "$MAC_DST" "$LEGACY_MAC_DST_COMPACT"
cp -R "$MAC_APP" "$MAC_DST"
xattr -dr com.apple.quarantine "$MAC_DST" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$MAC_DST"
open "$MAC_DST"
sleep 1
verify_mac_app "$MAC_DST"
echo "Installed and launched macOS app: $MAC_DST"

if [[ "${ENCRYPTED_MEMORIES_SKIP_IOS:-0}" == "1" ]]; then
    echo "iOS skipped: ENCRYPTED_MEMORIES_SKIP_IOS=1"
    exit 0
fi

if [[ -z "$IOS_DEVICE_NAME" ]]; then
    echo "iOS skipped: set ENCRYPTED_MEMORIES_IOS_DEVICE_NAME to select a connected device"
    exit 0
fi

IOS_DEVICE_ID="$(
    xcrun devicectl list devices \
        --filter "Name = '$IOS_DEVICE_NAME' AND State BEGINSWITH 'available'" \
        --columns Identifier --hide-default-columns --hide-headers --timeout 5 2>/dev/null \
        | awk '$1 ~ /^[[:xdigit:]-]{36}$/ { print $1; exit }' || true
)"

if [[ -z "$IOS_DEVICE_ID" ]]; then
    echo "iOS skipped: $IOS_DEVICE_NAME is not available"
    exit 0
fi

echo "Building iOS app for $IOS_DEVICE_NAME ($IOS_DEVICE_ID)"
xcodebuild build -project "$PROJECT" -scheme "$IOS_SCHEME" \
    -destination "id=$IOS_DEVICE_ID" -derivedDataPath "$IOS_DD" \
    -clonedSourcePackagesDirPath "$ENCRYPTED_MEMORIES_XCODE_SOURCE_PACKAGES" \
    -packageCachePath "$ENCRYPTED_MEMORIES_XCODE_PACKAGE_CACHE" \
    -disableAutomaticPackageResolution \
    -skipPackagePluginValidation -skipMacroValidation -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$IOS_DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic \
    CURRENT_PROJECT_VERSION="$SOURCE_BUILD_NUMBER" \
    ENCRYPTED_MEMORIES_BUILD_COMMIT="$SOURCE_BUILD_COMMIT"

IOS_APP="$IOS_DD/Build/Products/Debug-iphoneos/EncryptedMemoriesMobile.app"
IOS_APP_COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :EncryptedMemoriesBuildCommit' "$IOS_APP/Info.plist")"
IOS_APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$IOS_APP/Info.plist")"
if [[ "$IOS_APP_COMMIT" != "$SOURCE_BUILD_COMMIT" || "$IOS_APP_BUILD" != "$SOURCE_BUILD_NUMBER" ]]; then
    echo "Refusing to install iOS provenance commit=$IOS_APP_COMMIT build=$IOS_APP_BUILD; expected commit=$SOURCE_BUILD_COMMIT build=$SOURCE_BUILD_NUMBER." >&2
    exit 1
fi
IOS_EXECUTABLE_UUID="$(xcrun dwarfdump --uuid "$IOS_APP/EncryptedMemoriesMobile" | awk '{ print $2; exit }')"
echo "Verified iOS provenance: commit=$IOS_APP_COMMIT build=$IOS_APP_BUILD uuid=$IOS_EXECUTABLE_UUID"
echo "Installing iOS app on $IOS_DEVICE_NAME"
xcrun devicectl device install app --device "$IOS_DEVICE_ID" --timeout 120 "$IOS_APP"
xcrun devicectl device process launch --device "$IOS_DEVICE_ID" --timeout 30 \
    --terminate-existing "$IOS_BUNDLE_ID"
echo "Installed and launched iOS app on $IOS_DEVICE_NAME"

verify_mac_app "$MAC_DST"
echo "Final macOS signature verified after iOS provisioning"
