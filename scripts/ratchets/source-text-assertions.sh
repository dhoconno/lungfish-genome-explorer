#!/usr/bin/env python3
"""source-text-assertions.sh - Ratchet on tests that assert against Swift source text (review findings R5/R10).

Tests that read a Swift source file and check `.contains("...")` on its text pin
the implementation's spelling, not its behavior, and break on harmless refactors
and file splits. The count of such assertions may only fall.

Heuristic (documented approximation): a file under Tests/ is a "source-text test"
when it both
  1. reads file text (String(contentsOf:, contentsOfFile, String(decoding:, or the
     EINTR-proof readRepositorySource( helper from LungfishTestSupport), and
  2. names a Swift source path (a string literal ending in `.swift"`, or containing
     `Sources/` or starting `"Sources`).
Every `.contains("` occurrence in such a file is counted. Comment lines are
ignored. The count over-approximates slightly, since the same file may also call
.contains("...") on non-source strings, but it is stable and only needs to fall.

Usage:
    scripts/ratchets/source-text-assertions.sh              # check against the recorded baseline
    scripts/ratchets/source-text-assertions.sh --print      # print per-file counts and the total, no pass/fail
    scripts/ratchets/source-text-assertions.sh --update     # rewrite the baseline to the current count
                                                              (only for a deliberate, reviewed increase)

Exit codes: 0 = at or under baseline, 1 = over baseline.
"""
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TESTS_DIR = REPO_ROOT / "Tests"
BASELINE_FILE = Path(__file__).resolve().with_suffix(".baseline")

READS_FILE = re.compile(r"String\(contentsOf|contentsOfFile|String\(decoding|readRepositorySource\(")
NAMES_SOURCE = re.compile(r'\.swift"|"Sources[/"]|Sources/')
CONTAINS = re.compile(r'\.contains\("')


def scan():
    per_file = {}
    if not TESTS_DIR.is_dir():
        return per_file
    for path in sorted(TESTS_DIR.rglob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="replace")
        if not (READS_FILE.search(text) and NAMES_SOURCE.search(text)):
            continue
        n = sum(
            len(CONTAINS.findall(line))
            for line in text.splitlines()
            if not line.lstrip().startswith("//")
        )
        if n:
            per_file[path.relative_to(REPO_ROOT).as_posix()] = n
    return per_file


def read_baseline():
    if not BASELINE_FILE.exists():
        return None
    for line in BASELINE_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            return int(line.split()[0])
        except ValueError:
            return None
    return None


def main(argv):
    per_file = scan()
    count = sum(per_file.values())

    if "--print" in argv:
        for path, n in sorted(per_file.items()):
            print(f"{path} {n}")
        print(f"TOTAL {count}")
        return 0

    if "--update" in argv:
        BASELINE_FILE.write_text(f"{count}\n", encoding="utf-8")
        print(f"Updated baseline to {count} source-text assertions.")
        return 0

    baseline = read_baseline()
    if baseline is None:
        print(
            f"source-text-assertions: no baseline recorded at {BASELINE_FILE}. "
            f"Run with --update to record the current count ({count}).",
            file=sys.stderr,
        )
        return 1

    if count > baseline:
        print(
            f"source-text-assertions: {count} .contains(\" assertions against Swift source text, "
            f"up from the recorded baseline of {baseline}.",
            file=sys.stderr,
        )
        print(
            "Test behavior through the public API instead of reading source files. "
            "Run with --print for per-file counts.",
            file=sys.stderr,
        )
        return 1

    if count < baseline:
        print(
            f"source-text-assertions: {count} assertions, down from the recorded baseline of "
            f"{baseline}. Run with --update to lower the baseline."
        )
    else:
        print(f"source-text-assertions: {count} assertions, at the recorded baseline.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
