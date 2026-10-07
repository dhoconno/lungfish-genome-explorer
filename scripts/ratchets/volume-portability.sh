#!/usr/bin/env python3
"""volume-portability.sh - Ratchet on file-system calls that fail on ExFAT, FAT and SMB.

Most external SSDs are formatted ExFAT. On ExFAT these calls answer ENOTSUP, so code that
uses them without a fallback works on the internal APFS disk and fails for a project on an
external drive. See docs/contracts/EXTERNAL-VOLUMES.md.

Counts, under Sources/, of:
    exclusive-or-swap-rename   RENAME_EXCL or RENAME_SWAP passed to a raw rename call.
                               A use within three lines of PortableExclusiveRename is
                               not counted, because that helper falls back.
    clonefile                  clonefile, clonefileat, fclonefileat, COPYFILE_CLONE_FORCE
    hard-link                  link, linkat, FileManager.linkItem
    mkfifo                     mkfifo

Each count may only fall. Occurrences on comment lines (// or ///) and inside one-line
string literals are ignored, and so is
Sources/LungfishIO/Storage/PortableExclusiveRename.swift, the portable helper itself.

Baseline file: one "<name> <count>" line per pattern.

Usage:
    scripts/ratchets/volume-portability.sh              # check against the recorded baseline
    scripts/ratchets/volume-portability.sh --print      # print each occurrence and the counts, no pass/fail
    scripts/ratchets/volume-portability.sh --update     # rewrite the baseline to the current counts
                                                          (only for a deliberate, reviewed increase)

Exit codes: 0 = every count at or under baseline, 1 = a count rose.
"""
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCES_DIR = REPO_ROOT / "Sources"
BASELINE_FILE = Path(__file__).resolve().with_suffix(".baseline")
EXEMPT = {"Sources/LungfishIO/Storage/PortableExclusiveRename.swift"}
HELPER_WINDOW = 3
STRING_LITERAL = re.compile(r'"(?:[^"\\]|\\.)*"')

PATTERNS = {
    "exclusive-or-swap-rename": re.compile(r"\bRENAME_(?:EXCL|SWAP)\b"),
    "clonefile": re.compile(r"\b(?:f?clonefile(?:at)?\s*\(|COPYFILE_CLONE_FORCE\b)"),
    "hard-link": re.compile(r"(?<![\w.])link(?:at)?\s*\(|\blinkItem\s*\("),
    "mkfifo": re.compile(r"\bmkfifo(?:at)?\s*\("),
}


def scan():
    counts = {name: 0 for name in PATTERNS}
    sites = []
    if not SOURCES_DIR.is_dir():
        return counts, sites
    for path in sorted(SOURCES_DIR.rglob("*.swift")):
        rel = path.relative_to(REPO_ROOT).as_posix()
        if rel in EXEMPT:
            continue
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        for index, line in enumerate(lines):
            if line.lstrip().startswith("//"):
                continue
            code = STRING_LITERAL.sub('""', line)
            for name, rx in PATTERNS.items():
                for _ in rx.finditer(code):
                    if name == "exclusive-or-swap-rename":
                        window = lines[max(0, index - HELPER_WINDOW):index + 1]
                        if any("PortableExclusiveRename" in w for w in window):
                            continue
                    counts[name] += 1
                    sites.append(f"{rel}:{index + 1}: {name}")
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
        lines = ["# volume-portability baseline: counts under Sources/. Counts may only fall."]
        lines += [f"{name} {n}" for name, n in counts.items()]
        BASELINE_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print("Updated baseline: " + ", ".join(f"{n} {name}" for name, n in counts.items()) + ".")
        return 0
    baseline = read_baseline()
    if baseline is None:
        print(
            f"volume-portability: no baseline recorded at {BASELINE_FILE}. "
            f"Run with --update to record the current counts.",
            file=sys.stderr,
        )
        return 1
    over = [(name, n, baseline.get(name, 0)) for name, n in counts.items() if n > baseline.get(name, 0)]
    if over:
        for name, n, base in over:
            print(
                f"volume-portability: {n} uses of {name}, up from the recorded baseline of {base}.",
                file=sys.stderr,
            )
        print(
            "These calls fail with ENOTSUP on ExFAT, the default format of most external SSDs. "
            "Use PortableExclusiveRename or another portable path. "
            "See docs/contracts/EXTERNAL-VOLUMES.md.",
            file=sys.stderr,
        )
        return 1
    lower = [name for name, n in counts.items() if n < baseline.get(name, 0)]
    summary = ", ".join(f"{n} {name}" for name, n in counts.items())
    if lower:
        print(
            f"volume-portability: {summary}. Down from baseline for {', '.join(lower)}. "
            f"Run with --update to lower the baseline."
        )
    else:
        print(f"volume-portability: {summary}, at the recorded baseline.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
