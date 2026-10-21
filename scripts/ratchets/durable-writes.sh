#!/usr/bin/env python3
"""durable-writes.sh - Ratchet on the file writes that still pass the .atomic option.

Counts the lines under Sources/ that hold the whole token `.atomic`, as in
`try data.write(to: url, options: [.atomic])`. A line counts once however many tokens it holds.
A longer name such as `.atomicPackage` is another identifier and does not count. A line that
starts with // or /// is ignored, but a trailing comment on a code line does not hide a write.

A write that must leave a complete old or new file after a crash goes through DurableReplace
(Sources/LungfishCore/Storage/DurableReplace.swift) or PortableRename, as
docs/contracts/EXTERNAL-VOLUMES.md describes. Phase 4f moves the existing `.atomic` writes there,
and until then the count may only fall.

Baseline file: a comment line and one "durable-writes <count>" line.

Usage:
    scripts/ratchets/durable-writes.sh              # check against the recorded baseline
    scripts/ratchets/durable-writes.sh --print      # print each site and a TOTAL line, no pass/fail
    scripts/ratchets/durable-writes.sh --update     # rewrite the baseline to the current count
                                                      (only for a reviewed lowering or increase)

Exit codes: 0 = the count is at or under the baseline, 1 = the count rose or no baseline is recorded.
"""
import re
import sys
from pathlib import Path

NAME = "durable-writes"
REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCES_DIR = REPO_ROOT / "Sources"
BASELINE_FILE = Path(__file__).resolve().with_suffix(".baseline")

# The whole token only. A longer name such as .atomicPackage is another identifier.
TOKEN = re.compile(r"\.atomic(?!\w)")


def scan():
    """Every non-comment line under Sources/ that holds the token, as "path:line: text"."""
    sites = []
    if not SOURCES_DIR.is_dir():
        return sites
    for path in sorted(SOURCES_DIR.rglob("*.swift")):
        rel = path.relative_to(REPO_ROOT).as_posix()
        text = path.read_text(encoding="utf-8", errors="replace")
        for lineno, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("//"):
                continue
            if TOKEN.search(line):
                sites.append(f"{rel}:{lineno}: {line.strip()}")
    return sites


def read_baseline():
    """The recorded count, or None when the file or its entry is missing."""
    if not BASELINE_FILE.exists():
        return None
    for line in BASELINE_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, _, num = line.rpartition(" ")
        if name != NAME:
            continue
        try:
            return int(num)
        except ValueError:
            return None
    return None


def main(argv):
    sites = scan()
    count = len(sites)

    if "--print" in argv:
        sys.stdout.reconfigure(errors="replace")
        for site in sites:
            print(site)
        print(f"TOTAL {NAME} {count}")
        return 0

    if "--update" in argv:
        BASELINE_FILE.write_text(
            f"# {NAME} baseline: lines under Sources/ that hold the whole token .atomic. The count may only fall.\n"
            f"{NAME} {count}\n",
            encoding="utf-8",
        )
        print(f"Updated baseline: {count} lines with .atomic.")
        return 0

    baseline = read_baseline()
    if baseline is None:
        print(
            f"{NAME}: no baseline recorded at {BASELINE_FILE}. Run with --update to record the current count.",
            file=sys.stderr,
        )
        return 1

    if count > baseline:
        print(
            f"{NAME}: the count of lines with .atomic is {count}, up from the recorded baseline of {baseline}.",
            file=sys.stderr,
        )
        print(
            "Write the file through DurableReplace or PortableRename instead of the .atomic option. "
            "See docs/contracts/EXTERNAL-VOLUMES.md.",
            file=sys.stderr,
        )
        return 1

    if count < baseline:
        print(
            f"{NAME}: the count of lines with .atomic is {count}, down from the recorded baseline of {baseline}. "
            f"Run with --update to lower the baseline."
        )
    else:
        print(f"{NAME}: the count of lines with .atomic is {count}, at the recorded baseline.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
