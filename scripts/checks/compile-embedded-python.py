#!/usr/bin/env python3
"""compile-embedded-python.py - py_compile every bundled Python resource script.

Background (2026-09-23 best-practices audit, SIMP-16): about 1.4K lines of
Python used to live as raw string literals inside Swift files, which meant
no syntax checking, no linting, and noisy Swift diffs for every Python
change. Those scripts now live as ordinary .py files under each Swift
target's Resources/ directory, loaded at runtime via Bundle.module. This
script is the "add a py_compile step to the push gate" half of that
recommendation: it finds every .py file under Sources/*/Resources and
confirms it still parses as valid Python 3, catching a syntax error before
it reaches a shipped app that would only discover it when the script
actually runs.

Usage:
    scripts/checks/compile-embedded-python.py

Exit codes: 0 = every script compiles, 1 = at least one does not (or none
were found, which likely means the search path is wrong).
"""
from __future__ import annotations

import py_compile
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCES_DIR = REPO_ROOT / "Sources"


def find_scripts() -> list[Path]:
    return sorted(SOURCES_DIR.glob("*/Resources/**/*.py"))


def main() -> int:
    scripts = find_scripts()
    if not scripts:
        print(f"compile-embedded-python: no .py files found under {SOURCES_DIR}/*/Resources", file=sys.stderr)
        return 1

    failures: list[tuple[Path, str]] = []
    with tempfile.TemporaryDirectory() as tmp:
        for script in scripts:
            cfile = Path(tmp) / (script.name + "c")
            try:
                py_compile.compile(str(script), cfile=str(cfile), doraise=True)
            except py_compile.PyCompileError as error:
                failures.append((script, str(error)))

    if failures:
        print(f"compile-embedded-python: {len(failures)} of {len(scripts)} script(s) failed to compile:")
        for script, message in failures:
            rel = script.relative_to(REPO_ROOT)
            print(f"  - {rel}: {message}")
        return 1

    print(f"compile-embedded-python: {len(scripts)} script(s) compiled cleanly.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
