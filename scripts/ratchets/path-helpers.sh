#!/usr/bin/env python3
"""path-helpers.sh - Ratchet that freezes the copies of the path helpers (review finding R8).

Provenance records, manifests and bundle records store paths relative to a base, and Sources/
holds many hand-written copies of the function that computes one. The copies disagree about a
file outside the base. Some answer with the file name, some with the absolute path, some with nil,
some with a ../ path and some drop components blindly. A helper that feeds a directory checksum
also decides a recorded digest, so that one never changes without a science review. Collapsing
the copies is a later job that goes family by family under this ratchet. Until then nothing may
add another one. See docs/contracts/RECORDING-PROVENANCE.md.

Counts, over Sources/**/*.swift:
    relative_path_definitions   func relativePath or func projectRelativePath
    relative_path_relatives     func appRelativePath, bundleRelativePath, storedPath, relativeDescendantPath,
                                filesystemRelativePath or relativePathForMigrationProvenance, and
                                func relative(_ or func relative(path:
    directory_checksum_copies   func directoryChecksum, in its manifest and its URL spellings
Each count may only fall, and each counts occurrences, not files. Text after // on a line is
ignored (comment lines and trailing comments).

Blind spots. The scan reads one line at a time and does not parse Swift, so review catches the rest.
    - A helper under another name escapes the first two counts.
    - An inline copy such as dropFirst(base.count + 1) is not a function and escapes every count.

Baseline file: one "<name> <count>" line per count. Lower it with --update after a count falls.
A change that raises a count needs a reviewed reason.

Usage:
    scripts/ratchets/path-helpers.sh              # check against the recorded baseline
    scripts/ratchets/path-helpers.sh --print      # print each counted site and the counts, no pass/fail
    scripts/ratchets/path-helpers.sh --update     # rewrite the baseline to the current counts
                                                    (only for a deliberate, reviewed change)

Exit codes: 0 = every count at or under baseline, 1 = a count rose or no baseline is recorded.
"""
import re
import sys
from pathlib import Path
from typing import NamedTuple

REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCES_DIR = REPO_ROOT / "Sources"
BASELINE_FILE = Path(__file__).resolve().with_suffix(".baseline")

SEE = "See docs/contracts/RECORDING-PROVENANCE.md."


class Count(NamedTuple):
    name: str
    pattern: "re.Pattern[str]"
    fix: str


COUNTS = (
    Count(
        "relative_path_definitions",
        re.compile(r"\bfunc\s+(?:relativePath|projectRelativePath)\b"),
        "Do not add another relativePath or projectRelativePath function. The existing copies "
        "answer differently for a file outside the base, so a new copy is a new rule for recorded "
        "paths. Call CanonicalFilePath.relativePath(of:within:) in LungfishCore, or the helper your "
        "module already has, and say which in the review. " + SEE,
    ),
    Count(
        "relative_path_relatives",
        re.compile(
            r"\bfunc\s+(?:appRelativePath|bundleRelativePath|storedPath|relativeDescendantPath"
            r"|filesystemRelativePath|relativePathForMigrationProvenance)\b"
            r"|\bfunc\s+relative\(\s*(?:_|path:)"
        ),
        "Do not add another helper that turns a URL into a path relative to a base, under any name "
        "such as appRelativePath, storedPath or relative(_:to:). Call "
        "CanonicalFilePath.relativePath(of:within:) in LungfishCore, or the helper your module "
        "already has, and say which in the review. " + SEE,
    ),
    Count(
        "directory_checksum_copies",
        re.compile(r"\bfunc\s+directoryChecksum\b"),
        "Do not add another directoryChecksum function. Each copy hashes the path, checksum and size "
        "lines of a directory manifest, so a copy that drifts records a different checksum for the "
        "same folder. Take the checksum from ProvenanceRecorder.fileOrDirectoryRecord(url:format:role:) "
        "or reuse an existing copy, and say which in the review. " + SEE,
    ),
)


def strip_line_comment(line):
    """Drop text from the first // that is outside a double-quoted string."""
    in_string = False
    i = 0
    while i < len(line):
        ch = line[i]
        if in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_string = False
        elif ch == '"':
            in_string = True
        elif ch == "/" and line.startswith("//", i):
            return line[:i]
        i += 1
    return line


def scan():
    counts = {count.name: 0 for count in COUNTS}
    sites = []
    if not SOURCES_DIR.is_dir():
        return counts, sites
    for path in sorted(SOURCES_DIR.rglob("*.swift")):
        rel = path.relative_to(REPO_ROOT).as_posix()
        text = path.read_text(encoding="utf-8", errors="replace")
        for lineno, line in enumerate(text.splitlines(), 1):
            code = strip_line_comment(line)
            for count in COUNTS:
                for _ in count.pattern.finditer(code):
                    counts[count.name] += 1
                    sites.append(f"{rel}:{lineno}: {count.name}")
    return counts, sites


def read_baseline():
    if not BASELINE_FILE.exists():
        return None
    entries = {}
    for line in BASELINE_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, _, num = line.rpartition(" ")
        try:
            entries[name] = int(num)
        except ValueError:
            continue
    return entries


def main(argv):
    counts, sites = scan()

    if "--print" in argv:
        for s in sites:
            print(s)
        for name, n in counts.items():
            print(f"TOTAL {name} {n}")
        return 0

    if "--update" in argv:
        lines = ["# path-helpers baseline: counts under Sources/. Counts may only fall."]
        lines += [f"{name} {n}" for name, n in counts.items()]
        BASELINE_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print("Updated baseline: " + ", ".join(f"{n} {name}" for name, n in counts.items()) + ".")
        return 0

    baseline = read_baseline()
    if baseline is None:
        print(
            f"path-helpers: no baseline recorded at {BASELINE_FILE}. "
            f"Run with --update to record the current counts.",
            file=sys.stderr,
        )
        return 1

    over = [count for count in COUNTS if counts[count.name] > baseline.get(count.name, 0)]
    if over:
        for count in over:
            print(
                f"path-helpers: {counts[count.name]} for {count.name}, "
                f"up from the recorded baseline of {baseline.get(count.name, 0)}.",
                file=sys.stderr,
            )
            print(f"  {count.fix}", file=sys.stderr)
        print(
            "Run scripts/ratchets/path-helpers.sh --print to list every counted site.",
            file=sys.stderr,
        )
        return 1

    lower = [name for name, n in counts.items() if n < baseline.get(name, 0)]
    summary = ", ".join(f"{n} {name}" for name, n in counts.items())
    if lower:
        print(
            f"path-helpers: {summary}. Down from baseline for {', '.join(lower)}. "
            f"Run with --update to lower the baseline."
        )
    else:
        print(f"path-helpers: {summary}, at the recorded baseline.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
