#!/usr/bin/env python3
"""cli-parity-gaps.sh - Count the operations whose recorded command does not reproduce the run.

docs/contracts/CLI-EQUIVALENCE.md states owner decision 4 of 2026-10-03. Every
Operations panel row records a lungfish-cli command that parses and reproduces
the run. A row that cannot meet that rule yet is a gap. Its begin site records
nil and carries the marker `cli-parity-gap: <ID>` in the doc comment of the
function that holds the call, or in a comment between the start of that
function and the end of the call. A test pins it with
`assertCLIParityGap(item.cliCommand, id: "<ID>")`.

This script is a source scan with a test cross-check, so it needs no build.

1. A begin site is a call named `begin` whose argument list names
   `cliCommand:`. A call inside a function that is itself named `begin`
   forwards its caller's value and is not a site, but the call to that
   forwarder is, so a wrapper such as DemoProjectsViewModel's
   `begin(title:detail:cliCommand:)` hides no row.
2. The value counts gap sites. Each begin site counts once for every gap ID
   it carries, so a shared helper that serves several operations counts each
   of them, and a new nil site that reuses an existing ID still raises the
   value. Each line of cli-parity-gaps.pending (a gap whose site sits in a
   file another lane owns, so it carries no marker yet) counts once more. The
   value may not pass the baseline.
3. Every gap ID needs an `assertCLIParityGap(..., id: "<ID>")` pin in Tests,
   except a pending ID. Every pinned ID needs a marker or a pending line.
4. A begin site that passes the literal `nil` as `cliCommand` needs a gap
   marker or a `cli-parity-exempt: <reason>` marker.
5. The function that holds a begin site must be named in a test file under
   Tests/LungfishAppTests that also calls `RecordedCLICommand.parse`,
   `parseScript` or `assertCLIParityGap`, and that same file must name the
   type that encloses the site or the stem of its source file, so a generic
   function name such as `run` is not matched by an unrelated test. Sites that fail this today are listed
   in cli-parity-gaps.untested (one `file:function` per line), which may only
   shrink.
6. A gap or exempt marker must belong to a begin site.

Usage:
    scripts/ratchets/cli-parity-gaps.sh            # check
    scripts/ratchets/cli-parity-gaps.sh --print    # list every site with its status
    scripts/ratchets/cli-parity-gaps.sh --update   # lower the baseline and shrink the untested list

Exit codes: 0 = pass, 1 = a rule failed.
"""
from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

NAME = "cli-parity-gaps"
GAP_MARKER = re.compile(r"cli-parity-gap:\s*([a-z0-9][a-z0-9-]*)")
EXEMPT_MARKER = re.compile(r"cli-parity-exempt:\s*([a-z0-9][a-z0-9-]*)")
BEGIN_CALL = re.compile(r"(?<![A-Za-z0-9_])begin\(")
TYPE_DECL = re.compile(r"(?<![A-Za-z0-9_])(?:class|struct|enum|actor|extension)\s+([A-Za-z_][A-Za-z0-9_]*)")
FUNC_DECL = re.compile(r"(?<![A-Za-z0-9_])(?:func\s+([A-Za-z_][A-Za-z0-9_]*)|(init)\s*[?!]?\s*[(<])")
PIN_CALL = re.compile(r"(?<![A-Za-z0-9_])assertCLIParityGap\(")
PIN_ID = re.compile(r"\bid:\s*\"([^\"]+)\"")
PARSE_CALL = re.compile(r"RecordedCLICommand\.parse\b|\bparseScript\(|\bassertCLIParityGap\(")
NIL_COMMAND = re.compile(r"\bcliCommand:\s*nil\b")


# ------------------------------------------------------------------ lexing


def code_mask(text: str) -> list[bool]:
    """Marks each character that is code, not a comment or string literal body.

    Handles `//` and `/* */` comments, `"..."` and `\"\"\"...\"\"\"` strings, and
    `\\( ... )` interpolation inside strings, whose contents count as code.
    """
    mask = [True] * len(text)
    i = 0
    n = len(text)
    # A stack of string kinds we are inside, with the paren depth of the
    # interpolation that re-entered code.
    stack: list[list] = []  # entries: [quote, interpolation_depth or None]
    while i < n:
        top = stack[-1] if stack else None
        in_string = top is not None and top[1] is None
        if in_string:
            quote = top[0]
            mask[i] = False
            if text.startswith("\\(", i):
                mask[i + 1] = False
                top[1] = 1
                i += 2
                continue
            if text[i] == "\\":
                if i + 1 < n:
                    mask[i + 1] = False
                i += 2
                continue
            if text.startswith(quote, i):
                for k in range(len(quote)):
                    mask[i + k] = False
                stack.pop()
                i += len(quote)
                continue
            i += 1
            continue
        # Code, possibly inside an interpolation.
        if text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end == -1 else end
            for k in range(i, end):
                mask[k] = False
            i = end
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end == -1 else end + 2
            for k in range(i, end):
                mask[k] = False
            i = end
            continue
        if text.startswith('"""', i) or text[i] == '"':
            quote = '"""' if text.startswith('"""', i) else '"'
            for k in range(len(quote)):
                mask[i + k] = False
            stack.append([quote, None])
            i += len(quote)
            continue
        if top is not None:  # inside an interpolation
            if text[i] == "(":
                top[1] += 1
            elif text[i] == ")":
                top[1] -= 1
                if top[1] == 0:
                    top[1] = None
                    mask[i] = False
        i += 1
    return mask


def matching(text: str, mask: list[bool], start: int, open_char: str, close_char: str) -> int:
    """Index of the bracket that closes the one at `start`, or len(text)."""
    depth = 0
    for j in range(start, len(text)):
        if not mask[j]:
            continue
        if text[j] == open_char:
            depth += 1
        elif text[j] == close_char:
            depth -= 1
            if depth == 0:
                return j
    return len(text)


def comment_text(text: str, mask: list[bool], start: int, end: int) -> str:
    """The comment characters in [start, end), with string bodies left out."""
    out = []
    in_comment = False
    i = start
    while i < end:
        if mask[i]:
            in_comment = False
            out.append("\n" if text[i] == "\n" else " ")
            i += 1
            continue
        if text.startswith("//", i) or text.startswith("/*", i):
            in_comment = True
        if in_comment:
            out.append(text[i])
        elif text[i] == "\n":
            out.append("\n")
        i += 1
    return "".join(out)


# ------------------------------------------------------------------ model


@dataclass
class Function:
    name: str
    decl_start: int  # start of the doc comment and attributes above it
    keyword: int
    body_start: int
    body_end: int


@dataclass
class Site:
    path: str
    line: int
    function: str
    nil_command: bool
    enclosing_type: str = ""
    gaps: list[str] = field(default_factory=list)
    exempt: list[str] = field(default_factory=list)

    @property
    def key(self) -> str:
        return f"{self.path}:{self.function}"


def doc_comment_start(text: str, keyword: int) -> int:
    """Start of the comment and attribute lines directly above a declaration."""
    line_start = text.rfind("\n", 0, keyword) + 1
    start = line_start
    while start > 0:
        prev_end = start - 1
        prev_start = text.rfind("\n", 0, prev_end) + 1
        line = text[prev_start:prev_end].strip()
        if line.startswith("//") or line.startswith("@") or line.startswith("*") or line.startswith("/*"):
            start = prev_start
            continue
        break
    return start


def functions_in(text: str, mask: list[bool]) -> list[Function]:
    found = []
    for match in FUNC_DECL.finditer(text):
        if not mask[match.start()]:
            continue
        name = match.group(1) or match.group(2)
        brace = match.end()
        # The body opens at the first `{` in code after the signature. A
        # protocol requirement has none before the next declaration.
        while brace < len(text) and not (mask[brace] and text[brace] in "{}"):
            brace += 1
        if brace >= len(text) or text[brace] != "{":
            continue
        # Skip a requirement that ends at a newline with no body: a `{` that
        # follows a later `func` belongs to that one.
        next_decl = FUNC_DECL.search(text, match.end())
        if next_decl and next_decl.start() < brace and mask[next_decl.start()]:
            continue
        end = matching(text, mask, brace, "{", "}")
        found.append(Function(name, doc_comment_start(text, match.start()), match.start(), brace, end))
    return found


def types_in(text: str, mask: list[bool]) -> list[tuple[str, int, int]]:
    """Each class, struct, enum, actor or extension with its body range."""
    found = []
    for match in TYPE_DECL.finditer(text):
        if not mask[match.start()]:
            continue
        brace = match.end()
        while brace < len(text) and not (mask[brace] and text[brace] in "{};"):
            brace += 1
        if brace >= len(text) or text[brace] != "{":
            continue
        found.append((match.group(1), brace, matching(text, mask, brace, "{", "}")))
    return found


def scan_sources(root: Path) -> tuple[list[Site], dict[str, list[str]]]:
    """Begin sites, and every marker in Sources by ID with its location."""
    sites: list[Site] = []
    markers: dict[str, list[str]] = {}
    sources = root / "Sources"
    for path in sorted(sources.rglob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="replace")
        rel = path.relative_to(root).as_posix()
        has_marker = "cli-parity-gap:" in text or "cli-parity-exempt:" in text
        if "begin(" not in text and not has_marker:
            continue
        mask = code_mask(text)
        all_comments = comment_text(text, mask, 0, len(text)) if has_marker else ""
        for regex, kind in ((GAP_MARKER, "gap"), (EXEMPT_MARKER, "exempt")):
            for match in regex.finditer(all_comments):
                line = all_comments.count("\n", 0, match.start()) + 1
                markers.setdefault(f"{kind}:{match.group(1)}", []).append(f"{rel}:{line}")
        functions = functions_in(text, mask) if "begin(" in text else []
        types = types_in(text, mask) if "begin(" in text else []
        for match in BEGIN_CALL.finditer(text):
            if not mask[match.start()]:
                continue
            before = text[max(0, match.start() - 40) : match.start()]
            if re.search(r"func\s+$", before):
                continue
            open_paren = match.end() - 1
            close = matching(text, mask, open_paren, "(", ")")
            call = text[open_paren : close + 1]
            code_only = "".join(c if mask[open_paren + k] else " " for k, c in enumerate(call))
            if "cliCommand:" not in code_only:
                continue
            enclosing = [f for f in functions if f.body_start < match.start() < f.body_end]
            function = max(enclosing, key=lambda f: f.body_start) if enclosing else None
            if function is not None and function.name == "begin":
                continue  # a forwarding wrapper, such as OperationReporting's default arguments
            region_start = function.decl_start if function else 0
            comments = comment_text(text, mask, region_start, close + 1)
            holders = [t for t in types if t[1] < match.start() < t[2]]
            holder = max(holders, key=lambda t: t[1])[0] if holders else ""
            site = Site(
                enclosing_type=holder,
                path=rel,
                line=text.count("\n", 0, match.start()) + 1,
                function=function.name if function else "<top-level>",
                nil_command=bool(NIL_COMMAND.search(code_only)),
                gaps=sorted(set(GAP_MARKER.findall(comments))),
                exempt=sorted(set(EXEMPT_MARKER.findall(comments))),
            )
            sites.append(site)
    return sites, markers


def scan_pins(root: Path) -> dict[str, list[str]]:
    """IDs pinned by `assertCLIParityGap(..., id: "<ID>")` calls under Tests."""
    pins: dict[str, list[str]] = {}
    tests = root / "Tests"
    if not tests.exists():
        return pins
    for path in sorted(tests.rglob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="replace")
        if "assertCLIParityGap(" not in text:
            continue
        mask = code_mask(text)
        rel = path.relative_to(root).as_posix()
        for match in PIN_CALL.finditer(text):
            if not mask[match.start()]:
                continue
            if re.search(r"func\s+$", text[max(0, match.start() - 40) : match.start()]):
                continue
            close = matching(text, mask, match.end() - 1, "(", ")")
            pin = PIN_ID.search(text, match.end(), close + 1)
            if pin:
                line = text.count("\n", 0, match.start()) + 1
                pins.setdefault(pin.group(1), []).append(f"{rel}:{line}")
    return pins


def names_word(text: str, word: str) -> bool:
    return bool(word) and re.search(r"(?<![A-Za-z0-9_])" + re.escape(word) + r"(?![A-Za-z0-9_])", text) is not None


def tested_sites(root: Path, sites: list) -> set[str]:
    """Keys of the sites an App test file covers. The file calls a parse or a
    pin, names the site's function, and names its enclosing type or the stem
    of its source file."""
    tested: set[str] = set()
    app_tests = root / "Tests" / "LungfishAppTests"
    if not app_tests.exists():
        return tested
    texts = []
    for path in sorted(app_tests.rglob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="replace")
        if PARSE_CALL.search(text):
            texts.append(text)
    for site in sites:
        stem = Path(site.path).stem
        for text in texts:
            if names_word(text, site.function) and (
                names_word(text, site.enclosing_type) or stem in text
            ):
                tested.add(site.key)
                break
    return tested


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    lines = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            lines.append(line)
    return lines


def read_pending(path: Path) -> dict[str, str]:
    """Pending ID -> `file:function` of its site (fields: ID, site, closing lane)."""
    pending = {}
    for line in read_lines(path):
        parts = line.split()
        pending[parts[0]] = parts[1] if len(parts) > 1 else ""
    return pending


def read_baseline(path: Path):
    lines = read_lines(path)
    if not lines:
        return None
    try:
        return int(lines[0])
    except ValueError:
        return None


# ------------------------------------------------------------------ main


def evaluate(root: Path):
    sites, markers = scan_sources(root)
    pins = scan_pins(root)
    pending = read_pending(root / "scripts" / "ratchets" / f"{NAME}.pending")
    untested_listed = read_lines(root / "scripts" / "ratchets" / f"{NAME}.untested")

    tested = tested_sites(root, sites)
    untested = sorted({s.key for s in sites if s.key not in tested})

    gap_ids = {key.split(":", 1)[1] for key in markers if key.startswith("gap:")}
    site_gap_ids = {gap for s in sites for gap in s.gaps}
    site_exempt = {reason for s in sites for reason in s.exempt}
    # Gap sites, not distinct IDs (rule 2).
    pending_lines = read_lines(root / "scripts" / "ratchets" / f"{NAME}.pending")
    value = sum(len(s.gaps) for s in sites) + len(pending_lines)

    failures: list[str] = []
    for gap in sorted(gap_ids - site_gap_ids):
        failures.append(f"marker cli-parity-gap: {gap} at {', '.join(markers['gap:' + gap])} belongs to no begin site")
    for key, places in sorted(markers.items()):
        if key.startswith("exempt:") and key.split(":", 1)[1] not in site_exempt:
            failures.append(f"marker cli-parity-{key.replace(':', ': ', 1)} at {', '.join(places)} belongs to no begin site")
    for gap in sorted(gap_ids & set(pending)):
        failures.append(f"gap {gap} has both a source marker and a pending line. Delete the pending line.")
    for gap in sorted(gap_ids - set(pins)):
        failures.append(
            f"gap {gap} ({', '.join(markers['gap:' + gap])}) has no assertCLIParityGap(..., id: \"{gap}\") pin in Tests"
        )
    for pinned in sorted(set(pins) - gap_ids - set(pending)):
        failures.append(
            f"test pins gap {pinned} ({', '.join(pins[pinned])}) but no source marker or pending line carries it. "
            "Replace the pin with a parse test and a replay test."
        )
    for site in sites:
        if site.nil_command and not site.gaps and not site.exempt:
            failures.append(
                f"{site.path}:{site.line} ({site.function}) records cliCommand: nil with no "
                "cli-parity-gap or cli-parity-exempt marker"
            )
    for key in untested:
        if key not in untested_listed:
            failures.append(
                f"{key} holds a begin site that no test in Tests/LungfishAppTests names beside "
                "RecordedCLICommand.parse, parseScript or assertCLIParityGap"
            )
    stale_untested = sorted(set(untested_listed) - set(untested))
    return sites, pins, pending, untested, value, failures, stale_untested


def status_of(site: Site, pending: dict[str, str], untested: list[str]) -> str:
    parts = []
    if site.gaps:
        parts.append("gap " + ",".join(site.gaps))
    if site.exempt:
        parts.append("exempt " + ",".join(site.exempt))
    pending_ids = [gap for gap, where in pending.items() if where == site.key]
    if pending_ids:
        parts.append("pending " + ",".join(pending_ids))
    if not parts:
        parts.append("parses")
    if site.key in untested:
        parts.append("untested")
    return " ".join(parts)


def main(argv: list[str], root: Path = REPO_ROOT) -> int:
    sites, pins, pending, untested, value, failures, stale_untested = evaluate(root)
    baseline_path = root / "scripts" / "ratchets" / f"{NAME}.baseline"
    untested_path = root / "scripts" / "ratchets" / f"{NAME}.untested"

    if "--print" in argv:
        for site in sorted(sites, key=lambda s: (s.path, s.line)):
            print(f"{site.path}:{site.line} {site.function} {status_of(site, pending, untested)}")
        for gap, where in sorted(pending.items()):
            print(f"pending {gap} {where}")
        print(f"SITES {len(sites)}")
        print(f"TOTAL {value}")
        return 0

    baseline = read_baseline(baseline_path)

    if "--update" in argv:
        if baseline is not None and value > baseline:
            print(
                f"{NAME}: refusing to raise the baseline from {baseline} to {value}. "
                "A new operation lands with its command, never with a gap.",
                file=sys.stderr,
            )
            return 1
        # The list may only shrink, also once it is empty or missing.
        listed = read_lines(untested_path)
        added = sorted(set(untested) - set(listed))
        if added:
            print(f"{NAME}: refusing to add untested sites: {', '.join(added)}", file=sys.stderr)
            return 1
        baseline_path.write_text(f"{value}\n", encoding="utf-8")
        header = (
            "# Begin sites whose function no App test names beside a command parse.\n"
            "# One file:function per line. This list may only shrink.\n"
        )
        untested_path.write_text(header + "".join(f"{key}\n" for key in untested), encoding="utf-8")
        print(f"Updated {NAME} baseline to {value} and the untested list to {len(untested)} sites.")
        return 0

    if baseline is None:
        print(f"{NAME}: no baseline at {baseline_path}. Run with --update.", file=sys.stderr)
        return 1
    if value > baseline:
        failures.insert(
            0,
            f"{value} CLI parity gaps, up from the baseline of {baseline}. "
            "No new gap may be added (docs/contracts/CLI-EQUIVALENCE.md).",
        )

    if failures:
        print(f"{NAME}: FAILED", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1

    if stale_untested:
        print(f"{NAME}: {len(stale_untested)} listed untested sites are now tested. Run with --update to shrink the list.")
    if value < baseline:
        print(f"{NAME}: {value} gaps, down from the baseline of {baseline}. Run with --update to lower it.")
    else:
        print(f"{NAME}: {value} gaps, at the baseline.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
