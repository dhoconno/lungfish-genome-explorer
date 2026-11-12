#!/usr/bin/env python3
"""put_state.py NOTES.md STATE.md [--max-bytes 3072]

Replace the STATE block of a session notes file with the text of a state file.

The STATE block starts at the first line that begins with "## STATE" and runs to
the next line that begins with "## ", or to the end of the file. STATE.md holds
the new block. When its first line is not a "## STATE" heading, the script puts
"## STATE" above it. A notes file without a STATE block gets the new block under
its title line.

Prints "STATE block written, <n> bytes" and exits 0. Exits 2 and leaves the notes
file as it was when a file cannot be read, the new block is empty, or the block is
over --max-bytes (default 3072). The notes file is replaced in one step, with its
file mode kept.

Serves docs/contracts/RUNNING-A-PHASE-SESSION.md, section "Files the session
keeps", the row for the notes file (a STATE block of about 40 lines, rewritten at
every landing and launch).
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import tempfile

HEADING = re.compile(r"^## STATE(\s|$)")


def build_block(text: str) -> str:
    """The new block: the text with a STATE heading on top and one final newline."""
    body = text.strip("\n")
    if body and not HEADING.match(body.split("\n", 1)[0]):
        body = "## STATE\n" + body
    return body + "\n" if body else ""


def replace_block(notes: str, block: str) -> str:
    """The notes text with its first STATE block replaced, or the block put under the title."""
    lines = notes.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    new = block.rstrip("\n").split("\n")
    start = next((i for i, line in enumerate(lines) if HEADING.match(line)), None)
    if start is None:
        head = lines[:1] if lines and lines[0].startswith("# ") else []
        rest = lines[len(head):]
        while rest and rest[0] == "":
            rest = rest[1:]
        out = head + ([""] if head else []) + new + ([""] + rest if rest else [])
    else:
        end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
        out = lines[:start] + new + ([""] + lines[end:] if end < len(lines) else [])
    return "\n".join(out) + "\n"


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="put_state.py", description="Replace the STATE block of a notes file.")
    parser.add_argument("notes", help="the session notes file")
    parser.add_argument("state", help="a file that holds the new STATE block")
    parser.add_argument("--max-bytes", type=int, default=3072, help="largest block in bytes (default 3072)")
    args = parser.parse_args(argv)
    try:
        with open(args.notes, encoding="utf-8") as handle:
            notes = handle.read()
        with open(args.state, encoding="utf-8") as handle:
            state = handle.read()
    except OSError as error:
        print("put_state: refused: cannot read %s" % error, file=sys.stderr)
        return 2
    block = build_block(state)
    size = len(block.encode("utf-8"))
    if not block:
        print("put_state: refused: %s holds no text" % args.state, file=sys.stderr)
        return 2
    if size > args.max_bytes:
        print("put_state: refused: the block is %d bytes, over the limit of %d" % (size, args.max_bytes), file=sys.stderr)
        return 2
    directory = os.path.dirname(os.path.abspath(args.notes))
    mode = os.stat(args.notes).st_mode & 0o7777
    descriptor, temporary = tempfile.mkstemp(dir=directory, prefix=".put_state.")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(replace_block(notes, block))
        os.chmod(temporary, mode)
        os.replace(temporary, args.notes)
    except OSError as error:
        if os.path.exists(temporary):
            os.unlink(temporary)
        print("put_state: refused: cannot write %s" % error, file=sys.stderr)
        return 2
    print("STATE block written, %d bytes" % size)
    return 0


if __name__ == "__main__":
    sys.exit(main())
