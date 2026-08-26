# ML model releases

The app accepts new artifact revisions only through its signed remote catalog. Each release must
use a compatibility recipe that ships with the app. Keep the model ID stable for a weight update,
and increment `descriptorVersion` by one. A new tokenizer, preprocessing pipeline, runtime shape,
capability, or compatibility recipe requires an app update.

## Candidate archive

A GitHub release with an `ml-model-*` tag must include `ml-release-candidate.tar.gz`:

```text
source-repository-revision.txt
models/<model-id>/release-manifest.json
models/<model-id>/artifact-manifest.json
models/<model-id>/<one .mlmodelc or .mlpackage tree>
models/<model-id>/<declared runtime resources>
evidence/<model-id>.json
qualification/<model-id>.json
notices/<model-id>.txt
retired-models.json (optional)
```

Use the schemas in this directory for the release manifest, release approval, and qualification
report. The artifact manifest must list every runtime file with its exact byte count and SHA-256.
The notice hash in the release approval must match the corresponding notice file.

The release workflow rejects links, hidden files, archive traversal, undeclared sidecars, mutable
source revisions, incomplete rights, failed device gates, and contracts that the app does not know.
It merges the candidate with the current signed catalogs and publishes a new monotonic sequence.

Apps refresh the signed catalog after launch, on foreground entry, and every 15 minutes while
Smart Search is active. They adopt a compatible revision for the selected model ID without an app
update. A new descriptor version causes a clean semantic reindex. Existing verified model bytes
remain active until the replacement passes download, verification, and runtime loading.

## Local preparation

The production workflow supplies the previous signed active pair and the next sequence. A local
dry run for the first catalog uses this form:

```bash
xcrun swift scripts/prepare-ml-model-release.swift \
  --private-key /secure/catalog-ed25519.key \
  --output /safe/release-output \
  --bucket encrypted-memories-models \
  --base-url https://models.oncloud.at/models/ \
  --candidate-root /qualified-candidate \
  --evidence-dir /qualified-candidate/evidence \
  --qualification-dir /qualified-candidate/qualification \
  --notices-dir /qualified-candidate/notices \
  --repository-revision 0123456789012345678901234567890123456789 \
  --released-at 2026-08-25T20:00:00Z \
  --catalog-sequence 1 \
  --model siglip2-base-patch16-256=/qualified-candidate/models/siglip2-base-patch16-256
```

The command creates signed V1 and V2 catalogs, a paired history manifest, provenance, an SPDX
SBOM, model license text, and an idempotent R2 publication script. It does not change remote state.

## Activation contract

Catalog files and release manifests use immutable paths under
`catalog-history/<pair-sha256>/`. Model artifacts use immutable paths under
`models/<model-id>/<revision>/`.

`active-pair.json` is the only mutable activation object. The publisher uploads every immutable
object with conditional PutObject and `If-None-Match: *`. A retry accepts an existing object only
after it matches the expected byte count and SHA-256. The publisher then performs one PUT for
`active-pair.json`. The pointer uses `Cache-Control: no-cache, max-age=0, must-revalidate`.
Immutable objects use a one-year immutable cache policy.

The pointer contains one signed payload. The payload names the pair, catalog sequence, exact
content-addressed paths, byte counts, and SHA-256 values. Clients verify the pointer signature,
HTTPS host, path, size, hash, catalog signatures, and monotonic sequence before use. A failed
download keeps the last verified pair. Pair files use a pair-specific cache directory, and the
local pointer changes last.

The publisher uses the macOS runner's Python 3 standard library for signed R2 requests. It does
not use the preinstalled AWS CLI or rclone for immutable writes. Required variables are
`R2_ENDPOINT`, `R2_ACCESS_KEY_ID`, and `R2_SECRET_ACCESS_KEY`.

Legacy V1 clients continue to refresh from the signed root `catalog-v1.json` and `catalog-v1.sig`
mirror. The publisher verifies the V1 signature mirror before the V1 catalog mirror, then refreshes
the equivalent no-cache V2 mirrors, and activates `active-pair.json` last. Updated clients use the
atomic pointer; V1 clients continue to adopt compatible model updates without an app update.

## Retirement and restore

`retired-models.json` is optional. It contains `schemaVersion: 1` and a non-empty, unique
`modelIDs` array. Each ID must exist as an active V2 model in the previous signed pair. A retirement
removes the ID from V1 and keeps its immutable artifacts in V2 with `availability: "retired"` and
the next `releaseSequence`. Retired rows remain fully validated but are not selectable.

A retirement-only candidate can omit model directories. A later qualified candidate for the same ID
restores it as active with the next release sequence and the same compatibility recipe.

## Local preview channel

Preview composition is available only in Debug builds. In Xcode, use the `EncryptedMemories`
scheme for macOS or the `EncryptedMemoriesMobile` scheme for iOS and iPadOS. In the scheme's Run
environment, add `ENCRYPTED_MEMORIES_ML_PREVIEW_BASE_URL` with the configured HTTPS preview
directory ending in `/models/`. Leave the variable unset for production composition.

The preview channel uses separate catalog and Smart Search storage. The preview URL separates app
distribution, but it does not authenticate download readers. Reader authentication requires a
separate server-side access control and credential flow.

## Protected preview environment

Configure the protected GitHub Environment `ml-model-preview` with these values:

- Variables: `ML_MODEL_PREVIEW_BASE_URL`, `ML_MODEL_PREVIEW_R2_BUCKET`.
- Secrets: `ML_MODEL_PREVIEW_R2_ENDPOINT`, `ML_MODEL_PREVIEW_R2_ACCESS_KEY_ID`,
  `ML_MODEL_PREVIEW_R2_SECRET_ACCESS_KEY`.
- Existing catalog signing secret: `ML_CATALOG_ED25519_PRIVATE_KEY_BASE64`.

Do not add real values to this repository.
