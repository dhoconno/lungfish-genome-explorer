#!/usr/bin/env python3
"""provenance-writers.sh - Ratchet that freezes the code paths that write provenance (review finding R8).

ProvenanceWriter is the one encoder and writer for a ProvenanceEnvelope. Phase 2.4 moves every
other provenance writer onto it, one sub-phase at a time. This ratchet keeps those writers from
growing while they wait, so a new operation cannot add another copy. The rules are in
docs/contracts/RECORDING-PROVENANCE.md and in rule 6 of docs/contracts/ADDING-AN-OPERATION.md.

Counts, over Sources/**/*.swift, outside each count's exempt files:
    write_provenance_functions       func writeProvenance whose definition, signature and body, names neither
                                     ProvenanceWriter nor CLIProvenanceSupport.recordSingleStepRun, a private
                                     copy of a provenance writer
    bare_workflow_run_writes         .writeSidecar(, which writes a bare WorkflowRun and not an envelope
    legacy_run_embeds                legacyWorkflowRun: followed by anything but nil, which nests a
                                     WorkflowRun in an envelope
    envelope_encodes_outside_writer  an envelope encoded away from the writer, by ProvenanceJSON.encoder or
                                     by a plain encoder of a name the file binds as an envelope
    provenance_filename_literals     a string literal that names a provenance .json file
    keyless_writer_sites             signingProvider: nil, a writer built never to sign, even with a key set
Each count may only fall, and each counts occurrences, not files. Text after // on a line is
ignored (comment lines and trailing comments).

Exempt files, by path from the repository root. A glob may end the file name.
    legacy_run_embeds                the Provenance core that defines, rebuilds and records the
                                     envelope. These are ProvenanceEnvelope.swift and its
                                     ProvenanceEnvelope+<Part>.swift extensions, ProvenanceRecord.swift,
                                     ProvenanceRecorder*.swift, ProvenanceRunBuilder.swift and
                                     ProvenanceWriter.swift, all under Sources/LungfishWorkflow/Provenance/
    envelope_encodes_outside_writer  ProvenanceWriter.swift and ProvenanceEnvelopeReader.swift in that
                                     folder, and the Inspector display, which encodes only to show
                                     (Sources/LungfishApp/Views/Inspector/ProvenanceInspectorViewModel.swift)
The other four counts have no exempt file. The names file that a later sub-phase adds for the
provenance file names becomes the exemption of provenance_filename_literals when it exists.

Blind spots. The scan reads one line at a time, except that write_provenance_functions reads a definition
from its func to the brace that closes its body and envelope_encodes_outside_writer reads the names a file
binds as an envelope. It does not parse Swift, so review catches the rest.
    - A renamed writer function escapes write_provenance_functions. A definition that reaches the writer only
      through another function it calls counts 1, so it holds the writer it writes with and passes it down. A
      definition that names the writer counts 0 even when it also writes another file itself. A brace inside a
      raw or multi-line string literal can move the end of a body.
    - An envelope reached through a name the file never binds or types that way escapes
      envelope_encodes_outside_writer. That covers a generic value, a closure argument and a binding
      whose = sits on a later line than its name.
    - A provider passed as a variable that is nil, such as the rehydrator's fallback, escapes
      keyless_writer_sites.
The other counts are sinks, so they still carry the invariant when a writer escapes by name.

Baseline file: one "<name> <count>" line per count. Lower it with --update after a count falls.
A change that raises a count needs a reviewed reason.

Usage:
    scripts/ratchets/provenance-writers.sh              # check against the recorded baseline
    scripts/ratchets/provenance-writers.sh --print      # print each counted site and the counts, no pass/fail
    scripts/ratchets/provenance-writers.sh --update     # rewrite the baseline to the current counts
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

PROVENANCE_DIR = "Sources/LungfishWorkflow/Provenance/"

SEE = (
    "See docs/contracts/RECORDING-PROVENANCE.md and rule 6 of "
    "docs/contracts/ADDING-AN-OPERATION.md."
)


class Count(NamedTuple):
    name: str
    pattern: "re.Pattern[str]"
    exempt: tuple
    fix: str


COUNTS = (
    Count(
        "write_provenance_functions",
        re.compile(r"\bfunc\s+writeProvenance\b"),
        (),
        "Do not add another writeProvenance function. Build the record with ProvenanceRunBuilder "
        "and write it with ProvenanceWriter, or call CLIProvenanceSupport.recordSingleStepRun from "
        "a CLI command. " + SEE,
    ),
    Count(
        "bare_workflow_run_writes",
        re.compile(r"\.writeSidecar\("),
        (),
        "WorkflowRun.writeSidecar writes a bare run, which is not an envelope. Write "
        "run.canonicalEnvelope() through ProvenanceWriter.write(_:toSidecar:) instead, so the file "
        "decodes through ProvenanceEnvelopeReader. " + SEE,
    ),
    Count(
        "legacy_run_embeds",
        re.compile(r"\blegacyWorkflowRun:\s*(?!nil\b)\S"),
        (
            PROVENANCE_DIR + "ProvenanceEnvelope.swift",
            PROVENANCE_DIR + "ProvenanceEnvelope+*.swift",
            PROVENANCE_DIR + "ProvenanceRecord.swift",
            PROVENANCE_DIR + "ProvenanceRecorder*.swift",
            PROVENANCE_DIR + "ProvenanceRunBuilder.swift",
            PROVENANCE_DIR + "ProvenanceWriter.swift",
        ),
        "A non-nil legacyWorkflowRun nests a WorkflowRun inside the envelope, which is the legacy "
        "shape. New records carry no nested run, so complete the envelope with "
        "ProvenanceRunBuilder.complete(exitStatus:stderr:startedAt:endedAt:). " + SEE,
    ),
    Count(
        "envelope_encodes_outside_writer",
        re.compile(r"\bProvenanceJSON\.encoder\b"),
        (
            PROVENANCE_DIR + "ProvenanceWriter.swift",
            PROVENANCE_DIR + "ProvenanceEnvelopeReader.swift",
            "Sources/LungfishApp/Views/Inspector/ProvenanceInspectorViewModel.swift",
        ),
        "ProvenanceWriter is the one encoder for a ProvenanceEnvelope. Encoding one with "
        "ProvenanceJSON.encoder or a plain JSONEncoder elsewhere skips the writer's portable-path rewrite, "
        "signing and atomic publish. Pass the envelope to ProvenanceWriter instead. " + SEE,
    ),
    Count(
        "provenance_filename_literals",
        re.compile(r'"[^"\n]*[Pp]rovenance[^"\n]*\.json"'),
        (),
        "A new string literal that names a provenance .json file adds a sidecar name that every "
        "reader must learn. Take the name from ProvenanceRecorder.provenanceFilename or "
        "ProvenanceRecorder.fileSidecarURL(for:), and add no new sidecar file name. " + SEE,
    ),
    Count(
        "keyless_writer_sites",
        re.compile(r"\bsigningProvider:\s*nil\b"),
        (),
        "A ProvenanceWriter built with signingProvider: nil never signs, even when a key is set. Build it with "
        "ProvenanceWriter() so the record signs when LUNGFISH_PROVENANCE_SIGNING_KEY or "
        "LUNGFISH_PROVENANCE_SIGNING_KEY_FILE is set. A site that must stay unsigned needs a row with its reason "
        "in the table of docs/contracts/RECORDING-PROVENANCE.md and a reviewed baseline raise. " + SEE,
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


WRITER_FUNCTIONS = "write_provenance_functions"

# A definition that names the writer, or the recorder that writes through it, is not a private copy of a writer.
WRITER_FORMS = re.compile(r"\bProvenanceWriter\b|\bCLIProvenanceSupport\s*\.\s*recordSingleStepRun\b")
FUNC_WORD = re.compile(r"func\b")


def is_word_char(text, index):
    return index >= 0 and (text[index].isalnum() or text[index] == "_")


def definition_text(text, start, name_end):
    """The text of the definition whose func starts at `start` and whose name ends at `name_end`.

    It runs through the brace that closes the first { after the parameter list. Braces and parentheses
    inside a double-quoted string are skipped. When a } or the word func comes before that {, the
    definition has no body (a protocol requirement) and its text is its own line.
    """
    line_start = text.rfind("\n", 0, start) + 1
    line_end = text.find("\n", start)
    own_line = text[line_start : len(text) if line_end < 0 else line_end]
    in_string = False
    parens = 0
    listed = False  # the parameter list has closed
    braces = 0
    i = name_end
    while i < len(text):
        ch = text[i]
        if in_string:
            if ch == "\\":
                i += 1
            elif ch in '"\n':
                in_string = False
        elif ch == '"':
            in_string = True
        elif not listed:
            if ch == "(":
                parens += 1
            elif ch == ")" and parens:
                parens -= 1
                listed = parens == 0
        elif braces == 0:
            if ch == "{":
                braces = 1
            elif ch == "}" or (FUNC_WORD.match(text, i) and not is_word_char(text, i - 1)):
                return own_line
        elif ch == "{":
            braces += 1
        elif ch == "}":
            braces -= 1
            if braces == 0:
                return text[start : i + 1]
        i += 1
    return text[start:] if braces else own_line


def writer_copy_lines(codes, count):
    """The line of each definition the count pattern finds whose text names no writer form."""
    text = "\n".join(codes)
    lines = []
    for match in count.pattern.finditer(text):
        if not WRITER_FORMS.search(definition_text(text, match.start(), match.end())):
            lines.append(text.count("\n", 0, match.start()) + 1)
    return lines


ENVELOPE_COUNT = "envelope_encodes_outside_writer"

# A name the file binds as a ProvenanceEnvelope. Either a let or var assigned, on one line, from an expression that
# reaches .complete(, canonicalEnvelope( or ProvenanceEnvelope( (after an optional try and await), or any name typed
# ProvenanceEnvelope with a word boundary after the type (a parameter, a property or a typed binding, optional or not).
ENVELOPE_BINDING = re.compile(
    r"\b(?:let|var)\s+(?P<name>[A-Za-z_]\w*)\s*(?::[^=\n]*)?=\s*(?:try[?!]?\s+)?(?:await\s+)?"
    r"[^=\n]*?(?:\.complete\(|\bcanonicalEnvelope\(|\bProvenanceEnvelope\()"
)
ENVELOPE_TYPED = re.compile(r"\b(?P<name>[A-Za-z_]\w*)\s*:\s*ProvenanceEnvelope\b")
PLAIN_ENCODE = re.compile(r"\.encode\(\s*(?P<name>[A-Za-z_]\w*)\s*\)")


def envelope_names(codes):
    """The names one file binds as an envelope, read from its comment-stripped lines."""
    names = set()
    for code in codes:
        for rx in (ENVELOPE_BINDING, ENVELOPE_TYPED):
            names.update(match.group("name") for match in rx.finditer(code))
    return names


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
        codes = [strip_line_comment(line) for line in text.splitlines()]
        bound = envelope_names(codes) if any(count.name == ENVELOPE_COUNT for count in active) else set()
        found = []  # (line, position of the count in COUNTS, name), listed by line and then by count
        for order, count in enumerate(COUNTS):
            if count not in active:
                continue
            if count.name == WRITER_FUNCTIONS:
                found += [(lineno, order, count.name) for lineno in writer_copy_lines(codes, count)]
                continue
            for lineno, code in enumerate(codes, 1):
                hits = len(count.pattern.findall(code))
                if count.name == ENVELOPE_COUNT and bound and not hits:
                    hits = sum(1 for match in PLAIN_ENCODE.finditer(code) if match.group("name") in bound)
                found += [(lineno, order, count.name)] * hits
        for lineno, _, name in sorted(found):
            counts[name] += 1
            sites.append(f"{rel}:{lineno}: {name}")
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
        lines = ["# provenance-writers baseline: counts under Sources/ outside each count's exempt files. Counts may only fall."]
        lines += [f"{name} {n}" for name, n in counts.items()]
        BASELINE_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print("Updated baseline: " + ", ".join(f"{n} {name}" for name, n in counts.items()) + ".")
        return 0

    baseline = read_baseline()
    if baseline is None:
        print(
            f"provenance-writers: no baseline recorded at {BASELINE_FILE}. "
            f"Run with --update to record the current counts.",
            file=sys.stderr,
        )
        return 1

    over = [count for count in COUNTS if counts[count.name] > baseline.get(count.name, 0)]
    if over:
        for count in over:
            print(
                f"provenance-writers: {counts[count.name]} for {count.name}, "
                f"up from the recorded baseline of {baseline.get(count.name, 0)}.",
                file=sys.stderr,
            )
            print(f"  {count.fix}", file=sys.stderr)
        print(
            "Run scripts/ratchets/provenance-writers.sh --print to list every counted site.",
            file=sys.stderr,
        )
        return 1

    lower = [name for name, n in counts.items() if n < baseline.get(name, 0)]
    summary = ", ".join(f"{n} {name}" for name, n in counts.items())
    if lower:
        print(
            f"provenance-writers: {summary}. Down from baseline for {', '.join(lower)}. "
            f"Run with --update to lower the baseline."
        )
    else:
        print(f"provenance-writers: {summary}, at the recorded baseline.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
