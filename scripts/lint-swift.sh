#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
# SwiftLint prints paths with every symbolic link resolved, so the root must be resolved, too.
ROOT="$(pwd -P)"
source "$ROOT/scripts/swift-file-selection.sh"
source "$ROOT/scripts/build-paths.sh"

# Decision reads (#1148): `.swiftlint-decision-reads.yml` finds reads that turn a failure into absence. Each line of
# the baseline allows `count` sites of `rule` in `file`, independent of line numbers.
decision_baseline=".swiftlint-decision-reads-baseline"
decision_rules="no_try_optional_in_store_lookup|no_try_optional_store_read_in_decision_code|no_default_for_store_read_in_decision_code"
decision_work="$(mktemp -d)"
trap 'rm -rf "$decision_work"' EXIT
# Prints the `count rule file` lines of a baseline read from stdin. Fails for a line that is not `count rule file`
# with a positive count and a path without spaces, and for a repeated rule and file. `$1` names the baseline.
baseline_entries() {
  awk -v name="$1" '
    /^#/ || /^[[:space:]]*$/ { next }
    $0 !~ /^[1-9][0-9]* [a-z_]+ [^[:space:]]+$/ {
      print name ": line " FNR " is not \"count rule file\": " $0 > "/dev/stderr"; bad = 1; next
    }
    seen[$2 " " $3]++ { print name ": line " FNR " repeats " $2 " " $3 > "/dev/stderr"; bad = 1; next }
    { print }
    END { exit bad }'
}
# Reads two files of `count key…` lines and prints `key<TAB>count<TAB>limit` for each key of the second file whose
# count is above its count in the first file (0 when the first file lacks the key).
counts_above() {
  awk 'FILENAME == ARGV[1] { count = $1; $1 = ""; limit[$0] = count; next }
    { count = $1; $1 = ""; allowed = ($0 in limit) ? limit[$0] : 0 }
    count > allowed { print substr($0, 2) "\t" count "\t" allowed }' "$1" "$2"
}
# Sums the counts of `count rule file` lines per rule.
rule_totals() {
  awk '{ total[$2] += $1 } END { for (rule in total) print total[rule], rule }' "$1"
}

baseline_entries "$decision_baseline" < "$ROOT/$decision_baseline" > "$decision_work/baseline" || exit 1
if [[ "${1:-}" == "--diff" && $# -eq 3 ]]; then
  # The head's own baseline must be well formed: in CI the working tree merges the head with its base branch.
  : > "$decision_work/head"
  if git cat-file -e "$3:$decision_baseline" 2>/dev/null; then
    git show "$3:$decision_baseline" | baseline_entries "$3:$decision_baseline" > "$decision_work/head" || exit 1
  fi
  # A change may move, split or rename baseline lines, but the total of a rule must not rise. Compare with the merge
  # base, as the changed files of `--diff` are: the base branch can have lowered the baseline after the change
  # branched. A merge base without a baseline is the change that adds it.
  merge_base="$(git merge-base "$2" "$3")"
  if git cat-file -e "$merge_base:$decision_baseline" 2>/dev/null; then
    git show "$merge_base:$decision_baseline" | baseline_entries "$merge_base:$decision_baseline" \
      > "$decision_work/merge-base" || exit 1
    rule_totals "$decision_work/merge-base" > "$decision_work/merge-base-totals"
    rule_totals "$decision_work/head" > "$decision_work/head-totals"
    grown="$(counts_above "$decision_work/merge-base-totals" "$decision_work/head-totals")"
    if [[ -n "$grown" ]]; then
      echo "The decision-read baseline grew; the total of a rule can only shrink:" >&2
      awk -F '\t' '{ print $1 ": " $2 " sites, " $3 " at the merge base" }' <<< "$grown" >&2
      exit 1
    fi
  fi
fi

select_swift_files lint-swift.sh "$@"

if [[ ${#source_files[@]} -eq 0 ]]; then
  echo "No changed Swift files require linting."
  exit 0
fi

swiftlint="${SWIFTLINT_EXECUTABLE:-}"
if [[ -z "$swiftlint" ]] && command -v swiftlint >/dev/null 2>&1; then
  swiftlint="$(command -v swiftlint)"
fi
if [[ -z "$swiftlint" ]]; then
  for candidate in \
    "$ENCRYPTED_MEMORIES_XCODE_SOURCE_PACKAGES/artifacts/swiftlintplugins/SwiftLintBinary/SwiftLintBinary.artifactbundle/macos/swiftlint" \
    "$ENCRYPTED_MEMORIES_BUILD_ROOT/SourcePackages/artifacts/swiftlintplugins/SwiftLintBinary/SwiftLintBinary.artifactbundle/macos/swiftlint"; do
    if [[ -x "$candidate" ]]; then
      swiftlint="$candidate"
      break
    fi
  done
fi
[[ -x "$swiftlint" ]] || {
  echo "SwiftLint 0.65.1 is required. Set SWIFTLINT_EXECUTABLE to its executable path." >&2
  exit 69
}

actual_swiftlint_version="$($swiftlint version)"
[[ "$actual_swiftlint_version" == "0.65.1" ]] || {
  echo "SwiftLint 0.65.1 is required; found $actual_swiftlint_version." >&2
  exit 69
}

status=0
output="$("$swiftlint" lint --strict --config "$ROOT/.swiftlint.yml" "${source_files[@]}" 2>&1)" || status=$?
printf '%s\n' "$output"
[[ $status -eq 0 ]] || exit "$status"
# A `swiftlint:disable` comment would turn off a decision-read rule for its file or line.
disabled="$(grep -lE "swiftlint:disable[^[:cntrl:]]* ($decision_rules|custom_rules|all)([[:space:]]|$)" \
  "${source_files[@]}" || true)"
if [[ -n "$disabled" ]]; then
  echo "A swiftlint:disable comment turns off a decision-read rule; remove it:" >&2
  printf '%s\n' "$disabled" >&2
  exit 1
fi
decision_status=0
decision_output="$("$swiftlint" lint --strict --config "$ROOT/.swiftlint-decision-reads.yml" "${source_files[@]}" 2>&1)" ||
  decision_status=$?
# Without SourceKit, or when SourceKit fails, SwiftLint skips the comment rules and still succeeds. That would be a
# check that does not run.
if grep -qE "Skipping enabled rule|SourceKit-based rules will be skipped" <<< "$output"$'\n'"$decision_output"; then
  echo "A SwiftLint rule was skipped, so the style check is incomplete." >&2
  exit 1
fi
# One line per site: rule and file, relative to the repository.
root_pattern="$(sed 's/[][\.*^$#+?(){}|]/\\&/g' <<< "$ROOT/")"
decision_sites="$(sed -nE "s#^(${root_pattern})?([^:]+):[0-9]+:[0-9]+: error: .*\(([a-z_]+)\)\$#\3 \2#p" <<< "$decision_output")"
if [[ $decision_status -ne 0 && -z "$decision_sites" ]]; then
  printf '%s\n' "$decision_output"
  exit "$decision_status"
fi
sort <<< "$decision_sites" | uniq -c | awk 'NF == 3 { print $1, $2, $3 }' > "$decision_work/found"
over="$(counts_above "$decision_work/baseline" "$decision_work/found")"
if [[ -n "$over" ]]; then
  echo "Decision reads must not turn a failed read into absence (.swiftlint-decision-reads.yml):" >&2
  awk -F '\t' '{ print $1 ": " $2 " found, " $3 " allowed" }' <<< "$over" >&2
  grep -E ": error: " <<< "$decision_output" >&2
  exit 1
fi
# A linted file with fewer sites than its baseline line leaves room for a new site: name it, so the line gets lowered.
printf '%s\n' "${source_files[@]}" | sed -E "s#^${root_pattern}##" > "$decision_work/linted"
awk 'FILENAME == ARGV[1] { linted[$0] = 1; next } $3 in linted' "$decision_work/linted" "$decision_work/baseline" \
  > "$decision_work/linted-baseline"
counts_above "$decision_work/found" "$decision_work/linted-baseline" |
  awk -F '\t' '{ print "Notice: lower the decision-read baseline: " $1 ": " $3 " found, " $2 " allowed" }'
