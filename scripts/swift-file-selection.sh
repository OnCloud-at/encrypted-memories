#!/usr/bin/env bash

# Fills `source_files` from `--all`, `--diff BASE HEAD` or a list of files. Vendored code and the generated Xcode
# project stay out. The first argument names the calling script for the usage message.
select_swift_files() {
  local script="$1"
  shift
  local -a files=()
  source_files=()
  case "${1:-}" in
    --all)
      shift
      while IFS= read -r file; do files+=("$file"); done < <(
        git ls-files --cached --others --exclude-standard -- '*.swift'
      )
      ;;
    --diff)
      [[ $# -eq 3 ]] || { echo "usage: scripts/$script --all | --diff BASE HEAD | FILE..." >&2; exit 64; }
      local base="$2"
      local head="$3"
      shift 3
      while IFS= read -r file; do files+=("$file"); done < <(
        git diff --diff-filter=ACMR --name-only "$base...$head" -- '*.swift'
      )
      ;;
    "")
      echo "usage: scripts/$script --all | --diff BASE HEAD | FILE..." >&2
      exit 64
      ;;
    *)
      files=("$@")
      ;;
  esac

  if (( ${#files[@]} > 0 )); then
    for file in "${files[@]}"; do
      case "$file" in
        Vendor/*|EncryptedMemories.xcodeproj/*) continue ;;
      esac
      [[ -f "$file" ]] && source_files+=("$file")
    done
  fi
  return 0
}
