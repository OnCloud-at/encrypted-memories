#!/usr/bin/env bash
set -euo pipefail

platform="${1:-}"
archive_path="${2:-}"
export_path="${3:-}"
expected_version="${4:-}"
expected_build="${5:-}"
expected_profile_name="${6:-}"

case "$platform" in
  ios)
    expected_product="EncryptedMemoriesMobile.app"
    artifact_extension="ipa"
    ;;
  macos)
    expected_product="Encrypted Memories.app"
    artifact_extension="pkg"
    ;;
  *)
    echo "Usage: $0 ios|macos archive-path export-path version build profile-name" >&2
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
  APPLE_DEVELOPER_TEAM_ID \
  GITHUB_OUTPUT \
  RUNNER_TEMP; do
  required "$name"
done

for value in \
  "$archive_path" \
  "$export_path" \
  "$expected_version" \
  "$expected_build" \
  "$expected_profile_name"; do
  [[ -n "$value" ]] || {
    echo "A required argument is empty." >&2
    exit 64
  }
done

validate_app_signing() {
  local checked_app="$1"
  local bundle_identifier="$2"
  local label="$3"
  local suffix="$4"
  local checked_profile="$checked_app/embedded.mobileprovision"
  local app_identifier_key="application-identifier"
  local profile_plist="$RUNNER_TEMP/profile-$suffix.plist"
  local entitlements_plist="$RUNNER_TEMP/entitlements-$suffix.plist"

  if [[ "$platform" == "macos" ]]; then
    checked_profile="$checked_app/Contents/embedded.provisionprofile"
    app_identifier_key="com.apple.application-identifier"
  fi
  [[ -f "$checked_profile" ]] || {
    echo "$label does not contain an App Store provisioning profile." >&2
    exit 65
  }

  codesign --verify --deep --strict --verbose=2 "$checked_app"
  local signing_details
  signing_details="$(codesign --display --verbose=4 "$checked_app" 2>&1)"
  grep -q '^Authority=Apple Distribution:' <<< "$signing_details" || {
    echo "$label does not use an Apple Distribution identity." >&2
    exit 65
  }
  local actual_team
  actual_team="$(awk -F= '/^TeamIdentifier=/{print $2}' <<< "$signing_details")"
  [[ "$actual_team" == "$APPLE_DEVELOPER_TEAM_ID" ]] || {
    echo "$label TeamIdentifier is $actual_team, expected $APPLE_DEVELOPER_TEAM_ID." >&2
    exit 65
  }

  security cms -D -i "$checked_profile" > "$profile_plist"
  codesign --display --entitlements :- "$checked_app" > "$entitlements_plist" 2>/dev/null
  plutil -lint "$profile_plist" "$entitlements_plist"

  local profile_name
  profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$profile_plist")"
  [[ "$profile_name" == "$expected_profile_name" ]] || {
    echo "$label uses profile $profile_name, expected $expected_profile_name." >&2
    exit 65
  }

  local profile_team
  profile_team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$profile_plist")"
  local profile_app_identifier
  profile_app_identifier="$(
    /usr/libexec/PlistBuddy -c "Print :Entitlements:$app_identifier_key" "$profile_plist"
  )"
  local signed_app_identifier
  signed_app_identifier="$(
    /usr/libexec/PlistBuddy -c "Print :$app_identifier_key" "$entitlements_plist"
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
        "$entitlements_plist" 2>/dev/null
    )"; do
      local keychain_group_allowed=false
      local profile_group_index=0
      local profile_group
      while profile_group="$(
        /usr/libexec/PlistBuddy \
          -c "Print :Entitlements:keychain-access-groups:$profile_group_index" \
          "$profile_plist" 2>/dev/null
      )"; do
        [[ "$signed_keychain_group" != $profile_group ]] || keychain_group_allowed=true
        profile_group_index="$((profile_group_index + 1))"
      done
      [[ "$keychain_group_allowed" == "true" ]] || {
        echo "$label has a keychain group that its profile does not allow." >&2
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

archive_app="$archive_path/Products/Applications/$expected_product"
archive_info="$archive_app/Contents/Info.plist"
[[ "$platform" == "ios" ]] && archive_info="$archive_app/Info.plist"
[[ -f "$archive_info" ]] || {
  echo "Archive does not contain $expected_product." >&2
  exit 66
}

bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$archive_info")"
actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$archive_info")"
actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$archive_info")"
uses_nonexempt_encryption="$(
  /usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$archive_info"
)"

[[ "$bundle_identifier" == "at.oncloud.encryptedmemories" ]]
[[ "$actual_version" == "$expected_version" ]]
[[ "$actual_build" == "$expected_build" ]]
[[ "$uses_nonexempt_encryption" == "false" ]]
validate_app_signing "$archive_app" "$bundle_identifier" "Archive" "archive-$platform"

shopt -s nullglob
artifacts=("$export_path"/*."$artifact_extension")
[[ "${#artifacts[@]}" -eq 1 ]] || {
  echo "Expected one exported $artifact_extension, found ${#artifacts[@]}." >&2
  exit 66
}
artifact="${artifacts[0]}"

expanded_root="$(mktemp -d "$RUNNER_TEMP/exported-app-$platform.XXXXXX")"
if [[ "$platform" == "ios" ]]; then
  ditto -x -k "$artifact" "$expanded_root"
  exported_app="$expanded_root/Payload/$expected_product"
else
  package_signature="$(pkgutil --check-signature "$artifact")"
  printf '%s\n' "$package_signature"
  grep -Eq 'Mac Installer Distribution:|3rd Party Mac Developer Installer:' \
    <<< "$package_signature" || {
      echo "The package does not use a Mac Installer Distribution identity." >&2
      exit 65
  }
  pkgutil --expand-full "$artifact" "$expanded_root/package"
  exported_app=""
  exported_app_count=0
  while IFS= read -r candidate; do
    exported_app="$candidate"
    exported_app_count="$((exported_app_count + 1))"
  done < <(find "$expanded_root/package" -type d -name "$expected_product" -prune)
  [[ "$exported_app_count" -eq 1 ]] || {
    echo "Expected one signed app inside the package, found $exported_app_count." >&2
    exit 66
  }
fi

[[ -d "$exported_app" ]] || {
  echo "The exported package does not contain $expected_product." >&2
  exit 66
}
validate_app_signing "$exported_app" "$bundle_identifier" "Exported app" "exported-$platform"

echo "path=$artifact" >> "$GITHUB_OUTPUT"
echo "Validated $platform $expected_version ($expected_build): $artifact"
