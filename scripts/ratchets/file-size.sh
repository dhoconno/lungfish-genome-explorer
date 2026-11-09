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
    scripts/ratchets/file-size.sh --renames <base>
                                               # re-key the baseline rows of renamed files, then check

--renames reads `git diff -M --name-status <base>..HEAD`. A baselined file that the
diff shows renamed moves its row to the new path with the same number, or with the
file's length when that is lower, and a renamed file of 800 lines or fewer drops its
row. It refuses, with the baseline untouched, a rename whose file is longer than the
recorded number or whose new path already has a row. It adds a row for nothing else,
so a new oversize file still fails the check that follows. Like --update it writes
the baseline in a read-only run and skips the automatic lowering, since a lane asks
for it by name. The blanket --update stays as it is.

Exit codes: 0 = no new oversize file and no baselined file grew, 1 = violation,
2 = --renames could not read its base.
"""
import subprocess
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


def baseline_path(row):
    """The path of a baseline row, or None for a blank or comment row."""
    text = row.strip()
    return None if not text or text.startswith("#") else text.rpartition(" ")[0]


def renamed_pairs(base):
    """The (old, new) paths of the renames in git diff -M --name-status <base>..HEAD, or None when git fails."""
    done = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "-c", "core.quotepath=false", "diff", "-M", "--name-status", "-z", f"{base}..HEAD"],
        capture_output=True, text=True,
    )
    if done.returncode != 0:
        return None
    fields, pairs, i = done.stdout.split("\0"), [], 0
    while i < len(fields) and fields[i]:
        if fields[i][0] == "R":
            pairs.append((fields[i + 1], fields[i + 2]))
        i += 3 if fields[i][0] in "RC" else 2
    return pairs


def apply_renames(base):
    """Re-key the baseline rows of the files that git shows renamed since base. Returns 0, or a nonzero
    status with the reasons printed and the baseline untouched."""
    pairs = renamed_pairs(base)
    if pairs is None:
        print(f"file-size: git diff -M --name-status {base}..HEAD failed, so no rename was read.", file=sys.stderr)
        return 2
    baseline = read_baseline()
    if baseline is None:
        print(f"file-size: no baseline recorded at {BASELINE_FILE}.", file=sys.stderr)
        return 1
    drop, add, notes, refusals = set(), {}, [], []
    for old, new in pairs:
        if old not in baseline:
            continue
        path = REPO_ROOT / new
        size = count_lines(path) if new.startswith("Sources/") and new.endswith(".swift") and path.is_file() else 0
        if new in baseline:
            refusals.append(f"  {old} -> {new}: the new path already has a baseline row")
        elif size > baseline[old]:
            refusals.append(f"  {old} -> {new}: {size} lines, longer than the recorded {baseline[old]}, and --renames never raises a number")
        elif size <= LIMIT:
            drop.add(old)
            notes.append(f"  {old} -> {new}: {size} lines, at or under {LIMIT}, so its row is dropped")
        else:
            drop.add(old)
            add[new] = size
            notes.append(f"  {old} -> {new}: {size} lines, was {baseline[old]}")
    if refusals:
        print("file-size: --renames refuses these renames and leaves the baseline as it was.", file=sys.stderr)
        for line in refusals:
            print(line, file=sys.stderr)
        return 1
    if drop:
        rows = [row for row in BASELINE_FILE.read_text(encoding="utf-8").splitlines() if baseline_path(row) not in drop]
        for new, size in sorted(add.items()):
            at = next((i for i, row in enumerate(rows) if (baseline_path(row) or "") > new), len(rows))
            rows.insert(at, f"{new} {size}")
        BASELINE_FILE.write_text("\n".join(rows) + "\n", encoding="utf-8")
    print(f"file-size: --renames re-keyed {len(drop)} baseline row(s).")
    for line in notes:
        print(line)
    return 0


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

    if "--renames" in argv:
        at = argv.index("--renames") + 1
        if at >= len(argv) or argv[at].startswith("--"):
            print("file-size: --renames needs a base commit, as in --renames <base>.", file=sys.stderr)
            return 2
        status = apply_renames(argv[at])
        if status != 0:
            return status

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
    import ratchet_baseline
    if "--renames" in sys.argv[1:]:
        sys.exit(main(sys.argv[1:]))
    sys.exit(ratchet_baseline.run(main, sys.argv[1:], BASELINE_FILE))
