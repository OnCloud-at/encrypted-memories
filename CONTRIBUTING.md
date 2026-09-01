# Contributing to Encrypted Memories

Thank you for helping improve Encrypted Memories. Keep each pull request focused, testable, and safe for all supported Apple platforms.

## Before you start

- Search existing issues and pull requests.
- Open an issue before a large feature or architecture change.
- Never include credentials, private user data, signing files, or local build output.
- Do not change app versions, build numbers, tags, or release notes. Maintainers own releases.

## Architecture rules

- Put shared behavior in `Packages/EncryptedMemoriesKit`.
- Keep platform targets limited to native UI and unavoidable platform adapters.
- Implement each supported feature for macOS, iOS, and iPadOS.
- State an actual platform limitation in the pull request when parity is impossible.
- Do not duplicate business logic across platform targets.
- Prefer a smaller implementation when it preserves behavior and makes regressions less likely.
- Add or update tests for every changed contract and regression.
- Treat `project.yml` as the project source. Do not commit the generated Xcode project.
- Update the pinned SDK patch set when a Proton SDK change modifies vendored code.

The package uses feature modules and shared cores. A feature module owns reusable state, policy, and behavior. The macOS and mobile apps own native presentation and system integration.

## Pull request scope

- Use one pull request for one coherent change.
- Explain the user-visible result and the supported platforms.
- List the tests that you ran.
- Identify any manual check that remains.
- Keep unrelated formatting and refactors out of the pull request.
- Do not weaken a test to hide an application defect.

GitHub runs repository hygiene, Swift style, package tests, iOS app tests, and both platform builds. A maintainer reviews the result before merge.

## Local verification

Run focused tests while you work. Run these gates before requesting review:

```bash
./scripts/verify-tests.sh
./scripts/verify-ios-app-tests.sh
./scripts/verify-universal-core.sh fast
```

Run the platform shell build when your change affects that app:

```bash
./scripts/verify-macos-app-shell.sh
./scripts/verify-ios-app-shell.sh
```

Use the shared build root documented in the README. Do not create build caches in the repository or `/private/tmp`.

## Release ownership

A pull request must not set a version or build number. After tested changes reach `main`, a maintainer publishes a GitHub Release.

- `v1.2.0-beta.1` and `v1.2.0-rc.1` publish only to internal TestFlight.
- `v1.2.0` submits iOS and macOS to App Review and selects automatic release after approval.

The release body must contain owner-written `## Deutsch` and `## English` sections. Automation sends only those sections to Apple. It never sends contributor lists or generated pull request text.
