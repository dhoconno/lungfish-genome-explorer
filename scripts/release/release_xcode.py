#!/usr/bin/env python3
"""Resolve one full Xcode developer directory for every release child process."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shlex
import subprocess
import sys
from typing import Callable, Mapping


DEFAULT_DEVELOPER_DIR = Path("/Applications/Xcode.app/Contents/Developer")


class XcodeSelectionError(RuntimeError):
    """The release machine has no usable full Xcode selection."""


def _ambient_xcode_select() -> Path:
    result = subprocess.run(
        ["xcode-select", "-p"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0 or not result.stdout.strip():
        raise XcodeSelectionError(
            "no full Xcode is selected; install Xcode or set DEVELOPER_DIR"
        )
    return Path(result.stdout.strip())


def resolve_developer_dir(
    environment: Mapping[str, str] | None = None,
    *,
    default_developer_dir: Path = DEFAULT_DEVELOPER_DIR,
    xcode_select: Callable[[], Path] = _ambient_xcode_select,
) -> Path:
    """Return the canonical full-Xcode path selected for this release."""
    values = os.environ if environment is None else environment
    configured = values.get("DEVELOPER_DIR", "")
    if configured:
        candidate = Path(configured).expanduser()
    elif default_developer_dir.is_dir():
        candidate = default_developer_dir
    else:
        candidate = xcode_select()
    if "commandlinetools" in str(candidate).lower():
        raise XcodeSelectionError(
            "CommandLineTools alone are unsupported; select full Xcode"
        )
    try:
        canonical = candidate.resolve(strict=True)
    except OSError as error:
        raise XcodeSelectionError(
            "DEVELOPER_DIR does not identify a full Xcode installation"
        ) from error
    xcodebuild = canonical / "usr/bin/xcodebuild"
    if (
        not canonical.is_dir()
        or not xcodebuild.is_file()
        or not os.access(xcodebuild, os.X_OK)
    ):
        raise XcodeSelectionError(
            "DEVELOPER_DIR does not identify a full Xcode installation"
        )
    return canonical


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--shell",
        action="store_true",
        help="emit one shell-safe DEVELOPER_DIR assignment",
    )
    args = parser.parse_args(argv)
    try:
        selected = resolve_developer_dir()
    except XcodeSelectionError as error:
        print(f"Xcode selection: {error}", file=sys.stderr)
        return 1
    if args.shell:
        print(f"DEVELOPER_DIR={shlex.quote(str(selected))}")
    else:
        print(selected)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
