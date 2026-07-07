# Dynamic Clumping Defaults Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Trim Galore clumping support and default FASTQ import storage optimization to BBTools or Trim Galore based on input size versus available memory.

**Architecture:** Replace the current `skipClumpify` boolean at the ingestion boundary with a `ClumpingTool` enum: `auto`, `bbtools`, `trimGalore`, and `none`. Resolve `auto` after recipe execution and before ingestion so the decision uses the actual FASTQ files that will be clumped. The resolver estimates uncompressed input bytes, computes the BBTools heap budget as `min(31 GB, 60% physical RAM)`, and chooses BBTools when estimated input is at most 50% of that heap budget, otherwise Trim Galore.

**Tech Stack:** Swift 6.2, XCTest, ArgumentParser, AppKit, NativeToolRunner, bioconda Trim Galore.

---

### Task 1: Clumping Tool Model And Policy

**Files:**
- Create: `Sources/LungfishWorkflow/Ingestion/ClumpingTool.swift`
- Test: `Tests/LungfishWorkflowTests/FASTQClumpingToolTests.swift`

- [ ] **Step 1: Write failing tests** for `ClumpingTool.default == .auto`, raw CLI values, display names, and automatic resolution:

```swift
XCTAssertEqual(ClumpingTool.default, .auto)
XCTAssertEqual(ClumpingTool.auto.resolvedTool(inputBytes: 10_000, physicalMemoryBytes: 64.gib), .bbtools)
XCTAssertEqual(ClumpingTool.auto.resolvedTool(inputBytes: 40.gib, physicalMemoryBytes: 64.gib), .trimGalore)
```

- [ ] **Step 2: Run** `swift test --package-path . --skip-update --filter FASTQClumpingToolTests` and confirm it fails because `ClumpingTool` does not exist.

- [ ] **Step 3: Implement** `ClumpingTool` with a `Resolution` struct that records requested tool, resolved tool, estimated input bytes, physical memory bytes, heap bytes, threshold bytes, and reason.

- [ ] **Step 4: Run** the focused test and confirm it passes.

### Task 2: Register Trim Galore

**Files:**
- Modify: `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`
- Modify: `Sources/LungfishWorkflow/Native/NativeToolRunner.swift`
- Modify: `Sources/LungfishWorkflow/Conda/PluginPack.swift`
- Test: `Tests/LungfishWorkflowTests/NativeToolRunnerTests.swift`
- Test: `Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift`

- [ ] **Step 1: Write failing tests** that `NativeTool.trimGalore.executableName == "trim_galore"`, resolves to managed environment `trim_galore`, and the managed tool lock contains `trim_galore`.

- [ ] **Step 2: Run** the focused tests and confirm they fail because the tool is not registered.

- [ ] **Step 3: Register** `trim_galore` with bioconda package `bioconda::trim-galore=2.3.0`, GPL-3.0-only license metadata, source URL `https://github.com/FelixKrueger/TrimGalore`, and include it in the managed tool pack.

- [ ] **Step 4: Run** the focused tests and confirm they pass.

### Task 3: Ingestion Pipeline Branching

**Files:**
- Modify: `Sources/LungfishWorkflow/Ingestion/FASTQIngestionPipeline.swift`
- Modify: `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift`
- Test: `Tests/LungfishWorkflowTests/FASTQIngestionPipelineTests.swift`
- Test: `Tests/LungfishWorkflowTests/FASTQBatchImporterTests.swift`

- [ ] **Step 1: Write failing tests** for Trim Galore argument construction, automatic clumping resolution from input sizes, and provenance defaults that include requested/resolved clumping.

- [ ] **Step 2: Run** the focused tests and confirm failures.

- [ ] **Step 3: Implement** a Trim Galore branch using `trim_galore --clumpify --compression <N> --cores <N> --memory <budget> --output_dir <dir>`. Preserve existing BBTools behavior for `.bbtools`, existing compress-only behavior for `.none`, and choose using the resolver for `.auto`.

- [ ] **Step 4: Run** focused tests and confirm pass.

### Task 4: CLI And GUI Wiring

**Files:**
- Modify: `Sources/LungfishCLI/Commands/ImportFastqCommand.swift`
- Modify: `Sources/LungfishApp/Services/CLIImportRunner.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQImportConfiguration.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQImportConfigSheet.swift`
- Modify: FASTQ import call sites that currently use `skipClumpify`
- Test: `Tests/LungfishCLITests/CLIRegressionTests.swift`
- Test: `Tests/LungfishAppTests/CLIImportRunnerTests.swift`

- [ ] **Step 1: Write failing tests** for `--clumping-tool auto|bbtools|trim-galore|none`, CLI argument forwarding from the app, and default `auto`.

- [ ] **Step 2: Run** focused tests and confirm failures.

- [ ] **Step 3: Implement** the CLI option and import sheet popup. Preserve `--no-optimize-storage` as a compatibility alias for `--clumping-tool none`.

- [ ] **Step 4: Run** focused tests and confirm pass.

### Task 5: Verification And Commit

**Files:**
- All files changed above

- [ ] **Step 1: Run** `swift build --package-path /Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/weekly-issues-plans --skip-update`.

- [ ] **Step 2: Run** focused tests for clumping, tool registration, import CLI, batch importer, ingestion pipeline, and app CLI runner.

- [ ] **Step 3: Commit** with message `feat(import): choose clumping tool from memory pressure`.

