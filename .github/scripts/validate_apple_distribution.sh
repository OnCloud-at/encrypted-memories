#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/release_failure.sh"

assert_nonempty() {
  local label="$1" value="$2" remediation="$3"
  [[ -n "$value" ]] || release_fail configuration \
    "Checked $label; actual value was empty; expected a non-empty value." "$remediation"
}

assert_equal() {
  local label="$1" actual="$2" expected="$3" remediation="$4"
  [[ "$actual" == "$expected" ]] || release_fail validation \
    "Checked $label; actual value was '$actual'; expected '$expected'." "$remediation"
}

assert_file() {
  local label="$1" path="$2" remediation="$3"
  [[ -f "$path" ]] || release_fail validation \
    "Checked $label at '$path'; actual value was missing; expected a file." "$remediation"
}

assert_directory() {
  local label="$1" path="$2" remediation="$3"
  [[ -d "$path" ]] || release_fail validation \
    "Checked $label at '$path'; actual value was missing; expected a directory." "$remediation"
}

assert_contains() {
  local label="$1" actual="$2" expected="$3" remediation="$4"
  grep -Eq "$expected" <<< "$actual" || release_fail signing \
    "Checked $label; actual value was '$actual'; expected a match for '$expected'." "$remediation"
}

run_checked() {
  local label="$1" remediation="$2"
  shift 2
  local output status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  (( status == 0 )) || release_fail validation \
    "Checked $label; actual command failed with exit $status: $output" "$remediation"
  printf '%s' "$output"
}

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
    release_fail configuration \
      "Checked platform argument; actual value was '$platform'; expected ios or macos." \
      "Run the workflow with a supported matrix platform."
    ;;
esac

required() {
  local name="$1"
  assert_nonempty "$name" "${!name:-}" "Set the $name workflow variable or argument."
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
  assert_nonempty "required argument" "$value" "Pass all six validation arguments."
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
  assert_file "$label provisioning profile" "$checked_profile" \
    "Export the app again with the expected App Store provisioning profile."

  run_checked "$label code signature" "Re-archive and export the app with valid signing assets." \
    codesign --verify --deep --strict --verbose=2 "$checked_app" >/dev/null
  local signing_details
  signing_details="$(run_checked "$label signing metadata" "Re-sign and export the app with a valid Apple Distribution certificate." \
    codesign --display --verbose=4 "$checked_app")"
  assert_contains "$label signing authority" "$signing_details" '^Authority=Apple Distribution:' \
    "Import a valid Apple Distribution certificate and export the app again."
  local actual_team
  actual_team="$(awk -F= '/^TeamIdentifier=/{print $2}' <<< "$signing_details")"
  assert_equal "$label TeamIdentifier" "$actual_team" "$APPLE_DEVELOPER_TEAM_ID" \
    "Use the certificate and provisioning profile for the configured Apple team."

  run_checked "$label provisioning profile decode" "Renew the profile and export the app again." \
    security cms -D -i "$checked_profile" > "$profile_plist"
  # codesign reports `Executable=...` on stderr, which run_checked merges into its output. Let codesign
  # write the XML itself; it does not replace an existing file, so remove any earlier one first.
  rm -f "$entitlements_plist"
  run_checked "$label entitlements extraction" "Re-sign and export the app with valid entitlements." \
    codesign --display --entitlements "$entitlements_plist" --xml "$checked_app" >/dev/null
  run_checked "$label plist syntax" "Regenerate the archive and export options." \
    plutil -lint "$profile_plist" "$entitlements_plist" >/dev/null

  local profile_name
  profile_name="$(run_checked "$label profile name" "Renew and export the provisioning profile again." \
    /usr/libexec/PlistBuddy -c 'Print :Name' "$profile_plist")"
  assert_equal "$label profile name" "$profile_name" "$expected_profile_name" \
    "Renew and select the named provisioning profile."

  local profile_team
  profile_team="$(run_checked "$label profile team" "Renew the provisioning profile for the configured Apple team." \
    /usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$profile_plist")"
  local profile_app_identifier
  profile_app_identifier="$(
    run_checked "$label profile application identifier" "Renew the provisioning profile for the app bundle identifier." \
      /usr/libexec/PlistBuddy -c "Print :Entitlements:$app_identifier_key" "$profile_plist"
  )"
  local signed_app_identifier
  signed_app_identifier="$(
    run_checked "$label signed application identifier" "Re-sign the app with valid entitlements." \
      /usr/libexec/PlistBuddy -c "Print :$app_identifier_key" "$entitlements_plist"
  )"
  assert_equal "$label profile team" "$profile_team" "$APPLE_DEVELOPER_TEAM_ID" \
    "Renew the provisioning profile for the configured Apple team."
  [[ "$profile_app_identifier" == *."$bundle_identifier" ]] || release_fail signing \
    "Checked $label profile application identifier; actual value was '$profile_app_identifier'; expected a suffix of '$bundle_identifier'." \
    "Renew the profile for bundle identifier '$bundle_identifier'."
  assert_equal "$label signed application identifier" "$signed_app_identifier" "$profile_app_identifier" \
    "Export the app with the provisioning profile that matches its entitlements."

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
        [[ "$signed_keychain_group" != "$profile_group" ]] || keychain_group_allowed=true
        profile_group_index="$((profile_group_index + 1))"
      done
      [[ "$keychain_group_allowed" == "true" ]] || release_fail signing \
        "Checked $label keychain group '$signed_keychain_group'; actual value was not allowed by the profile; expected an allowed group." \
        "Renew the profile with the app's keychain access group."
      signed_group_index="$((signed_group_index + 1))"
    done
    (( signed_group_index > 0 )) || release_fail signing \
      "Checked $label keychain access groups; actual count was 0; expected at least 1." \
      "Export the macOS app with its configured keychain access group."
  fi
}

archive_app="$archive_path/Products/Applications/$expected_product"
archive_info="$archive_app/Contents/Info.plist"
[[ "$platform" == "ios" ]] && archive_info="$archive_app/Info.plist"
assert_file "archive product Info.plist" "$archive_info" \
  "Archive the expected product before exporting the app."

bundle_identifier="$(run_checked "archive bundle identifier" "Archive the expected product with a valid Info.plist." \
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$archive_info")"
actual_version="$(run_checked "archive marketing version" "Archive the release with the expected version." \
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$archive_info")"
actual_build="$(run_checked "archive build number" "Archive the release with the expected build number." \
  /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$archive_info")"
uses_nonexempt_encryption="$(
  run_checked "export compliance flag" "Set ITSAppUsesNonExemptEncryption to false in the app target." \
    /usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$archive_info"
)"

assert_equal "bundle identifier" "$bundle_identifier" "at.oncloud.encryptedmemories" \
  "Build the app with bundle identifier at.oncloud.encryptedmemories."
assert_equal "marketing version" "$actual_version" "$expected_version" \
  "Create the archive from the release commit and version."
assert_equal "build number" "$actual_build" "$expected_build" \
  "Create the archive with the validated release build number."
assert_equal "export compliance flag" "$uses_nonexempt_encryption" "false" \
  "Set ITSAppUsesNonExemptEncryption to false and archive again."
validate_app_signing "$archive_app" "$bundle_identifier" "Archive" "archive-$platform"

shopt -s nullglob
artifacts=("$export_path"/*."$artifact_extension")
assert_equal "exported $artifact_extension count" "${#artifacts[@]}" "1" \
  "Export exactly one signed $artifact_extension into '$export_path'."
artifact="${artifacts[0]}"

expanded_root="$(mktemp -d "$RUNNER_TEMP/exported-app-$platform.XXXXXX")"
if [[ "$platform" == "ios" ]]; then
  run_checked "iOS package expansion" "Export a valid IPA package." \
    ditto -x -k "$artifact" "$expanded_root" >/dev/null
  exported_app="$expanded_root/Payload/$expected_product"
else
  package_signature="$(run_checked "macOS package signature" "Export a signed macOS pkg with a valid installer certificate." \
    pkgutil --check-signature "$artifact")"
  printf '%s\n' "$package_signature"
  assert_contains "macOS package installer authority" "$package_signature" \
    'Mac Installer Distribution:|3rd Party Mac Developer Installer:' \
    "Export the package with a valid Mac Installer Distribution certificate."
  run_checked "macOS package expansion" "Export a valid macOS pkg package." \
    pkgutil --expand-full "$artifact" "$expanded_root/package" >/dev/null
  exported_app=""
  exported_app_count=0
  while IFS= read -r candidate; do
    exported_app="$candidate"
    exported_app_count="$((exported_app_count + 1))"
  done < <(find "$expanded_root/package" -type d -name "$expected_product" -prune)
  assert_equal "signed macOS apps in package" "$exported_app_count" "1" \
    "Export exactly one signed app inside the macOS package."
fi

assert_directory "exported product" "$exported_app" \
  "Export a package that contains $expected_product."
validate_app_signing "$exported_app" "$bundle_identifier" "Exported app" "exported-$platform"

echo "path=$artifact" >> "$GITHUB_OUTPUT"
echo "Validated $platform $expected_version ($expected_build): $artifact"
