#!/usr/bin/env bash
# run_all.sh <swift-format executable> <swiftlint executable> <output directory>
# Records the verdicts of both tools on the broken corpora and on the whole repository (without the corpora).
set -uo pipefail
swift_format="$1"; swiftlint="$2"; out="$3"
root="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$out"
here="$root/.github/lint-differential"

bash "$here/run_lint.sh" "$swift_format" "$root/.swift-format" "$here/swift-format-corpus" "$out/corpus-swift-format.txt"
bash "$here/run_swiftlint.sh" "$swiftlint" "$root/.swiftlint.yml" "$here/swiftlint-corpus" "$out/corpus-swiftlint.txt"

cd "$root"
files=()
while IFS= read -r file; do
  case "$file" in
    Vendor/*|EncryptedMemories.xcodeproj/*|.github/lint-differential/*) continue ;;
  esac
  [[ -f "$file" ]] && files+=("$file")
done < <(git ls-files --cached -- '*.swift')
echo "repository files: ${#files[@]}" > "$out/repository-count.txt"

text="$("$swift_format" lint --strict --parallel --configuration "$root/.swift-format" "${files[@]}" 2>&1)"
echo "exit $?" > "$out/repository-swift-format.txt"
printf '%s\n' "$text" | sort >> "$out/repository-swift-format.txt"

text="$("$swiftlint" lint --strict --no-cache --config "$root/.swiftlint.yml" "${files[@]}" 2>&1)"
echo "exit $?" > "$out/repository-swiftlint.txt"
printf '%s\n' "$text" | grep -v "^Linting\|^Done linting\|^Loading configuration" | sed -E "s#^$root/##" | sort >> "$out/repository-swiftlint.txt"
wc -l "$out"/*.txt
