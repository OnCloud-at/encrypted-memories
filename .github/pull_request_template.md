## Result

Describe the user-visible result and the reason for the change.

## Platforms

- [ ] macOS
- [ ] iOS
- [ ] iPadOS
- [ ] A platform is not supported for a stated technical reason.

## Verification

List the exact focused tests and final gates that you ran.

- [ ] I added or updated regression tests.
- [ ] I ran `./scripts/verify-tests.sh`.
- [ ] I ran `./scripts/verify-ios-app-tests.sh`.
- [ ] I ran the relevant platform or architecture gate.
- [ ] I documented every skipped or manual check.

## Contributor checklist

- [ ] Shared behavior is in `Packages/EncryptedMemoriesKit`.
- [ ] The change does not duplicate business logic between apps.
- [ ] The change preserves feature parity on supported platforms.
- [ ] The pull request contains no version, build-number, tag, or release-note change.
- [ ] The pull request contains no generated Xcode project or private data.
- [ ] The pull request contains no unrelated refactor or formatting change.
