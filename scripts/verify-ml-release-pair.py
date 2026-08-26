#!/usr/bin/env python3

from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit

EXPECTED_FILES = {
    "catalog-v1.json",
    "catalog-v1.sig",
    "catalog-v2.json",
    "catalog-v2.sig",
}
POINTER_OBJECT_NAMES = EXPECTED_FILES | {"release-pair.json"}
SHA256 = re.compile(r"^[0-9a-f]{64}$")
MODEL_ID = re.compile(r"^(?:[a-z0-9]|[a-z0-9](?:[a-z0-9]|-(?!-)){0,126}[a-z0-9])$")
MODEL_REVISION = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
MAX_ARTIFACT_BYTES = 1_073_741_824


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_artifact_list(catalog_path: Path, base_url: str) -> list[str]:
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    if not isinstance(catalog, dict) or catalog.get("schemaVersion") != 2:
        raise ValueError("artifact catalog schema is invalid")
    parsed_base = urlsplit(base_url)
    if (
        parsed_base.scheme != "https"
        or not parsed_base.hostname
        or parsed_base.username
        or parsed_base.password
        or parsed_base.query
        or parsed_base.fragment
        or not parsed_base.path.endswith("/")
    ):
        raise ValueError("artifact base URL must be a public HTTPS directory")
    models = catalog.get("models")
    if not isinstance(models, list):
        raise ValueError("artifact catalog models are invalid")

    rows: list[str] = []
    seen: set[str] = set()
    for model in models:
        if not isinstance(model, dict):
            raise ValueError("artifact catalog model is invalid")
        availability = model.get("availability", "active")
        if not isinstance(availability, str) or availability not in {"active", "retired"}:
            raise ValueError("artifact catalog model availability is invalid")
        model_id = model.get("id")
        revision = model.get("revision")
        if (
            not isinstance(model_id, str)
            or MODEL_ID.fullmatch(model_id) is None
            or not isinstance(revision, str)
            or MODEL_REVISION.fullmatch(revision) is None
        ):
            raise ValueError("artifact catalog model metadata is invalid")
        if availability == "retired":
            continue
        artifacts = model.get("artifacts")
        if not isinstance(artifacts, list) or not artifacts:
            raise ValueError("artifact catalog model metadata is invalid")
        for artifact in artifacts:
            if not isinstance(artifact, dict):
                raise ValueError("artifact catalog entry is invalid")
            path = artifact.get("path")
            digest = artifact.get("sha256")
            byte_count = artifact.get("bytes")
            url = artifact.get("url")
            if (
                not isinstance(path, str)
                or path.startswith("/")
                or "\\" in path
                or any(part in {"", ".", ".."} for part in path.split("/"))
                or not isinstance(digest, str)
                or SHA256.fullmatch(digest) is None
                or not isinstance(byte_count, int)
                or isinstance(byte_count, bool)
                or not 0 < byte_count <= MAX_ARTIFACT_BYTES
                or not isinstance(url, str)
            ):
                raise ValueError("artifact catalog contains invalid artifact metadata")
            artifact_url = urlsplit(url)
            expected_path = f"{parsed_base.path.rstrip('/')}/{model_id}/{revision}/{path}"
            if (
                artifact_url.scheme != "https"
                or artifact_url.netloc != parsed_base.netloc
                or artifact_url.username
                or artifact_url.password
                or artifact_url.query
                or artifact_url.fragment
                or unquote(artifact_url.path) != expected_path
            ):
                raise ValueError("artifact catalog contains an untrusted artifact URL")
            key = expected_path.removeprefix("/")
            if key in seen:
                raise ValueError("artifact catalog contains a duplicate artifact")
            seen.add(key)
            rows.append(f"{key}\t{digest}\t{byte_count}")
    if not rows:
        raise ValueError("artifact catalog contains no model artifacts")
    return rows


def verify_pointer(pointer_path: Path, expected_pair: str | None = None) -> tuple[str, int]:
    pointer = json.loads(pointer_path.read_text(encoding="utf-8"))
    if set(pointer) != {"payload", "signature"}:
        raise ValueError("active pointer fields are invalid")
    signature = pointer.get("signature")
    try:
        signature_bytes = base64.b64decode(signature, validate=True)
    except (ValueError, TypeError):
        raise ValueError("active pointer signature is invalid") from None
    if len(signature_bytes) != 64:
        raise ValueError("active pointer signature is invalid")

    payload = pointer.get("payload")
    if not isinstance(payload, dict):
        raise ValueError("active pointer payload is invalid")
    if payload.get("schemaVersion") != 1:
        raise ValueError("active pointer schema is invalid")
    pair_id = payload.get("pairID")
    sequence = payload.get("catalogSequence")
    if not isinstance(pair_id, str) or SHA256.fullmatch(pair_id) is None:
        raise ValueError("active pointer pair ID is invalid")
    if not isinstance(sequence, int) or isinstance(sequence, bool) or not 0 < sequence < 2**64:
        raise ValueError("active pointer sequence is invalid")
    if expected_pair is not None and pair_id != expected_pair:
        raise ValueError("active pointer pair hash mismatch")

    objects = payload.get("objects")
    if (
        not isinstance(objects, list)
        or len(objects) != len(POINTER_OBJECT_NAMES)
        or any(not isinstance(item, dict) for item in objects)
    ):
        raise ValueError("active pointer object set is invalid")
    names: set[str] = set()
    for item in objects:
        name = item.get("name")
        path = item.get("path")
        digest = item.get("sha256")
        size = item.get("bytes")
        if (
            not isinstance(name, str)
            or name not in POINTER_OBJECT_NAMES
            or name in names
            or not isinstance(path, str)
            or path.startswith("/")
            or "\\" in path
            or any(part in {"", ".", ".."} for part in path.split("/"))
            or path != f"catalog-history/{pair_id}/{name}"
            or not isinstance(digest, str)
            or SHA256.fullmatch(digest) is None
            or not isinstance(size, int)
            or isinstance(size, bool)
            or size <= 0
        ):
            raise ValueError("active pointer object is invalid")
        names.add(name)
    if names != POINTER_OBJECT_NAMES:
        raise ValueError("active pointer object set is incomplete")
    return pair_id, sequence


def verify_pair(directory: Path, expected_pair: str | None = None) -> tuple[str, int]:
    manifest_path = directory / "release-pair.json"
    pair_id = file_sha256(manifest_path)
    if expected_pair is not None and pair_id != expected_pair:
        raise ValueError("release pair hash mismatch")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != 1:
        raise ValueError("unsupported release pair schema")
    sequence = manifest.get("catalogSequence")
    if not isinstance(sequence, int) or isinstance(sequence, bool) or not 0 < sequence < 2**64:
        raise ValueError("invalid catalog sequence")

    files = manifest.get("files")
    if (
        not isinstance(files, list)
        or len(files) != len(EXPECTED_FILES)
        or any(not isinstance(item, dict) for item in files)
        or {item.get("path") for item in files} != EXPECTED_FILES
    ):
        raise ValueError("release pair file set is invalid")
    for item in files:
        path = item.get("path")
        digest = item.get("sha256")
        size = item.get("bytes")
        if (
            not isinstance(path, str)
            or not isinstance(digest, str)
            or SHA256.fullmatch(digest) is None
            or not isinstance(size, int)
            or isinstance(size, bool)
            or size <= 0
        ):
            raise ValueError("release pair digest entry is invalid")
        relative = Path(path)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError(f"release pair path escapes its directory: {path}")
        file_path = directory / relative
        if not file_path.is_file() or file_path.stat().st_size != size or file_sha256(file_path) != digest:
            raise ValueError(f"release pair file mismatch: {path}")

    v1 = json.loads((directory / "catalog-v1.json").read_text(encoding="utf-8"))
    v2 = json.loads((directory / "catalog-v2.json").read_text(encoding="utf-8"))
    if not isinstance(v1, dict) or not isinstance(v2, dict):
        raise ValueError("catalog root must be an object")
    if v1.get("schemaVersion") != 1 or v2.get("schemaVersion") != 2:
        raise ValueError("catalog schema mismatch")
    v1_models = v1.get("models")
    if (
        not isinstance(v1_models, list)
        or any(not isinstance(model, dict) for model in v1_models)
    ):
        raise ValueError("legacy catalog models are invalid")
    v1_by_id: dict[str, dict] = {}
    for model in v1_models:
        model_id = model.get("id")
        revision = model.get("revision")
        artifacts = model.get("artifacts")
        if (
            not isinstance(model_id, str)
            or MODEL_ID.fullmatch(model_id) is None
            or model_id in v1_by_id
            or not isinstance(revision, str)
            or MODEL_REVISION.fullmatch(revision) is None
            or not isinstance(artifacts, list)
            or not artifacts
        ):
            raise ValueError("legacy catalog model metadata is invalid")
        v1_by_id[model_id] = model
    if v2.get("catalogSequence") != sequence:
        raise ValueError("catalog sequence does not match the release pair")
    models = manifest.get("models")
    v2_models = v2.get("models")
    if (
        not isinstance(models, list)
        or not isinstance(v2_models, list)
        or any(not isinstance(model, dict) for model in models + v2_models)
    ):
        raise ValueError("release pair models are invalid")
    model_ids: set[str] = set()
    for model in v2_models:
        model_id = model.get("id")
        revision = model.get("revision")
        release_sequence = model.get("releaseSequence")
        availability = model.get("availability", "active")
        if (
            not isinstance(model_id, str)
            or MODEL_ID.fullmatch(model_id) is None
            or model_id in model_ids
            or not isinstance(revision, str)
            or MODEL_REVISION.fullmatch(revision) is None
            or not isinstance(release_sequence, int)
            or isinstance(release_sequence, bool)
            or not 0 < release_sequence < 2**64
            or not isinstance(availability, str)
            or availability not in {"active", "retired"}
        ):
            raise ValueError("catalog model metadata is invalid")
        model_ids.add(model_id)
    v2_by_id = {model["id"]: model for model in v2_models}
    for model_id, legacy in v1_by_id.items():
        current = v2_by_id.get(model_id)
        if current is None:
            raise ValueError(f"legacy model {model_id} is missing from catalog-v2")
        if current.get("availability", "active") != "active":
            raise ValueError(f"legacy model {model_id} must map to an active V2 model")
        if (
            current.get("revision") != legacy["revision"]
            or current.get("artifacts") != legacy["artifacts"]
            or current.get("qualification") != legacy.get("qualification")
        ):
            raise ValueError(f"legacy model {model_id} diverges from catalog-v2")
    expected_models = []
    for model in v2_models:
        expected = {"id": model["id"], "revision": model["revision"]}
        if "availability" in model:
            expected["availability"] = model["availability"]
        expected_models.append(expected)
    expected_models.sort(key=lambda model: model["id"])
    if models != expected_models:
        raise ValueError("model revisions do not match the release pair")
    pointer_path = directory / "active-pair.json"
    if pointer_path.exists():
        pointer_pair, pointer_sequence = verify_pointer(pointer_path, pair_id)
        if pointer_pair != pair_id or pointer_sequence != sequence:
            raise ValueError("active pointer does not match the release pair")
        pointer = json.loads(pointer_path.read_text(encoding="utf-8"))
        for item in pointer["payload"]["objects"]:
            file_path = directory / item["name"]
            if (
                not file_path.is_file()
                or file_path.stat().st_size != item["bytes"]
                or file_sha256(file_path) != item["sha256"]
            ):
                raise ValueError(f"active pointer file mismatch: {item['name']}")
    return pair_id, sequence


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path, nargs="?")
    parser.add_argument("--expected-pair")
    parser.add_argument("--pointer", type=Path)
    parser.add_argument("--artifact-list", type=Path)
    parser.add_argument(
        "--artifact-base-url",
        default="https://models.oncloud.at/models/",
    )
    arguments = parser.parse_args()
    if arguments.artifact_list is not None:
        if arguments.directory is not None or arguments.pointer is not None or arguments.expected_pair is not None:
            parser.error("--artifact-list cannot be combined with pair verification options")
        for row in verify_artifact_list(arguments.artifact_list, arguments.artifact_base_url):
            print(row)
        return
    if arguments.pointer is not None:
        pair_id, sequence = verify_pointer(arguments.pointer, arguments.expected_pair)
        print(f"Verified active pointer {pair_id} at sequence {sequence}")
        return
    if arguments.directory is None:
        parser.error("directory is required unless --pointer is provided")
    pair_id, sequence = verify_pair(arguments.directory, arguments.expected_pair)
    print(f"Verified release pair {pair_id} at sequence {sequence}")


if __name__ == "__main__":
    main()
