# TaxTriage Serial Batch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run multi-sample TaxTriage app jobs as one serial TaxTriage/Nextflow execution per sample while preserving aggregate batch viewing and provenance.

**Architecture:** Add a workflow-level serial batch runner that splits a multi-sample `TaxTriageConfig` into single-sample configs, executes them in order, and writes an aggregate root `TaxTriageResult`. Update the app to use the runner after FASTQ materialization. Update `build-db taxtriage` to parse serial sample subdirectories when the root has no direct TaxTriage reports.

**Tech Stack:** Swift, XCTest, ArgumentParser CLI, existing TaxTriage workflow/result models, existing ProvenanceRecorder.

---

### Task 1: Serial Runner Tests

**Files:**
- Modify: `Tests/LungfishWorkflowTests/TaxTriagePipelineTests.swift`

- [x] **Step 1: Write failing async tests**

Add tests that instantiate `TaxTriageSerialBatchRunner` with a fake pipeline closure. Verify sample IDs are observed in order, each fake pipeline call receives exactly one sample, multi-sample output directories are sample subdirectories, the aggregate result is saved at the batch root, and partial failures continue to later samples.

- [x] **Step 2: Run red tests**

Run: `swift test --filter TaxTriagePipelineTests/testSerialBatchRunner`

Expected: compile failure because `TaxTriageSerialBatchRunner` does not exist yet.

### Task 2: Recursive Build-DB Test

**Files:**
- Modify: `Tests/LungfishCLITests/BuildDbCommandTests.swift`

- [x] **Step 1: Write failing CLI test**

Create `taxtriage-batch/Alpha/top/Alpha.top_report.tsv` and `taxtriage-batch/Beta/top/Beta.top_report.tsv`, run `BuildDbCommand.TaxTriageSubcommand`, and assert the aggregate `taxtriage.sqlite` contains both samples.

- [x] **Step 2: Run red test**

Run: `swift test --filter BuildDbCommandTests/testBuildDbTaxTriageParsesSerialSampleSubdirectories`

Expected: failure saying no supported TaxTriage taxonomy report was found at the batch root.

### Task 3: Implement Serial Batch Runner

**Files:**
- Create: `Sources/LungfishWorkflow/TaxTriage/TaxTriageSerialBatchRunner.swift`
- Modify: `Sources/LungfishWorkflow/TaxTriage/TaxTriageResult.swift`

- [x] **Step 1: Add `TaxTriageSampleFailure` to `TaxTriageResult`**

Add a backward-compatible optional-decoding property for failed serial samples and include it in `summary`.

- [x] **Step 2: Add `TaxTriageSerialBatchRunner`**

Implement single-sample passthrough, multi-sample serial execution, sanitized unique sample directories, aggregate result saving, partial-failure continuation, all-failed error handling, and root `.lungfish-provenance.json`.

- [x] **Step 3: Run green workflow tests**

Run: `swift test --filter TaxTriagePipelineTests/testSerialBatchRunner`

Expected: serial runner tests pass.

### Task 4: Implement Recursive TaxTriage Build-DB Import

**Files:**
- Modify: `Sources/LungfishCLI/Commands/BuildDbCommand.swift`

- [x] **Step 1: Add serial sample directory discovery**

If root reports are absent, enumerate immediate child directories containing `report/multiqc_data/multiqc_confidences.txt` or `top/*.top_report.tsv`.

- [x] **Step 2: Prefix relative paths**

When parsed rows come from a sample subdirectory, prefix relative BAM/index paths with that subdirectory name before creating the aggregate database.

- [x] **Step 3: Run green CLI test**

Run: `swift test --filter BuildDbCommandTests/testBuildDbTaxTriageParsesSerialSampleSubdirectories`

Expected: aggregate DB contains both sample IDs.

### Task 5: App Integration

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`

- [x] **Step 1: Replace direct pipeline call after materialization**

Use `TaxTriageSerialBatchRunner().run(config: resolvedConfig, progress:)` instead of `TaxTriagePipeline().run(config:)`. The runner preserves single-sample behavior.

- [x] **Step 2: Surface sample failures**

Log sample failures to Operations Center and include them in completion text when partial failures occur.

- [x] **Step 3: Run focused app tests**

Run: `swift test --filter UnifiedClassifierRunnerTests/testFASTQOperationsDialogRunDispatchesOnlyMappingAndClassifierEmbedsDirectly`

Expected: app routing test passes.

### Task 6: Verification And Release Prep

**Files:**
- Modify version files and `docs/release-notes/v0.4.0-alpha.6.md`

- [x] **Step 1: Run focused tests**

Run the serial runner, build-db, routing, annotation import, annotation drawer, release configuration, CLI version, CLI help, and Conda lock tests.

- [x] **Step 2: Bump version**

Change all active `0.4.0-alpha.5` runtime/version assertions to `0.4.0-alpha.6`, leaving historical release notes intact.

- [x] **Step 3: Write release notes**

Document changes since `v0.4.0-alpha.5`, including TaxTriage serial batches, GFF3 custom type imports, import failure reporting, annotation drawer filtering under overload, and release maintenance.

- [ ] **Step 4: Commit, push main, tag, build notarized DMG**

Follow `.codex/agents/release-agent.md` exactly for source verification, tagging, notarized DMG generation, independent artifact verification, and GitHub release publication.
