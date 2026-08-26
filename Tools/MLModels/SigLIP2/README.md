# SigLIP2 Core ML conversion

This tool converts the pinned Apache-2.0
`google/siglip2-base-patch16-256` revision into the Core ML artifact consumed by
Encrypted Memories Smart Search. Generated weights and test photos must stay outside
the source tree.

```bash
cd Tools/MLModels/SigLIP2
python3 -m venv .venv
.venv/bin/pip install -r requirements.lock
.venv/bin/python convert_siglip2.py /absolute/path/to/output
```

The command writes conversion intermediates under `work/` and the only
installable payload under `distribution/`:

- `SigLIP2.mlmodelc`
- `tokenizer.json`
- `artifact-manifest.json`
- `release-manifest.json`

Add the release approval, qualification report, and Apache-2.0 notice outside the model directory.
Use the candidate layout in `Tools/MLModels/README.md`. The release workflow computes the artifact
revision, verifies every file, and publishes it under an immutable R2 path.
