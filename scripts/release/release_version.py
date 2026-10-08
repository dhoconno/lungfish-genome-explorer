#!/usr/bin/env python3
"""The release version is the newest CalVer release-notes file.

A release declares its version by committing docs/release-notes/<version>.md,
which every release needs anyway. No Swift source, project setting or
resource carries the version. Packaging stamps it into the app after the
compile, so cutting a release changes nothing a compiler or test reads, and
unit-tier evidence carries across the notes commit
(docs/contracts/VERIFICATION-ORDER.md).

Older notes files with other names (v0.4.0-alpha.*, deps-*) are ignored.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys

NOTES_RELATIVE = Path("docs/release-notes")
CALVER_NOTES = re.compile(r"^([1-9][0-9]{3})\.([1-9]|1[0-2])\.([1-9][0-9]*)\.md$")


class ReleaseVersionError(ValueError):
    """No release version can be read from the release notes."""


def release_version(root: Path) -> str:
    """Return the highest YYYY.M.PATCH among the committed notes files."""
    directory = Path(root) / NOTES_RELATIVE
    try:
        names = [entry.name for entry in directory.iterdir()
                 if not entry.is_symlink() and entry.is_file()]
    except OSError as error:
        raise ReleaseVersionError(f"release notes folder is unreadable: {directory}") from error
    versions = []
    for name in names:
        match = CALVER_NOTES.match(name)
        if match:
            versions.append(tuple(int(part) for part in match.groups()))
    if not versions:
        raise ReleaseVersionError(f"no YYYY.M.PATCH release notes under {directory}")
    return ".".join(str(part) for part in max(versions))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2],
                        help="Repository root (default: this checkout).")
    args = parser.parse_args(argv)
    try:
        print(release_version(args.root))
    except ReleaseVersionError as error:
        print(f"release version: {error}", file=sys.stderr)
        return 65
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
