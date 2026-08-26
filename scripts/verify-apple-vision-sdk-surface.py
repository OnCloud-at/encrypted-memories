#!/usr/bin/env python3

"""Fail when the selected Xcode exposes an unreviewed Vision request type."""

from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
INVENTORY = (
    ROOT
    / "Packages"
    / "EncryptedMemoriesKit"
    / "Sources"
    / "MLSearchAppleAdapter"
    / "AppleVisionCapabilityInventory.swift"
)


def sdk_path() -> Path:
    environment = os.environ.copy()
    result = subprocess.run(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"],
        check=True,
        capture_output=True,
        text=True,
        env=environment,
    )
    return Path(result.stdout.strip())


def request_descriptor_names(interface: Path) -> set[str]:
    source = interface.read_text(encoding="utf-8")
    match = re.search(
        r"public enum RequestDescriptor\b.*?^\}",
        source,
        flags=re.MULTILINE | re.DOTALL,
    )
    if match is None:
        raise RuntimeError(f"RequestDescriptor was not found in {interface}")
    names = set()
    for case_name in re.findall(r"^\s*case\s+([A-Za-z0-9_]+)\(", match.group(0), re.MULTILINE):
        names.add(case_name[0].upper() + case_name[1:])
    if not names:
        raise RuntimeError(f"RequestDescriptor has no cases in {interface}")
    return names


def reviewed_request_names(source: str | None = None) -> tuple[set[str], set[str]]:
    if source is None:
        source = INVENTORY.read_text(encoding="utf-8")
    swift_entries = set(
        re.findall(
            r'entry\(\s*\.[A-Za-z0-9_]+\s*,\s*"([A-Za-z0-9_]+Request)"',
            source,
        )
    )
    legacy_entries = set(
        re.findall(
            r'entry\(\s*\.[A-Za-z0-9_]+\s*,\s*"[A-Za-z0-9_]+Request"\s*,\s*"([A-Za-z0-9_]+Request)"',
            source,
        )
    )
    exclusions = set(
        re.findall(
            r'AppleVisionRequestExclusion\(\s*requestName:\s*"([A-Za-z0-9_]+Request)"',
            source,
        )
    )
    modern = swift_entries | exclusions
    legacy = legacy_entries | {f"VN{name}" for name in modern}
    return modern, legacy


def legacy_request_names(sdk: Path) -> set[str]:
    headers = (
        sdk
        / "System"
        / "Library"
        / "Frameworks"
        / "Vision.framework"
        / "Versions"
        / "A"
        / "Headers"
    )
    if not headers.is_dir():
        raise RuntimeError(f"Vision headers were not found under {headers}")
    names: set[str] = set()
    for header in headers.glob("*.h"):
        source = header.read_text(encoding="utf-8")
        names.update(
            re.findall(
                r"@interface\s+(VN[A-Za-z0-9_]+Request)\s*:",
                source,
            )
        )
    abstract = {
        "VNRequest",
        "VNImageBasedRequest",
        "VNImageRegistrationRequest",
        "VNStatefulRequest",
        "VNTargetedImageRequest",
        "VNTrackingRequest",
    }
    return names - abstract


def vision_interface(sdk: Path) -> Path:
    directory = (
        sdk
        / "System"
        / "Library"
        / "Frameworks"
        / "Vision.framework"
        / "Versions"
        / "A"
        / "Modules"
        / "Vision.swiftmodule"
    )
    preferred = directory / "arm64e-apple-macos.swiftinterface"
    if preferred.is_file():
        return preferred
    candidates = sorted(directory.glob("*-apple-macos.swiftinterface"))
    if not candidates:
        raise RuntimeError(f"Vision Swift interface was not found under {directory}")
    return candidates[0]


def main() -> int:
    try:
        sdk = sdk_path()
        interface = vision_interface(sdk)
        exposed = request_descriptor_names(interface)
        legacy_exposed = legacy_request_names(sdk)
        reviewed, legacy_reviewed = reviewed_request_names()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"[vision-surface] unable to inspect the selected SDK: {error}", file=sys.stderr)
        return 2

    missing = sorted(exposed - reviewed)
    missing_legacy = sorted(legacy_exposed - legacy_reviewed)
    if missing or missing_legacy:
        if missing:
            print(
                "[vision-surface] unreviewed Vision RequestDescriptor cases: "
                + ", ".join(missing),
                file=sys.stderr,
            )
        if missing_legacy:
            print(
                "[vision-surface] unreviewed legacy Vision request classes: "
                + ", ".join(missing_legacy),
                file=sys.stderr,
            )
        print(
            "[vision-surface] add each request to AppleVisionCapabilityInventory.entries "
            "or document why it belongs in exclusions.",
            file=sys.stderr,
        )
        return 1

    print(
        f"[vision-surface] {len(exposed)} Swift request descriptors and "
        f"{len(legacy_exposed)} concrete legacy request classes are explicitly reviewed"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
