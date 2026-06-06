# Haplotype Threshold Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep genotype evidence/workbooks complete while applying min-read and percent thresholds only to haplotype assignment.

**Architecture:** The retained-demux CSV remains the complete exact retained genotype observation table. The Swift haplotype analyzer applies the run thresholds from the request when creating persisted haplotype calls and evidence notes. The genotype viewport Inspector no longer exposes dynamic read/dropout filters; users rerun the genotyping workflow to change thresholded haplotype calls.

**Tech Stack:** Swift, Swift Testing/XCTest, embedded Python report/filter scripts, openpyxl verification.

---

### Task 1: Preserve Full Genotype CSV Rows

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift`
- Test: `Tests/LungfishWorkflowTests/ONTBarcodeDemuxGenotypingPipelineTests.swift`

- [ ] **Step 1: Write failing tests**

Change retained-demux filter tests so `--min-support`, `--haplotype-min-sample-percent`, and per-locus overrides do not remove rows from `*.retained_demux_genotypes.csv`.

- [ ] **Step 2: Verify red**

Run:

```bash
PATH=/Users/dho/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin:$PATH swift test --filter ONTBarcodeDemuxGenotypingPipelineTests/testRetainedDemuxGenotypeCSVIncludesRowsBelowHaplotypeMinSupport --filter ONTBarcodeDemuxGenotypingPipelineTests/testRetainedDemuxGenotypeCSVIncludesRowsBelowHaplotypePercentThresholds
```

Expected: failures because the current Python filter skips low-support rows.

- [ ] **Step 3: Implement**

Remove threshold gates from the Python `genotype_rows` loop, but keep threshold values in stats/provenance.

- [ ] **Step 4: Verify green**

Run the same focused tests; expected pass.

### Task 2: Apply Thresholds Only During Haplotype Analysis

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift`
- Test: `Tests/LungfishWorkflowTests/ONTBarcodeDemuxGenotypingPipelineTests.swift`
- Test: `Tests/LungfishIOTests/GenotypeHaplotypeAnalyzerTests.swift`

- [ ] **Step 1: Write failing tests**

Add a pipeline/report assertion that low-support genotype rows survive in the current workbook while persisted haplotype calls are derived from the filtered analyzer input.

- [ ] **Step 2: Verify red**

Run:

```bash
PATH=/Users/dho/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin:$PATH swift test --filter ONTBarcodeDemuxGenotypingPipelineTests/testReportScriptWritesMCMClientCurrentWorkbook
```

Expected: fail until workbook visibility and haplotype evidence are decoupled.

- [ ] **Step 3: Implement**

Ensure persisted `haplotype-analysis.json` uses `request.haplotypeDropoutEvaluator`, and ensure workbook generation consumes the unfiltered genotype CSV.

- [ ] **Step 4: Verify green**

Run related workflow and analyzer tests; expected pass.

### Task 3: Disable Inspector-Level Read Filtering

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Test: `Tests/LungfishAppTests/GenotypeResultDisplaySectionTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Write failing tests**

Assert the Inspector source no longer includes `Hide Low Support`, `Minimum Reads`, or live dropout text, and that saved dropout settings do not recompute viewport haplotypes.

- [ ] **Step 2: Verify red**

Run:

```bash
PATH=/Users/dho/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin:$PATH swift test --filter GenotypeResultDisplaySectionTests --filter GenotypeResultViewportTests/testConfigureUsesPersistedHaplotypeAnalysisWhenSavedDropoutThresholdsExist
```

Expected: fail on current Inspector source/live recomputation behavior.

- [ ] **Step 3: Implement**

Replace support/dropout controls with static guidance and stop eager recomputation from saved sidecar thresholds.

- [ ] **Step 4: Verify green**

Run the same tests plus focused viewport tests; expected pass.

### Task 4: Final Verification

- [ ] Run focused workflow/UI/CLI tests.
- [ ] Rebuild the Debug app.
- [ ] Verify the embedded CLI still exposes threshold options.
