#!/usr/bin/env bash
# run_swiftlint.sh <swiftlint> <config> <corpus dir> <output file>
set -uo pipefail
tool="$1"; config="$2"; corpus="$3"; out="$4"
: > "$out"
cd "$corpus" || exit 2
for f in $(ls *.swift | sort); do
  text="$("$tool" lint --strict --no-cache --config "$config" "$f" 2>&1)"
  code=$?
  printf '== %s exit %s\n' "$f" "$code" >> "$out"
  printf '%s\n' "$text" | sed -E "s#^.*/($f)#\1#" | grep -v "^Linting\|^Done linting\|^Loading configuration" | sort >> "$out"
done
wc -l "$out"
