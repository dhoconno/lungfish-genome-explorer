# MCM MHC MiSeq Prompt Preset Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a locked MCM MHC MiSeq preset that runs genotyping and prompt-based GPT-5.5 medium haplotyping against the curated MCM reference database.

**Architecture:** Introduce a small preset model in workflow code, use it from CLI and GUI request construction, bundle the reference resource with a digest manifest, and thread preset metadata into provenance. Keep generic genotyping and generic AI haplotyping configurable outside this preset.

**Tech Stack:** Swift Package Manager, ArgumentParser, AppKit/Swift UI state, Lungfish provenance JSON, bundled resources, XCTest, OpenAI structured-output provider.

---

### Task 1: Preset Model And Resource Manifest

**Files:**
- Create: `Sources/LungfishWorkflow/ONTGenotyping/MCMHaplotypingPreset.swift`
- Create: `Sources/LungfishWorkflow/Resources/MCMHaplotyping/mcm_mhc_miseq_reference.trimmed.unique.fasta`
- Create: `Sources/LungfishWorkflow/Resources/MCMHaplotyping/mcm-mhc-miseq-preset.json`
- Test: `Tests/LungfishWorkflowTests/MCMHaplotypingPresetTests.swift`

- [ ] Write failing tests that assert the preset ID, reference digest, record count, definition ID, assay ID, species code, model, and reasoning effort.
- [ ] Add the bundled reference and manifest.
- [ ] Implement loading and digest validation.
- [ ] Run `swift test --filter MCMHaplotypingPresetTests`.

### Task 2: CLI Preset Validation

**Files:**
- Modify: `Sources/LungfishCLI/Commands/FastqGenotypingSubcommand.swift`
- Modify: `Sources/LungfishCLI/Commands/FastqONTBarcodeGenotypingSubcommand.swift`
- Test: `Tests/LungfishCLITests/FastqGenotypingCommandTests.swift`
- Test: `Tests/LungfishCLITests/FastqONTBarcodeGenotypingCommandTests.swift`

- [ ] Write failing tests for `--preset mcm-mhc-miseq` without `--reference`.
- [ ] Write failing tests showing `--preset mcm-mhc-miseq --reference /tmp/other.fa` is rejected.
- [ ] Implement preset argument parsing and request construction.
- [ ] Run focused CLI tests.

### Task 3: GUI Preset Routing

**Files:**
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift`
- Modify: `Sources/LungfishApp/Services/WorkflowOperationExecutionService.swift`
- Test: `Tests/LungfishAppWorkflowTests/WorkflowOperationDialogStateTests.swift`
- Test: `Tests/LungfishAppWorkflowTests/WorkflowOperationExecutionServiceTests.swift`

- [ ] Write failing tests showing the GUI MCM workflow creates a request with the bundled preset reference and no user reference requirement.
- [ ] Implement GUI state and CLI argument emission for the preset.
- [ ] Run focused app workflow tests.

### Task 4: AI Haplotyping Preset Defaults

**Files:**
- Modify: `Sources/LungfishCLI/Commands/GenotypeAIHaplotypingSubcommand.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingRunner.swift`
- Test: `Tests/LungfishCLITests/GenotypeSubcommandsTests.swift`
- Test: `Tests/LungfishWorkflowTests/AIHaplotypingRunnerTests.swift`

- [ ] Write failing tests that preset AI haplotyping resolves to `gpt-5.5` and `medium`.
- [ ] Implement preset defaults without changing generic AI haplotyping defaults.
- [ ] Run focused AI haplotyping tests.

### Task 5: Provenance And Benchmark Verification

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift`
- Test: `Tests/LungfishWorkflowTests/ONTBarcodeDemuxGenotypingPipelineTests.swift`

- [ ] Write failing tests that preset provenance contains preset ID, reference digest, model, and reasoning effort.
- [ ] Implement provenance fields.
- [ ] Run focused provenance tests.
- [ ] Run a small sample workflow and compare calls to the previous GPT-5.5 medium benchmark.

### Task 6: Merge And Release

**Files:**
- Modify release notes and version files discovered during release prep.

- [ ] Run full relevant test suite.
- [ ] Commit implementation.
- [ ] Remove stale endpoint worktree once merged into `main`.
- [ ] Push `main`.
- [ ] Build signed/notarized DMG.
- [ ] Publish GitHub release asset and Sparkle notification.
