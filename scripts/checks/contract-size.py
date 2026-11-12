#!/usr/bin/env python3
"""contract-size.py - Hold the byte caps of the contracts and the guides that agents load.

The row Contracts of docs/contracts/SCOPE-AND-DELIVERY.md says the caps are in bytes
(1 KB is 1,024 bytes), that this script holds them and that a file over its cap may only
shrink. The file scripts/checks/contract-size.baseline has one line for each file that is
over its cap, `<path> <cap bytes> <baseline bytes>`, sorted by path. The covered files are
AGENTS.md, docs/contracts/*.md, Sources/*/AGENTS.md and .claude/agents/*.md, and their
caps are set below.

Usage:
    scripts/checks/contract-size.py [--root DIR]
    scripts/checks/contract-size.py [--root DIR] --update
    scripts/checks/contract-size.py [--root DIR] --print

With no option it prints one line for each fault and exits 1 when a file over its cap is
larger than its baseline, a file over its cap has no baseline line, a baseline line names
a file that is gone or now at or under its cap, or a baseline line holds another cap than
this script. --update rewrites the baseline from the tree. It lowers a line to the size of
its file, removes a stale line, never raises a line and never adds one, except that it
writes a first baseline when the file does not exist. --print lists every covered file with
its size, cap and state. Exit codes: 0 = no fault, 1 = a fault or a refused update,
2 = an unreadable file.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Dict, List, NamedTuple, Optional, Tuple

DEFAULT_ROOT = Path(__file__).resolve().parents[2]
BASELINE = "scripts/checks/contract-size.baseline"
KB = 1024
GLOBS = ("AGENTS.md", "Sources/*/AGENTS.md", ".claude/agents/*.md", "docs/contracts/*.md")
ROOT_GUIDE_KB = 6
MODULE_GUIDE_KB = 12
AGENT_TYPE_KB = 6
OTHER_CONTRACT_KB = 20
CONTRACT_KB = {
    "SCOPE-AND-DELIVERY.md": 10,
    "OWNER-DIRECTIONS.md": 6,
    "RUNNING-A-PHASE-SESSION.md": 12,
    "VERIFICATION-ORDER.md": 12,
    "EXPERT-PANEL.md": 10,
    "MACHINES.md": 12,
    "analysis-surface-checklist.md": 10,
    "README.md": 6,
}
FAULT_STATES = ("NEW", "GROWN", "STALE", "GONE", "CAP")
Line = Tuple[int, int]  # the cap and the baseline bytes of one baseline line


class Row(NamedTuple):
    path: str
    size: Optional[int]
    cap: int
    line: Optional[Line]
    state: str


def cap_of(path: str) -> int:
    """The cap in bytes of a covered file, from its place in the tree."""
    if path == "AGENTS.md":
        return ROOT_GUIDE_KB * KB
    if path.startswith("Sources/"):
        return MODULE_GUIDE_KB * KB
    if path.startswith(".claude/agents/"):
        return AGENT_TYPE_KB * KB
    return CONTRACT_KB.get(path.rsplit("/", 1)[-1], OTHER_CONTRACT_KB) * KB


def covered(root: Path) -> Dict[str, int]:
    """Map each covered file, as a path from the root with forward slashes, to its bytes."""
    found: Dict[str, int] = {}
    for pattern in GLOBS:
        for path in root.glob(pattern):
            if path.is_file():
                found[path.relative_to(root).as_posix()] = path.stat().st_size
    return found


def read_baseline(path: Path) -> Tuple[Dict[str, Line], List[str]]:
    """Return the lines of the baseline by path and a fault for each line that is malformed."""
    lines: Dict[str, Line] = {}
    faults: List[str] = []
    if not path.is_file():
        return lines, faults
    for number, raw in enumerate(path.read_bytes().decode("utf-8").splitlines(), 1):
        fields = raw.rsplit(" ", 2)
        if len(fields) != 3 or not fields[0] or not (fields[1].isdigit() and fields[2].isdigit()):
            faults.append(f"{BASELINE}:{number}: expected `<path> <cap bytes> <baseline bytes>`, found {raw!r}")
        elif fields[0] in lines:
            faults.append(f"{BASELINE}:{number}: {fields[0]} has a second line")
        else:
            lines[fields[0]] = (int(fields[1]), int(fields[2]))
    return lines, faults


def state_of(size: Optional[int], cap: int, line: Optional[Line]) -> str:
    """Name where a file stands. Lower case states are fine and upper case states are faults."""
    if size is None:
        return "GONE"
    if size <= cap:
        return "under" if line is None else "STALE"
    if line is None:
        return "NEW"
    if size > line[1]:
        return "GROWN"
    if line[0] != cap:
        return "CAP"
    return "held" if size == line[1] else "shrunk"


def describe(row: Row) -> str:
    """One line that says what is wrong with a row in a fault state."""
    path, size, cap, line = row.path, row.size, row.cap, row.line
    if row.state == "NEW":
        return f"{path} is {size} bytes, over its cap of {cap}, and has no line in {BASELINE}"
    if row.state == "GROWN":
        return (f"{path} is {size} bytes, over its cap of {cap} and larger than its baseline of "
                f"{line[1]} (a file over its cap may only shrink)")
    if row.state == "STALE":
        return f"{path} is {size} bytes, at or under its cap of {cap}, so its line in {BASELINE} must go (run --update)"
    if row.state == "CAP":
        return f"{path} has the cap {line[0]} in {BASELINE} but {cap} in this script (run --update)"
    return f"{BASELINE} names {path}, which is gone or not a covered file (run --update)"


def survey(root: Path) -> Tuple[List[Row], List[str]]:
    """Return a row for each covered file and each baseline line, and the malformed line faults."""
    files = covered(root)
    lines, faults = read_baseline(root / BASELINE)
    rows = []
    for path in sorted(set(files) | set(lines)):
        size, line, cap = files.get(path), lines.get(path), cap_of(path)
        rows.append(Row(path, size, cap, line, state_of(size, cap, line)))
    return rows, faults


def cmd_check(root: Path) -> int:
    rows, faults = survey(root)
    faults += [describe(row) for row in rows if row.state in FAULT_STATES]
    for fault in faults:
        print(f"contract-size: {fault}", file=sys.stderr)
    if faults:
        return 1
    over = sum(1 for row in rows if row.line is not None)
    print(f"contract-size: ok ({len(rows)} covered files, {over} over their caps at their baselines)")
    return 0


def cmd_update(root: Path) -> int:
    path = root / BASELINE
    rows, faults = survey(root)
    for fault in faults:
        print(f"contract-size: {fault}", file=sys.stderr)
    if faults:
        return 1
    first = not path.is_file()
    keep: Dict[str, Line] = {}
    refused: List[str] = []
    for row in rows:
        if row.state in ("held", "shrunk", "CAP"):
            keep[row.path] = (row.cap, row.size)
            if row.size < row.line[1]:
                print(f"contract-size: lowered {row.path} from {row.line[1]} to {row.size}")
            if row.line[0] != row.cap:
                print(f"contract-size: set the cap of {row.path} to {row.cap}")
        elif row.state == "GROWN" or (row.state == "NEW" and not first):
            if row.line is not None:
                keep[row.path] = row.line
            refused.append(describe(row))
        elif row.state == "NEW":
            keep[row.path] = (row.cap, row.size)
        elif row.state in ("STALE", "GONE"):
            print(f"contract-size: removed the line of {row.path}")
    text = "".join(f"{name} {cap} {size}\n" for name, (cap, size) in sorted(keep.items()))
    old = path.read_bytes().decode("utf-8") if path.is_file() else None
    if text != old:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text.encode("utf-8"))
    for fault in refused:
        print(f"contract-size: refused to raise the baseline: {fault}", file=sys.stderr)
    print(f"contract-size: baseline {'rewritten' if text != old else 'unchanged'} ({len(keep)} lines)")
    return 1 if refused else 0


def cmd_print(root: Path) -> int:
    rows, faults = survey(root)
    for fault in faults:
        print(f"contract-size: {fault}", file=sys.stderr)
    print(f"{'state':<7} {'bytes':>8} {'cap':>7} {'baseline':>8}  path")
    for row in rows:
        size = "-" if row.size is None else row.size
        base = "-" if row.line is None else row.line[1]
        print(f"{row.state:<7} {size:>8} {row.cap:>7} {base:>8}  {row.path}")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Hold the byte caps of the contracts and the guides.")
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="repository root")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--update", action="store_true", help="lower or remove baseline lines, never raise or add one")
    mode.add_argument("--print", action="store_true", dest="listing", help="list every covered file")
    args = parser.parse_args(argv)
    try:
        if args.update:
            return cmd_update(args.root)
        if args.listing:
            return cmd_print(args.root)
        return cmd_check(args.root)
    except (OSError, UnicodeDecodeError) as error:
        print(f"contract-size: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
