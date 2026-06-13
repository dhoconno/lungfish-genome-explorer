# Full-Length MHC Checkpoints Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add opt-in native checkpoints for full-length ONT MHC genotyping so report and workbook generation can be iterated without rerunning expensive SavONT clustering.

**Architecture:** Keep the workflow in Swift and add a small checkpoint layer inside `FullLengthONTMHCGenotypingPipeline`. Checkpoints are opt-in, stored under `.full-length-ont-mhc/checkpoints`, keyed by reproducibility signatures, and rehydrated into normal sample results with explicit provenance reuse steps.

**Nextflow recommendation:** Do not move the full-length ONT MHC workflow to Nextflow for this checkpointing need yet. The current workflow already has Swift-native scheduling, app integration, bundle writing, workbook generation, and provenance APIs. Introducing Nextflow would add another runtime, duplicate parameter/provenance translation, and complicate GUI reuse for a single workflow whose expensive boundary is sample-level SavONT/minimap processing. Revisit Nextflow if the workflow grows into a multi-tool cohort DAG that needs cluster/cloud execution, resume across many independent processes, or shared execution with existing Nextflow pipelines.

**Tech Stack:** Swift Package Manager, XCTest, LungfishWorkflow, LungfishCLI, existing `ProvenanceRunBuilder`/`ProvenanceEnvelope` APIs.

---

### Task 1: CLI and Request Model

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift`
- Modify: `Sources/LungfishCLI/Commands/FastqFullLengthONTMHCGenotypingSubcommand.swift`
- Modify: `Sources/LungfishApp/Services/WorkflowOperationExecutionService.swift`
- Test: `Tests/LungfishCLITests/FastqFullLengthONTMHCGenotypingCommandTests.swift`
- Test: `Tests/LungfishAppWorkflowTests/WorkflowOperationExecutionServiceTests.swift`

- [x] **Step 1: Write failing parser/argv tests**

Add tests that parse `--keep-intermediates` and `--reuse-compatible-checkpoints`, verify `FullLengthONTMHCGenotypingRunRequest.argv` includes them when enabled, and verify app CLI argument construction forwards them.

- [x] **Step 2: Run parser/argv tests to verify failure**

Run: `swift test --filter 'FastqFullLengthONTMHCGenotypingCommandTests|WorkflowOperationExecutionServiceTests'`
Expected: fails because the flags and request fields do not exist.

- [x] **Step 3: Implement request fields and CLI/app argument wiring**

Add Boolean fields with default `false`, append flags only when true, and thread them from CLI parse into the run request.

- [x] **Step 4: Run parser/argv tests to verify pass**

Run: `swift test --filter 'FastqFullLengthONTMHCGenotypingCommandTests|WorkflowOperationExecutionServiceTests'`
Expected: pass.

### Task 2: Sample Checkpoint Reuse

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`

- [x] **Step 1: Write failing workflow reuse test**

Add a test that runs the fake workflow once with checkpoint reuse enabled, swaps SavONT to a script that exits nonzero, runs the same request again, and verifies the second run completes, includes a `lungfish full-length MHC checkpoint reuse` provenance step, and does not add a second SavONT execution.

- [x] **Step 2: Run the single test to verify failure**

Run: `swift test --filter FullLengthONTMHCGenotypingPipelineTests/testRunReusesCompatibleSampleCheckpointWithoutRerunningSavont`
Expected: fails because the second run invokes SavONT.

- [x] **Step 3: Implement checkpoint manifests**

Persist a Codable sample checkpoint containing signature, sample result payload, retained output paths, and original provenance steps. Load it only when `reuseCompatibleCheckpoints` is enabled and the signature matches current inputs/options.

- [x] **Step 4: Run the single test to verify pass**

Run: `swift test --filter FullLengthONTMHCGenotypingPipelineTests/testRunReusesCompatibleSampleCheckpointWithoutRerunningSavont`
Expected: pass.

### Task 3: Cleanup, Provenance, and Focused Regression

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`

- [x] **Step 1: Add cleanup/provenance assertions**

Update or add tests confirming default cleanup still removes `workflow`, `--keep-intermediates` preserves it, checkpoint provenance records reuse plus final output bundle paths, and incompatible inputs do not reuse stale checkpoints.

- [x] **Step 2: Implement cleanup and signature guard refinements**

Make cleanup conditional on `keepIntermediates`, include checkpoint-related options in provenance defaults/resolved fields, and make signature mismatches fall through to recomputation.

- [x] **Step 3: Run focused workflow and CLI tests**

Run: `swift test --filter 'FullLengthONTMHCGenotypingPipelineTests|FastqFullLengthONTMHCGenotypingCommandTests|WorkflowOperationExecutionServiceTests'`
Expected: pass.

- [x] **Step 4: Commit implementation**

Run: `git status --short`, review the diff, then commit the checkpoint implementation after verification.
