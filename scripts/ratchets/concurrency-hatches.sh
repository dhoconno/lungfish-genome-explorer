#!/usr/bin/env python3
"""concurrency-hatches.sh - Ratchet on Swift concurrency escape hatches (review finding R11).

Counts occurrences under Sources/ of:
    MainActor.assumeIsolated
    @unchecked Sendable
    nonisolated(unsafe)              (all uses)
    nonisolated(unsafe) static var   (counted separately, a subset of the line above)
Each count may only fall. Occurrences on comment lines (// or ///) are ignored.
New code should use real isolation, Sendable value types or actors. See
docs/contracts/CONCURRENCY-PLAYBOOK.md.

Baseline file: one "<name> <count>" line per hatch.

Usage:
    scripts/ratchets/concurrency-hatches.sh              # check against the recorded baseline
    scripts/ratchets/concurrency-hatches.sh --print      # print each occurrence and the counts, no pass/fail
    scripts/ratchets/concurrency-hatches.sh --update     # rewrite the baseline to the current counts
                                                           (only for a deliberate, reviewed increase)

Exit codes: 0 = every count at or under baseline, 1 = a count rose.
"""
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCES_DIR = REPO_ROOT / "Sources"
BASELINE_FILE = Path(__file__).resolve().with_suffix(".baseline")

PATTERNS = {
    "MainActor.assumeIsolated": re.compile(r"MainActor\.assumeIsolated"),
    "@unchecked Sendable": re.compile(r"@unchecked\s+Sendable"),
    "nonisolated(unsafe)": re.compile(r"nonisolated\(unsafe\)"),
    "nonisolated(unsafe) static var": re.compile(
        r"nonisolated\(unsafe\)\s+(?:(?:public|internal|private|fileprivate|open|final)\s+)*static\s+var"
    ),
}


def scan():
    counts = {name: 0 for name in PATTERNS}
    sites = []
    if not SOURCES_DIR.is_dir():
        return counts, sites
    for path in sorted(SOURCES_DIR.rglob("*.swift")):
        rel = path.relative_to(REPO_ROOT).as_posix()
        text = path.read_text(encoding="utf-8", errors="replace")
        for lineno, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("//"):
                continue
            for name, rx in PATTERNS.items():
                for _ in rx.finditer(line):
                    counts[name] += 1
                    sites.append(f"{rel}:{lineno}: {name}")
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
        lines = ["# concurrency-hatches baseline: counts under Sources/. Counts may only fall."]
        lines += [f"{name} {n}" for name, n in counts.items()]
        BASELINE_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print("Updated baseline: " + ", ".join(f"{n} {name}" for name, n in counts.items()) + ".")
        return 0

    baseline = read_baseline()
    if baseline is None:
        print(
            f"concurrency-hatches: no baseline recorded at {BASELINE_FILE}. "
            f"Run with --update to record the current counts.",
            file=sys.stderr,
        )
        return 1

    over = [(name, n, baseline.get(name, 0)) for name, n in counts.items() if n > baseline.get(name, 0)]
    if over:
        for name, n, base in over:
            print(
                f"concurrency-hatches: {n} uses of {name}, up from the recorded baseline of {base}.",
                file=sys.stderr,
            )
        print(
            "Use real actor isolation, Sendable value types or an actor instead of a new escape hatch. "
            "See docs/contracts/CONCURRENCY-PLAYBOOK.md (review finding R11).",
            file=sys.stderr,
        )
        return 1

    lower = [name for name, n in counts.items() if n < baseline.get(name, 0)]
    summary = ", ".join(f"{n} {name}" for name, n in counts.items())
    if lower:
        print(
            f"concurrency-hatches: {summary}. Down from baseline for {', '.join(lower)}. "
            f"Run with --update to lower the baseline."
        )
    else:
        print(f"concurrency-hatches: {summary}, at the recorded baseline.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
