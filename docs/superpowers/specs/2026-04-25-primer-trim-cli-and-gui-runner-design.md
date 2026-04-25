# Primer-Trim CLI Subcommand and GUI Runner — Design

**Status:** Draft
**Date:** 2026-04-25
**Related:** `docs/superpowers/specs/2026-04-24-bam-primer-trim-and-primer-scheme-bundles-design.md` (Track 1, shipped)

## Summary

Track 1 shipped the BAM primer-trim pipeline, the `.lungfishprimers` bundle format, the canonical QIASeqDIRECT-SARS2 bundle, the Inspector button, and the iVar auto-confirm. What it deferred: clicking Run in the primer-trim dialog actually does nothing. The button opens the dialog, the dialog collects state, the dialog dismisses on Run, but `InspectorViewController.launchPrimerTrimOperation` is an empty stub.

This spec wires the GUI to the existing `BAMPrimerTrimPipeline` through a new CLI subcommand, mirroring how variant calling shells out to `lungfish-cli variants call`. The result: a script can run `lungfish-cli bam primer-trim …` and end up with a bundle in exactly the same state the GUI produces — a new alignment track plus its provenance sidecar — and the Inspector surfaces that provenance for any track that has it.

## Motivation

CLI parity is binding per `feedback_project_lead_process.md`: every GUI operation must shell out to the CLI so debugging, scripting, and testing all use the same code path. Track 1 stopped short of this for primer trimming because the runner wiring is a non-trivial slice on its own. Bringing the GUI online without the CLI parity rule satisfied would mean retrofitting both later, at higher cost.

The user's note: "All commands should be CLI backed so they can be run in scripts outside the app but create app-compatible output."

## CLI namespace

The subcommand is `lungfish-cli bam primer-trim`. The `bam` parent is new — there are no other `bam` subcommands today — but the BAM-vs-FASTQ distinction matters for primer trimming specifically. FASTQ-level primer trim (sequence-based, via cutadapt or bbduk) is a different operation from BAM-level primer trim (coordinate-based, via ivar trim). Future BAM-only operations (filter, sort, mark-duplicates, downsample) slot into `lungfish-cli bam …` cleanly.

## Architecture

```
LungfishCLI                        LungfishApp
┌─────────────────────────┐        ┌─────────────────────────────────┐
│ Commands/               │        │ Services/                       │
│   BAMCommand            │◄───────│   CLIPrimerTrimRunner           │
│     primer-trim         │ JSON   │     (actor, spawns lungfish-cli)│
│                         │ events │                                 │
└──────────┬──────────────┘ stdout └────────┬────────────────────────┘
           │                                │
           │ uses                           │ used by
           ▼                                ▼
┌─────────────────────────┐        ┌─────────────────────────────────┐
│ LungfishWorkflow        │        │ Views/Inspector/                │
│   Primers/              │        │   InspectorViewController       │
│     BAMPrimerTrimPipeline       │     .launchPrimerTrimOperation  │
│   (already exists)      │        │     (currently a stub)          │
└─────────────────────────┘        └─────────────────────────────────┘
```

### Reuse policy

- `BAMPrimerTrimPipeline.run` is unchanged. It is the load-bearing primitive both the CLI and existing tests already call.
- Bundle adoption (writing the new alignment track into the manifest) lives in **LungfishCLI**, not LungfishApp. The CLI is the single source of truth for "how a Lungfish-compatible bundle gets a new track." The GUI runner only drives the CLI; it never mutates the bundle directly. A script run produces an identical bundle to a GUI run.
- OperationCenter integration mirrors `CLIVariantCallingRunner` exactly: same JSON event protocol, same `applyEvent` static dispatcher, same `[weak self]` Task discipline, same DispatchQueue.main / MainActor.assumeIsolated guard for UI callbacks.

### Component boundaries

- **`BAMCommand`** (LungfishCLI) — top-level `lungfish-cli bam` group. Owns subcommand registration. Empty body otherwise; lifts when more BAM subcommands land.
- **`BAMPrimerTrimSubcommand`** (LungfishCLI) — argv parsing, bundle/track/scheme resolution, pipeline invocation, bundle adoption (rename pipeline outputs into `<bundle>/alignments/`, mutate manifest, write back). Emits JSON events on stdout when `--format json`. Emits text on stdout when `--format text` (default).
- **`CLIPrimerTrimRunner`** (LungfishApp) — actor wrapping a `Process`. Builds CLI args from a `BAMPrimerTrimDialogState`, parses each line of subprocess stdout into `CLIPrimerTrimEvent`, surfaces events via an `AsyncThrowingStream` (matches `CLIVariantCallingRunner`'s shape). Also exposes a `cancel()` that sends SIGTERM.
- **`InspectorViewController.launchPrimerTrimOperation`** — replaces the stub. Mirrors `launchVariantCallingOperation` line-for-line: OperationCenter lock check → start operation → spawn Task → run runner → map events to OperationCenter → reload sidebar on completion → present alert on failure.
- **`ReadStyleSectionViewModel.primerTrimProvenance`** — new optional, populated when the selected alignment track has a sibling primer-trim sidecar. Drives a new "Primer-trim Derivation" disclosure group in the Inspector.

## CLI surface

```
lungfish-cli bam primer-trim
  --bundle <path>                  # .lungfishref bundle path (required)
  --alignment-track <id>           # source alignment track ID (required)
  --scheme <path>                  # .lungfishprimers bundle directory (required)
  --name <string>                  # output alignment track name (required, no default)
  [--target-reference <name>]      # override @SQ SN; defaults to source BAM's @SQ
  [--ivar-min-quality <int>]       # default 20 (ivar trim -q)
  [--ivar-min-length <int>]        # default 30 (ivar trim -m)
  [--ivar-sliding-window <int>]    # default 4  (ivar trim -s)
  [--ivar-primer-offset <int>]     # default 0  (ivar trim -x)
  [--format json|text]             # default text; json emits structured events
  [--no-progress]                  # suppress periodic progress lines (text mode)
  [--threads <int>]                # default = ProcessInfo.activeProcessorCount
```

`--name` is required so batch scripts don't depend on auto-suggest. The GUI populates it from an editable field whose default is `"<source-track-name> • Primer-trimmed (<scheme-bundle-name>)"`.

## JSON event protocol

Mirrors `CLIVariantCallingEvent`. Each line is a complete JSON object terminated by `\n`. Errors go to stderr; exit code disambiguates.

```jsonl
{"event":"runStart","message":"Trimming primers"}
{"event":"preflightStart","message":"Resolving primer scheme"}
{"event":"preflightComplete","message":"Scheme: QIASeqDIRECT-SARS2 (563 primers)"}
{"event":"stageStart","message":"ivar trim"}
{"event":"stageProgress","progress":0.4,"message":"trim 40%"}
{"event":"stageComplete","message":"trim complete"}
{"event":"stageStart","message":"samtools sort/index"}
{"event":"stageComplete","message":"sort/index complete"}
{"event":"attachStart","message":"Adopting trimmed BAM into bundle"}
{"event":"attachComplete","trackID":"aln-...","trackName":"...","bamPath":"alignments/...","provenancePath":"alignments/....primer-trim-provenance.json"}
{"event":"runComplete","trackID":"aln-...","trackName":"...","bamPath":"alignments/...","provenancePath":"alignments/....primer-trim-provenance.json"}
```

`runFailed` may appear at any point and is followed by exit. The pipeline's own progress callback (currently `(Double, String) -> Void`) is bridged to `stageProgress` events.

## Bundle adoption contract

The CLI is responsible for landing three artifacts in the bundle. Same artifacts whether the trigger was GUI or `lungfish-cli` invocation:

### 1. Trimmed BAM and index

Path: `<bundle>/alignments/<sanitized-name>.primer-trimmed.bam` (and `.bai`). The path is bundle-relative; `sourcePath` and `indexPath` in the new manifest entry use the same relative form.

Naming: `--name` runs through the same filesystem sanitizer the variant-calling adopt path uses (lowercased, spaces→`-`, non-alphanum stripped), then `.primer-trimmed.bam` is appended. Collisions resolved by appending `-2`, `-3`, etc. The user-facing track *name* in the manifest is the original `--name` verbatim; only the on-disk filename is sanitized.

### 2. Provenance sidecar

Path: `<bundle>/alignments/<sanitized-name>.primer-trimmed.primer-trim-provenance.json`.

The CLI does not write this file directly. `BAMPrimerTrimPipeline.run` already writes it next to the output BAM using the load-bearing convention `<bam-sans-ext>.primer-trim-provenance.json`. The CLI's only job is to **move** the pipeline's output BAM and sidecar atomically into the bundle's `alignments/` directory while keeping the pairing intact (sidecar must remain at the BAM-sans-ext sibling path).

The sidecar's JSON content is unchanged from Track 1:

```json
{
  "operation": "primer-trim",
  "primer_scheme": {
    "bundle_name": "QIASeqDIRECT-SARS2",
    "bundle_source": "built-in",
    "bundle_version": "1.0.0",
    "canonical_accession": "MN908947.3"
  },
  "source_bam": "alignments/sample.sorted.bam",
  "ivar_version": "1.4.4",
  "ivar_trim_args": ["trim", "-b", "...", "-i", "...", "-p", "...", "-q", "20", "-m", "30", "-s", "4", "-x", "0", "-e"],
  "timestamp": "2026-04-25T..."
}
```

### 3. Manifest entry

Append a new `AlignmentTrackInfo` to `bundle.manifest.alignments`:

| Field | Value |
|---|---|
| `id` | `aln-<UUID>` (mirrors variant-track ID generation) |
| `name` | `--name` value verbatim |
| `description` | `"Primer-trimmed from <source-track-name> using <scheme-bundle-name>"` |
| `format` | `.bam` |
| `sourcePath` | `alignments/<sanitized-name>.primer-trimmed.bam` |
| `indexPath` | `alignments/<sanitized-name>.primer-trimmed.bam.bai` |
| `addedDate` | `Date()` at adopt time |
| `mappedReadCount` / `unmappedReadCount` / `sampleNames` | copied from the source track. iVar trim soft-clips primer-derived bases but does not remove reads, so the read counts and sample identities are unchanged. Staleness detection re-derives via `samtools idxstats` later if needed. |
| `checksumSHA256` / `fileSizeBytes` | unset on first adopt (matches `variants call`) |

The CLI rewrites `manifest.json` with the new entry plus an updated `modifiedDate`. Atomic write via temp file + rename.

## Bundle Inspector visibility

The user must be able to look at any alignment track and know whether it was primer-trimmed and exactly how. This is the primary affordance for trust and for reproducibility.

### Track listing — automatic

`AlignmentBundleSection` already iterates `bundle.manifest.alignments` and shows each track's stats. The new track appears in the list as soon as the manifest is rewritten — no Inspector code changes required for basic visibility.

### "Primer-trim Derivation" disclosure section — new

When a track is selected and the selected track's BAM has a sibling `.primer-trim-provenance.json` file, render a new disclosure group beneath "Alignment Summary":

> **Primer-trim Derivation**
> - Primer scheme: QIASeqDIRECT-SARS2 (built-in, version 1.0.0)
> - Canonical accession: MN908947.3
> - Source BAM: alignments/sample.sorted.bam
> - iVar version: 1.4.4
> - iVar trim args: `trim -b primers.bed -i input.bam -p output -q 20 -m 30 -s 4 -x 0 -e`
> - Timestamp: 2026-04-25 14:32:08
> - [Copy CLI command] (button reconstructing the `lungfish-cli bam primer-trim …` invocation that produced this track)

Implementation:
- Add `var primerTrimProvenance: BAMPrimerTrimProvenance?` to `ReadStyleSectionViewModel`. Populated whenever `selectedAlignmentTrackID` changes (in its existing `didSet`), using the same `<bam-sans-ext>.primer-trim-provenance.json` lookup that `BAMVariantCallingDialogState.readPrimerTrimProvenance` already uses. Move that helper into a shared location (`PrimerTrimProvenanceLoader.load(for:bundle:trackID:)`) and call it from both sites — single source of truth for the lookup logic.
- New `@ViewBuilder primerTrimDerivationSection` in `ReadStyleSection.swift`, rendered when `viewModel.primerTrimProvenance != nil`. Reuses the disclosure-group / `monospacedDigit` styling of "Alignment Summary".
- "Copy CLI command" button uses the same `OperationCenter.buildCLICommand` builder the operation panel uses for shell-quoted commands.

This pattern leans on file-on-disk-as-source-of-truth, which keeps the manifest small (we don't duplicate the sidecar contents into manifest fields) and ensures the Inspector reflects ground truth even if the manifest and sidecar drift.

## Error handling

CLI exits 1 (user-facing errors, before pipeline invocation):
- bundle path not found, or not a `.lungfishref` directory
- alignment track ID not in manifest
- alignment track's source BAM missing on disk
- scheme path not a `.lungfishprimers` bundle
- scheme fails `PrimerSchemeBundle.load`
- target reference resolves through neither canonical nor equivalent (`PrimerSchemeResolver.ResolveError.unknownAccession`)
- output `--name` collides with an existing track name (deterministic, no silent rename)

CLI exits 2 (tool failures, during pipeline invocation):
- `ivar trim` non-zero exit (passed through from `NativeToolRunner`)
- `samtools sort` or `samtools index` non-zero exit
- temp directory creation / disk full
- atomic manifest write failed

CLI exits 64 (argument errors): missing required flag, malformed value (parsed by ArgumentParser).

GUI mapping:
- Exit 1 → red banner alert with the stderr message
- Exit 2 → operation-failed entry in OperationCenter (auto-opens panel) with full stderr captured
- Runner crash / signal → "lungfish-cli terminated unexpectedly" alert

## Concurrency

- The CLI subprocess is spawned in the GUI as `Task(priority: .userInitiated)`.
- `CLIPrimerTrimRunner` is an actor managing the `Process` lifecycle (mirrors `CLIVariantCallingRunner`).
- Cancel button calls `runner.cancel()` which sends SIGTERM. The CLI catches SIGTERM, cleans up its temp directory (the pipeline's intermediate `.unsorted.bam` and rewritten BED), then exits non-zero with `runFailed` event.
- UI callbacks from the runner go through `DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { … } }` to avoid the cooperative-executor footgun documented in `MEMORY.md`.

## Idempotency and rollback

The CLI never modifies the source BAM. On failure mid-adopt (e.g., BAM written but manifest write fails), the CLI rolls back partially-written `<bundle>/alignments/*.primer-trimmed.bam`, `*.bai`, and `*.primer-trim-provenance.json` files before exiting. The bundle ends up either fully updated or fully unchanged — no half-state.

If the user runs the same `lungfish-cli bam primer-trim …` twice with the same `--name`, the second run exits 1 (collision) without touching the existing track. Re-running with a different `--name` produces a second track.

## Test plan

### CLI integration

`Tests/LungfishCLITests/BAMPrimerTrimSubcommandTests.swift`:
- Real `lungfish-cli bam primer-trim` against a fixture bundle wrapping the sarscov2 BAM (`MT192765.1` reference) using the existing `mt192765-integration.lungfishprimers` scheme.
- Asserts: exit 0, new alignment track in manifest with expected ID/name/sourcePath, BAM and BAI exist at expected paths, sidecar exists and decodes to `BAMPrimerTrimProvenance` with `bundle_name == "mt192765-integration"`.
- Skips when ivar/samtools missing in `~/.lungfish/conda`.
- Negative tests: nonexistent bundle, nonexistent track ID, scheme reference mismatch (expects exit 1), name collision (expects exit 1).

### GUI runner unit

`Tests/LungfishAppTests/PrimerTrim/CLIPrimerTrimRunnerTests.swift`:
- `buildCLIArguments(request:)` round-trips a fully-populated request struct.
- `parseEvent(from:)` parses every JSON event variant correctly.
- Empty / malformed / non-JSON lines are silently ignored.

### GUI integration

`Tests/LungfishIntegrationTests/PrimerTrim/PrimerTrimGUIIntegrationTests.swift`:
- Drives `InspectorViewController.launchPrimerTrimOperation` end-to-end against a fixture bundle.
- Asserts OperationCenter receives the expected sequence of events.
- Asserts the bundle ends up with the new track + sidecar after the operation completes.
- Asserts the Inspector's `ReadStyleSectionViewModel.primerTrimProvenance` populates when the new track is selected.

### Inspector display

`Tests/LungfishAppTests/PrimerTrim/PrimerTrimInspectorSectionTests.swift`:
- When an alignment track has a primer-trim sidecar, `ReadStyleSectionViewModel.primerTrimProvenance` populates and exposes the expected fields.
- When the track has no sidecar, the property is nil.
- Sidecar with wrong `operation` value → nil (matches Track 1's auto-confirm behavior).

### XCUI

`Tests/LungfishXCUITests/TestSupport/LungfishProjectFixtureBuilder.swift` extension:
- `makeMappedBundleProject(named:)` creates a `.lungfishref` bundle wrapping a tiny synthetic BAM (a few reads aligned to a 200bp synthetic chromosome with a corresponding small `.lungfishprimers` scheme). Generates the BAM via samtools at fixture-build time. Cached on disk between runs.
- `makePrimerTrimmedBundleProject(named:)` does the same plus pre-runs the pipeline to seed the sidecar.

`Tests/LungfishXCUITests/PrimerTrim/PrimerTrimXCUITests.swift`:
- `testInspectorButtonOpensDialog` (existing skipped test, unblocked by `makeMappedBundleProject`).
- `testRunButtonProducesNewTrack` (new): click Primer-trim BAM → pick scheme → click Run → wait for OperationCenter to settle → assert sidebar shows new alignment track and the inspector's primer-trim derivation section is visible.

`Tests/LungfishXCUITests/PrimerTrim/VariantCallingAutoConfirmXCUITests.swift`:
- `testVariantCallingDialogAutoConfirmsTrimForLungfishTrimmedBAM` (existing skipped test, unblocked by `makePrimerTrimmedBundleProject`).

## Files touched

**New:**
- `Sources/LungfishCLI/Commands/BAMCommand.swift` (~30 lines, `bam` parent group)
- `Sources/LungfishCLI/Commands/BAMPrimerTrimSubcommand.swift` (~250 lines)
- `Sources/LungfishApp/Services/CLIPrimerTrimRunner.swift` (~280 lines)
- `Sources/LungfishApp/Services/PrimerTrimProvenanceLoader.swift` (~30 lines, shared sidecar lookup)
- `Tests/LungfishCLITests/BAMPrimerTrimSubcommandTests.swift`
- `Tests/LungfishAppTests/PrimerTrim/CLIPrimerTrimRunnerTests.swift`
- `Tests/LungfishAppTests/PrimerTrim/PrimerTrimInspectorSectionTests.swift`
- `Tests/LungfishIntegrationTests/PrimerTrim/PrimerTrimGUIIntegrationTests.swift`
- `Tests/LungfishXCUITests/TestSupport/LungfishProjectFixtureBuilder+PrimerTrim.swift` (new fixture-builder methods)

**Modified:**
- `Sources/LungfishCLI/Lungfish.swift` (or wherever the root command's subcommand list lives) — register `BAMCommand` as a subcommand
- `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift` — `launchPrimerTrimOperation` becomes real, mirroring `launchVariantCallingOperation`. New `applyPrimerTrimEvent(_:operationID:)` static dispatcher.
- `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift` — add `var primerTrimProvenance: BAMPrimerTrimProvenance?` to `ReadStyleSectionViewModel`, populate when track changes, render new "Primer-trim Derivation" disclosure section.
- `Sources/LungfishApp/Views/BAM/BAMVariantCallingDialogState.swift` — replace local `readPrimerTrimProvenance` static with call to shared `PrimerTrimProvenanceLoader.load(...)`.
- `Tests/LungfishXCUITests/PrimerTrim/PrimerTrimXCUITests.swift` — remove `XCTSkip`, add `testRunButtonProducesNewTrack`.
- `Tests/LungfishXCUITests/PrimerTrim/VariantCallingAutoConfirmXCUITests.swift` — remove `XCTSkip`.

## Out of scope

- Adoption of trimmed BAMs into bundles other than the source bundle (e.g., importing a pre-trimmed BAM from disk). The Import Center already handles BAM import; if it needs primer-trim awareness, that's a separate spec.
- A FASTQ-level primer-trim CLI subcommand. When that lands, it will live elsewhere in the namespace (likely under FASTQ ops).
- Resampling primer-trim parameters from the source track's existing provenance (e.g., re-trimming a track with stricter min-quality). The user re-runs the dialog manually.
- Multi-track batch primer-trim in one CLI invocation. Scripts loop.
- Routing `PrimerSchemeInspectorView` as the inspector for `.lungfishprimers` selections in the sidebar. Already a Track 1 follow-up; orthogonal to this work.
