# Compact miSEQ Haplotype Band and Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Show compact effective miSeq haplotype pairs in the genotype matrix and mount a shared-style, audited haplotype assignment editor when one sample column is selected.

**Architecture:** GenotypeHaplotypeCallBandSnapshot becomes the formatter for compact locus rows while retaining per-slot tooltip and accessibility APIs. A new effective-call editor adapts the existing assignment-editor layout controls to dynamic miSeq loci and saves through commitEffectiveHaplotypeMutation, keeping pipeline calls and analyst overrides in the effective projection rather than creating ManualHaplotypeAssignment records.

**Tech Stack:** Swift 6, AppKit, SwiftUI, Combine, XCTest, Lungfish annotation and audit store.

---

## File Map

- Modify Sources/LungfishGenotypeUI/GenotypeHaplotypeCallBand.swift for compact formatting.
- Modify Sources/LungfishGenotypeUI/GenotypeManualHaplotypeAssignmentBand.swift for one visible value with two semantic hit regions.
- Modify Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEditor.swift to share responsive controls.
- Create Sources/LungfishGenotypeUI/GenotypeEffectiveHaplotypeEditor.swift for the dynamic editor.
- Modify Sources/LungfishGenotypeUI/GenotypeResultViewController.swift to mount and persist the editor.
- Modify Tests/LungfishGenotypeUITests/GenotypeHaplotypeCallBandTests.swift.
- Create Tests/LungfishGenotypeUITests/GenotypeEffectiveHaplotypeEditorTests.swift.
- Modify Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift.

### Task 1: Compact Effective Haplotype Band

**Files:**
- Modify: Tests/LungfishGenotypeUITests/GenotypeHaplotypeCallBandTests.swift
- Modify: Sources/LungfishGenotypeUI/GenotypeHaplotypeCallBand.swift
- Modify: Sources/LungfishGenotypeUI/GenotypeManualHaplotypeAssignmentBand.swift

- [ ] **Step 1: Write failing compact-rendering tests**

Assert paired M2A • M4A, partial M2A • —, empty —, Too many genotypes, and Too many haplotypes. Assert visible values omit pipeline/status words while tooltip and accessibility summaries retain them. Assert H1 and H2 remain distinct accessible hit targets.

- [ ] **Step 2: Run tests to verify failure**

Run: swift test --filter GenotypeHaplotypeCallBandTests

Expected: failure because compact locus rendering does not exist.

- [ ] **Step 3: Implement minimal formatting**

Add renderedLocusValue(sample:locus:). Normalize empty, hyphen, ERR: TMG, ERR: TMH, not-assayed, and no-haplotype values to an em dash. Prioritize the two concise error labels. Otherwise join the two slots with a centered bullet. Leave rich tooltip and accessibility methods unchanged.

- [ ] **Step 4: Draw one value and preserve targets**

Replace per-slot drawing with one centered valueLayout(sample:locus:). Keep refreshEffectiveHitTargets split into H1 and H2 halves.

- [ ] **Step 5: Verify and commit**

Run: swift test --filter GenotypeHaplotypeCallBandTests

Expected: all band tests pass.

Commit the three files with message: fix: compact miSeq haplotype matrix rows

### Task 2: Dynamic Effective-Call Assignment Editor

**Files:**
- Create: Sources/LungfishGenotypeUI/GenotypeEffectiveHaplotypeEditor.swift
- Modify: Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEditor.swift
- Create: Tests/LungfishGenotypeUITests/GenotypeEffectiveHaplotypeEditorTests.swift

- [ ] **Step 1: Write failing model tests**

Test dynamic MHC-A/MHC-DR/MHC-DQ loci, seeded H1/H2 values, completeness, edits, clears, shared validation, read-only behavior, no-op Save, save-error draft retention, and reload.

- [ ] **Step 2: Run tests to verify failure**

Run: swift test --filter GenotypeEffectiveHaplotypeEditorTests

Expected: build failure because the model and view do not exist.

- [ ] **Step 3: Implement the model**

Create a hashable Address with String locus and HaplotypeSlot, plus a Snapshot containing sample, ordered loci, indexed values, suggestions, and read-only state. Store baseline and draft values, use the existing 128-scalar/control-character validation, expose changed addresses, and retain drafts after save errors.

- [ ] **Step 4: Implement the shared-style view**

Make ManualHaplotypeLocusLayout and ManualHaplotypeComboBox internal. Build the same card, heading, dynamic completeness, responsive H1/H2 rows, combo fields, clear controls, Save, read-only message, and retry/reload controls for effective miSeq loci.

- [ ] **Step 5: Verify and commit**

Run:
- swift test --filter GenotypeEffectiveHaplotypeEditorTests
- swift test --filter GenotypeManualHaplotypeEditorTests

Expected: both suites pass.

Commit with message: feat: add effective miSeq haplotype editor

### Task 3: Mount the Editor and Save Audited Overrides

**Files:**
- Modify: Sources/LungfishGenotypeUI/GenotypeResultViewController.swift
- Modify: Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift

- [ ] **Step 1: Write failing integration tests**

Select one haplotyped-miSeq matrix column and assert the effective editor is mounted with active loci and effective values. Edit H1 and H2 in one draft and assert one Save writes two call overrides, one sidecar notification, one workbook-dirty request, no manual assignments, and synchronized values in Haplotype Calls and Genotype Matrix. Clear an override and assert the pipeline value returns. Add read-only and no-op cases.

- [ ] **Step 2: Run focused tests to verify failure**

Run: swift test --filter GenotypeResultViewportTests/testHaplotypedMiSeq

Expected: failure because selected columns still use legacy detail.

- [ ] **Step 3: Build snapshots from the effective projection**

Preserve active included-locus order, normalize unresolved placeholders to empty fields, and collect completion suggestions from effective calls across the analysis. Never read or write manualHaplotypeAssignments.

- [ ] **Step 4: Mount the haplotyped-miSeq editor**

In showSingleSampleColumnSelection, put the effective editor in the existing sample curation workbench assignment column and retain the supported-alleles evidence column.

- [ ] **Step 5: Transact all changes once**

For a nonempty edit, create a CallOverrideMutation from the projected baseline to the draft value with analystJudgment and a plain generated rationale. For a cleared authoritative override, mutate back to baseline with rationale Restore pipeline call. Ignore cleared untouched pipeline values. Submit the complete array once through commitEffectiveHaplotypeMutation, then rebuild the editor snapshot. Propagate errors so the draft remains visible.

- [ ] **Step 6: Preserve draft transitions**

Include the effective editor in the existing Save/Discard/Cancel transition guard for sample, bundle, view, and filter changes.

- [ ] **Step 7: Verify and commit**

Run:
- swift test --filter GenotypeResultViewportTests/testHaplotypedMiSeq
- swift test --filter GenotypeResultViewportTests/testGenotypeOnly

Expected: synchronized miSeq and unchanged genotype-only tests pass.

Commit with message: feat: edit miSeq haplotypes from sample columns

### Task 4: Regression and Performance Verification

**Files:**
- Modify if needed: Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
- Modify if needed: Tests/LungfishGenotypeUITests/GenotypeManualHaplotypePerformanceTests.swift

- [ ] **Step 1: Add a no-rebuild assertion**

Capture testingProjectionPerformanceSnapshot before Save. Assert the base projection and full table reload counters do not increase, while the affected sample band is invalidated.

- [ ] **Step 2: Run focused suites**

Run:
- swift test --filter GenotypeHaplotypeCallBandTests
- swift test --filter GenotypeEffectiveHaplotypeEditorTests
- swift test --filter GenotypeManualHaplotypeEditorTests
- swift test --filter GenotypeManualHaplotypePerformanceTests
- swift test --filter GenotypeResultViewportTests/testHaplotypedMiSeq

Expected: all selected tests pass.

- [ ] **Step 3: Run the complete genotype UI suite**

Run: swift test --filter LungfishGenotypeUITests

Expected: zero failures.

- [ ] **Step 4: Inspect final state**

Run:
- git diff --check
- git status --short
- git diff main...HEAD --stat

Commit any final test refinements with message: test: verify compact miSeq haplotype editing
