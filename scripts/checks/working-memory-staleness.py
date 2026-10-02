#!/usr/bin/env python3
"""working-memory-staleness.py - Flag working-memory docs that look finished or stale.

docs/README.md calls plans, specs, issue notes and verification notes agent working
memory. The rule is to delete them in the commit that finishes the work they describe,
because git history is the record. Review finding R5 found 33 plans and 16 specs that
had piled up for shipped work, and grep returned them next to live code. This check
makes the rule mechanical so the pile cannot grow back.

Scanned files are every `*.md` below these directories, relative to the repo root.
  all three rules   docs/superpowers/plans, docs/superpowers/specs, docs/plans,
                    docs/product-specs, docs/proposals, docs/issues, docs/verification
  rule 1 only       docs/reports (a report is evidence and may outlive its plan)
docs/features is not scanned. docs/README.md lists it as working memory, but its files
are living feature documents.

Rules. Each finding prints as `<path>: <rule>: <message>`.
  finished-status    A Status line in the first 25 lines names a finished state. The
                     finished words are done, shipped, complete, completed, implemented,
                     merged, released, resolved, closed, verified, passed, pass,
                     superseded, delivered, landed, fixed, finished, abandoned, obsolete
                     and withdrawn. The Status line may be `Status: ...`,
                     `**Status:** ...`, `**Status: ...**`, `Status 2026-07-05: ...` or a
                     `## Status` heading followed by text. A word is ignored when not,
                     never, no, nothing, none, until, before, once, when, after, if or
                     unless comes earlier in the same clause, so `Status: not yet merged`
                     passes. Delete the file, or change the Status line if the work is
                     still open.
  all-steps-done     At least 3 checkbox steps and every one is ticked.
  stale-no-status    No Status line and the file is older than --max-age-days (default
                     14). Age comes from the YYYY-MM-DD- prefix of the file name, or
                     else from the last commit that touched the file, and the rule is
                     skipped when neither is known. A plan that is still live declares
                     `Status: active` in its first lines.

Allowlist at scripts/checks/working-memory-staleness.allowlist. Each entry is one line
shaped as `<path>  # reason`. A path ending in `/` exempts everything below that
directory. Use an entry only for a deliberate exception, such as a document that code or
a test reads, and give the reason. An entry that matches no file prints a warning and
does not fail the check.

Usage
    scripts/checks/working-memory-staleness.py
    scripts/checks/working-memory-staleness.py --root DIR --allowlist FILE \\
        --today YYYY-MM-DD --max-age-days N

Exit codes. 0 means nothing looks finished or stale. 1 means at least one finding.
"""
from __future__ import annotations

import argparse
import datetime as dt
import re
import subprocess
import sys
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ALLOWLIST = Path(__file__).resolve().with_suffix(".allowlist")
DEFAULT_MAX_AGE_DAYS = 14

ALL_RULES_DIRS = (
    "docs/superpowers/plans",
    "docs/superpowers/specs",
    "docs/plans",
    "docs/product-specs",
    "docs/proposals",
    "docs/issues",
    "docs/verification",
)
STATUS_ONLY_DIRS = ("docs/reports",)

STATUS_WINDOW = 25
FINISHED = re.compile(
    r"\b(done|shipped|complete|completed|implemented|merged|released|resolved|closed|"
    r"verified|passed|pass|superseded|delivered|landed|fixed|finished|abandoned|"
    r"obsolete|withdrawn)\b",
    re.IGNORECASE,
)
NEGATION = re.compile(
    r"\b(not|never|no|nothing|none|until|before|once|when|after|if|unless)\b",
    re.IGNORECASE,
)
CLAUSE_END = re.compile(r"[.;:!?]")
STATUS_LINE = re.compile(r"^[\s>*_#-]*status\b[^:\n]{0,16}:\s*(.*)$", re.IGNORECASE)
STATUS_HEADING = re.compile(r"^\s*#{1,6}\s*status\s*$", re.IGNORECASE)
CHECKBOX = re.compile(r"^\s*[-*+]\s+\[([ xX])\]\s")
DATE_PREFIX = re.compile(r"^(\d{4})-(\d{2})-(\d{2})-")


def read_allowlist(path: Path) -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []
    if not path.exists():
        return entries
    for line in path.read_text(encoding="utf-8").splitlines():
        body, _, reason = line.partition("#")
        entry = body.strip()
        if entry:
            entries.append((entry, reason.strip()))
    return entries


def is_allowed(rel: str, entries: list[tuple[str, str]]) -> bool:
    for entry, _ in entries:
        if entry.endswith("/"):
            if rel.startswith(entry):
                return True
        elif rel == entry:
            return True
    return False


def markdown_files(root: Path, directories) -> list[Path]:
    found: list[Path] = []
    for directory in directories:
        base = root / directory
        if base.is_dir():
            found.extend(sorted(p for p in base.rglob("*.md") if p.is_file()))
    return found


def status_text(lines: list[str]) -> str | None:
    """Return the text of the Status line in the first lines, or None when there is none."""
    window = lines[:STATUS_WINDOW]
    for index, line in enumerate(window):
        match = STATUS_LINE.match(line)
        if match:
            return match.group(1).strip().strip("*_ ")
        if STATUS_HEADING.match(line):
            for following in window[index + 1:]:
                if following.strip():
                    return following.strip()
            return ""
    return None


def finished_word(text: str) -> str | None:
    """First finished-state word that no negation precedes in its own clause."""
    for match in FINISHED.finditer(text):
        clause = CLAUSE_END.split(text[: match.start()])[-1]
        if NEGATION.search(clause):
            continue
        return match.group(1)
    return None


def checklist_all_done(lines: list[str]) -> bool:
    boxes = [m.group(1) for m in (CHECKBOX.match(line) for line in lines) if m]
    return len(boxes) >= 3 and all(box in "xX" for box in boxes)


def file_date(path: Path, rel: str, root: Path) -> dt.date | None:
    match = DATE_PREFIX.match(path.name)
    if match:
        try:
            return dt.date(*(int(part) for part in match.groups()))
        except ValueError:
            return None
    try:
        out = subprocess.run(
            ["git", "-C", str(root), "log", "-1", "--format=%cs", "--", rel],
            capture_output=True,
            text=True,
            check=False,
        ).stdout.strip()
        return dt.date.fromisoformat(out) if out else None
    except (OSError, ValueError):
        return None


def check(root: Path, allow, today: dt.date, max_age_days: int):
    findings: list[tuple[str, str, str]] = []
    scanned: set[str] = set()
    for directories, all_rules in ((ALL_RULES_DIRS, True), (STATUS_ONLY_DIRS, False)):
        for path in markdown_files(root, directories):
            rel = path.relative_to(root).as_posix()
            scanned.add(rel)
            if is_allowed(rel, allow):
                continue
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
            status = status_text(lines)
            if status is not None:
                word = finished_word(status)
                if word:
                    findings.append((rel, "finished-status", f"Status line says '{word}', delete the file or fix the line"))
            if not all_rules:
                continue
            if checklist_all_done(lines):
                findings.append((rel, "all-steps-done", "every checkbox step is ticked, delete the file"))
            if status is None:
                date = file_date(path, rel, root)
                if date is not None:
                    age = (today - date).days
                    if age > max_age_days:
                        findings.append((
                            rel,
                            "stale-no-status",
                            f"{age} days old with no Status line, delete it if the work shipped or add 'Status: active'",
                        ))
    return findings, scanned


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--allowlist", type=Path, default=DEFAULT_ALLOWLIST)
    parser.add_argument("--today", type=dt.date.fromisoformat, default=None)
    parser.add_argument("--max-age-days", type=int, default=DEFAULT_MAX_AGE_DAYS)
    args = parser.parse_args(argv)
    root = args.root.resolve()
    today = args.today or dt.date.today()

    allow = read_allowlist(args.allowlist)
    findings, scanned = check(root, allow, today, args.max_age_days)

    for entry, _ in allow:
        matched = any(rel.startswith(entry) for rel in scanned) if entry.endswith("/") else entry in scanned
        if not matched:
            print(f"working-memory-staleness: allowlist entry matches no scanned file: {entry}", file=sys.stderr)

    if findings:
        print(f"working-memory-staleness: {len(findings)} working-memory doc(s) look finished or stale:", file=sys.stderr)
        for rel, rule, message in findings:
            print(f"  {rel}: {rule}: {message}", file=sys.stderr)
        print(
            "Delete a finished doc in the commit that finishes its work (docs/README.md). "
            "For a deliberate exception add `<path>  # reason` to "
            "scripts/checks/working-memory-staleness.allowlist.",
            file=sys.stderr,
        )
        return 1

    print("working-memory-staleness: no working-memory doc looks finished or stale.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
