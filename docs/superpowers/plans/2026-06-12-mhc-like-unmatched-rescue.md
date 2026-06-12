# MHC-Like Unmatched Rescue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add local BLAST rescue evidence for unmatched full-length ONT MHC clusters and MHC-like-only workbook tabs.

**Architecture:** Keep exact genotype calling unchanged. Add a small rescue model/parser and workbook builders inside the existing ONT MHC pipeline file, then wire per-sample `blastn` rescue before workbook generation. Provenance records the BLAST query/reference FASTA inputs and TSV output for each rescue step.

**Tech Stack:** Swift, XCTest, existing XLSX package writer, NCBI `blastn`.

---

### Task 1: Workbook Builder Contract

**Files:**
- Modify: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift`

- [x] Add a failing unit test that builds rows with one original closest match, one rescued BLAST match, and one non-MHC unmatched cluster.
- [x] Verify the test fails because MHC-like detail/pivot builders do not exist.
- [x] Add the minimal row model and builder methods.
- [x] Verify the focused test passes.

### Task 2: BLAST Rescue Parser

**Files:**
- Modify: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift`

- [x] Add a failing parser test for accepted/rejected BLAST tabular rows and best-hit ordering.
- [x] Verify the parser test fails.
- [x] Implement tabular parsing, thresholding, and deterministic sorting.
- [x] Verify the parser test passes.

### Task 3: Pipeline Wiring and Provenance

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift`
- Modify: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`

- [x] Update workbook integration assertions to include `MHC-like Unmatched Clusters` and `MHC-like Unmatched Pivot`.
- [x] Run the focused integration test to verify it fails.
- [x] Write rescue query FASTA, run `blastn`, write rescue TSV, parse accepted hits, merge with original closest-match rows, and append a provenance step.
- [x] Add interpretation-guide text and top-level provenance options for rescue thresholds.
- [x] Verify focused tests pass.

### Task 4: Final Verification

**Files:**
- No new files.

- [x] Run `swift test --filter FullLengthONTMHCGenotypingPipelineTests`.
- [x] Inspect failures if any, fix only scoped issues, and rerun.
