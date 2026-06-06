# Current Workbook Provenance And Overrides Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the client-facing `current.xlsx` carry haplotype calling rules, make Review-pane override actions slot-explicit, and provide a GUI mechanism to update `current.xlsx` after analyst haplotype overrides.

**Architecture:** Keep pipeline workbook creation as the source of initial MCM workbook formatting, and add a small current-workbook refresh service for analyst override updates. The Review pane will emit explicit `(haplotype, slot)` override actions instead of inferring slots from the candidate name.

**Tech Stack:** Swift/AppKit/SwiftUI for the Viewport and sidecar workflow; embedded Python/openpyxl for workbook creation and workbook patching; existing `GenotypeWorkbookRevisionService` for current workbook history and provenance.

---

### Task 1: Interpretation Guide Provenance

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift`
- Test: `Tests/LungfishWorkflowTests/ONTBarcodeDemuxGenotypingPipelineTests.swift`

- [ ] Write a failing workbook-script test that passes threshold values in `stats.json` and expects the `Interpretation Guide` sheet to include min reads, sample percent, locus percent, per-locus overrides, assay, definition ID, analysis name, and run name.
- [ ] Update `write_interpretation_guide` to accept `args`, `stats`, `haplotype_analysis`, and `haplotype_definition`, append a “Run provenance” section, and preserve the current sheet order/formatting.
- [ ] Run the MCM workbook script test and confirm it passes.

### Task 2: Slot-Explicit Review Override Actions

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeCallEvidenceView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeCallEvidenceViewTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] Write a failing pure UI test for a `M4DP / M7DP` evidence row where candidate `M3DP` exposes two actions: `Replace H1 M4DP -> M3DP` and `Replace H2 M7DP -> M3DP`.
- [ ] Change the evidence view callback to include the selected `HaplotypeSlot`.
- [ ] Replace the single “Set haplotype” button with slot-explicit buttons generated from the current H1/H2 values.
- [ ] Add a controller test that applying a candidate to H1 records an H1 override and applying a candidate to H2 records an H2 override.

### Task 3: Update Current Workbook After Overrides

**Files:**
- Create or modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeCurrentWorkbookOverrideApplier.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Test: `Tests/LungfishWorkflowTests/GenotypeCurrentWorkbookOverrideApplierTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] Write a failing workflow test that creates a minimal MCM-style `current.xlsx`, applies an effective call map with an H1 override, and expects `Abbreviated Haplotypes`, `Full Sequencing Results 1`, and `Custom Sort` to reflect the override while the workbook revision service records provenance.
- [ ] Implement a focused openpyxl patcher service that snapshots the current workbook, patches haplotype cells from effective calls, writes a revision via `GenotypeWorkbookRevisionService.importRevisedWorkbook`, and records app provenance.
- [ ] Add a read-only “Workbook needs update” status and “Update Current Workbook” button in the artifact/Provenance lens when sidecar overrides exist.
- [ ] Mark the workbook stale after each override and clear the stale flag after successful update.

### Verification

- [ ] Run targeted tests for workbook provenance, Review actions, override sidecar behavior, and current workbook patching.
- [ ] Run the focused genotype/workflow test suite used for the MHC haplotyping work.
- [ ] Run the macOS Debug `xcodebuild` build.
