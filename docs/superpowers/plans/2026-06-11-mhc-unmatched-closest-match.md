# MHC Unmatched Closest Match Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add closest-reference metadata and a shared read-count pivot for unmatched Savont clusters in the full-length ONT MHC genotype workbook.

**Architecture:** Extend `FullLengthONTMHCClusterGenotyper` so SNP-containing alignments are retained as closest-match candidates for clusters that are not exact genotype calls. Pass closest-match records through `FullLengthONTMHCGenotypingPipeline` to the XLSX package writer as two additional sheets. Keep all data deterministic and derived from existing minimap2/reference/Savont evidence.

**Tech Stack:** Swift Package Manager, XCTest, existing XLSX package writer, existing minimap2 SAM parser and FASTA parser.

---

### Task 1: Closest Match Classification

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCClusterGenotyper.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`

- [ ] Write a failing test proving unmatched clusters retain closest reference metadata when a SAM hit has SNP mismatches.
- [ ] Write a failing test proving zero-SNP indel-only hits are classified as extensions.
- [ ] Run the focused tests and confirm they fail for missing closest-match support.
- [ ] Add `FullLengthONTMHCClosestMatch` and include closest matches in `FullLengthONTMHCClusterGenotypingSummary`.
- [ ] Parse CIGAR `X`, `I`, `D`, and `=` counts into SNP, indel, and aligned-base metrics.
- [ ] Select best closest match by SNPs, indels, aligned bases, score, and reference name.
- [ ] Run the focused tests and confirm they pass.

### Task 2: Workbook Detail and Pivot Rows

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`

- [ ] Write a failing workbook-row test for `Unmatched Closest Matches` and `Unmatched Shared Pivot`.
- [ ] Run the focused test and confirm it fails because the sheets are not generated.
- [ ] Add pipeline row structs for unmatched closest-match details.
- [ ] Pass closest-match metadata from sample results into `writeWorkbook`.
- [ ] Add workbook rows for closest-match details and shared pivot.
- [ ] Keep `Unmatched Clusters` unchanged.
- [ ] Run the focused tests and confirm they pass.

### Task 3: Package Writer Sheet Coverage

**Files:**
- Modify: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`

- [ ] Update the XLSX package test to include the new sheet names and expected worksheet count.
- [ ] Run the package writer test and confirm it fails before workbook generation is updated.
- [ ] Verify the package writer supports the additional sheets without temp metadata.
- [ ] Run the package writer test and confirm it passes.

### Task 4: Verification

**Files:**
- No additional files expected.

- [ ] Run `swift test --filter FullLengthONTMHCGenotypingPipelineTests`.
- [ ] Run CLI-focused tests if the implementation changes public initializers or command behavior.
- [ ] Inspect `git diff --stat` and confirm only intended files changed.

