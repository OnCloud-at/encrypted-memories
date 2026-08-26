#!/usr/bin/env bash
set -euo pipefail

platform="${1:-}"
case "$platform" in
  ios)
    scheme="EncryptedMemoriesMobile"
    destination="generic/platform=iOS"
    expected_product="EncryptedMemoriesMobile.app"
    ;;
  macos)
    scheme="EncryptedMemories"
    destination="generic/platform=macOS"
    expected_product="Encrypted Memories.app"
    ;;
  *)
    echo "Usage: $0 ios|macos" >&2
    exit 64
    ;;
esac

required() {
  local name="$1"
  [[ -n "${!name:-}" ]] || {
    echo "Missing $name" >&2
    exit 64
  }
}

for name in \
  APP_STORE_CONNECT_ISSUER_ID \
  APP_STORE_CONNECT_KEY_ID \
  APP_STORE_CONNECT_KEY_PATH \
  APPLE_DEVELOPER_TEAM_ID \
  APPLE_RELEASE_VERSION \
  APPLE_BUILD_NUMBER \
  GITHUB_SHA \
  RUNNER_TEMP; do
  required "$name"
done

source scripts/build-paths.sh

validate_app_signing() {
  local checked_app="$1"
  local bundle_identifier="$2"
  local label="$3"
  local temp_suffix="$4"
  local checked_profile="$checked_app/embedded.mobileprovision"
  local app_identifier_key="application-identifier"
  local checked_profile_plist="$RUNNER_TEMP/profile-$temp_suffix.plist"
  local checked_entitlements="$RUNNER_TEMP/entitlements-$temp_suffix.plist"

  if [[ "$platform" == "macos" ]]; then
    checked_profile="$checked_app/Contents/embedded.provisionprofile"
    app_identifier_key="com.apple.application-identifier"
  fi
  [[ -f "$checked_profile" ]] || {
    echo "$label does not contain its App Store provisioning profile." >&2
    exit 65
  }

  codesign --verify --deep --strict --verbose=2 "$checked_app"
  local signing_details
  signing_details="$(codesign --display --verbose=4 "$checked_app" 2>&1)"
  local actual_team
  actual_team="$(awk -F= '/^TeamIdentifier=/{print $2}' <<< "$signing_details")"
  [[ "$actual_team" == "$APPLE_DEVELOPER_TEAM_ID" ]] || {
    echo "$label TeamIdentifier is $actual_team, expected $APPLE_DEVELOPER_TEAM_ID." >&2
    exit 65
  }

  security cms -D -i "$checked_profile" > "$checked_profile_plist"
  codesign --display --entitlements :- "$checked_app" > "$checked_entitlements" 2>/dev/null
  plutil -lint "$checked_profile_plist" "$checked_entitlements"

  local profile_team
  profile_team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$checked_profile_plist")"
  local profile_app_identifier
  profile_app_identifier="$(
    /usr/libexec/PlistBuddy -c "Print :Entitlements:$app_identifier_key" "$checked_profile_plist"
  )"
  local signed_app_identifier
  signed_app_identifier="$(
    /usr/libexec/PlistBuddy -c "Print :$app_identifier_key" "$checked_entitlements"
  )"
  [[ "$profile_team" == "$APPLE_DEVELOPER_TEAM_ID" ]]
  [[ "$profile_app_identifier" == *."$bundle_identifier" ]]
  [[ "$signed_app_identifier" == "$profile_app_identifier" ]]

  if [[ "$platform" == "macos" ]]; then
    local signed_group_index=0
    local signed_keychain_group
    while signed_keychain_group="$(
      /usr/libexec/PlistBuddy \
        -c "Print :keychain-access-groups:$signed_group_index" \
        "$checked_entitlements" 2>/dev/null
    )"; do
      local keychain_group_allowed=false
      local profile_group_index=0
      local profile_group
      while profile_group="$(
        /usr/libexec/PlistBuddy \
          -c "Print :Entitlements:keychain-access-groups:$profile_group_index" \
          "$checked_profile_plist" 2>/dev/null
      )"; do
        # Provisioning profiles can allow a keychain group with a trailing wildcard.
        [[ "$signed_keychain_group" != $profile_group ]] || keychain_group_allowed=true
        profile_group_index="$((profile_group_index + 1))"
      done
      [[ "$keychain_group_allowed" == "true" ]] || {
        echo "$label has a keychain access group that its profile does not allow." >&2
        exit 65
      }
      signed_group_index="$((signed_group_index + 1))"
    done
    [[ "$signed_group_index" -gt 0 ]] || {
      echo "$label does not contain a keychain access group." >&2
      exit 65
    }
  fi
}

archive_path="$RUNNER_TEMP/EncryptedMemories-$platform.xcarchive"
derived_data="$RUNNER_TEMP/DerivedData-$platform.noindex"
export_path="$RUNNER_TEMP/export-$platform"
export_options="$RUNNER_TEMP/ExportOptions-$platform.plist"

authentication=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$APP_STORE_CONNECT_KEY_PATH"
  -authenticationKeyID "$APP_STORE_CONNECT_KEY_ID"
  -authenticationKeyIssuerID "$APP_STORE_CONNECT_ISSUER_ID"
)

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_26.6.app/Contents/Developer}" \
xcodebuild archive \
  -project EncryptedMemories.xcodeproj \
  -scheme "$scheme" \
  -configuration Release \
  -destination "$destination" \
  -archivePath "$archive_path" \
  -derivedDataPath "$derived_data" \
  -clonedSourcePackagesDirPath "$ENCRYPTED_MEMORIES_XCODE_SOURCE_PACKAGES" \
  -packageCachePath "$ENCRYPTED_MEMORIES_XCODE_PACKAGE_CACHE" \
  -onlyUsePackageVersionsFromResolvedFile \
  -disableAutomaticPackageResolution \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  "${authentication[@]}" \
  DEVELOPMENT_TEAM="$APPLE_DEVELOPER_TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  MARKETING_VERSION="$APPLE_RELEASE_VERSION" \
  CURRENT_PROJECT_VERSION="$APPLE_BUILD_NUMBER" \
  ENCRYPTED_MEMORIES_BUILD_COMMIT="$GITHUB_SHA" \
  COMPILER_INDEX_STORE_ENABLE=NO

app_path="$archive_path/Products/Applications/$expected_product"
info_plist="$app_path/Contents/Info.plist"
[[ "$platform" == "ios" ]] && info_plist="$app_path/Info.plist"
[[ -f "$info_plist" ]] || {
  echo "Archive does not contain $expected_product." >&2
  exit 66
}

actual_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
uses_nonexempt_encryption="$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$info_plist")"

[[ "$actual_identifier" == "at.oncloud.encryptedmemories" ]]
[[ "$actual_version" == "$APPLE_RELEASE_VERSION" ]]
[[ "$actual_build" == "$APPLE_BUILD_NUMBER" ]]
[[ "$uses_nonexempt_encryption" == "false" ]]
validate_app_signing "$app_path" "$actual_identifier" "Archive" "archive-$platform"

cat > "$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>method</key>
  <string>app-store-connect</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>teamID</key>
  <string>$APPLE_DEVELOPER_TEAM_ID</string>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
PLIST
plutil -lint "$export_options"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_26.6.app/Contents/Developer}" \
xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_options" \
  "${authentication[@]}"

shopt -s nullglob
if [[ "$platform" == "ios" ]]; then
  artifacts=("$export_path"/*.ipa)
else
  artifacts=("$export_path"/*.pkg)
fi
[[ "${#artifacts[@]}" -eq 1 ]] || {
  echo "Expected one exported $platform package, found ${#artifacts[@]}." >&2
  exit 66
}
artifact="${artifacts[0]}"

exported_app_root="$RUNNER_TEMP/exported-app-$platform"
rm -rf -- "$exported_app_root"
mkdir -p "$exported_app_root"
if [[ "$platform" == "ios" ]]; then
  ditto -x -k "$artifact" "$exported_app_root"
  exported_app="$exported_app_root/Payload/$expected_product"
else
  package_signature="$(pkgutil --check-signature "$artifact")"
  printf '%s\n' "$package_signature"
  grep -Eq 'Mac Installer Distribution:|3rd Party Mac Developer Installer:' <<< "$package_signature" || {
    echo "The exported macOS package does not use a Mac Installer Distribution identity." >&2
    exit 65
  }
  pkgutil --expand-full "$artifact" "$exported_app_root/expanded"
  exported_app=""
  exported_app_count=0
  while IFS= read -r candidate; do
    exported_app="$candidate"
    exported_app_count="$((exported_app_count + 1))"
  done < <(find "$exported_app_root/expanded" -type d -name "$expected_product" -prune)
  [[ "$exported_app_count" -eq 1 ]] || {
    echo "Expected one signed app inside the macOS package, found $exported_app_count." >&2
    exit 66
  }
fi

[[ -d "$exported_app" ]] || {
  echo "The exported package does not contain $expected_product." >&2
  exit 66
}
exported_signing_details="$(codesign --display --verbose=4 "$exported_app" 2>&1)"
grep -q '^Authority=Apple Distribution:' <<< "$exported_signing_details" || {
  echo "The exported app does not use an Apple Distribution identity." >&2
  exit 65
}
exported_team="$(awk -F= '/^TeamIdentifier=/{print $2}' <<< "$exported_signing_details")"
[[ "$exported_team" == "$APPLE_DEVELOPER_TEAM_ID" ]] || {
  echo "Exported TeamIdentifier is $exported_team, expected $APPLE_DEVELOPER_TEAM_ID." >&2
  exit 65
}
validate_app_signing "$exported_app" "$actual_identifier" "Exported app" "exported-$platform"

xcrun altool --upload-package "$artifact" \
  --api-key "$APP_STORE_CONNECT_KEY_ID" \
  --api-issuer "$APP_STORE_CONNECT_ISSUER_ID" \
  --p8-file-path "$APP_STORE_CONNECT_KEY_PATH" \
  --wait \
  --output-format json

echo "Uploaded $platform $APPLE_RELEASE_VERSION ($APPLE_BUILD_NUMBER) to App Store Connect."
