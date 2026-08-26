#!/usr/bin/env bash
set -euo pipefail

RCLONE_VERSION="1.75.0"
RCLONE_AMD64_SHA256="19edbb8e5e73096eb66e92a42abbc5c34bfa8981ea3986a53872c7eef85a22f4"
RCLONE_ARM64_SHA256="35e8f2a666ce789b29111db0dd843ddabc0d59c6b609d07bcaae5d1a07cba6f8"

install_root="${1:-}"
[[ -n "$install_root" ]] || {
  echo "usage: scripts/install-rclone.sh INSTALL_ROOT" >&2
  exit 64
}

case "$(uname -m)" in
  arm64)
    archive_arch="arm64"
    expected_sha256="$RCLONE_ARM64_SHA256"
    ;;
  x86_64)
    archive_arch="amd64"
    expected_sha256="$RCLONE_AMD64_SHA256"
    ;;
  *)
    echo "Unsupported macOS architecture: $(uname -m)" >&2
    exit 69
    ;;
esac

archive_name="rclone-v$RCLONE_VERSION-osx-$archive_arch.zip"
archive="$install_root/$archive_name"
executable="$install_root/rclone-v$RCLONE_VERSION-osx-$archive_arch/rclone"

if [[ ! -x "$executable" ]]; then
  mkdir -p "$install_root"
  curl --fail --location --silent --show-error \
    "https://downloads.rclone.org/v$RCLONE_VERSION/$archive_name" \
    --output "$archive"
  echo "$expected_sha256  $archive" | shasum --algorithm 256 --check >&2
  ditto -x -k "$archive" "$install_root"
fi

[[ -x "$executable" ]] || {
  echo "The rclone $RCLONE_VERSION executable is missing." >&2
  exit 69
}
"$executable" version | head -n 1 | grep -Fx "rclone v$RCLONE_VERSION" >/dev/null || {
  echo "The installed rclone version is not $RCLONE_VERSION." >&2
  exit 69
}

printf '%s\n' "$executable"
