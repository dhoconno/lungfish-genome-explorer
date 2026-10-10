#!/usr/bin/env python3
"""tool-identity.sh - Ratchet that freezes the places that decide on a tool by its bare name (review finding R2).

Phase 2.5 gave analysis kinds and managed tools typed ids and two registries. An analysis kind is
a result type under Analyses/ and has an AnalysisToolID and a descriptor in
Sources/LungfishIO/Analysis/. A managed tool is a lock entry and has a ManagedToolID. Code that
still branches on a bare string waits for the sub-phase that converts it (2.6 and later). This
ratchet keeps those sites from growing while they wait, so new code reads the registry instead of
adding another literal. The recipes are in docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md and
docs/contracts/RUNNING-A-TOOL.md.

Counts, over Sources/**/*.swift, outside each count's exempt files:
    analysis_id_decisions     a string literal that is one of the 21 analysis ids or one of the three
                              legacy aliases (classification, kraken, nao-mgs), used as a decision.
                              A decision is one of three spellings.
                                  case "kraken2": or case "kraken2", "bbmap":   one per literal in the arm
                                  == "kraken2" or != "kraken2", the literal on either side
                                  .hasPrefix("kraken2-") or .hasSuffix("kraken2"), a literal that starts
                                  with an id
                              A trailing hyphen is allowed, so the prefix literals "kraken2-" and
                              "kraken2-batch-" count. A literal passed as a value, such as a sidecar
                              name, a CLI argument or an enum raw value, is not a decision and is
                              not counted.
    tool_named_lookups        .tool(named: , the lock lookup that searches the tools list and not the
                              pack tools. Use ManagedToolLock.entry(id:) or entry(environment:).
    unknown_version_fallbacks getToolVersion(...) ?? "unknown" on one line, which records the text
                              unknown as if it were a tool version. Use the version evidence type.
Each count may only fall, and each counts occurrences, not files. Text after // on a line is ignored
(comment lines and trailing comments).

Exempt files, by path from the repository root. A glob may end the file name.
    analysis_id_decisions     everything under Sources/LungfishIO/Analysis/, where the registry
                              defines the ids
The other two counts have no exempt file.

Blind spots. The scan reads one line at a time and does not parse Swift, so review catches the rest.
    - A case arm that spans two lines counts only the literals on the line that ends in a colon.
    - An id held in a constant or a variable and compared by name escapes analysis_id_decisions.
    - A fallback written as a ternary or with a different default text escapes
      unknown_version_fallbacks.
The ids are the 21 in AnalysisToolRegistry. Add an id here in the same commit that adds a descriptor.

Baseline file: one "<name> <count>" line per count. Lower it with --update after a count falls.
A change that raises a count needs a reviewed reason.

Usage:
    scripts/ratchets/tool-identity.sh              # check against the recorded baseline
    scripts/ratchets/tool-identity.sh --print      # print each counted site and the counts, no pass/fail
    scripts/ratchets/tool-identity.sh --update     # rewrite the baseline to the current counts
                                                     (only for a deliberate, reviewed change)

Exit codes: 0 = every count at or under baseline, 1 = a count rose or no baseline is recorded.
"""
import fnmatch
import re
import sys
from pathlib import Path
from typing import NamedTuple

REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCES_DIR = REPO_ROOT / "Sources"
BASELINE_FILE = Path(__file__).resolve().with_suffix(".baseline")

REGISTRY_DIR = "Sources/LungfishIO/Analysis/"

ANALYSIS_IDS = (
    "esviritu", "kraken2", "taxtriage", "minimap2", "bwa-mem2", "bowtie2", "bbmap",
    "spades", "megahit", "skesa", "flye", "hifiasm", "naomgs", "nvd", "cz-id",
    "mafft", "ont-genotyping", "viralrecon", "primer-order", "pbaa", "savont",
)
LEGACY_ALIASES = ("classification", "kraken", "nao-mgs")

SEE = (
    "See docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md and docs/contracts/RUNNING-A-TOOL.md."
)

_ALT = "|".join(re.escape(i) for i in sorted(ANALYSIS_IDS + LEGACY_ALIASES, key=len, reverse=True))
_LITERAL = rf'"(?:{_ALT})-?"'
_ONE_LITERAL = re.compile(_LITERAL)
_SWITCH_ARM = re.compile(rf"\bcase\s+(?:{_LITERAL}\s*,\s*)*{_LITERAL}\s*(?:,\s*{_LITERAL}\s*)*:")
_EQUALITY = re.compile(rf"(?:==|!=)\s*{_LITERAL}|{_LITERAL}\s*(?:==|!=)")
_PREFIX = re.compile(rf'\.(?:hasPrefix|hasSuffix)\(\s*"(?:{_ALT})')


def decisions(code):
    """The number of id literals used as a decision on one line of code."""
    total = 0
    for arm in _SWITCH_ARM.finditer(code):
        total += len(_ONE_LITERAL.findall(arm.group(0)))
    total += len(_EQUALITY.findall(code))
    total += len(_PREFIX.findall(code))
    return total


def pattern_counter(pattern):
    compiled = re.compile(pattern)
    return lambda code: len(compiled.findall(code))


class Count(NamedTuple):
    name: str
    occurrences: object  # a function from one line of code to the number of sites on it
    exempt: tuple
    fix: str


COUNTS = (
    Count(
        "analysis_id_decisions",
        decisions,
        (REGISTRY_DIR + "*",),
        "Do not branch on an analysis id spelled as a string. Read the AnalysisToolRegistry "
        "descriptor (display name, symbol, batch badge, provisioning) or compare AnalysisToolID "
        "values, and add a descriptor field in Sources/LungfishIO/Analysis/ when none fits. " + SEE,
    ),
    Count(
        "tool_named_lookups",
        pattern_counter(r"\.tool\(named:"),
        (),
        "tool(named:) searches the tools list and skips the pack tools. Use "
        "ManagedToolLock.entry(id:) with a ManagedToolID, or entry(environment:), which search both "
        "lists. " + SEE,
    ),
    Count(
        "unknown_version_fallbacks",
        pattern_counter(r'getToolVersion\([^)]*\)\s*\?\?\s*"unknown"'),
        (),
        "Falling back to the text unknown records a made-up version. Keep the missing version as "
        "missing and say why with ToolVersionEvidence. " + SEE,
    ),
)


def strip_line_comment(line):
    """Drop text from the first // that is outside a double-quoted string."""
    in_string = False
    i = 0
    while i < len(line):
        ch = line[i]
        if in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_string = False
        elif ch == '"':
            in_string = True
        elif ch == "/" and line.startswith("//", i):
            return line[:i]
        i += 1
    return line


def is_exempt(rel, exempt):
    return any(fnmatch.fnmatchcase(rel, pattern) for pattern in exempt)


def scan():
    counts = {count.name: 0 for count in COUNTS}
    sites = []
    if not SOURCES_DIR.is_dir():
        return counts, sites
    for path in sorted(SOURCES_DIR.rglob("*.swift")):
        rel = path.relative_to(REPO_ROOT).as_posix()
        active = [count for count in COUNTS if not is_exempt(rel, count.exempt)]
        if not active:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for lineno, line in enumerate(text.splitlines(), 1):
            code = strip_line_comment(line)
            for count in active:
                found = count.occurrences(code)
                if found:
                    counts[count.name] += found
                    sites.extend([f"{rel}:{lineno}: {count.name}"] * found)
    return counts, sites


def read_baseline():
    if not BASELINE_FILE.exists():
        return None
    entries = {}
    for line in BASELINE_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, _, num = line.rpartition(" ")
        try:
            entries[name] = int(num)
        except ValueError:
            continue
    return entries


def main(argv):
    counts, sites = scan()

    if "--print" in argv:
        for s in sites:
            print(s)
        for name, n in counts.items():
            print(f"TOTAL {name} {n}")
        return 0

    if "--update" in argv:
        lines = ["# tool-identity baseline: counts under Sources/ outside each count's exempt files. Counts may only fall."]
        lines += [f"{name} {n}" for name, n in counts.items()]
        BASELINE_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print("Updated baseline: " + ", ".join(f"{n} {name}" for name, n in counts.items()) + ".")
        return 0

    baseline = read_baseline()
    if baseline is None:
        print(
            f"tool-identity: no baseline recorded at {BASELINE_FILE}. "
            f"Run with --update to record the current counts.",
            file=sys.stderr,
        )
        return 1

    over = [count for count in COUNTS if counts[count.name] > baseline.get(count.name, 0)]
    if over:
        for count in over:
            print(
                f"tool-identity: {counts[count.name]} for {count.name}, "
                f"up from the recorded baseline of {baseline.get(count.name, 0)}.",
                file=sys.stderr,
            )
            print(f"  {count.fix}", file=sys.stderr)
        print(
            "Run scripts/ratchets/tool-identity.sh --print to list every counted site.",
            file=sys.stderr,
        )
        return 1

    lower = [name for name, n in counts.items() if n < baseline.get(name, 0)]
    summary = ", ".join(f"{n} {name}" for name, n in counts.items())
    if lower:
        print(
            f"tool-identity: {summary}. Down from baseline for {', '.join(lower)}. "
            f"Run with --update to lower the baseline."
        )
    else:
        print(f"tool-identity: {summary}, at the recorded baseline.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
