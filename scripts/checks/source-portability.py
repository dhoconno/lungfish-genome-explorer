#!/usr/bin/env python3
"""Fail when a text file under Sources holds a literal that the release portability scan forbids.

scripts/release/scan-release-portability.py reads every byte of the assembled app and fails the package
when a string of its FORBIDDEN_PATTERNS appears. A literal added on a lane passes every test tier and
fails release.py package about 17 minutes in. This check runs the same table over Sources at each push,
so the lane that adds the literal is the first to see it.

The table is loaded from the scanner by path and never copied, so a pattern added there is checked here.
The dynamic label repository-root is left out, since it names the checkout the scanner runs in and not a
literal of the source. A file with a NUL byte in its first 8000 bytes is binary and is skipped, as
git grep -I skips it.

Which lines count. The compiler drops a Swift line that starts with //, so a .swift file skips those
lines. Every other text file under Sources (json, html, py, md and the rest) can ship whole as a resource,
and // is no comment mark in most of them, so each of its lines counts. A line that holds code and a
trailing comment counts too. A line that starts with // inside a multi-line Swift string literal is
skipped although it ships, which is the one gap of this cheap form. The package scan stays the proof.

Output is one "path:line: label" per hit, sorted by path and line, with exit status 1. A clean tree prints
nothing and exits 0. A missing scanner or Sources folder prints a message on stderr and exits 2.
"""

from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SCANNER_NAME = "scan-release-portability.py"
DYNAMIC_LABEL = "repository-root"
COMMENT_SKIPPED_SUFFIXES = frozenset({".swift"})
BINARY_SNIFF_BYTES = 8000


class CheckError(Exception):
    """The check could not run, which is not the same as a clean tree."""


def load_scanner(repo: Path):
    """Load the scanner module by path. Its file name holds hyphens and it imports
    release_cache_security from its own folder."""
    release = repo / "scripts" / "release"
    path = release / SCANNER_NAME
    if not path.is_file():
        raise CheckError(f"{path} is missing")
    spec = importlib.util.spec_from_file_location("scan_release_portability", path)
    if spec is None or spec.loader is None:
        raise CheckError(f"{path} cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(release))
    try:
        spec.loader.exec_module(module)
    except (ImportError, SyntaxError, OSError) as error:
        raise CheckError(f"{path} cannot be loaded: {error}") from error
    finally:
        sys.path.remove(str(release))
        sys.dont_write_bytecode = previous
    return module


def forbidden_patterns(scanner) -> list[tuple[bytes, str]]:
    """The scanner's table at call time, without the dynamic repository-root entry."""
    return [
        (pattern, label)
        for pattern, label in scanner.FORBIDDEN_PATTERNS
        if label != DYNAMIC_LABEL
    ]


def source_files(sources: Path):
    for directory, directory_names, file_names in os.walk(sources, followlinks=False):
        directory_names.sort()
        for name in sorted(file_names):
            path = Path(directory) / name
            if not path.is_symlink():
                yield path


def read_text_bytes(path: Path) -> bytes | None:
    """The file's bytes, or None when git grep -I would call it binary."""
    try:
        with path.open("rb") as handle:
            head = handle.read(BINARY_SNIFF_BYTES)
            if b"\0" in head:
                return None
            return head + handle.read()
    except OSError as error:
        raise CheckError(f"cannot read {path}: {error.strerror}") from error


def hits_in(
    data: bytes, patterns: list[tuple[bytes, str]], skip_comment_lines: bool
) -> list[tuple[int, str]]:
    present = [(pattern, label) for pattern, label in patterns if pattern in data]
    if not present:
        return []
    hits: list[tuple[int, str]] = []
    for number, line in enumerate(data.split(b"\n"), start=1):
        if skip_comment_lines and line.lstrip().startswith(b"//"):
            continue
        labels: list[str] = []
        for pattern, label in present:
            if label not in labels and pattern in line:
                labels.append(label)
        hits.extend((number, label) for label in labels)
    return hits


def find_hits(repo: Path, scanner) -> list[tuple[str, int, str]]:
    sources = repo / "Sources"
    if not sources.is_dir():
        raise CheckError(f"{sources} is not a folder")
    patterns = forbidden_patterns(scanner)
    found: list[tuple[str, int, str]] = []
    for path in source_files(sources):
        data = read_text_bytes(path)
        if data is None:
            continue
        skip_comments = path.suffix in COMMENT_SKIPPED_SUFFIXES
        relative = path.relative_to(repo).as_posix()
        found.extend(
            (relative, number, label)
            for number, label in hits_in(data, patterns, skip_comments)
        )
    return found


def main() -> int:
    try:
        hits = find_hits(REPO, load_scanner(REPO))
    except CheckError as error:
        print(f"source-portability check error: {error}", file=sys.stderr)
        return 2
    for relative, number, label in hits:
        print(f"{relative}:{number}: {label}")
    return 1 if hits else 0


if __name__ == "__main__":
    raise SystemExit(main())
