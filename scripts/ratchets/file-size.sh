#!/usr/bin/env python3
"""file-size.sh - Ratchet on Swift source file length (review finding R10).

Rule: every Swift file under Sources/ is at most 800 lines. Files already over
800 lines are recorded in file-size.baseline as "<path> <lines>" and may not grow
past their recorded length. A file that is not in the baseline and exceeds 800
lines fails. Baselined files that shrink are reported so the baseline can be
lowered; a baselined file that no longer exists or drops to 800 or fewer lines
is reported as removable. Line count is the number of newline-terminated lines
(same as wc -l, plus one for an unterminated last line).

Usage:
    scripts/ratchets/file-size.sh              # check against the recorded baseline
    scripts/ratchets/file-size.sh --print      # print each over-limit file and its length, no pass/fail
    scripts/ratchets/file-size.sh --update     # rewrite the baseline to the current state
                                                 (only for a deliberate, reviewed change)

Exit codes: 0 = no new oversize file and no baselined file grew, 1 = violation.
"""
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCES_DIR = REPO_ROOT / "Sources"
BASELINE_FILE = Path(__file__).resolve().with_suffix(".baseline")
LIMIT = 800


def count_lines(path):
    data = path.read_bytes()
    if not data:
        return 0
    return data.count(b"\n") + (0 if data.endswith(b"\n") else 1)


def oversize_files():
    result = {}
    if not SOURCES_DIR.is_dir():
        return result
    for path in SOURCES_DIR.rglob("*.swift"):
        n = count_lines(path)
        if n > LIMIT:
            result[path.relative_to(REPO_ROOT).as_posix()] = n
    return result


def read_baseline():
    if not BASELINE_FILE.exists():
        return None
    entries = {}
    for line in BASELINE_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        path, _, num = line.rpartition(" ")
        try:
            entries[path] = int(num)
        except ValueError:
            continue
    return entries


def main(argv):
    current = oversize_files()

    if "--print" in argv:
        for path, n in sorted(current.items()):
            print(f"{path} {n}")
        print(f"TOTAL {len(current)}")
        return 0

    if "--update" in argv:
        lines = [f"# file-size baseline: Swift files over {LIMIT} lines (path, length). Lengths may only fall."]
        lines += [f"{p} {n}" for p, n in sorted(current.items())]
        BASELINE_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"Updated baseline to {len(current)} files over {LIMIT} lines.")
        return 0

    baseline = read_baseline()
    if baseline is None:
        print(
            f"file-size: no baseline recorded at {BASELINE_FILE}. "
            f"Run with --update to record the current state ({len(current)} files).",
            file=sys.stderr,
        )
        return 1

    violations = []
    for path, n in sorted(current.items()):
        if path not in baseline:
            violations.append(f"  {path}: {n} lines (new file over {LIMIT})")
        elif n > baseline[path]:
            violations.append(f"  {path}: {n} lines, grew past the recorded {baseline[path]}")
    if violations:
        print(
            f"file-size: {len(violations)} file(s) over the limit. New Swift files must be "
            f"{LIMIT} lines or fewer and baselined files may not grow. Split the file instead "
            f"(review finding R10).",
            file=sys.stderr,
        )
        for v in violations:
            print(v, file=sys.stderr)
        return 1

    shrunk = [p for p, n in current.items() if n < baseline[p]]
    stale = [p for p in baseline if p not in current]
    if shrunk or stale:
        print(
            f"file-size: {len(current)} files over {LIMIT} lines, {len(shrunk)} shrunk and "
            f"{len(stale)} no longer over the limit. Run with --update to lower the baseline."
        )
    else:
        print(f"file-size: {len(current)} files over {LIMIT} lines, at the recorded baseline.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
