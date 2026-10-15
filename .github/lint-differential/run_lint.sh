#!/usr/bin/env bash
# run_lint.sh <swift-format executable> <config> <corpus dir> <output file>
# One result line per file: file name, exit code, then every diagnostic as "line:column: rule/message" (paths removed).
set -uo pipefail
tool="$1"; config="$2"; corpus="$3"; out="$4"
: > "$out"
cd "$corpus" || exit 2
for f in $(ls *.swift | sort); do
  text="$("$tool" lint --strict --configuration "$config" "$f" 2>&1)"
  code=$?
  printf '== %s exit %s\n' "$f" "$code" >> "$out"
  printf '%s\n' "$text" | sed -E "s#^.*/##; s#^$f:#$f:#" | sort >> "$out"
done
wc -l "$out"
