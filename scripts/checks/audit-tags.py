#!/usr/bin/env python3
"""audit-tags.py - Fail when a source file still carries a finding tag from the 2026-09-23 audit.

Background (architecture review R5): the best-practices audit numbered every finding
with a prefix, a hyphen and a number. The prefixes were ARC, FEA, GEN, NEW, PERF, REC,
REL, SCI, SIMP, TST, UX and WFL. Hundreds of comments cited those tags, and the audit
report that explained them is deleted, so a tag left in a comment points at nothing.
Each comment must state its own rule or reason in a self-contained sentence instead.

This check scans every text file under Sources, Tests, scripts, agents, .github and
.codex for a tag, allowing one lowercase letter after the number for sub-items. Only
those twelve prefixes match, so look-alikes such as UTF-8, SHA-256, GPL-3, BY-NC and
HSV-1 pass. Binary files and the directories .git, .build, .swiftpm, node_modules and
__pycache__ are skipped.

A tag that cannot be reworded stays on purpose. Examples are a tag inside a string literal
that reaches exported output and a tag in a bundled script whose digest is recorded in
provenance. List each one in scripts/checks/audit-tags.allowlist as one `<path>:<tag>`
entry per remaining tag, with the path relative to the repository root. An entry exempts
that tag in that file and nothing else, so a different tag added to the same file still
fails. An entry that no longer matches a tag is reported as stale (warning, exit 0).
Lines starting with # and blank lines are ignored. The allowlist file itself is not
scanned, because it names tags on purpose.

Usage:
    scripts/checks/audit-tags.py
    scripts/checks/audit-tags.py --root DIR --allowlist FILE

Exit codes: 0 = no unlisted tag, 1 = at least one tag, 2 = unreadable allowlist.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ALLOWLIST = Path(__file__).resolve().with_suffix(".allowlist")

SCAN_ROOTS = ("Sources", "Tests", "scripts", "agents", ".github", ".codex")
SKIP_DIRS = {".git", ".build", ".swiftpm", "node_modules", "__pycache__"}
PREFIXES = ("ARC", "FEA", "GEN", "NEW", "PERF", "REC", "REL", "SCI", "SIMP", "TST", "UX", "WFL")
# Built from the prefixes so this file holds no literal tag and never matches itself.
TAG_PATTERN = r"\b(?:" + "|".join(PREFIXES) + r")-[0-9]+[a-z]?\b"
TAG = re.compile(TAG_PATTERN.encode())
ENTRY_TAG = re.compile(TAG_PATTERN)
SNIFF_BYTES = 8192
MAX_SHOWN = 160


def read_allowlist(path: Path) -> dict[str, set[str]]:
    """Return {relative path: {tags}}. Raises ValueError for a malformed entry."""
    entries: dict[str, set[str]] = {}
    if not path.exists():
        return entries
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        target, sep, found = line.rpartition(":")
        target, found = target.strip(), found.strip()
        if not sep or not target or not ENTRY_TAG.fullmatch(found):
            raise ValueError(f"{path.name}:{number}: expected `<path>:<tag>` naming one audit finding tag, got {raw!r}")
        entries.setdefault(target, set()).add(found)
    return entries


def is_binary(path: Path) -> bool:
    with path.open("rb") as handle:
        return b"\0" in handle.read(SNIFF_BYTES)


def scan_file(path: Path) -> list[tuple[int, str, list[str]]]:
    """Return [(line number, line text, tags on that line)] for each line that carries a tag."""
    hits: list[tuple[int, str, list[str]]] = []
    with path.open("rb") as handle:
        for number, raw in enumerate(handle, 1):
            found = TAG.findall(raw)
            if found:
                text = raw.decode("utf-8", errors="replace").strip()
                hits.append((number, text, [item.decode("ascii") for item in found]))
    return hits


def walk(root: Path):
    for name in SCAN_ROOTS:
        base = root / name
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if any(part in SKIP_DIRS for part in path.relative_to(root).parts):
                continue
            if path.is_file() and not path.is_symlink():
                yield path


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--allowlist", type=Path, default=DEFAULT_ALLOWLIST)
    args = parser.parse_args(argv)
    root = args.root.resolve()
    allowlist_path = args.allowlist.resolve()

    try:
        allow = read_allowlist(allowlist_path)
    except ValueError as error:
        print(f"audit-tags: {error}", file=sys.stderr)
        return 2

    unlisted: dict[str, list[tuple[int, str]]] = {}
    used: set[tuple[str, str]] = set()
    scanned = 0
    for path in walk(root):
        # The allowlist names tags on purpose, so it is data for this check and not source.
        if path == allowlist_path or is_binary(path):
            continue
        scanned += 1
        hits = scan_file(path)
        if not hits:
            continue
        rel = path.relative_to(root).as_posix()
        permitted = allow.get(rel, set())
        used.update((rel, found) for _, _, tags in hits for found in tags if found in permitted)
        flagged = [(number, text) for number, text, tags in hits if any(found not in permitted for found in tags)]
        if flagged:
            unlisted[rel] = flagged

    stale = sorted((rel, found) for rel, tags in allow.items() for found in tags if (rel, found) not in used)
    for rel, found in stale:
        print(f"audit-tags: allowlist entry {rel}:{found} matches no tag in that file (or the file is gone), remove it.")

    if unlisted:
        total = sum(len(hits) for hits in unlisted.values())
        print(f"audit-tags: {total} line(s) in {len(unlisted)} file(s) cite an audit finding tag:", file=sys.stderr)
        for rel in sorted(unlisted):
            for number, text in unlisted[rel]:
                shown = text if len(text) <= MAX_SHOWN else text[: MAX_SHOWN - 3] + "..."
                print(f"  {rel}:{number}: {shown}", file=sys.stderr)
        print(
            "Rewrite each comment as a self-contained sentence that states the rule or reason. "
            "For a tag that must stay, such as one inside a string literal that reaches exported output, "
            "add one `<path>:<tag>` entry to scripts/checks/audit-tags.allowlist.",
            file=sys.stderr,
        )
        return 1

    print(f"audit-tags: no audit finding tags in Sources, Tests, scripts, agents, .github or .codex ({scanned} files scanned, {len(used)} allowlisted).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
