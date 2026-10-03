#!/usr/bin/env python3
"""Verify that a git range only moves Swift lines between files.

Usage: verify_pure_move.py <repo> <base> <head>

Collects every removed and every added line in .swift files over the range
(git diff -U0, renames detected). Lines that are blank, `import` statements,
`// MARK:` lines and the leading `//` header block of a newly added file are
ignored. The remaining removed lines and added lines must match as
multisets, compared after stripping surrounding whitespace, so indentation
changes are tolerated. A `private let logger = Logger(...)` line that is
added more often than removed is reported as INFO, because a moved type may
need its own copy of a file-private logger.

Non-Swift files are listed as NOTE for the reviewer to read.
Exit 0 when the Swift lines match, 1 otherwise.
"""
import collections
import re
import subprocess
import sys

LOGGER = re.compile(r"^(private|fileprivate)\s+let\s+logger\s*=\s*Logger\(")


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], check=True,
                          capture_output=True, text=True).stdout


def ignorable(stripped):
    return (not stripped or stripped.startswith("import ")
            or stripped.startswith("@preconcurrency import ")
            or stripped.startswith("// MARK:"))


def main(argv):
    repo, base, head = argv[1:4]
    names = git(repo, "diff", "--name-status", "-M", f"{base}..{head}")
    added_files = set()
    for row in names.splitlines():
        parts = row.split("\t")
        if parts[0] == "A":
            added_files.add(parts[1])
        if not parts[-1].endswith(".swift"):
            print(f"NOTE non-Swift {parts[0]} {parts[-1]}")
    removed, added = collections.Counter(), collections.Counter()
    diff = git(repo, "diff", "-U0", "-M", f"{base}..{head}", "--", "*.swift")
    current, in_header = None, False
    for line in diff.splitlines():
        if line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else None
            current = path
            in_header = path in added_files
            continue
        if line.startswith("--- ") or line.startswith("@@") or line.startswith("diff ") \
                or line.startswith("index ") or line.startswith("new file") \
                or line.startswith("deleted file") or line.startswith("similarity") \
                or line.startswith("rename "):
            continue
        if line.startswith("+"):
            text = line[1:].strip()
            if in_header:
                if text.startswith("//") or not text:
                    continue
                in_header = False
            if ignorable(text):
                continue
            added[text] += 1
        elif line.startswith("-"):
            text = line[1:].strip()
            if ignorable(text):
                continue
            removed[text] += 1
    ok = True
    extra = added - removed
    missing = removed - added
    for text, n in sorted(extra.items()):
        if LOGGER.match(text):
            print(f"INFO logger copy x{n}: {text[:160]}")
            continue
        ok = False
        print(f"ADDED-NOT-REMOVED x{n}: {text[:160]}")
    for text, n in sorted(missing.items()):
        ok = False
        print(f"REMOVED-NOT-ADDED x{n}: {text[:160]}")
    print("PURE-MOVE OK" if ok else "NOT A PURE MOVE")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
