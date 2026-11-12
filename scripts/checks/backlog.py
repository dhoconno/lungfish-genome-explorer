#!/usr/bin/env python3
"""backlog.py - Hold the caps and the rules of the two backlog files.

docs/plans/BACKLOG.md holds, in at most 80 KB, a first section Results and data with
every open S1, S2 and probe row, then the section of the phase now and the section of
the next phase. A probe row is one whose rating waits on a measurement. The file
docs/plans/backlog-later.tsv holds every other open row, one row a line, with the tab
separated columns id, severity, field, effect, source, phase_filed and keep. The line
`Phase now: N` in the header of BACKLOG.md names the phase now. The rules are in
docs/contracts/SCOPE-AND-DELIVERY.md, row One backlog.

Usage:
    scripts/checks/backlog.py [--root DIR]
    scripts/checks/backlog.py [--root DIR] list --phase N [--later]
    scripts/checks/backlog.py [--root DIR] close ID COMMIT

With no command it checks and prints one line for each fault. `list` prints the rows of
a phase section, and with --later the later rows filed in that phase, as id, severity and
field. `close` removes a row from the file that holds it and prints the id and commit for
the commit message. Exit codes: 0 = no fault, 1 = a fault, or a close whose id is not
found exactly once, 2 = an unreadable file.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import NamedTuple

DEFAULT_ROOT = Path(__file__).resolve().parents[2]
BACKLOG = "docs/plans/BACKLOG.md"
LATER = "docs/plans/backlog-later.tsv"
BACKLOG_CAP = 80 * 1024
LATER_CAP = 450 * 1024
RESULTS = "Results and data"
HEADER = ["Id", "Effect on results or users", "Severity", "Field", "Source"]
COLUMNS = ["id", "severity", "field", "effect", "source", "phase_filed", "keep"]
KEEP = ("results", "data", "crash", "hang")
DONE = re.compile(r"(?:done|fixed|closed|landed)\b", re.I)
# A rating that waits on something not yet shown: the contract's `S? probe`, a word that
# says unmeasured, unread or unchecked, or a condition (if, until, once, the day).
CONDITIONAL = re.compile(
    r"S\?|\b(?:probe|if|until|once|pending|unrated|unknown|unmeasured|unverified|"
    r"unchecked|unread)\b|\bthe day\b",
    re.I,
)


class Row(NamedTuple):
    id: str
    severity: str
    field: str
    effect: str
    source: str
    file: str
    line: int
    section: str = ""
    phase_filed: str = ""
    keep: str = ""

    @property
    def where(self) -> str:
        return f"{self.file}:{self.line}"


def kind(severity: str) -> str:
    """Return S1, S2, probe or other for the text of a Severity cell.

    A quoted earlier rating is history, so it is dropped before the test."""
    text = re.sub(r'"[^"]*"', " ", severity).strip()
    if re.match(r"S1\b", text, re.I):
        return "S1"
    if re.match(r"S2\b", text, re.I):
        return "S2"
    return "probe" if CONDITIONAL.search(text) else "other"


def is_done(effect: str) -> bool:
    """True when an effect cell begins with Done, Fixed, Closed or Landed."""
    return DONE.match(effect.lstrip()) is not None


def table_cells(line: str):
    """Return the cells of a table line, or None when the line is not one."""
    text = line.strip()
    if not text.startswith("|"):
        return None
    body = text[1:]
    if body.endswith("|") and not body.endswith("\\|"):
        body = body[:-1]
    return [cell.strip() for cell in re.split(r"(?<!\\)\|", body)]


def parse_backlog(text: str, faults: list):
    """Return (header text, section names, rows) of BACKLOG.md."""
    header, sections, rows = [], [], []
    for number, line in enumerate(text.split("\n"), 1):
        if line.startswith("## "):
            sections.append(line[3:].strip())
            continue
        if not sections:
            header.append(line)
            continue
        cells = table_cells(line)
        if cells is None or all(re.fullmatch(r":?-{3,}:?", c) for c in cells):
            continue
        where = f"{BACKLOG}:{number}"
        if cells[0].lower() == "id":
            if cells != HEADER:
                faults.append(f"{where}: the table header must read | " + " | ".join(HEADER) + " |")
            continue
        if len(cells) != len(HEADER) or not cells[0]:
            faults.append(
                f"{where}: malformed row with {len(cells)} cells and id '{cells[0][:40]}' "
                f"(a row has {len(HEADER)} cells and an id, and a pipe inside a cell is written \\|)"
            )
            continue
        rows.append(Row(cells[0], cells[2], cells[3], cells[1], cells[4], BACKLOG, number, sections[-1]))
    return "\n".join(header), sections, rows


def parse_later(text: str, faults: list):
    """Return the rows of backlog-later.tsv."""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    head = "\t".join(COLUMNS)
    if not lines or lines[0] != head:
        faults.append(f"{LATER}:1: the first line must be the header {head!r}")
    rows = []
    for number, line in enumerate(lines[1:], 2):
        cells = line.split("\t")
        where = f"{LATER}:{number}"
        if len(cells) != len(COLUMNS) or not cells[0]:
            faults.append(
                f"{where}: malformed row with {len(cells)} cells and id '{cells[0][:40]}' "
                f"(a row has {len(COLUMNS)} tab separated cells and an id)"
            )
        elif not cells[5].isdigit() or cells[6] not in ("",) + KEEP:
            faults.append(
                f"{where}: {cells[0]}: phase_filed must be a number and keep must be empty "
                f"or one of {', '.join(KEEP)}"
            )
        else:
            rows.append(Row(cells[0], cells[1], cells[2], cells[3], cells[4], LATER, number, "", cells[5], cells[6]))
    return rows


def check(root: Path):
    """Return (faults, rows in BACKLOG.md, rows in backlog-later.tsv)."""
    faults: list = []
    texts = {}
    for rel, cap in ((BACKLOG, BACKLOG_CAP), (LATER, LATER_CAP)):
        path = root / rel
        if not path.is_file():
            faults.append(f"{rel}: file not found")
            continue
        raw = path.read_bytes()
        if len(raw) > cap:
            faults.append(f"{rel}: {len(raw)} bytes, over the {cap}-byte cap")
        texts[rel] = raw.decode("utf-8")
    rows, later, now = [], [], None
    if BACKLOG in texts:
        header, sections, rows = parse_backlog(texts[BACKLOG], faults)
        found = re.search(r"^Phase now:[ \t]*(\d+)[ \t]*$", header, re.M)
        now = int(found.group(1)) if found else None
        if now is None:
            faults.append(f"{BACKLOG}: the header needs a line 'Phase now: N'")
        if not sections or sections[0] != RESULTS:
            faults.append(f"{BACKLOG}: the first section must be '## {RESULTS}'")
    if LATER in texts:
        later = parse_later(texts[LATER], faults)
    for row in rows + later:
        if is_done(row.effect):
            faults.append(
                f"{row.where}: {row.id}: begins with a done word, so delete the row "
                "(the commit that closes it is its record)"
            )
    for row in rows:
        group = kind(row.severity)
        if row.section == RESULTS and group == "other":
            faults.append(
                f"{row.where}: {row.id}: rated '{row.severity[:40]}', but {RESULTS} "
                "holds only S1, S2 and probe rows"
            )
        elif row.section != RESULTS and group != "other":
            faults.append(f"{row.where}: {row.id}: {group} rows belong in {RESULTS}")
    for row in later:
        group = kind(row.severity)
        if group != "other":
            faults.append(f"{row.where}: {row.id}: {group} rows belong in BACKLOG.md under {RESULTS}")
        if now is not None and not row.keep and now - int(row.phase_filed) >= 2:
            faults.append(
                f"{row.where}: {row.id}: filed in phase {row.phase_filed}, two or more phases "
                f"before phase {now}, with keep empty (close it, or set keep to {', '.join(KEEP)})"
            )
    seen: dict = {}
    for row in rows + later:
        if row.id in seen:
            faults.append(f"{row.where}: {row.id}: appears twice, also at {seen[row.id]}")
        else:
            seen[row.id] = row.where
    return faults, len(rows), len(later)


def load_rows(root: Path):
    """Return (BACKLOG.md rows, backlog-later.tsv rows) and ignore faults."""
    sink: list = []
    rows, later = [], []
    path = root / BACKLOG
    if path.is_file():
        rows = parse_backlog(path.read_bytes().decode("utf-8"), sink)[2]
    path = root / LATER
    if path.is_file():
        later = parse_later(path.read_bytes().decode("utf-8"), sink)
    return rows, later


def cmd_list(root: Path, phase: int, with_later: bool) -> int:
    rows, later = load_rows(root)
    picked = [row for row in rows if row.section == f"Phase {phase}"]
    if with_later:
        picked += [row for row in later if int(row.phase_filed) == phase]
    for row in picked:
        print(f"{row.id}  {row.severity}  {row.field}")
    return 0


def cmd_close(root: Path, row_id: str, commit: str) -> int:
    if not commit or re.search(r"\s", commit):
        print("backlog: close needs the commit as one word", file=sys.stderr)
        return 2
    rows, later = load_rows(root)
    hits = [row for row in rows + later if row.id == row_id]
    if len(hits) != 1:
        print(f"backlog: {row_id}: found {len(hits)} times, expected exactly once", file=sys.stderr)
        return 1
    row = hits[0]
    path = root / row.file
    lines = path.read_bytes().decode("utf-8").split("\n")
    del lines[row.line - 1]
    path.write_bytes("\n".join(lines).encode("utf-8"))
    print(f"Backlog: {row.id} closed by {commit}")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Hold the caps and the rules of the two backlog files.")
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="repository root")
    sub = parser.add_subparsers(dest="command")
    sub.add_parser("check", help="check both files (the default)")
    listing = sub.add_parser("list", help="print the rows of one phase section")
    listing.add_argument("--phase", type=int, required=True)
    listing.add_argument("--later", action="store_true", help="also the later rows filed in that phase")
    closing = sub.add_parser("close", help="remove a closed row from the file that holds it")
    closing.add_argument("id")
    closing.add_argument("commit")
    args = parser.parse_args(argv)
    try:
        if args.command == "list":
            return cmd_list(args.root, args.phase, args.later)
        if args.command == "close":
            return cmd_close(args.root, args.id, args.commit)
        faults, n_rows, n_later = check(args.root)
    except (OSError, UnicodeDecodeError) as error:
        print(f"backlog: {error}", file=sys.stderr)
        return 2
    for fault in faults:
        print(f"backlog: {fault}", file=sys.stderr)
    if faults:
        return 1
    print(f"backlog: ok ({n_rows} rows in BACKLOG.md, {n_later} in backlog-later.tsv)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
