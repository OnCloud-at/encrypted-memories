#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/build-paths.sh"

warn_gib="${ENCRYPTED_MEMORIES_BUILD_WARN_GIB:-100}"
total_kib=0

report_path() {
  local path="$1"
  local size_kib
  [[ -e "$path" ]] || return 0
  size_kib="$(du -sk "$path" 2>/dev/null | awk '{print $1}')"
  [[ -n "$size_kib" ]] || return 0
  total_kib=$((total_kib + size_kib))
  printf '%8.1f GiB  %s\n' "$(awk -v kib="$size_kib" 'BEGIN { print kib / 1048576 }')" "$path"
}

echo "Canonical Encrypted Memories build storage:"
report_path "$ENCRYPTED_MEMORIES_BUILD_ROOT"
report_path "$ROOT/Packages/EncryptedMemoriesKit/.build"
report_path "$ROOT/Vendor/sdk-swift/.build"

echo "Ad-hoc Proton build roots outside the canonical location:"
while IFS= read -r path; do
  report_path "$path"
done < <(find /private/tmp -xdev -mindepth 1 -maxdepth 1 -type d \
  \( -iname '*proton*spm*' -o -iname '*proton*derived*' -o -iname '*proton*dd.noindex' \
     -o -iname '*proton*tests*' -o -iname '*proton*gates*' \) -print 2>/dev/null | sort)

total_gib="$(awk -v kib="$total_kib" 'BEGIN { printf "%.1f", kib / 1048576 }')"
echo "Total reported build storage: $total_gib GiB"

if (( total_kib > warn_gib * 1048576 )); then
  echo "WARNING: Encrypted Memories build storage exceeds ${warn_gib} GiB." >&2
fi
