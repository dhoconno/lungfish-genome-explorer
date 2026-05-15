# Sequence Menu CLI Operations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every exposed Sequence menu command either perform its expected action through `lungfish-cli`, navigate the selected/current sequence correctly, or be removed/deferred when it is not ready.

**Architecture:** Scientific data changes are CLI-backed. The app gathers the active sequence/bundle target and visible options, launches a `lungfish` command, then refreshes/imports the resulting bundle state while preserving CLI provenance. ORF finding is implemented as a reference-bundle annotation-track command that stores translated products on ORF annotations; reverse complement and protein FASTA translation continue through the existing FASTQ/FASTA operation dialog and execution service.

**Tech Stack:** Swift Package Manager, Swift ArgumentParser, LungfishCore/LungfishIO/LungfishWorkflow provenance APIs, SQLite annotation databases, AppKit/SwiftUI operation dialogs, XCTest.

---

## File Structure

- `Sources/LungfishWorkflow/SequenceAnnotation/SequenceAnnotationTrackWorkflow.swift`: new shared workflow for building ORF annotation tracks inside `.lungfishref` bundles, with translated products stored in attributes.
- `Sources/LungfishCLI/Commands/SequenceCommand.swift`: new CLI group with the `annotate-orfs` subcommand.
- `Sources/LungfishCLI/LungfishCLI.swift`: register `SequenceCommand`.
- `Sources/LungfishCore/Models/SequenceAnnotation.swift`: add `orf` annotation type and color, while retaining translation rendering support for imported/legacy tracks.
- `Sources/LungfishCore/Bundles/BundleManifest.swift`: add `orf` annotation track kind.
- `Sources/LungfishApp/Services/SequenceAnnotationOperationRunner.swift`: new app-side CLI launcher for annotation-track commands.
- `Sources/LungfishApp/Views/Sequence/SequenceORFOperationDialog.swift`: new standard operation dialog for ORF annotation parameters.
- `Sources/LungfishApp/App/MainMenu.swift`: remove restriction-site menu item, add annotation-track operations.
- `Sources/LungfishApp/App/AppDelegate.swift`: wire Sequence actions to CLI-backed operations and fix active-window navigation.
- `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift` and bundle display extension as needed: expose active bundle/chromosome navigation helpers.
- `docs/TODO.md`: add deferred restriction-site search feature request.
- `Tests/LungfishCLITests/SequenceAnnotationCommandTests.swift`: CLI and provenance coverage for real bundle artifacts.
- `Tests/LungfishAppTests/SequenceMenuOperationTests.swift`: menu wiring, command construction, and restriction-site removal.
- `Tests/LungfishIntegrationTests/SequenceAnnotationE2ETests.swift`: real artifact smoke tests where practical.

## Task 1: CLI Annotation Workflow Tests

**Files:**
- Create: `Tests/LungfishCLITests/SequenceAnnotationCommandTests.swift`

- [ ] Write tests that create a small `.lungfishref` bundle containing `genome/sequence.fa`, `genome/sequence.fa.fai`, and `manifest.json`.
- [ ] Add a failing test for:
  - `SequenceCommand.AnnotateORFsSubcommand.parse([...])`
  - `try await command.run()`
  - exactly one new manifest annotation track with `annotation_type == "orf"`
  - SQLite rows containing `type == "ORF"`, `frame`, `length_nt`, `length_aa`, `start_codon`, `genetic_code_table`, and `partial`
  - bundle provenance exists at `.lungfish-provenance.json`, `provenance/bundle.lungfish-provenance.json`, and a per-output sidecar for the new SQLite database.
- [ ] Add a failing test proving standalone `annotate-translations` is not registered; ORF annotations carry translated peptide attributes instead.
- [ ] Add a failing parse/defaults test proving `--min-length`, `--table`, `--frames`, `--sequence`, `--start`, `--end`, `--track-id`, and `--track-name` are accepted and defaulted.
- [ ] Run:

```bash
swift test --filter SequenceAnnotationCommandTests
```

Expected before implementation: compile failure because `SequenceCommand` and the workflow do not exist.

## Task 2: Core/Workflow Implementation

**Files:**
- Modify: `Sources/LungfishCore/Models/SequenceAnnotation.swift`
- Modify: `Sources/LungfishCore/Bundles/BundleManifest.swift`
- Create: `Sources/LungfishWorkflow/SequenceAnnotation/SequenceAnnotationTrackWorkflow.swift`

- [ ] Add `AnnotationType.orf = "ORF"`, map it in `from(rawString:)`, and give it a distinct non-restriction color.
- [ ] Add `AnnotationTrackType.orf`.
- [ ] Implement request/result types:

```swift
public struct SequenceAnnotationTrackRequest: Sendable {
    public enum Operation: String, Sendable { case orf }
    public let bundleURL: URL
    public let operation: Operation
    public let sequenceName: String?
    public let start: Int?
    public let end: Int?
    public let frames: [ReadingFrame]
    public let codonTableID: Int
    public let minimumNucleotideLength: Int
    public let includePartial: Bool
    public let allowAlternativeStarts: Bool
    public let trackID: String?
    public let trackName: String?
    public let argv: [String]
}
```

- [ ] Implement `SequenceAnnotationTrackWorkflow.run(_:)` to:
  - load and validate the reference bundle manifest
  - fetch selected sequence/range using `ReferenceBundle.fetchSequence(region:)`
  - build BED-like rows with columns 12 and 13 carrying type and attributes
  - create `annotations/<track-id>.bed` and `annotations/<track-id>.db`
  - append a manifest annotation track
  - write CLI-grade provenance to the bundle root with outputs for the BED, DB, and manifest.
- [ ] ORF detection must use `CodonTable.table(id:)`, `CodonTable.isStartCodon`, and `CodonTable.isStopCodon`; alternative starts mean table starts plus GTG/TTG/CTG where not already present.
- [ ] ORF annotations must include `frame`, `translation`, `length_aa`, `genetic_code_table`, `sequence`, `range_start`, and `range_end`.
- [ ] Run:

```bash
swift test --filter SequenceAnnotationCommandTests
```

Expected after implementation: pass.

## Task 3: CLI Command Wiring

**Files:**
- Create: `Sources/LungfishCLI/Commands/SequenceCommand.swift`
- Modify: `Sources/LungfishCLI/LungfishCLI.swift`

- [ ] Implement `lungfish sequence annotate-orfs <bundle>`.
- [ ] Shared options:
  - `--sequence <name>`
  - `--start <0-based inclusive>`
  - `--end <0-based exclusive>`
  - `--frames +1,+2,+3,-1,-2,-3`
  - `--table <id>` default `1`
  - `--track-id <id>`
  - `--track-name <name>`
  - `--quiet`
- [ ] ORF-only options:
  - `--min-length <nt>` default `100`
  - `--include-partial`
  - `--allow-alternative-starts`
- [ ] Register `SequenceCommand.self` in `LungfishCLI`.
- [ ] Run:

```bash
swift test --filter SequenceAnnotationCommandTests
swift run lungfish-cli sequence annotate-orfs --help
```

Expected: tests pass and the help command lists the options above.

## Task 4: App Menu and Operation Dialogs

**Files:**
- Modify: `Sources/LungfishApp/App/MainMenu.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Create: `Sources/LungfishApp/Services/SequenceAnnotationOperationRunner.swift`
- Create: `Sources/LungfishApp/Views/Sequence/SequenceORFOperationDialog.swift`
- Modify/create app tests under `Tests/LungfishAppTests/`

- [ ] Remove `Find Restriction Sites...` from the Sequence menu and remove the action from `SequenceMenuActions`.
- [ ] Add `Find ORFs...`; do not add a separate Annotate Translations command.
- [ ] Keep `Reverse Complement...` and `Translate...` routed through `runSelectedSequenceFASTAOperation(toolID:)` / `showFASTQOperationsDialog`; do not add in-app sequence transformation logic.
- [ ] Add a standard operation dialog for ORF annotations with controls for sequence/range display, frames, codon table, track name, minimum ORF length, include partial ORFs, and alternative starts.
- [ ] Add `SequenceAnnotationOperationRunner` that builds and launches:

```bash
lungfish sequence annotate-orfs <bundle> --sequence <name> --start <start> --end <end> --frames <frames> --table <id> --min-length <nt> --track-name <name>
```

- [ ] After success, refresh the active reference bundle/sidebar so the new annotation track is visible.
- [ ] Add app tests that assert menu items exist/are absent and command construction is exact.

## Task 5: Go To Gene and Go To Location

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Modify: viewer helpers as needed
- Add tests under `Tests/LungfishAppTests/`

- [ ] Change `goToGene(_:)` to use `activeMainWindowController(sender:)`, matching `goToPosition(_:)`.
- [ ] Resolve navigation against the selected/current sequence target, not only the first/global viewer.
- [ ] For reference bundles, call chromosome-aware navigation with the selected chromosome length.
- [ ] For single FASTA/multi-sequence views, validate coordinates against the active sequence length and selected sequence name.
- [ ] Disable coordinate/gene navigation for non-coordinate FASTQ-only selections unless an associated reference/alignment target is available.

## Task 6: Restriction-Site Backlog

**Files:**
- Modify: `docs/TODO.md`
- Modify: `docs/user-manual/help-ids.yaml` if the removed menu help ID would otherwise expose a dead command.

- [ ] Add a dated deferred TODO entry for restriction-site searching.
- [ ] State that future implementation must be CLI-backed, provenance-writing, and track-producing; plugin-only searching is not sufficient.

## Task 7: Independent End-to-End Evaluation

**Files:**
- Create: `docs/superpowers/reviews/2026-05-15-sequence-menu-cli-ops-evaluation.md`

- [ ] Cycle 1: Build and run targeted CLI tests with real `.lungfishref` fixture.
- [ ] Cycle 2: Run direct CLI commands against a temporary real bundle; inspect `manifest.json`, SQLite rows, and `provenance/` sidecars.
- [ ] Cycle 3: Run app/menu tests for menu presence/absence, command construction, and navigation target selection.
- [ ] Cycle 4: Ask independent expert subagents to review CLI/provenance and app/menu behavior end to end.
- [ ] Cycle 5: If any blocking issues remain, patch and re-run the failed checks; otherwise record the residual risks.

Verification commands:

```bash
swift test --filter SequenceAnnotationCommandTests
swift test --filter SequenceMenuOperationTests
swift test --filter ScientificCLIProvenanceCoverageTests
swift build
```
