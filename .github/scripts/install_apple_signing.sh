#!/usr/bin/env bash
set -euo pipefail

required() {
  local name="$1"
  [[ -n "${!name:-}" ]] || {
    echo "Missing $name" >&2
    exit 64
  }
}

required APP_STORE_CONNECT_KEY_ID
required APP_STORE_CONNECT_PRIVATE_KEY_BASE64
required APPLE_SIGNING_CERTIFICATES_P12_BASE64
required APPLE_SIGNING_CERTIFICATES_PASSWORD
required GITHUB_ENV
required RUNNER_TEMP

keychain="$RUNNER_TEMP/encrypted-memories-signing.keychain-db"
keychain_password="$(openssl rand -hex 24)"
certificate="$RUNNER_TEMP/apple-signing-certificates.p12"
private_key_directory="$RUNNER_TEMP/app-store-connect-private-keys"
private_key="$private_key_directory/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"

{
  echo "APP_STORE_CONNECT_KEY_PATH=$private_key"
  echo "APPLE_SIGNING_CERTIFICATE_PATH=$certificate"
  echo "APPLE_SIGNING_KEYCHAIN=$keychain"
} >> "$GITHUB_ENV"

ruby -rbase64 -e \
  'File.binwrite(ARGV.fetch(0), Base64.strict_decode64(ENV.fetch("APPLE_SIGNING_CERTIFICATES_P12_BASE64")))' \
  "$certificate"
mkdir -p "$private_key_directory"
ruby -rbase64 -e \
  'File.binwrite(ARGV.fetch(0), Base64.strict_decode64(ENV.fetch("APP_STORE_CONNECT_PRIVATE_KEY_BASE64")))' \
  "$private_key"
chmod 600 "$certificate" "$private_key"

openssl pkey -in "$private_key" -noout
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21_600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$certificate" \
  -k "$keychain" \
  -P "$APPLE_SIGNING_CERTIFICATES_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  -T /usr/bin/productbuild
security set-key-partition-list \
  -S apple-tool:,apple: \
  -s \
  -k "$keychain_password" \
  "$keychain" >/dev/null
security list-keychains -d user -s "$keychain"
security default-keychain -d user -s "$keychain"

if ! security find-identity -v -p codesigning "$keychain" | grep -q '"Apple Distribution:'; then
  echo "The signing archive does not contain an Apple Distribution identity." >&2
  exit 65
fi
if ! security find-identity -v "$keychain" | grep -Eq '"(Mac Installer Distribution|3rd Party Mac Developer Installer):'; then
  echo "The signing archive does not contain a Mac Installer Distribution identity." >&2
  exit 65
fi

echo "Installed the App Store Connect key and Apple distribution identities in an ephemeral keychain."
