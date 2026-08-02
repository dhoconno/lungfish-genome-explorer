# Incomplete MHC Candidate Artifacts and Ranking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make partial class II observations scientifically honest and inspectable by ranking closest references with the complete edit burden, displaying a partial/unvalidated label, and publishing FASTA, GenBank, and EMBL sequence records that clearly state their validation limits.

**Architecture:** Keep reference-ready candidates unchanged. When canonicalization determines that a candidate covers only part of its reference, preserve its observed sequence as a diagnostic artifact, retain it in the un-nameable document, and mark every representation as partial and not reference-ready. Use substitution plus ordinary insertion/deletion bases when ranking competing closest references and when describing partial observations; never promote a partial observation to a named allele.

**Tech Stack:** Swift 6, XCTest, Lungfish typed bundle models, GenBank/FASTA renderers, a small deterministic EMBL renderer, JSON provenance manifests.

---

### Task 1: Correct closest-reference ranking and partial labels

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateClassifier.swift`
- Modify: `Sources/LungfishIO/Bundles/ONTMHCCandidateAlleles.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateClassifierTests.swift`

- [ ] **Step 1: Write a failing ranking regression test**

Create two partial-compatible alignments mirroring the DRB failure: one with one substitution plus several ordinary indel bases and a worse alignment score, and another with two substitutions, no indels, more comparable sequence, and a better score. Assert that the second reference is selected because it has fewer total observed edits.

- [ ] **Step 2: Run the focused classifier test and confirm it fails**

Run: `swift test --filter FullLengthONTMHCCandidateClassifierTests`

Expected: the new test reports that the SNP-only reference was selected.

- [ ] **Step 3: Rank biological matches by total edit burden**

Compare `snps + nonIntronIndelBases` before comparable bases and alignment score. Preserve deterministic name/reference/CIGAR fallbacks and keep intron-sized cDNA fills excluded from ordinary edit burden.

- [ ] **Step 4: Describe incomplete interpretations as partial observations**

Give `ONTMHCIncompleteCandidateInterpretation` a display name of the form `<closest-reference>_partial_<N>diff`, where `N` is substitutions plus ordinary inserted and deleted bases. Preserve the separate SNP, inserted-base, and deleted-base fields so analysts can inspect the evidence.

- [ ] **Step 5: Run focused model and classifier tests**

Run: `swift test --filter FullLengthONTMHCCandidateClassifierTests`

Expected: all focused tests pass.

### Task 2: Publish partial observed sequences with explicit warnings

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateArtifactWriter.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateArtifactWriterTests.swift`

- [ ] **Step 1: Replace the old omission assertions with failing diagnostic-export assertions**

Assert that an incomplete candidate has a FASTA record keyed by its stable cluster ID, a matching GenBank record, and comments that state the sequence is partial, cannot be fully validated, is not reference-ready, and must not be treated as a named allele.

- [ ] **Step 2: Run the focused artifact tests and confirm they fail**

Run: `swift test --filter FullLengthONTMHCCandidateArtifactWriterTests`

Expected: the incomplete candidate is absent from the current external artifacts.

- [ ] **Step 3: Retain diagnostic identity without changing publication readiness**

For `.incompleteReferenceSpan` only, store the normalized observed sequence under the raw stable cluster ID and its SHA-256 in the un-nameable document. Continue omitting candidates whose reference relationship is unavailable, and keep incomplete records out of `candidate_alleles.*` and the reference-ready deduplicated FASTA.

- [ ] **Step 4: Add warnings to FASTA and GenBank**

Write the FASTA warning in the description after the stable ID so parsers retain the exact ID. Publish the existing diagnostic GenBank record with the same observed sequence, append prominent `COMMENT` fields, and set source qualifiers declaring `reference_readiness_status=not-reference-ready-incomplete` and `validation_scope=partial-observation-only`.

- [ ] **Step 5: Update provenance wording and checksums**

Record that incomplete sequences are diagnostic outputs rather than reference-ready candidate publications, include them in output descriptors/checksums, and remove the obsolete “excluded from FASTA and GenBank” rule.

- [ ] **Step 6: Run focused artifact tests**

Run: `swift test --filter FullLengthONTMHCCandidateArtifactWriterTests`

Expected: all focused tests pass.

### Task 3: Add deterministic EMBL artifacts and surface all three formats

**Files:**
- Create: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCEMBLWriter.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateArtifactWriter.swift`
- Modify: `Sources/LungfishIO/Bundles/ONTMHCCandidateAlleles.swift`
- Modify: `Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCEMBLWriterTests.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateArtifactWriterTests.swift`
- Test: `Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift`

- [ ] **Step 1: Write failing EMBL format and manifest tests**

Assert deterministic `ID`, `AC`, `DE`, `CC`, `FT`, `SQ`, and terminator lines; verify that partial-record warning comments survive; verify optional candidate and un-nameable EMBL manifest fields round-trip without breaking older manifests.

- [ ] **Step 2: Run the focused tests and confirm they fail**

Run: `swift test --filter FullLengthONTMHCEMBLWriterTests && swift test --filter ONTGenotypeResultBundleTests`

Expected: the EMBL writer and manifest fields do not yet exist.

- [ ] **Step 3: Implement the minimal EMBL renderer**

Render the same sequence identity, definition, source span, and record comments already used for GenBank. Keep it deterministic and diagnostic; do not invent missing annotations or bases.

- [ ] **Step 4: Publish, checksum, and manifest EMBL outputs**

Create `candidate_alleles.embl` and `unnameable_unmatched_clusters.embl`, add them to staging/materialization/provenance, and add backward-compatible optional manifest and resolved-URL fields.

- [ ] **Step 5: Show EMBL links in the artifact inspector**

Add Candidate Alleles EMBL and Un-nameable Clusters EMBL rows beside their FASTA and GenBank counterparts when present.

- [ ] **Step 6: Run focused workflow, IO, and UI tests**

Run: `swift test --filter FullLengthONTMHCEMBLWriterTests && swift test --filter FullLengthONTMHCCandidateArtifactWriterTests && swift test --filter ONTGenotypeResultBundleTests && swift test --filter GenotypeResultViewportTests`

Expected: all focused tests pass.

### Task 4: Reproduce CN29 and rebuild the debug app

**Files:**
- Modify: `docs/superpowers/plans/2026-08-02-incomplete-candidate-artifacts-and-ranking.md` only if verification reveals a documented exception.

- [ ] **Step 1: Run the complete focused test set**

Run the classifier, artifact writer, GenBank builder, EMBL writer, bundle-loading, workbook-projection, and genotype viewport suites.

- [ ] **Step 2: Run CN29 against the versioned DRB reference into a fresh temporary bundle**

Use the same visible workflow options as the reported run. Verify provenance exists, the selected closest references reflect complete edit burden, labels say `partial`, incomplete records appear in FASTA/GenBank/EMBL with warnings, and no incomplete record appears in the reference-ready candidate files.

- [ ] **Step 3: Build and verify the debug app**

Run: `./scripts/build-app.sh --configuration debug --log-dir build/logs`

Verify the built app signature and bundle metadata, terminate the prior debug process, and launch the new worktree build.

- [ ] **Step 4: Commit the verified change**

Commit the implementation, tests, and plan on `codex/sidebar-row-filter-classii`. Do not merge or push unless requested.
