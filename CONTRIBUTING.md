# Contributing to Encrypted Memories

Thank you for helping improve Encrypted Memories. Keep each pull request focused, testable, and safe for all supported Apple platforms.

## Before you start

- Search existing issues and pull requests.
- Open an issue before a large feature or architecture change.
- Never include credentials, private user data, signing files, or local build output.
- PR authors never set app versions, build numbers, release tags, or release notes. Maintainers own releases.

## Architecture rules

- Put shared behavior in `Packages/EncryptedMemoriesKit`.
- Keep platform targets limited to native UI and unavoidable platform adapters.
- Implement each supported feature for macOS, iOS, and iPadOS.
- State an actual platform limitation in the pull request when parity is impossible.
- Do not duplicate business logic across platform targets.
- Prefer a smaller implementation when it preserves behavior and makes regressions less likely.
- Add or update tests for every changed contract and regression.
- Test behavior through the code under test. Do not add tests that search source files for code text; they break on renames and stay green when the behavior breaks. Module import rules in `CoreArchitectureGateTests` and build-configuration checks in `ProjectHygieneTests` are the exceptions.
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

## Own your pull request

You own your pull request until a maintainer merges or closes it. A review can take time, and a fix that is not urgent can wait for a later release.

- Keep your branch current with `main` while the pull request waits.
- Rebase onto `main` when `main` moves on, and resolve every conflict yourself.
- Run the local gates again after a rebase, then push the updated branch.
- Answer review comments and push the requested changes.

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

## Automated PR review

The LLM review is advisory. You can merge if it fails, times out, or reports a serious finding,
provided the required checks and repository rules allow the merge.
Never make `Review changed code` a required check or make this workflow a required workflow.
The automation only updates a conversation comment. It never submits an approval or requests changes.
Code links point to the reviewed commit; they do not create unresolved review threads that can block merging.

- Green: no actionable findings in the reviewed changes.
- Yellow: actionable notices without a serious finding.
- Red: serious findings survived evidence verification; this remains advice.
- Grey: review unavailable or incomplete. Unreviewed patch lines, files without a textual patch, model-reported testing gaps, or evidence verification gaps remain. Partial findings also carry a coverage note.

The comment shows at most three findings. Expand the details for evidence and coverage limitations.

The review sends the cumulative pull request diff in bounded batches.
Each request, validation retry, and evidence verification stays at or below 100,000 UTF-8 bytes.
With 8,000 reserved output tokens, this stays below the 131,072-token window measured for Lumo Lite and Max.
A file stays whole when it fits into one request.
A larger file is split at hunk boundaries. A larger hunk is split at line boundaries with an exact `(continued)` hunk header.
Each batch also receives a list of all changed files and short summaries of earlier batches as cross-file context.
If the provider still rejects a batch as too large, the review splits that batch at most twice.
The comment counts text coverage per GitHub patch line, including files beyond the file limit.
For each file, it names the failed, rejected, timed-out, or unstarted batch that left lines unreviewed. It lists up to 40 of these gaps.
Files without a textual patch, such as images, appear in a separate list. The automation does not inspect image or binary content.
Model-reported testing gaps and evidence verification gaps appear in two more lists.
The workflow runs the reviewer from the default branch. A reviewer change takes effect only after it is merged.
A second model pass challenges candidate findings using the patch and redacted source windows
from the exact head and base commits. It checks the trigger, impact, counterevidence, and source quotation.
Missing tests, style preferences, and speculative risks do not justify a serious finding.
Model agreement and a matching quotation cannot prove correctness; human judgment remains necessary.

The review logs activity once per minute without logging response or reasoning text.
Reasoning and answer events count as model output. Transport heartbeats only show connection activity.
Without provider output, the client cannot distinguish silent computation from a stalled model.
It waits ten minutes by default before returning an unavailable review.
Set repository variable `LLM_REVIEW_IDLE_SECONDS` between `120` and `1800` to change this waiting limit.
All model passes and retries share a thirty-minute analysis budget.
The workflow reserves additional time for source reads and comment publication.
The issue-triage workflow keeps its existing shorter timeout policy.

Review coverage is bounded: 80 files, 8 review batches, and 12 review requests, including context splits.
A patch line longer than 24,000 characters is truncated and counts as a coverage gap.
Source reads accept text files up to 200,000 bytes and select windows around candidate lines.
Large inputs can reduce these windows. Omitted patches, unavailable source, and specific missing context produce coverage limitations.
Dismissed suspicions, low-confidence candidates, existing issues, and optional test improvements do not count as coverage gaps.
The model reports optional test improvements as review notes, so they do not change the review status.
Invalid evidence triggers regeneration. Repeated validation failure leaves the lines of that batch as a text coverage gap.
Logs report decision counts without candidate text. An uncertain decision must identify its missing context.
The reviewer does not execute PR code or search the entire repository for callers and tests.
The trusted default-branch script reads PR source as data, including for fork PRs.
Stale runs cannot replace comments for a newer PR snapshot.

Run `python3 .github/scripts/test_review_advisory.py` for evidence-policy and HTTP-stream tests.
Also run the existing review and issue-triage tests when changing their shared client.
Before claiming improved model accuracy, replay maintainer-adjudicated true findings and false positives
through the configured provider. Deterministic tests alone do not establish model accuracy.

References: [GitHub required checks](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches),
[CodeRabbit context verification](https://www.coderabbit.ai/blog/context-engineering-ai-code-reviews).

## Release ownership

A pull request must not set an app version, build number, release tag, or release notes.
After tested changes reach `main`, a maintainer publishes a GitHub Release.

- `v1.2.0-beta.1` and `v1.2.0-rc.1` publish only to internal TestFlight.
- `v1.2.0` submits iOS and macOS to App Review and selects automatic release after approval.

Automation derives one shared Apple build number from the immutable GitHub Release ID and validates it with App Store Connect before starting Xcode. Separate prerelease and stable releases get new builds even on the same source commit. Keep beta tags and their notes unchanged as release history; publish a new stable release instead of renaming a beta. Retrying the same release reuses its build number. Releases through `v1.0.2-beta.3` retain their previously uploaded, commit-derived numbers.

Write owner-written notes under `## English`. This is the only required release-notes section.
Keep notes short and understandable to app users. For a maintenance release, `Bug fixes and performance improvements.` is enough; technical details belong in the pull request.
Without platform subsections, English applies to both platforms.
Optional `### All Platforms`, `### iOS and iPadOS`, and `### macOS` subsections let each platform receive shared text plus its specific text.

`## Deutsch` is optional and uses the same structure. English is used for `de-DE` when German is absent.

Automation sends only extracted owner text to Apple. It never sends contributor names, pull request lists, or generated changelog text.
Contributors have no release-note work.

Before stable replacement, automation waits for both new builds.
It validates both platform plans before it changes either review submission.
It removes lower active review versions independently per platform only in Apple-removable states.
It waits for `DEVELOPER_REJECTED`, updates the same version record, and starts a new review submission.
It does not delete that record or create a fallback for that platform when Apple rejects the update.
It refuses equal or newer active versions or unsafe states.

The manual `External TestFlight` workflow runs from `main` with one published release tag.
It reuses existing builds and never rebuilds or uploads.
It uses the `testflight-external` environment.
`TESTFLIGHT_EXTERNAL_GROUP_NAME` optionally overrides `External Testers`.
Stable and prerelease release tags can be promoted externally.
