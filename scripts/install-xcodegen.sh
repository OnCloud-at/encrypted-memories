#!/usr/bin/env bash
set -euo pipefail

XCODEGEN_VERSION="2.46.0"
XCODEGEN_SHA256="ef6d0a23bfb7393387f98e321ffd78a487231172e2e78c48d3c26275c263fd0c"

install_root="${1:-}"
[[ -n "$install_root" ]] || {
  echo "usage: scripts/install-xcodegen.sh INSTALL_ROOT" >&2
  exit 64
}

executable="$install_root/xcodegen.artifactbundle/xcodegen-$XCODEGEN_VERSION-macosx/bin/xcodegen"
if [[ ! -x "$executable" ]]; then
  archive="$install_root/xcodegen.artifactbundle.zip"
  mkdir -p "$install_root"
  curl --fail --location --silent --show-error \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.artifactbundle.zip" \
    --output "$archive"
  echo "$XCODEGEN_SHA256  $archive" | shasum --algorithm 256 --check >&2
  ditto -x -k "$archive" "$install_root"
fi

[[ -x "$executable" ]] || {
  echo "The XcodeGen $XCODEGEN_VERSION executable is missing." >&2
  exit 69
}
[[ "$("$executable" --version)" == "Version: $XCODEGEN_VERSION" ]] || {
  echo "The installed XcodeGen version is not $XCODEGEN_VERSION." >&2
  exit 69
}

printf '%s\n' "$executable"
