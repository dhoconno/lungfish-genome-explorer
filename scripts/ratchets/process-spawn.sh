#!/usr/bin/env python3
"""process-spawn.sh - Ratchet on direct subprocess creation and termination (review finding R7).

Counts, over Sources/**/*.swift, outside the two folders that host the process primitive
(Sources/LungfishCore/Process/ and Sources/LungfishWorkflow/Native/):
    files_creating_process   files that contain Process()
    raw_terminate_calls      occurrences of .terminate()
Each count may only fall. Text after // on a line is ignored (comment lines and trailing
comments). A folder that does not exist yet is simply not excluded from anything.
New code should launch tools through the shared process primitive so cancellation, process
group teardown and output capture behave the same everywhere.

Baseline file: one "<name> <count>" line per count.

Usage:
    scripts/ratchets/process-spawn.sh              # check against the recorded baseline
    scripts/ratchets/process-spawn.sh --print      # print each occurrence and the counts, no pass/fail
    scripts/ratchets/process-spawn.sh --update     # rewrite the baseline to the current counts
                                                     (only for a deliberate, reviewed increase)

Exit codes: 0 = every count at or under baseline, 1 = a count rose.
"""
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCES_DIR = REPO_ROOT / "Sources"
BASELINE_FILE = Path(__file__).resolve().with_suffix(".baseline")

EXCLUDED_PREFIXES = (
    "Sources/LungfishCore/Process/",
    "Sources/LungfishWorkflow/Native/",
)

PROCESS_RX = re.compile(r"(?<![\w.])(?:Foundation\.)?Process\(\)")
TERMINATE_RX = re.compile(r"\.terminate\(\)")

NAMES = ("files_creating_process", "raw_terminate_calls")


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
    counts = {name: 0 for name in NAMES}
    sites = []
    if not SOURCES_DIR.is_dir():
        return counts, sites
    for path in sorted(SOURCES_DIR.rglob("*.swift")):
        rel = path.relative_to(REPO_ROOT).as_posix()
        if rel.startswith(EXCLUDED_PREFIXES):
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        creates = False
        for lineno, line in enumerate(text.splitlines(), 1):
            code = strip_line_comment(line)
            if PROCESS_RX.search(code):
                if not creates:
                    counts["files_creating_process"] += 1
                    creates = True
                sites.append(f"{rel}:{lineno}: Process()")
            for _ in TERMINATE_RX.finditer(code):
                counts["raw_terminate_calls"] += 1
                sites.append(f"{rel}:{lineno}: .terminate()")
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
        lines = ["# process-spawn baseline: counts under Sources/ outside the process primitive folders. Counts may only fall."]
        lines += [f"{name} {n}" for name, n in counts.items()]
        BASELINE_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print("Updated baseline: " + ", ".join(f"{n} {name}" for name, n in counts.items()) + ".")
        return 0

    baseline = read_baseline()
    if baseline is None:
        print(
            f"process-spawn: no baseline recorded at {BASELINE_FILE}. "
            f"Run with --update to record the current counts.",
            file=sys.stderr,
        )
        return 1

    over = [(name, n, baseline.get(name, 0)) for name, n in counts.items() if n > baseline.get(name, 0)]
    if over:
        for name, n, base in over:
            print(
                f"process-spawn: {n} for {name}, up from the recorded baseline of {base}.",
                file=sys.stderr,
            )
        print(
            "Launch tools through the shared process primitive (Sources/LungfishCore/Process/ or "
            "Sources/LungfishWorkflow/Native/) instead of creating a Process() or calling .terminate() "
            "directly (review finding R7).",
            file=sys.stderr,
        )
        return 1

    lower = [name for name, n in counts.items() if n < baseline.get(name, 0)]
    summary = ", ".join(f"{n} {name}" for name, n in counts.items())
    if lower:
        print(
            f"process-spawn: {summary}. Down from baseline for {', '.join(lower)}. "
            f"Run with --update to lower the baseline."
        )
    else:
        print(f"process-spawn: {summary}, at the recorded baseline.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
