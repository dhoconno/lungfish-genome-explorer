#!/usr/bin/env python3
"""Verify that a git range only moves Swift lines between files.

Usage: verify_pure_move.py [--access-only] <repo> <base> <head>

Default mode proves a move commit. It collects every removed and every added
line in .swift files over the range (git diff -U0, renames detected). Lines
that are blank, `import` lines (the `@testable`, `@preconcurrency`, `public`,
`package` and `internal` forms too), `// MARK:` lines and the leading `//`
header block of a newly added file are ignored. The remaining removed lines
and added lines must match as multisets, compared after stripping surrounding
whitespace, so indentation changes are tolerated. Every access word stays as
it was, so a move that also widens `private` fails and the widening lands first.

Two things are tolerated and printed as INFO.
- A `private let logger = Logger(...)` line that is added more often than
  removed, because a moved type may need its own copy of a file-private logger.
- Left-over `extension Name {` lines and as many left-over bare `}` lines on
  one side, only when Name is declared or extended in a file the range changes,
  so a split of one extension over several files passes.

Run check. Per added file, the added lines are cut into maximal runs that are
consecutive in the removed lines of one hunk, and the bare `}` lines that follow
a run belong to it, since git may line a block's closing brace up with another
`}`. A run of fewer than 3 lines that is not made of bare `}` lines fails as
RUN-BREAK, so two swapped statements fail and a block split over several new
files passes. A move of fewer than 3 lines fails too. A reorder of whole members
is not caught, so it lands alone.

--access-only proves a widening commit alone. In each hunk the removed and added
lines pair one to one and in order, and a pair is equal once one access word
(private, fileprivate, internal, package, public or open, each with an optional
(set)) leaves the modifiers wherever it stands, as in `@objc private func` and
`private(set) var`. No word counts as internal. The added access must be wider
and must not be public or open as a new word. A removed and added pair that is
the same line is git's own merge of a hunk and is skipped. A pass prints
ACCESS-ONLY OK <n> widened. No flag relaxes the move check.

Non-Swift files are listed as NOTE for the reviewer to read, and so is the root
Package.swift, which the line check leaves out.
Exit 0 when the check passes, 1 when it fails, 2 on a usage error.
"""
import collections
import re
import subprocess
import sys

LOGGER = re.compile(r"^(private|fileprivate)\s+let\s+logger\s*=\s*Logger\(")
IMPORT = re.compile(r"^(@\w+(\(\w+\))?\s+)*((public|package|internal)\s+)?import\s")
EXTENSION = re.compile(r"^extension\s+([A-Za-z_][\w.]*)\s*\{$")
DECLARES = re.compile(r"\b(?:extension|class|struct|enum|actor|protocol)\s+([A-Za-z_][\w.]*)")
HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
MIN_RUN = 3
MANIFEST = "Package.swift"
DIFF = ["-c", "core.quotepath=false", "diff", "--no-color", "--no-ext-diff",
        "--src-prefix=a/", "--dst-prefix=b/"]


def git(repo, *args, check=True):
    done = subprocess.run(["git", "-C", repo, *args], check=check, capture_output=True,
                          encoding="utf-8", errors="replace")
    return done.stdout if done.returncode == 0 else ""


def ignorable(stripped):
    return (not stripped or IMPORT.match(stripped) is not None
            or stripped.startswith("// MARK:"))


def path_of(raw, prefix):
    raw = raw.rstrip("\t")
    if raw == "/dev/null":
        return None
    return raw[len(prefix):] if raw.startswith(prefix) else raw


def parse_hunks(text):
    """Every hunk of a -U0 diff as (old path, new path, new start, removed lines, added lines).

    The body of a hunk is read by the counts of its header, so a removed line that
    starts with `-- ` is never taken for a file header."""
    hunks, old_path, new_path, lines, i = [], None, None, text.splitlines(), 0
    while i < len(lines):
        line = lines[i]
        i += 1
        match = HUNK.match(line)
        if line.startswith("--- "):
            old_path = path_of(line[4:], "a/")
        elif line.startswith("+++ "):
            new_path = path_of(line[4:], "b/")
        elif match:
            old_n, new_n = int(match.group(2) or 1), int(match.group(4) or 1)
            removed, added = [], []
            while i < len(lines) and (len(removed) < old_n or len(added) < new_n):
                body = lines[i]
                if body.startswith("-") and len(removed) < old_n:
                    removed.append(body[1:])
                elif body.startswith("+") and len(added) < new_n:
                    added.append(body[1:])
                elif not body.startswith("\\"):
                    break
                i += 1
            hunks.append((old_path, new_path, int(match.group(3)), removed, added))
    return hunks


def name_status(repo, base, head):
    """The rows of git diff --name-status as (status, [old path, new path] or [path])."""
    out = git(repo, "-c", "core.quotepath=false", "diff", "--name-status", "-M", f"{base}..{head}")
    rows = []
    for row in out.splitlines():
        parts = row.split("\t")
        rows.append((parts[0], parts[1:]))
    return rows


def collect(hunks, added_files):
    """The removed lines as one list per hunk and the added lines as {path: [(line number, text)]},
    without the ignorable lines and without the header comment of a newly added file."""
    segments, added, started = [], {}, set()
    for _old, new_path, new_start, removed, plus in hunks:
        segment = [t for t in (raw.strip() for raw in removed) if not ignorable(t)]
        if segment:
            segments.append(segment)
        header = new_path in added_files and new_path not in started
        started.add(new_path)
        for offset, raw in enumerate(plus):
            text = raw.strip()
            if header:
                if text.startswith("//") or not text:
                    continue
                header = False
            if not ignorable(text):
                added.setdefault(new_path, []).append((new_start + offset, text))
    return segments, added


def declared_names(repo, rev, paths):
    """The type names that `extension`, `class`, `struct`, `enum`, `actor` and `protocol` name in the
    given files at rev, each as written and by its last component."""
    names = set()
    for path in sorted(paths):
        for name in DECLARES.findall(git(repo, "show", f"{rev}:{path}", check=False)):
            names.update({name, name.rsplit(".", 1)[-1]})
    return names


def wrapper_lines(leftover, names):
    """The left-over lines of one side that the move check tolerates: `extension Name {` lines whose
    Name is in names, and as many bare `}` lines, only when the two numbers are equal."""
    openers = collections.Counter()
    for text, n in leftover.items():
        match = EXTENSION.match(text)
        if match and (match.group(1) in names or match.group(1).rsplit(".", 1)[-1] in names):
            openers[text] = n
    count = sum(openers.values())
    if not count or leftover.get("}", 0) != count:
        return collections.Counter()
    openers["}"] = count
    return openers


def run_breaks(segments, added, dropped):
    """The runs of added lines that fail the run check, as (path, line, length, first line).

    Per added file the lines, less the tolerated `extension Name {` lines in dropped, are cut greedily
    into the longest runs that sit consecutively in one removed hunk. A run under MIN_RUN lines fails
    unless it is made of bare `}` lines. A line that no removed line matches is the multiset check's."""
    where = collections.defaultdict(list)
    for s, segment in enumerate(segments):
        for p, text in enumerate(segment):
            where[text].append((s, p))
    budget, problems = collections.Counter(dropped), []
    for path, rows in added.items():
        seq = []
        for line, text in rows:
            if budget[text] > 0:
                budget[text] -= 1
            else:
                seq.append((line, text))
        i = 0
        while i < len(seq):
            best = 0
            for s, p in where.get(seq[i][1], ()):
                segment, k = segments[s], 0
                while p + k < len(segment) and i + k < len(seq) and segment[p + k] == seq[i + k][1]:
                    k += 1
                best = max(best, k)
            if best == 0:
                i += 1
                continue
            run = best
            while i + run < len(seq) and seq[i + run][1] == "}":
                run += 1
            if run < MIN_RUN and any(text != "}" for _, text in seq[i:i + run]):
                problems.append((path, seq[i][0], run, seq[i][1]))
            i += run
    return problems


def check_move(repo, base, head, rows, hunks):
    added_files = {parts[0] for status, parts in rows if status == "A"}
    segments, added = collect(hunks, added_files)
    removed = collections.Counter(t for segment in segments for t in segment)
    plus = collections.Counter(t for lines in added.values() for _, t in lines)
    extra, missing = plus - removed, removed - plus
    dropped = collections.Counter()
    old_paths = {h[0] for h in hunks if h[0]}
    new_paths = {h[1] for h in hunks if h[1]}
    for side, leftover, rev, paths in (("added", extra, base, old_paths), ("removed", missing, head, new_paths)):
        if not any(EXTENSION.match(text) for text in leftover):
            continue
        wrappers = wrapper_lines(leftover, declared_names(repo, rev, paths))
        for text, n in sorted(wrappers.items()):
            print(f"INFO wrapper {side} x{n}: {text}")
        leftover.subtract(wrappers)
        leftover += collections.Counter()
        if side == "added":
            dropped = collections.Counter({t: n for t, n in wrappers.items() if t != "}"})
    ok = True
    for text, n in sorted(extra.items()):
        if LOGGER.match(text):
            print(f"INFO logger copy x{n}: {text[:160]}")
            continue
        ok = False
        print(f"ADDED-NOT-REMOVED x{n}: {text[:160]}")
    for text, n in sorted(missing.items()):
        ok = False
        print(f"REMOVED-NOT-ADDED x{n}: {text[:160]}")
    for path, line, length, text in run_breaks(segments, added, dropped):
        ok = False
        print(f"RUN-BREAK {path}:{line}: {length} line(s) in a row are not consecutive in the removed lines: {text[:120]}")
    print("PURE-MOVE OK" if ok else "NOT A PURE MOVE")
    return 0 if ok else 1


RANK = {"private": 0, "fileprivate": 1, "internal": 2, "package": 3, "public": 4, "open": 5}
ACCESS = re.compile(r"(private|fileprivate|internal|package|public|open)(\(set\))?(?![\w(])")
ATTRIBUTE = re.compile(r"@[A-Za-z_]\w*")
MODIFIER = re.compile(r"(?:static|class|final|override|required|convenience|dynamic|lazy|weak|unowned|"
                      r"mutating|nonmutating|indirect|nonisolated|isolated|distributed|optional|prefix|"
                      r"postfix|infix|consuming|borrowing)(?:\((?:unsafe|safe)\))?(?![\w(])")


def skip_parens(text, i):
    """The index after the parenthesis that closes the one at text[i], or -1."""
    depth, quoted = 0, False
    while i < len(text):
        c = text[i]
        if quoted:
            if c == "\\":
                i += 1
            elif c == '"':
                quoted = False
        elif c == '"':
            quoted = True
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return -1


def split_modifiers(line):
    """The access words, the other modifiers and attributes that open a declaration line, and the rest."""
    access, others, i = [], [], 0
    while i < len(line):
        if line[i] in " \t":
            i += 1
            continue
        match = ACCESS.match(line, i)
        if match:
            access.append(match.group(0))
            i = match.end()
            continue
        if line[i] == "@":
            match = ATTRIBUTE.match(line, i)
            if match is None:
                break
            j = match.end()
            if line.startswith("(", j):
                j = skip_parens(line, j)
                if j < 0:
                    break
            others.append(line[i:j])
            i = j
            continue
        match = MODIFIER.match(line, i)
        if match is None:
            break
        others.append(match.group(0))
        i = match.end()
    return access, others, line[i:].strip()


def levels(access):
    """(getter rank, setter rank) of the access words of one declaration, or None for words that
    cannot belong to one. No word counts as internal, and `private(set)` leaves the getter alone."""
    plain = [w for w in access if not w.endswith("(set)")]
    setter = [w for w in access if w.endswith("(set)")]
    if len(plain) > 1 or len(setter) > 1:
        return None
    getter_rank = RANK[plain[0]] if plain else RANK["internal"]
    return getter_rank, RANK[setter[0][:-5]] if setter else getter_rank


def widening_problem(before, after):
    """Why a removed and an added line are not a widening of one access word, or None when they are."""
    old_access, old_others, old_rest = split_modifiers(before.strip())
    new_access, new_others, new_rest = split_modifiers(after.strip())
    if before[:len(before) - len(before.lstrip())] != after[:len(after) - len(after.lstrip())]:
        return "indentation changed"
    if old_others != new_others or old_rest != new_rest:
        return "more than the access word changed"
    old, new = levels(old_access), levels(new_access)
    if old is None or new is None:
        return "more than one access word"
    if new[0] < old[0] or new[1] < old[1]:
        return "narrower access word"
    if new == old:
        return "the access did not widen"
    if any(n != o and n >= RANK["public"] for n, o in zip(new, old)):
        return "public or open as a new word"
    return None


def check_access_only(rows, hunks):
    problems, widened = [], 0
    for status, parts in rows:
        path = parts[-1]
        if path.endswith(".swift") and path != MANIFEST and not status.startswith("M"):
            problems.append(f"NOT-WIDENING {status} {path}: a widening commit only modifies files")
    for old_path, new_path, start, removed, added in hunks:
        path = new_path or old_path
        if len(removed) != len(added):
            problems.append(f"NOT-WIDENING {path}:{start}: {len(removed)} removed and {len(added)} added lines do not pair")
            continue
        for offset, (before, after) in enumerate(zip(removed, added)):
            if before == after:
                continue
            why = widening_problem(before, after)
            if why is None:
                widened += 1
            else:
                problems.append(f"NOT-WIDENING {path}:{start + offset}: {why}: -{before.strip()[:100]} +{after.strip()[:100]}")
    for problem in problems:
        print(problem)
    if problems:
        print("NOT AN ACCESS-ONLY WIDENING")
        return 1
    print(f"ACCESS-ONLY OK {widened} widened")
    return 0


def main(argv):
    flags = [a for a in argv[1:] if a.startswith("--")]
    args = [a for a in argv[1:] if not a.startswith("--")]
    if len(args) != 3 or any(flag != "--access-only" for flag in flags):
        print("usage: verify_pure_move.py [--access-only] <repo> <base> <head>", file=sys.stderr)
        return 2
    repo, base, head = args
    rows = name_status(repo, base, head)
    for status, parts in rows:
        if parts[-1] == MANIFEST:
            print(f"NOTE non-Swift {status} {MANIFEST} (left out of the line check, read its diff)")
        elif not parts[-1].endswith(".swift"):
            print(f"NOTE non-Swift {status} {parts[-1]}")
    hunks = parse_hunks(git(repo, *DIFF, "-U0", "-M", f"{base}..{head}", "--", "*.swift", f":(exclude){MANIFEST}"))
    if "--access-only" in flags:
        return check_access_only(rows, hunks)
    return check_move(repo, base, head, rows, hunks)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
