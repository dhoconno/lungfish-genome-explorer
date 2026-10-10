#!/usr/bin/env python3
"""provenance-writers.sh - Ratchet that freezes the code paths that write provenance (review finding R8).

ProvenanceWriter is the one encoder and writer for a ProvenanceEnvelope. Phase 2.4 moves every
other provenance writer onto it, one sub-phase at a time. This ratchet keeps those writers from
growing while they wait, so a new operation cannot add another copy. The rules are in
docs/contracts/RECORDING-PROVENANCE.md and in rule 6 of docs/contracts/ADDING-AN-OPERATION.md.

Counts, over Sources/**/*.swift, outside each count's exempt files:
    write_provenance_functions       func writeProvenance, a private copy of a provenance writer
    bare_workflow_run_writes         .writeSidecar(, which writes a bare WorkflowRun and not an envelope
    legacy_run_embeds                legacyWorkflowRun: followed by anything but nil, which nests a
                                     WorkflowRun in an envelope
    envelope_encodes_outside_writer  ProvenanceJSON.encoder, an envelope encoded away from the writer
    provenance_filename_literals     a string literal that names a provenance .json file
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
The other three counts have no exempt file. The names file that a later sub-phase adds for the
provenance file names becomes the exemption of provenance_filename_literals when it exists.

Blind spots. The scan reads one line at a time and does not parse Swift, so review catches the rest.
    - A renamed writer function escapes write_provenance_functions.
    - An envelope encoded with a plain JSONEncoder escapes envelope_encodes_outside_writer. The known
      cases are PrimerAnalysisNativeInspectionService.swift:219, PrimalScheme3DesignPipeline.swift:618
      and :651, PrimalScheme3AlleleLabelMap.swift:170 and AnalysesMigration.swift:441.
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
        "ProvenanceJSON.encoder elsewhere skips the writer's portable-path rewrite, signing and "
        "atomic publish. Pass the envelope to ProvenanceWriter instead. " + SEE,
    ),
    Count(
        "provenance_filename_literals",
        re.compile(r'"[^"\n]*[Pp]rovenance[^"\n]*\.json"'),
        (),
        "A new string literal that names a provenance .json file adds a sidecar name that every "
        "reader must learn. Take the name from ProvenanceRecorder.provenanceFilename or "
        "ProvenanceRecorder.fileSidecarURL(for:), and add no new sidecar file name. " + SEE,
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
                for _ in count.pattern.finditer(code):
                    counts[count.name] += 1
                    sites.append(f"{rel}:{lineno}: {count.name}")
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
