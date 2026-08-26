#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${APPLE_SIGNING_KEYCHAIN:-}" && -f "$APPLE_SIGNING_KEYCHAIN" ]]; then
  security delete-keychain "$APPLE_SIGNING_KEYCHAIN"
fi

if [[ -n "${APP_STORE_CONNECT_KEY_PATH:-}" ]]; then
  rm -f -- "$APP_STORE_CONNECT_KEY_PATH"
fi

if [[ -n "${APPLE_SIGNING_CERTIFICATE_PATH:-}" ]]; then
  rm -f -- "$APPLE_SIGNING_CERTIFICATE_PATH"
fi

if [[ -n "${RUNNER_TEMP:-}" ]]; then
  rm -f -- "$RUNNER_TEMP/apple-signing-certificates.p12"
  rm -rf -- "$RUNNER_TEMP/app-store-connect-private-keys"
  if [[ -f "$RUNNER_TEMP/encrypted-memories-signing.keychain-db" ]]; then
    security delete-keychain "$RUNNER_TEMP/encrypted-memories-signing.keychain-db"
  fi
fi
