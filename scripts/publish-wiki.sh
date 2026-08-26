#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Wiki"
WIKI_REMOTE="${ENCRYPTED_MEMORIES_WIKI_REMOTE:-git@github.com:OnCloud-at/encrypted-memories.wiki.git}"
MODE="${1:-preview}"

if [[ "$MODE" != "preview" && "$MODE" != "--publish" ]]; then
  echo "Usage: $0 [--publish]" >&2
  exit 64
fi

if [[ ! -f "$SOURCE/Home.md" || ! -f "$SOURCE/_Sidebar.md" ]]; then
  echo "Wiki source is incomplete: Home.md and _Sidebar.md are required." >&2
  exit 66
fi

WIKI_CHECKOUT="$(mktemp -d "${TMPDIR:-/tmp}/encrypted-memories-wiki.XXXXXX")"
cleanup() {
  case "$WIKI_CHECKOUT" in
    */encrypted-memories-wiki.*) rm -rf -- "$WIKI_CHECKOUT" ;;
    *) echo "Refusing to remove unexpected temporary path: $WIKI_CHECKOUT" >&2 ;;
  esac
}
trap cleanup EXIT

if ! git clone --quiet "$WIKI_REMOTE" "$WIKI_CHECKOUT"; then
  echo "The built-in Wiki is not initialized or cannot be accessed." >&2
  echo "Create its first Home page at https://github.com/OnCloud-at/encrypted-memories/wiki, then retry." >&2
  exit 69
fi

while IFS= read -r tracked_page; do
  page_name="$(basename "$tracked_page")"
  if [[ ! -f "$SOURCE/$page_name" ]]; then
    rm -f -- "$WIKI_CHECKOUT/$tracked_page"
  fi
done < <(git -C "$WIKI_CHECKOUT" ls-files '*.md')

while IFS= read -r source_page; do
  cp -- "$source_page" "$WIKI_CHECKOUT/$(basename "$source_page")"
done < <(find "$SOURCE" -maxdepth 1 -type f -name '*.md' -print | sort)

git -C "$WIKI_CHECKOUT" add --all
git -C "$WIKI_CHECKOUT" diff --cached --check

if git -C "$WIKI_CHECKOUT" diff --cached --quiet; then
  echo "Wiki is already synchronized."
  exit 0
fi

git -C "$WIKI_CHECKOUT" status --short
if [[ "$MODE" != "--publish" ]]; then
  echo "Preview only. Run '$0 --publish' to commit and publish these Wiki changes."
  exit 0
fi

SOURCE_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD)"
git -C "$WIKI_CHECKOUT" commit --quiet -m "Sync Wiki from encrypted-memories $SOURCE_COMMIT"
git -C "$WIKI_CHECKOUT" push origin HEAD
echo "Published Wiki from encrypted-memories $SOURCE_COMMIT."
