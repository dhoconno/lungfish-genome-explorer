#!/usr/bin/env python3
"""features-yaml-sources.py - Verify the file registry in
docs/user-manual/features.yaml is still current.

features.yaml maps every user-reachable feature to the source files that
implement it. Files move and get deleted, and the registry silently rots
(seven entries pointed at paths that no longer existed when this check was
written). This script checks, for every feature entry:

  - each path under `sources:` exists in the repository (a file, or a
    directory, since a few entries name a whole source directory),
  - each path under `tests:` exists in the repository,
  - each name under `module:` (a string or a list) is a directory under
    Sources/.

Like features-yaml-entry-points.py it reads the file with a tiny line parser
instead of a YAML library, so it runs on a bare Python 3 with no packages.
It relies on the file's fixed shape: feature ids at two-space indent, keys at
four, list items at six, either as `key: [a, b]` or as a block list.

Usage:
    scripts/checks/features-yaml-sources.py
    scripts/checks/features-yaml-sources.py --features PATH --root DIR

Exit codes: 0 = every checked path resolves, 1 = at least one does not.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_FEATURES = REPO_ROOT / "docs/user-manual/features.yaml"

CHECKED_KEYS = ("sources", "tests", "module")

FEATURE_RE = re.compile(r"^  ([A-Za-z][\w.\-]*):\s*$")
KEY_RE = re.compile(r"^    ([a-z_]+):\s*(.*?)\s*$")
ITEM_RE = re.compile(r"^      -\s+(.*?)\s*$")


def unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def parse_features(text: str) -> dict[str, dict[str, list[str]]]:
    """Return {feature_id: {key: [values]}} for the checked keys only."""
    features: dict[str, dict[str, list[str]]] = {}
    current: dict[str, list[str]] | None = None
    key: str | None = None
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = FEATURE_RE.match(line)
        if match:
            current = features.setdefault(match.group(1), {})
            key = None
            continue
        if current is None:
            continue
        match = KEY_RE.match(line)
        if match:
            name, rest = match.group(1), match.group(2)
            key = name if name in CHECKED_KEYS else None
            if key is None:
                continue
            values = current.setdefault(key, [])
            if rest.startswith("[") and rest.endswith("]"):
                inner = rest[1:-1]
                values.extend(unquote(v) for v in inner.split(",") if v.strip())
            elif rest and not rest.startswith(("#", ">", "|")):
                values.append(unquote(rest))
            continue
        match = ITEM_RE.match(line)
        if match and key is not None:
            current.setdefault(key, []).append(unquote(match.group(1)))
    return features


def check(features_path: Path, root: Path) -> tuple[int, list[str]]:
    """Return (number of checked values, list of failure messages)."""
    features = parse_features(features_path.read_text())
    failures: list[str] = []
    checked = 0
    sources_dir = root / "Sources"
    for fid, fields in features.items():
        for key in ("sources", "tests"):
            for rel in fields.get(key, []):
                checked += 1
                if not (root / rel).exists():
                    failures.append(f"{fid}: {key} path does not exist: {rel}")
        for name in fields.get("module", []):
            checked += 1
            if not (sources_dir / name).is_dir():
                failures.append(f"{fid}: module is not a directory under Sources/: {name}")
    return checked, failures


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--features", type=Path, default=DEFAULT_FEATURES,
                        help="features.yaml to check")
    parser.add_argument("--root", type=Path, default=REPO_ROOT,
                        help="repository root that paths resolve against")
    args = parser.parse_args(argv)

    if not args.features.is_file():
        print(f"features-yaml-sources: {args.features} not found", file=sys.stderr)
        return 1
    checked, failures = check(args.features, args.root)
    if failures:
        print(f"features-yaml-sources: {len(failures)} problem(s):")
        for message in failures:
            print(f"  {message}")
        print("\nFix docs/user-manual/features.yaml. Find a moved file with "
              "`git log --follow --name-status -- <path>`, and remove the entry "
              "if the feature was removed.")
        return 1
    print(f"features-yaml-sources: {checked} value(s) checked, all resolve.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
