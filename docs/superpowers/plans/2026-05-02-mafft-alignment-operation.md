# MAFFT Alignment Operation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the first MSA tool operation: run MAFFT from the Multiple Sequence Alignment conda pack and create a native `.lungfishmsa` bundle.

**Architecture:** Implement the scientific run in `LungfishWorkflow` as a small MAFFT request/command/pipeline unit, then expose it through `lungfish-cli align mafft`. The app launches that CLI command, parses JSON progress into Operation Center, and opens the resulting native bundle. The MAFFT run writes only project-owned artifacts; staging is under `<project>.lungfish/.tmp`.

**Tech Stack:** Swift 6.2, ArgumentParser, `CondaManager.runTool`, existing `.lungfishmsa` bundle writer, Operation Center JSON event parsing, XCTest.

---

## Expert Consensus

- First MSA tool is MAFFT.
- Default command is `mafft --auto --thread <threads> <staged-input.fasta>`, with stdout captured to an aligned FASTA.
- First release exposes conservative options only: `--strategy auto|localpair|globalpair|genafpair`, `--preserve-order`, `--threads`, `--name`, and optional extra arguments for CLI-only advanced use.
- The output is a `.lungfishmsa` bundle, not an exposed decoded FASTA.
- Bundle provenance must record both the Lungfish wrapper command and the external MAFFT invocation, including conda environment, executable path when available, version, argv, stdout/stderr, wall time, exit status, checksums, and final bundle paths.
- The canonical payload for IQ-TREE and TreeTime is `alignment/primary.aligned.fasta`.

## File Structure

- Create `Sources/LungfishWorkflow/MSA/MSAAlignmentRunRequest.swift`: request/options and MAFFT strategy enum.
- Create `Sources/LungfishWorkflow/MSA/MAFFTAlignmentPipeline.swift`: command construction, project-local staging, conda execution, import into `.lungfishmsa`.
- Create `Sources/LungfishCLI/Commands/AlignCommand.swift`: `lungfish align mafft` with JSON events.
- Create `Sources/LungfishApp/Services/CLIMSAAlignmentRunner.swift`: app runner that parses `msaAlignment*` JSON events.
- Modify `Sources/LungfishCLI/LungfishCLI.swift`: register `AlignCommand`.
- Modify `Sources/LungfishIO/Bundles/MultipleSequenceAlignmentBundle.swift`: allow external tool provenance details for generated bundles.
- Modify `Sources/LungfishApp/Services/DownloadCenter.swift`: add operation type for MSA generation.
- Modify `Sources/LungfishApp/Views/FASTQ/FASTQOperationsCatalog.swift`: add Alignment category requiring `multiple-sequence-alignment`.
- Modify `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift`: add MAFFT tool and pending request.
- Modify `Sources/LungfishApp/App/AppDelegate.swift`: dispatch pending MAFFT request through `CLIMSAAlignmentRunner`.

## Tasks

### Task 1: Workflow Command Model

- [ ] Write failing tests in `Tests/LungfishWorkflowTests/MSA/MAFFTAlignmentPipelineTests.swift` for command construction, strategy flags, project-local `.tmp` staging root, and provenance field propagation.
- [ ] Run `swift test --filter MAFFTAlignmentPipelineTests` and verify the tests fail because the MAFFT workflow types do not exist.
- [ ] Implement `MSAAlignmentRunRequest`, `MAFFTAlignmentStrategy`, `ManagedMSACommand`, and `MAFFTAlignmentPipeline.buildCommand(for:)`.
- [ ] Add pipeline execution using `CondaManager.runTool(name:"mafft", environment:"mafft", ...)`, capturing stdout to staged aligned FASTA and importing it with `MultipleSequenceAlignmentBundle.importAlignment`.
- [ ] Run `swift test --filter MAFFTAlignmentPipelineTests` and verify it passes.

### Task 2: CLI Surface

- [ ] Write failing tests in `Tests/LungfishCLITests/AlignCommandTests.swift` for `align mafft` request construction and JSON event emission using an injected runtime.
- [ ] Run `swift test --filter AlignCommandTests` and verify the tests fail because `AlignCommand` is missing.
- [ ] Add `AlignCommand` with `mafft` subcommand and JSON events: `msaAlignmentStart`, `msaAlignmentProgress`, `msaAlignmentWarning`, `msaAlignmentComplete`, `msaAlignmentFailed`.
- [ ] Register `AlignCommand` in `LungfishCLI`.
- [ ] Run `swift test --filter AlignCommandTests` and verify it passes.

### Task 3: App Operation Runner

- [ ] Write failing tests in `Tests/LungfishAppTests/CLIMSAAlignmentRunnerTests.swift` for argument construction and Operation Center progress parsing.
- [ ] Run `swift test --filter CLIMSAAlignmentRunnerTests` and verify the tests fail because the runner is missing.
- [ ] Add `CLIMSAAlignmentRunner` and `CLIMSAAlignmentEvent`.
- [ ] Add `OperationType.multipleSequenceAlignmentGeneration`.
- [ ] Run `swift test --filter CLIMSAAlignmentRunnerTests` and verify it passes.

### Task 4: FASTQ/FASTA Operations UI Wiring

- [ ] Write failing catalog/state tests asserting the Alignment category exists, requires `multiple-sequence-alignment`, contains MAFFT, and generates a pending `MSAAlignmentRunRequest`.
- [ ] Run `swift test --filter 'FASTQOperationsCatalogTests|FASTQOperationDialogRoutingTests'` and verify the new tests fail.
- [ ] Add `FASTQOperationCategoryID.alignment`, `FASTQOperationToolID.mafft`, `pendingMSAAlignmentRequest`, and a request builder that treats selected FASTA/reference/sequence bundles as inputs.
- [ ] Update `AppDelegate.showFASTQOperationsDialog` to call `runMAFFTAlignment(request:)`.
- [ ] Run the catalog/state tests and verify they pass.

### Task 5: Artifact Verification and Build

- [ ] Run `swift test --filter 'MAFFTAlignmentPipelineTests|AlignCommandTests|CLIMSAAlignmentRunnerTests|FASTQOperationsCatalogTests|PluginPackRegistryTests|MultipleSequenceAlignmentBundleTests'`.
- [ ] Run an env-gated real MAFFT smoke test only if the `mafft` conda environment is installed locally.
- [ ] Run `scripts/build-app.sh --debug --log-dir build/logs`.
- [ ] Report the debug build path and any blocked verification honestly.
