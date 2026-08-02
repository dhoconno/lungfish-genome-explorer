# Partial MHC Named Candidates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish resolved partial MHC observations as ordinary named novel/extension candidates while describing their missing reference regions in every sequence format.

**Architecture:** Keep the classifier responsible for overlap-based biological ranking and the artifact canonicalizer responsible for determining whether an observed sequence is publishable. Allow `.incomplete` canonicalizations with a resolved lifted span into candidate aggregation, attach coverage descriptions while the reference projection is available, and preserve those comments through GenBank and EMBL publication.

**Tech Stack:** Swift 6, XCTest, Lungfish typed bundle artifacts, reciprocal minimap2 evidence, GenBank/FASTA/EMBL writers, provenance envelopes.

---

### Task 1: Restore overlap-only SNP ranking

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateClassifier.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateClassifierTests.swift`

- [ ] Add a regression test in which the hit with fewer overlap SNPs has more ordinary indel bases and must still be selected.
- [ ] Run the test and verify that total-edit-burden ranking selects the wrong reference.
- [ ] Rank by SNP count, comparable bases, and alignment score; retain lexical/evidence fallbacks only for deterministic ties.
- [ ] Run the complete classifier test suite.

### Task 2: Publish resolved partial canonicalizations as candidates

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateGenBankArtifactBuilder.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateCanonicalizer.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateArtifactWriter.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateArtifactWriterTests.swift`

- [ ] Change the incomplete-candidate fixture to require a standard `_Nnt_nov` candidate in candidate JSON/FASTA/GenBank/EMBL and no corresponding un-nameable record.
- [ ] Run the focused test and confirm the existing demotion fails it.
- [ ] Expose the observed lifted sequence for `.incomplete` candidate canonicalizations while keeping `.unavailable` blocked.
- [ ] Accept resolved `.incomplete` inputs in canonical aggregation and demote only inputs without a usable observed external sequence.
- [ ] Update source-identity and provenance rules to classify these records as candidates with partial reference coverage.
- [ ] Run the artifact-writer suite.

### Task 3: Describe missing reference sequence and annotations

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateGenBankArtifactBuilder.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCEMBLWriter.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateGenBankArtifactBuilderTests.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCEMBLWriterTests.swift`

- [ ] Add a builder test with an observation missing the leading reference interval and annotated exon/intron features.
- [ ] Verify the test fails because the current record only says the lifted CDS is incomplete.
- [ ] Add deterministic comments for observed reference coordinates, terminal missing-base counts, wholly absent annotated features, and observed-bases-only publication.
- [ ] Add matching source qualifiers and ensure EMBL preserves the comments.
- [ ] Run GenBank-builder and EMBL tests.

### Task 4: Remove obsolete partial-unnameable presentation

**Files:**
- Modify: `Sources/LungfishIO/Bundles/ONTMHCCandidateAlleles.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeAlleleSequenceRecord.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] Update UI regression tests to expect the partial sequence as an ordinary candidate record.
- [ ] Remove the newly added partial-unnameable sequence-detail path and prohibition wording while retaining backward-compatible decoding/display of older bundles.
- [ ] Ensure candidate sequence detail shows GenBank, FASTA, and EMBL content with partial-coverage comments.
- [ ] Run the focused viewport and sequence-record tests.

### Task 5: End-to-end scientific verification

**Files:**
- Modify: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift` only if provenance expectations change.

- [ ] Run classifier, canonicalizer, artifact-writer, EMBL, bundle-loader, workbook-projection, and viewport tests.
- [ ] Rerun CN29 against `IPD-MHC_NHKIR_Mamu-DRB.v3.17.0.0.2.lungfishref` with the reported workflow settings.
- [ ] Confirm candidates use normal `_Nnt_nov`/`_ext` labels, different closest references when supported, and missing-region comments in FASTA/GenBank/EMBL.
- [ ] Confirm provenance contains the exact inputs, options, checksums, output paths, runtime identity, timing, exit status, and new ranking/publication rules.
- [ ] Build, sign, relaunch, and smoke-test the debug app.
- [ ] Commit the verified implementation on `codex/sidebar-row-filter-classii` without merging or pushing.
