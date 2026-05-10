# Follow-up issues from the 2026-05-09 evaluation sweep

The first round of fixes against `2026-05-09-technical-gaps-from-documentation.md`
landed across 22 commits. A re-evaluation of the resulting build
(`lungfish-cli 0.4.0-alpha.11`, fresh Debug build at
`~/Library/Developer/Xcode/DerivedData/Lungfish-aygvdshcdayvgybtylkaywokohex/`)
sweeps **all 40 issues** from the parent backlog. Each issue with a
PARTIAL or BROKEN verdict gets a single concrete recommendation Codex can
implement directly. NON-RESPONSIVE issues remain open in the parent file
and are not duplicated here.

The full evaluation manifest with evidence paths, CLI transcripts, captured
artifacts, and 39 GUI screenshots lives at
`/tmp/lungfish-eval/MANIFEST.md` on the reviewer's machine. Screenshots are
at `docs/user-manual/shots/captured/2026-05-09/`.

## Roll-up of all 40 issues

| ID | Severity | Topic | Verdict | Follow-up |
|---|---|---|---|---|
| docs-001 | P0 | GenBank → annotations | FIXED | — |
| docs-002 + docs-027 | P1, P2 | Project locks + user attribution | FIXED | — |
| docs-003 | P2 | Bundle migration | FIXED | — |
| docs-004 | P1 | NCBI 429 retry | FIXED | — |
| docs-005 | P2 | NCBI API key in Settings | FIXED | — |
| docs-006 | P2 | Pathoplexus search dialog | FIXED | — |
| docs-007 | P2 | Phased variant calling | PARTIAL | command-plan surface added; iVar phase-aware warning remains open |
| docs-008 | P2 | Clair3 ONT caller | FIXED | — |
| docs-010 | P2 | bcftools as caller | NON-RESPONSIVE | parent stays open |
| docs-011 | P1 | Freyja | PARTIAL | command-plan surface added; richer GUI run dialog remains open |
| docs-012 | P2 | Database update tracking | NON-RESPONSIVE | parent stays open |
| docs-013 | P2 | BLAST rate-limiting | NON-RESPONSIVE | parent stays open |
| **docs-014** | P1 | Read groups in mapping | **PARTIAL** | docs-014a |
| docs-016 | P1 | viralrecon wizard chapter | FIXED | — |
| docs-017 | P1 | Tree-viewport result tools | NON-RESPONSIVE | parent stays open |
| docs-018 | P1 | Container image export | NON-RESPONSIVE | parent stays open |
| docs-019 | P1 | Conda lockfile generation | NON-RESPONSIVE | parent stays open |
| docs-020 | P2 | Workflow versioning + diff | NON-RESPONSIVE | parent stays open |
| **docs-021** | P1 | Pass-through args | **PARTIAL** | docs-021a, docs-021b |
| **docs-022** | P2 | Headless / batch CI mode | **PARTIAL** | docs-022a |
| docs-023 | P1 | Sample sheet support | NON-RESPONSIVE | parent stays open |
| **docs-024** | P2 | Multi-sample VCF + filter | **PARTIAL** | docs-024a |
| docs-025 | P2 | Reject VCFv3 | FIXED | — |
| docs-026 | P3 | Signed provenance sidecars | NON-RESPONSIVE | parent stays open |
| docs-028 | P2 | Methods Section banner | FIXED | — |
| docs-029 | P1 | Tool-version reference table | FIXED | — |
| docs-030 | P2 | Tool-paper bibliography | FIXED | — |
| docs-031 | P2 | Offline conda install | FIXED | — |
| **docs-032** | P2 | Shared conda root | **PARTIAL** | docs-032a |
| docs-033 | P2 | Per-operation runtime estimates | NON-RESPONSIVE | parent stays open |
| **docs-034** | P2 | Hardware floor declaration | **PARTIAL** | docs-034a |
| docs-035 | P3 | Empty GFF3 manifest entry | NON-RESPONSIVE | parent stays open |
| docs-036 | P3 | Custom primer scheme builder | NON-RESPONSIVE | parent stays open |
| docs-037 | P3 | fastp combined adapter+quality | NON-RESPONSIVE | parent stays open |
| **docs-038** | P1 | CZ-ID first-class import | **PARTIAL** | docs-038a |
| docs-039 | P1 | GATK first-class | FIXED at CLI | — |
| **docs-040** | P1 | Workflow Builder | **BROKEN — dead code** | docs-040a, b, c, d |

**Tally:** 14 FIXED, 8 PARTIAL, 16 NON-RESPONSIVE, 1 BROKEN.

The 11 follow-up entries below are ordered by parent issue id.

---

## docs-014a — Surface read-group fields in the Mapping dialog

**Parent:** docs-014 (Read groups in mapping)
**Severity:** P1

### Reproduction

```bash
$ lungfish-cli map --help | grep -E "^  --rg-"
  --rg-id <rg-id>     BAM read-group ID (default: sample name)
  --rg-lb <rg-lb>     BAM read-group library/LB (default: sample name)
  --rg-pl <rg-pl>     BAM read-group platform/PL (default: mapper preset platform)
  --rg-pu <rg-pu>     BAM read-group platform unit/PU (default: sample name)
```

GUI Mapping dialog (Tools > FASTQ/FASTA Operations > Mapping..., screenshot
`mapping-dialog-overview.png` and `mapping-dialog-advanced-options.png`)
shows: Reference picker, Preset (Short-read), Input Compatibility, plus
Advanced Settings disclosure with Threads / Secondary alignments /
Supplementary / Min mapping quality + Advanced Options text field. **No
read-group fields.**

### Recommendation

Add a "Read Group" disclosure section to the Mapping dialog (between Preset
and Advanced Settings) with five text fields bound to `--rg-id`, `--rg-sm`,
`--rg-lb`, `--rg-pl`, `--rg-pu`. Default each to its CLI default
("sample name" → derive from selected sample). The disclosure is collapsed
by default; expanding it does not change the default values.

### Acceptance criteria

- [ ] Mapping dialog has a "Read Group" disclosure with five text fields
- [ ] Default values match the CLI: id/sm/pu = sample name, lb = sample name,
  pl = mapper preset platform
- [ ] Values forward verbatim into the BAM `@RG` header
- [ ] Provenance sidecar records the read-group fields under
  `parameters.readGroup.{id,sm,lb,pl,pu}`

---

## docs-021a — Rename `--advanced-options` to `--extra-args`

**Parent:** docs-021 (Pass-through arguments)
**Severity:** P2

### Reproduction

```bash
$ lungfish-cli gatk haplotype-caller --help | grep extra-args
  --extra-args <extra-args>  Additional GATK arguments...

$ lungfish-cli map --help | grep -cE "extra-args|advanced-options"
1   # --advanced-options

$ lungfish-cli assemble --help | grep -cE "extra-args|advanced-options"
1   # --advanced-options
```

GATK uses `--extra-args`. Map and assemble use `--advanced-options`. Two
flag names mean the same thing.

The Variant Calling GUI dialog (`variant-call-dialog-lofreq.png`) labels the
text field "Advanced Options" — same naming gap surfaces in the GUI.

### Recommendation

Rename `--advanced-options` to `--extra-args` on `lungfish map` and `lungfish
assemble`. Keep `--advanced-options` as a hidden alias that prints a
single-line stderr deprecation warning for one release, then remove. Rename
the GUI Mapping dialog and Variant Calling dialog "Advanced Options" labels
to "Extra arguments" to match.

### Acceptance criteria

- [ ] `lungfish map --help` shows `--extra-args` and not `--advanced-options`
- [ ] `lungfish assemble --help` shows `--extra-args` and not `--advanced-options`
- [ ] `lungfish map --advanced-options "..."` parses for one release with
  stderr warning `warning: --advanced-options is deprecated, use --extra-args`
- [ ] GUI label change in Mapping dialog and Variant Calling dialog
- [ ] Provenance sidecar field renamed to `parameters.extraArgs` consistently
  across map, assemble, and GATK
- [ ] `docs/user-manual/chapters/appendices/01-cli-reference.md` updated

---

## docs-021b — Add `--extra-args` to nine wrapped tools

**Parent:** docs-021 (Pass-through arguments)
**Severity:** P1

### Reproduction

```bash
for cmd in "orient" "blast" "esviritu" "taxtriage" "tree infer" \
           "msa run" "align" "fastq trim" "conda classify"; do
  flag=$(lungfish-cli $cmd --help 2>&1 | grep -cE 'extra-args|advanced-options')
  echo "$cmd: $flag"
done
# All print 0.
```

The original docs-021 acceptance required all GUI-backed tools to expose
pass-through. Nine still don't.

### Recommendation

Add `--extra-args <string>` to each of the nine subcommands. Each forwards
its value verbatim to the wrapped tool in the constructed command line. The
matching GUI dialog adds an "Extra arguments" text field bound to the same
parameter. Provenance sidecar records the verbatim string under
`parameters.extraArgs`.

### Acceptance criteria

- [ ] `lungfish-cli orient`, `blast`, `esviritu`, `taxtriage`, `tree infer`,
  `msa run`, `align`, `fastq trim`, `conda classify` all gain `--extra-args`
- [ ] Each GUI dialog (Orient, BLAST verification, EsViritu, TaxTriage,
  Tree Inference, MSA, Align, Trim & Filter, Kraken2 Classify) gains an
  "Extra arguments" text field
- [ ] `Tests/LungfishCLITests` adds a smoke test per subcommand asserting
  the flag parses and is forwarded into the constructed command line

---

## docs-022a — Add `lungfish run-headless` subcommand and CI documentation

**Parent:** docs-022 (Headless / batch CI mode)
**Severity:** P2

### Reproduction

```bash
$ lungfish-cli --help | grep -i headless
The `lungfish` command provides headless access to the Lungfish Genome
# (no run-headless subcommand)
```

The CLI is headless by design — every subcommand runs without a display
server. The spec called for an explicit `run-headless` subcommand plus a CI
documentation chapter to make this discoverable.

### Recommendation

Add `lungfish run-headless <workflow.yaml>` as a thin alias for `lungfish
workflow run --quiet <workflow>`. Its purpose is to be a single discoverable
entry point in `--help` and in CI documentation. Add an
`appendices/06-running-in-ci.md` chapter that walks through invoking
`lungfish-cli` from GitHub Actions and CircleCI with cached conda packs.

### Acceptance criteria

- [ ] `lungfish-cli run-headless --help` exists and points to the workflow run path
- [ ] `appendices/06-running-in-ci.md` ships with a worked GitHub Actions example
- [ ] The chapter references the offline conda export/install path (docs-031) for cached environments

---

## docs-024a — Add per-sample filter syntax and CLI extract-sample/query

**Parent:** docs-024 (Multi-sample VCF rendering and per-sample filtering)
**Severity:** P2

### Reproduction

```bash
$ lungfish-cli variants --help | tail -3
SUBCOMMANDS:
  call    Call viral variants from a bundle-owned alignment track
# (no extract-sample, no query subcommands)
```

Variant browser (`variant-browser-with-inspector.png`) renders the table
with quality/QC filter chips (PASS, Qual ≥ 30, DP ≥ 10) and Population /
Frequency chips (Singleton, Minor <20%, Mixed 20-80%, Dominant ≥80%) plus
DEL/SNP type chips. **No per-sample filter syntax.** The SQLite-backed
variant store is in place; the gap is just the filter surface and the CLI
extraction commands.

### Recommendation

Extend the existing smart-filter grammar with per-sample syntax that
compiles to SQL against the variant store:

- `Sample[NA12878].GT=1/1`, `Sample[NA12878].AF>=0.5`, `Sample[NA12878].DP>=30`
- Composite: `count(Sample[*].GT=1/1) >= 5`
- Inequality: `Sample[NA12878].GT != Sample[NA12879].GT`

Add a sample selector control to the variant browser left pane that toggles
column visibility for selected samples. Add CLI subcommands:

- `lungfish-cli variants extract-sample <bundle> --sample <name> --output <file>`
- `lungfish-cli variants query <bundle> --filter "<smart-filter>" --output <file>`

### Acceptance criteria

- [ ] Smart-filter grammar parses `Sample[<name>].<field><op><value>`
- [ ] Filters compile to SQL queries against the bundle's variant store
- [ ] Sample selector control added to variant browser left pane
- [ ] `lungfish variants extract-sample` and `variants query` ship
- [ ] `chapters/05-variants/02-reading-the-variant-browser.md` and `06-importing-existing-vcfs.md` updated with examples
- [ ] Benchmark verifies filter latency < 1 s for a 1000-sample, 100,000-row store

---

## docs-032a — Verify shared conda root lock semantics and document admin install

**Parent:** docs-032 (Shared `~/.lungfish/conda` across machines)
**Severity:** P2

### Reproduction

```bash
$ grep LUNGFISH_CONDA_ROOT Sources/LungfishCore/Storage/ManagedStorageConfigStore.swift
85:        if let override = environment["LUNGFISH_CONDA_ROOT"]?
```

The env var is honored in source. Lock semantics for two users running
`conda install` against the same `LUNGFISH_CONDA_ROOT` simultaneously, plus
read-only shared-install support (one admin user installs, all users on the
host can run), are not verified.

### Recommendation

Acquire an exclusive flock on `<conda-root>/.install.lock` for the duration
of any conda mutation operation (install, remove, offline-install,
offline-export). When the lock is held by another process, the second
process prints `waiting for conda lock held by pid <n>` and blocks until the
lock is released or the user Ctrl-C's. Add a chapter section in
`01-foundations/07-plugin-packs.md` covering the shared-install workflow:
admin user runs `lungfish conda install --pack ...`, then `chmod -R a-w`
the conda root, then sets `LUNGFISH_CONDA_ROOT` in /etc/launchd.conf or
each user's shell profile.

### Acceptance criteria

- [ ] flock-based lock on `<conda-root>/.install.lock`
- [ ] Concurrent install attempts print waiting-for-lock message and block
- [ ] Read-only conda root is detected; mutation operations error with
  `conda root is read-only; reinstall as the admin user`
- [ ] Chapter section in `07-plugin-packs.md` covers the admin shared-install pattern

---

## docs-034a — Declare hardware floor in About panel

**Parent:** docs-034 (Hardware floor declaration)
**Severity:** P2

### Reproduction

```bash
$ grep -rn "minimumMacOSVersion\|hardwareFloor\|minimumRAM" Sources/ --include="*.swift"
Sources/LungfishWorkflow/Engines/ContainerRuntimeProtocol.swift:61: minimumMacOSVersion
# Only at the container runtime layer; no Settings or About panel exposes this to the user
```

Plugin Manager Databases tab (`plugin-manager-databases-tab.png`) does
flag database sizes against system RAM ("Standard 67 GB total · exceeds
system RAM"), so partial coverage exists at the database picker. The full
hardware floor — minimum macOS version, minimum CPU architecture, minimum
RAM for default workflows — is not declared in the app.

### Recommendation

Add a "System Requirements" section to the About Lungfish panel (Lungfish >
About Lungfish) listing: minimum macOS (26 Tahoe), CPU architecture (Apple
Silicon required), recommended RAM (16 GB), recommended disk (50 GB free).
Mirror these as a static list in `01-foundations/07-plugin-packs.md`
under a new "System requirements" subsection.

### Acceptance criteria

- [ ] About Lungfish panel has a System Requirements section
- [ ] `01-foundations/07-plugin-packs.md` declares minimum hardware
- [ ] Per-classifier chapters (`06-classification/02-running-kraken2.md` etc.)
  declare minimum RAM per database in their parameter tables

---

## docs-038a — Add `lungfish import cz-id`

**Parent:** docs-038 (CZ-ID first-class import)
**Severity:** P1

### Reproduction

```bash
$ lungfish-cli import --help | grep -E "(nao-mgs|nvd|cz-id|kraken2)"
  kraken2  Import Kraken2 classification results
  esviritu Import EsViritu viral detection results
  taxtriage Import TaxTriage classification results
  nao-mgs   Import NAO-MGS metagenomic surveillance results
  nvd       Import NVD BLAST results
# (no cz-id)

$ lungfish-cli cz-id --help
OVERVIEW: Display a summary of a CZ-ID taxon report TSV
USAGE: lungfish cz-id summary ...
```

Verified in the GUI: Import Center > Classification Results
(`import-center-classification-results.png`) lists NAO-MGS, Kraken2,
EsViritu, TaxTriage — no CZ-ID entry.

### Recommendation

Add `lungfish import cz-id` mirroring `lungfish import nao-mgs`. Inputs:
the CZ-ID taxon report TSV (positional), optional `--non-host-fastq`,
optional `--metadata`. Output: `<project>/Classifications/<sample>.lungfishtax`
bundle with the standard taxonomy track schema, registered under the project
sidebar's Classifications. Add CZ-ID Results entry to the Import Center >
Classification Results pane.

### Acceptance criteria

- [ ] `lungfish import cz-id <report.tsv> --project <p> --sample-name <s>`
  produces a `Classifications/<sample>.lungfishtax` bundle
- [ ] Bundle is loadable in the GUI under Classifications, parity with NAO-MGS
- [ ] Import Center > Classification Results adds a CZ-ID Results entry
- [ ] Integration test against a captured CZ-ID export fixture under `Tests/Fixtures/czid/`
- [ ] `docs/user-manual/chapters/06-classification/07-importing-cz-id-results.md` updated to use the new importer

---

## docs-040a — Add Sample input and Project output anchor nodes

**Parent:** docs-040 (Workflow Builder)
**Severity:** P1

### Reproduction

```bash
$ grep -rn "sampleInput\|projectOutput\|pinned" \
    Sources/LungfishApp/Views/WorkflowBuilder/ \
    Sources/LungfishWorkflow/
# (no output)

$ grep -E "case .* = " Sources/LungfishWorkflow/Builder/WorkflowNode.swift
case fastqInput = "fastq_input"
case fastaInput = "fasta_input"
case bamInput = "bam_input"
case sampleSheet = "sample_sheet"
# ... export = "export"
```

`WorkflowNodeType` declares input and export node kinds, but they are
draggable like every other node. Chapter 08 promises pinned, non-draggable
Sample input and Project output nodes that bracket every workflow.

### Recommendation

Add `WorkflowGraph.sampleInput: WorkflowNode` and
`WorkflowGraph.projectOutput: WorkflowNode` as required, non-removable,
non-draggable members. Render at fixed canvas positions. Sample input's
port type is `Any` so any input node kind can connect; project output
accepts any output port.

### Acceptance criteria

- [ ] `WorkflowGraph.init` creates both anchors automatically
- [ ] `WorkflowGraph.removeNode(id:)` returns nil and is a no-op for either anchor's id
- [ ] `WorkflowCanvasView` renders both anchors with a distinct visual style
- [ ] Save/load round-trips the anchors
- [ ] `Tests/LungfishWorkflowTests/WorkflowBuilderTests.swift` adds a regression test

---

## docs-040b — Add Run button and switch save to native `.lungfishflow` bundle

**Parent:** docs-040 (Workflow Builder)
**Severity:** P1

### Reproduction

```bash
$ grep -rn "runWorkflow\|executeWorkflow\|runButton" \
    Sources/LungfishApp/Views/WorkflowBuilder/
# (no output)

$ grep -B1 -A3 "panel.allowedContentTypes" \
    Sources/LungfishApp/Views/WorkflowBuilder/WorkflowBuilderViewController.swift
176: panel.allowedContentTypes = [.json]
225: panel.allowedContentTypes = [.json]    # native save uses .json, not .lungfishflow
226: panel.nameFieldStringValue = "\(graph.name).json"
265: panel.allowedContentTypes = [UTType(filenameExtension: "nf") ?? ...]    # Nextflow EXPORT
```

Native save uses `.json`, not `.lungfishflow` as the chapter says. (The
`.nf` extension is used by `exportToNextflow` which DOES emit Nextflow DSL
via `NextflowExporter`.) No Run button.

### Recommendation

Switch native save and open to a `.lungfishflow` bundle directory containing
`graph.json`, `provenance.json`, and `runs/<run-id>/` per execution.
Register `org.lungfish.workflow` UTType in `Info.plist`. Add a toolbar
**Run** button that opens a sheet listing samples in the active project,
binds the chosen sample to the Sample input anchor (per docs-040a),
validates the graph, and dispatches each node to the Operation Center in
dependency order.

### Acceptance criteria

- [ ] `Info.plist` declares the `org.lungfish.workflow` UTType bound to `.lungfishflow`
- [ ] `WorkflowBuilderViewController.saveWorkflow` writes to a `.lungfishflow` bundle, never a bare `.json`
- [ ] `openWorkflow` accepts only `.lungfishflow` bundles
- [ ] Toolbar Run button exists; on press: sample picker sheet, validation, dispatch to Operation Center
- [ ] Operation Center rows for each node carry the workflow's run-id
- [ ] On node failure: stop downstream nodes, mark failed row red, expose Resume action

---

## docs-040c — Wire Workflow Builder into the application

**Parent:** docs-040 (Workflow Builder)
**Severity:** P1

### Reproduction

The Workflow Builder is **dead code**.

```bash
$ grep -rn "WorkflowBuilderViewController" Sources/ Tests/
# Sources/LungfishApp/Views/WorkflowBuilder/WorkflowBuilderViewController.swift
#   12, 25, 64, 375, 394, 585: self-references inside its own file only

$ grep -rn "Workflow" Sources/LungfishApp/App/MainMenu.swift
# 260:    withTitle: "Snakemake Workflow…",  # provenance export, not the builder
```

Tools menu (verified by screenshot `tools-menu.png`):

- Tools > FASTQ/FASTA Operations (submenu)
- Tools > Call Variants...
- Tools > Search Online Databases...
- Tools > Plugin Manager...

The 2,809-line WorkflowBuilder view + 1,300-line model are unreachable from
the GUI.

### Recommendation

Add `Tools > Workflow Builder...` menu item that opens a borderless-titlebar
window containing `WorkflowBuilderViewController`. Default size 1024x720.
Lazy creation on first menu invocation; reuse on subsequent. Cmd-W prompts
to save unsaved changes.

### Acceptance criteria

- [ ] `MainMenu.swift` adds `withTitle: "Workflow Builder…"` under Tools, before Plugin Manager…
- [ ] Selecting the menu item opens a window with `accessibilityIdentifier = "WorkflowBuilderWindow"`
- [ ] The window survives close-and-reopen with state
- [ ] Cmd-W prompts to save before closing if `hasUnsavedChanges` is true
- [ ] XCUI test asserts the menu item exists and opens the window

---

## docs-040d — Delete chapter 08-workflows/01-the-workflow-builder.md until docs-040a-c land

**Parent:** docs-040 (Workflow Builder)
**Severity:** P1 (documentation correctness)

### Background

`chapters/08-workflows/01-the-workflow-builder.md` describes a feature that
does not exist for end users. Every step in the procedure section fails at
the first instruction (no Tools > Workflow Builder menu item). Anyone
reading this chapter will conclude the manual is broken.

### Recommendation

Delete the chapter file in the same commit as docs-040c menu wiring lands.
Until that point, the chapter must not ship in any rendered manual build.
If a TOC stub is needed, a one-line "this chapter is being written; the
Workflow Builder is shipping in 0.5.0" placeholder is acceptable; the
current full-procedure chapter is not.

### Acceptance criteria

- [ ] Chapter file removed in the same PR as docs-040c
- [ ] If a stub replaces it, the stub is no longer than 5 lines and links to docs-040
- [ ] `docs/user-manual/ARCHITECTURE.md` TOC entry updated
- [ ] `docs/user-manual/help-ids.yaml` does not point any in-app surface at the deleted chapter

---
