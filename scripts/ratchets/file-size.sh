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
    scripts/ratchets/file-size.sh --raise <path> --lane <LANE-ID>
                                               # raise one baselined row to the file's current length
    scripts/ratchets/file-size.sh --range <base>..<head>
                                               # fail a commit that only removes blank lines or joins lines

--renames reads `git diff -M --name-status <base>..HEAD`. A baselined file that the
diff shows renamed moves its row to the new path with the same number, or with the
file's length when that is lower, and a renamed file of 800 lines or fewer drops its
row. It refuses, with the baseline untouched, a rename whose file is longer than the
recorded number or whose new path already has a row. It adds a row for nothing else,
so a new oversize file still fails the check that follows. Like --update it writes
the baseline in a read-only run and skips the automatic lowering, since a lane asks
for it by name. The blanket --update stays as it is.

--raise is the landing's tool when a baselined file grew in a fix or rider lane (row File sizes of
docs/contracts/SCOPE-AND-DELIVERY.md). It raises the row of <path> to the file's current length and prints
one line, `<path> <old> -> <new> <LANE-ID>`, for the fold commit's message. That line is all it prints to
stdout, and it changes no other row, not even the row of a file that has since shrunk. <path> is relative to
the repository root, as in the baseline. It refuses, with the baseline untouched, a path with no row, a
file that is missing or shorter than its row, and a call with no path or no lane id. Like --update it
writes the baseline in a read-only run and skips the automatic lowering, since a lane asks for it by name.
A file as long as its row keeps the row, and the line shows the same number twice.

--range reads the commits of `git rev-list --no-merges <base>..<head>` and fails, naming each commit and
file, on a commit whose change to a Sources/ Swift file with a baseline row is only removed blank lines or
only joined lines. A file has a row when the baseline at <base> or the baseline file now names it. The test
of "only" compares the whole file before and after the commit and needs the new file to have fewer lines
than the old one. The change is only removed blank lines when the non-blank lines are the same lines in the
same order. It is only joined lines when the text is the same once all white space is ignored, so a call
folded onto one line counts. A commit that adds, removes or edits any other text in the file passes, so a
blank line removed beside a real change is allowed. The check reads git and writes no file.

Exit codes: 0 = no new oversize file and no baselined file grew, 1 = violation, a refused --raise or a
commit that --range fails, 2 = --renames, --raise or --range could not read its arguments or its base.
"""
import os
import re
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


def option_word(argv, flag):
    """The word after flag in argv, "" when nothing or another flag follows it, None when flag is absent."""
    if flag not in argv:
        return None
    at = argv.index(flag) + 1
    return argv[at] if at < len(argv) and not argv[at].startswith("--") else ""


def repo_relative(word):
    """A path word as the posix path relative to the repository root that the baseline rows use."""
    path = Path(word)
    if path.is_absolute():
        try:
            path = Path(os.path.realpath(path)).relative_to(REPO_ROOT)
        except ValueError:
            pass
    return path.as_posix()


def raise_row(word, lane):
    """Raise the one baseline row of the file `word` to the file's current length and print the line
    `<path> <old> -> <new> <lane>`. Returns 0, or a nonzero status with the reason printed and the
    baseline untouched. No other row changes."""
    recorded = read_baseline()
    if recorded is None:
        print(f"file-size: no baseline recorded at {BASELINE_FILE}.", file=sys.stderr)
        return 1
    rel = repo_relative(word)
    if rel not in recorded:
        print(f"file-size: --raise refuses {rel}: it has no baseline row. "
              f"A new file over {LIMIT} lines is split, not raised.", file=sys.stderr)
        return 1
    path = REPO_ROOT / rel
    old = recorded[rel]
    size = count_lines(path) if path.is_file() else 0
    if size < old:
        shown = f"{size} lines" if path.is_file() else "no file"
        print(f"file-size: --raise refuses {rel}: {shown}, shorter than the recorded {old}, "
              f"so its row is lowered, not raised.", file=sys.stderr)
        return 1
    if size > old:
        rows = []
        for row in BASELINE_FILE.read_bytes().decode("utf-8").splitlines(keepends=True):
            if baseline_path(row) == rel:
                row = f"{rel} {size}" + row[len(row.rstrip("\r\n")):]
            rows.append(row)
        BASELINE_FILE.write_bytes("".join(rows).encode("utf-8"))
    print(f"{rel} {old} -> {size} {lane}")
    return 0


def text_lines(text):
    """The lines of text, split on newlines only, as count_lines counts them."""
    lines = text.split("\n")
    if lines[-1] == "":
        lines.pop()
    return lines


def squeeze_kind(old, new):
    """What a change from old to new only does to the line count, or None when it does anything more.
    "removes blank lines" when the non-blank lines are the same lines in the same order, "joins lines"
    when only the text is the same once white space is ignored. The new text must have fewer lines."""
    before, after = text_lines(old), text_lines(new)
    if len(after) >= len(before) or "".join(old.split()) != "".join(new.split()):
        return None
    same = [line for line in before if line.strip()] == [line for line in after if line.strip()]
    return "removes blank lines" if same else "joins lines"


def git_run(*args):
    return subprocess.run(["git", "-C", str(REPO_ROOT), "-c", "core.quotepath=false", *args], capture_output=True)


def blob(rev, path):
    """The text of path at rev, or None when git has no such file there."""
    done = git_run("show", f"{rev}:{path}")
    return done.stdout.decode("utf-8", errors="replace") if done.returncode == 0 else None


def check_range(spec):
    """Fail on a commit of base..head whose change to a baselined Swift file only removes blank lines or only
    joins lines. Returns 0, 1 with the commits named, or 2 when the range cannot be read."""
    base, dots, head = spec.partition("..")
    if not dots or not base or not head or head.startswith("."):
        print(f"file-size: --range needs <base>..<head>, as in --range origin/main..HEAD, and got {spec}.", file=sys.stderr)
        return 2
    listed = git_run("rev-list", "--reverse", "--no-merges", spec, "--")
    if listed.returncode != 0:
        print(f"file-size: git rev-list {spec} failed, so no commit was read.", file=sys.stderr)
        return 2
    commits = listed.stdout.decode().split()
    rows = set(read_baseline() or {})
    at_base = blob(base, BASELINE_FILE.relative_to(REPO_ROOT).as_posix())
    rows |= {baseline_path(row) for row in (at_base or "").splitlines()} - {None}
    changes, found = 0, []
    for commit in commits:
        diff = git_run("diff-tree", "-r", "--root", "--no-commit-id", "--no-renames", "--name-status", "-z", commit)
        fields = diff.stdout.decode("utf-8", errors="replace").split("\0")
        for status, path in zip(fields[0::2], fields[1::2]):
            if status != "M" or path not in rows:
                continue
            old, new = blob(f"{commit}^", path), blob(commit, path)
            if old is None or new is None:
                continue
            changes += 1
            kind = squeeze_kind(old, new)
            if kind:
                found.append((commit, path, kind, len(text_lines(old)), len(text_lines(new))))
    if found:
        print(f"file-size: {len(found)} change(s) in {spec} only remove blank lines or join lines in a baselined "
              f"file. No commit does that to hold a count (row File sizes of docs/contracts/SCOPE-AND-DELIVERY.md). "
              f"Extract code instead.", file=sys.stderr)
        for commit, path, kind, before, after in found:
            print(f"  {commit} {path}: only {kind}, {before} lines to {after}", file=sys.stderr)
        return 1
    print(f"file-size: --range {spec} read {len(commits)} commit(s) and {changes} change(s) to baselined files, "
          f"and none only removes blank lines or joins lines.")
    return 0


def main(argv):
    if "--raise" in argv:
        word, lane = option_word(argv, "--raise"), option_word(argv, "--lane")
        if not word:
            print("file-size: --raise needs a path, as in --raise <path> --lane <LANE-ID>.", file=sys.stderr)
            return 2
        if not lane or not re.fullmatch(r"[^\s-]\S*", lane):
            print("file-size: --raise needs a lane id of one word that does not start with -, "
                  "as in --raise <path> --lane <LANE-ID>.", file=sys.stderr)
            return 2
        return raise_row(word, lane)

    if "--range" in argv:
        spec = option_word(argv, "--range")
        if not spec:
            print("file-size: --range needs <base>..<head>, as in --range origin/main..HEAD.", file=sys.stderr)
            return 2
        return check_range(spec)

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
    if any(flag in sys.argv[1:] for flag in ("--renames", "--raise", "--range")):
        sys.exit(main(sys.argv[1:]))
    sys.exit(ratchet_baseline.run(main, sys.argv[1:], BASELINE_FILE))
