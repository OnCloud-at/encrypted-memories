#!/usr/bin/env python3
"""Merge two SwiftPM lock files without allowing version drift."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def load(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: merge-package-resolved.py PRIMARY SECONDARY OUTPUT", file=sys.stderr)
        return 64

    primary_path, secondary_path, output_path = map(Path, sys.argv[1:])
    primary = load(primary_path)
    secondary = load(secondary_path)

    pins: dict[str, dict] = {}
    for source_path, document in ((primary_path, primary), (secondary_path, secondary)):
        for pin in document.get("pins", []):
            identity = pin.get("identity")
            if not identity:
                print(f"pin without identity in {source_path}", file=sys.stderr)
                return 65
            previous = pins.get(identity)
            if previous is not None and previous != pin:
                print(f"conflicting pin for {identity} between lock files", file=sys.stderr)
                return 66
            pins[identity] = pin

    merged = dict(primary)
    merged["pins"] = [pins[identity] for identity in sorted(pins)]

    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = output_path.with_name(f".{output_path.name}.tmp-{os.getpid()}")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(merged, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    os.replace(temporary, output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
