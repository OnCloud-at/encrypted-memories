#!/usr/bin/env python3

from __future__ import annotations

import argparse
import os
from pathlib import Path, PurePosixPath
import shutil
import tarfile

MAX_FILES = 20_000
MAX_FILE_BYTES = 1_000_000_000
MAX_TOTAL_BYTES = 4_000_000_000


def validated_members(archive: tarfile.TarFile) -> list[tuple[tarfile.TarInfo, PurePosixPath]]:
    result: list[tuple[tarfile.TarInfo, PurePosixPath]] = []
    paths: set[PurePosixPath] = set()
    total_bytes = 0

    for member in archive.getmembers():
        path = PurePosixPath(member.name)
        if (
            not member.name
            or member.name.startswith("/")
            or "\x00" in member.name
            or any(part in {"", ".", ".."} or part.startswith(".") for part in path.parts)
        ):
            raise ValueError(f"unsafe archive path: {member.name!r}")
        if path in paths:
            raise ValueError(f"duplicate archive path: {member.name}")
        paths.add(path)
        if not (member.isdir() or member.isreg()):
            raise ValueError(f"unsupported archive entry: {member.name}")
        if member.isreg():
            if member.size <= 0 or member.size > MAX_FILE_BYTES:
                raise ValueError(f"invalid archive file size: {member.name}")
            total_bytes += member.size
            if total_bytes > MAX_TOTAL_BYTES:
                raise ValueError("archive expands beyond the release size limit")
        result.append((member, path))
        if len(result) > MAX_FILES:
            raise ValueError("archive contains too many entries")
    return result


def extract_candidate(archive_path: Path, destination: Path) -> None:
    if destination.exists() and any(destination.iterdir()):
        raise ValueError("destination must be empty")
    destination.mkdir(parents=True, exist_ok=True)
    destination_root = destination.resolve()

    with tarfile.open(archive_path, mode="r:gz") as archive:
        members = validated_members(archive)
        for member, relative_path in members:
            output = destination.joinpath(*relative_path.parts)
            resolved_parent = output.parent.resolve()
            if resolved_parent != destination_root and destination_root not in resolved_parent.parents:
                raise ValueError(f"archive path escaped destination: {member.name}")
            if member.isdir():
                output.mkdir(parents=True, exist_ok=True)
                continue
            output.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                raise ValueError(f"cannot read archive entry: {member.name}")
            with source, output.open("xb") as target:
                shutil.copyfileobj(source, target, length=1024 * 1024)
            os.chmod(output, 0o600)

    required = [
        destination / "source-repository-revision.txt",
        destination / "models",
        destination / "evidence",
        destination / "qualification",
        destination / "notices",
    ]
    if not required[0].is_file() or any(not path.is_dir() for path in required[1:]):
        raise ValueError("archive does not contain the required candidate layout")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("destination", type=Path)
    arguments = parser.parse_args()
    extract_candidate(arguments.archive, arguments.destination)


if __name__ == "__main__":
    main()
