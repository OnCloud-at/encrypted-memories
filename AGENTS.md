# Instructions for coding agents

These rules apply to every coding agent in this repository, for example Codex, Claude Code, Cursor, GitHub Copilot, Gemini, and OpenCode. `CONTRIBUTING.md` is the source of truth for architecture, tests, and pull requests. Read it completely before you change anything. When the two files disagree, `CONTRIBUTING.md` applies.

Claude Code loads it through this import:

@CONTRIBUTING.md

## Before you change code

- Work on one open issue. Open one first when the work has none.
- Read the code that you change, its callers, and its tests. Follow the existing names and structure.
- Check platform and SDK APIs against current Apple documentation and the versions pinned in this repository. Never invent an API.

## Code

The architecture rules in `CONTRIBUTING.md` are binding. In short:

- Features and core logic belong in `Packages/EncryptedMemoriesKit`. The macOS and iOS apps contain only native presentation and platform adapters.
- Every feature works on macOS, iOS, and iPadOS with native controls.
- No duplicated code. Reuse or extract a shared type before you copy logic.
- Delete code when a simpler version keeps the behavior; the tests prove that nothing changed.
- No regressions. Keep existing behavior unless the issue asks to change it.
- Keep the change minimal: no unrelated refactors, renames, or formatting.

## Tests

Follow the Tests section of `CONTRIBUTING.md`: every new feature and every bug fix comes with tests. Run the local gates before you open or update a pull request, and report the exact commands and every check that you skipped.

## Never

- Never commit credentials, keys, tokens, signing files, or personal data such as names, host names, local paths, and device identifiers.
- Never set app versions, build numbers, release tags, or release notes.
- Never commit the generated Xcode project.
- Never push to `main` or merge a pull request. Maintainers merge.

## Pull requests

- Describe the result for users, the platforms, the tests that you ran, and the checks that remain manual.
- An automated review comments on every pull request. It is advisory; a maintainer reviews every pull request before it merges.
