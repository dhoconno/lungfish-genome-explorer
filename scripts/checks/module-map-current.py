#!/usr/bin/env python3
"""module-map-current.py - Fail when docs/architecture/MODULES.md is stale.

Background (2026-10-02 architecture review, finding R5): the generated module
map is only useful while it matches Package.swift and the Sources tree. This
check regenerates the map into a temporary file with
scripts/index/generate-module-map.py and diffs it against the committed copy.

Usage:
    scripts/checks/module-map-current.py              # check the repository
    scripts/checks/module-map-current.py --root PATH  # check another checkout

Exit codes: 0 = MODULES.md is current, 1 = it is missing or differs.
Fix a failure by running `python3 scripts/index/generate-module-map.py` and
committing the result.
"""
from __future__ import annotations

import argparse
import difflib
import importlib.util
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
GENERATOR = REPO_ROOT / "scripts/index/generate-module-map.py"
MAX_DIFF_LINES = 60


def load_generator():
    spec = importlib.util.spec_from_file_location("generate_module_map", GENERATOR)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=REPO_ROOT)
    args = parser.parse_args(argv)
    root = args.root.resolve()

    generator = load_generator()
    committed_path = root / generator.DEFAULT_OUTPUT
    if not committed_path.exists():
        print(f"module-map-current: {generator.DEFAULT_OUTPUT} is missing.")
        print("Run: python3 scripts/index/generate-module-map.py")
        return 1

    with tempfile.TemporaryDirectory() as tmp:
        fresh_path = Path(tmp) / "MODULES.md"
        generator.main(["--root", str(root), "--output", str(fresh_path)])
        fresh = fresh_path.read_text(encoding="utf-8")

    committed = committed_path.read_text(encoding="utf-8")
    if committed == fresh:
        print("module-map-current: docs/architecture/MODULES.md is current.")
        return 0

    diff = list(
        difflib.unified_diff(
            committed.splitlines(),
            fresh.splitlines(),
            fromfile="docs/architecture/MODULES.md (committed)",
            tofile="docs/architecture/MODULES.md (regenerated)",
            lineterm="",
        )
    )
    print("module-map-current: docs/architecture/MODULES.md is stale.")
    for line in diff[:MAX_DIFF_LINES]:
        print(line)
    if len(diff) > MAX_DIFF_LINES:
        print(f"... {len(diff) - MAX_DIFF_LINES} more diff lines")
    print("Run: python3 scripts/index/generate-module-map.py")
    return 1


if __name__ == "__main__":
    sys.exit(main())
