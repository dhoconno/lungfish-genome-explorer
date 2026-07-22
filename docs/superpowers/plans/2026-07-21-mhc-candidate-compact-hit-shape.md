# Full-Length MHC Compact Hit-Shape Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Replace unbounded per-alignment candidate JSON locators with compact query-to-target hit shapes so fresh full-length MHC candidate artifacts load below the existing safety budget and remain instantaneous in the viewport.

**Architecture:** The CLI workflow remains the scientific producer. It streams the final cohort SAM into per-target query-count maps and reduces reciprocal classification alignments into per-query target-count maps. LungfishIO dual-reads version 1 and 2 documents into one bounded projection. The full-length-only viewport and both Excel export paths consume counts and relationships without opening BAMs; sorted/indexed BAMs remain authoritative for individual alignments.

**Tech Stack:** Swift 6, Codable JSON, XCTest, minimap2, samtools, AppKit, Python/openpyxl workbook updater.

---

## Task 1: Add version-2 compact hit-shape models

**Files:**

- Modify: `Sources/LungfishIO/Bundles/ONTMHCCandidateAlleles.swift`
- Test: `Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift`

- [ ] Add failing Codable and invariant tests for genotyping target summaries and reciprocal query summaries.
- [ ] Add typed compact summary models, computed alignment/edge counts, and version-aware legacy locator normalization.
- [ ] Keep one selected reciprocal locator per candidate and an optional selected locator per un-nameable record.
- [ ] Keep the artifact manifest at schema version 1 and write document schema version 2.
- [ ] Run the focused model tests.

## Task 2: Stream compact genotyping hit shapes

**Files:**

- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateArtifactWriter.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateArtifactWriterTests.swift`

- [ ] Add failing tests for duplicate alignment collapse, per-query counts, exact matches, closest ties, and multiple source targets.
- [ ] Replace `genotypingEvidenceLocators` with a streaming accumulator that emits summaries and discards per-alignment strings after use.
- [ ] Merge summaries by stable sequence/sample without merging distinct target IDs.
- [ ] Assert query counts sum to each summary's total.
- [ ] Record the derivation and resolved ranking rules in transformation provenance.
- [ ] Run focused pipeline/writer tests.

## Task 3: Compact reciprocal evidence

**Files:**

- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateClassifier.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateArtifactWriter.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateClassifierTests.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateArtifactWriterTests.swift`

- [ ] Add failing tests for target counts, biological closest ties, exact relationships, and no-alignment un-nameables.
- [ ] Reduce reciprocal alignments to one query hit shape per stable cluster.
- [ ] Retain the classifier-selected locator only; remove un-nameable bulk locator arrays from version 2.
- [ ] Validate selected targets against the closest target set.
- [ ] Run focused classifier/writer tests.

## Task 4: Dual-read and validate version 1/version 2 bundles

**Files:**

- Modify: `Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift`
- Test: `Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift`
- Test: `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift`

- [ ] Add failing tests for valid v1, valid v2, mixed versions, schema 3, negative/reconciled counts, target ownership, and typed BAM mismatches.
- [ ] Accept document versions 1 and 2 while leaving the manifest gate at version 1.
- [ ] Normalize version-1 locator arrays after bounded decoding and validate version-2 summaries directly.
- [ ] Keep fail-soft behavior and the 256 MiB aggregate safety budget unchanged.
- [ ] Run focused loader/update tests.

## Task 5: Project compact summaries into the viewport

**Files:**

- Modify: `Sources/LungfishGenotypeUI/GenotypeCandidateMatrixRow.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeCandidateEvidenceSection.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] Add failing tests for version-2 controls, per-sample counts, bounded selection details, and no BAM access on selection.
- [ ] Remove the unused flattened locator arrays from matrix rows.
- [ ] Show bounded counts and exact/closest names in the facts rail.
- [ ] Preserve the selected locator path used by the graphical allele view.
- [ ] Run focused viewport tests.

## Task 6: Update both Excel projections

**Files:**

- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCWorkbookProjection.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCWorkbookProjectionTests.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`
- Test: `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift`

- [ ] Add failing tests proving one row per stable ID, numeric hit counts, exact/closest relationship fields, and retention of all candidates in both analyst-facing views.
- [ ] Replace un-nameable locator-expanded rows with compact single rows.
- [ ] Update initial workbook sheets, the unified pivot, managed `Full Sequencing Results 1`, and the explicit current-workbook updater.
- [ ] Preserve candidate tints, separate colliding stable IDs, and analyst content outside managed blocks.
- [ ] Update the Interpretation Guide and workbook provenance.
- [ ] Run focused workbook tests.

## Task 7: Verify, analyze, build, and launch

- [ ] Run all focused IO, workflow, UI, CLI, and app tests touched by the change.
- [ ] Run the full Swift test suite and `git diff --check`.
- [ ] Generate a high-cardinality synthetic artifact and verify aggregate size and bounded load behavior.
- [ ] If practical, rerun the four-sample CLI exemplar against the supplied `.lungfishref` and verify novel/extension stable IDs link to `deduplicated_unmatched_clusters.fasta`.
- [ ] Build a fresh Debug app, confirm the user-visible app name is `Lungfish Debug`, quit older Lungfish instances, and launch the exact worktree build.
- [ ] Perform a final diff review limited to the full-length MHC surface and provenance requirements.
