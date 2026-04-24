# Advanced Tool Options Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one arbitrary advanced-options string to assembly, mapping, and variant-calling dialogs and CLIs, then carry it into command execution and provenance.

**Architecture:** Add a shared parser in `LungfishWorkflow` so SwiftUI and CLI paths produce identical argv arrays. Reuse existing request `extraArguments`/`advancedArguments` for assembly and mapping; add the same field to variant calling and include it in durable variant metadata.

**Tech Stack:** Swift, Swift ArgumentParser, SwiftUI/AppKit, XCTest, LungfishWorkflow request/command builders.

---

### Task 1: Shared parser

**Files:**
- Modify: `Sources/LungfishWorkflow/Native/ShellUtilities.swift`
- Test: `Tests/LungfishWorkflowTests/AdvancedCommandLineOptionsTests.swift`

- [ ] Write failing tests for simple whitespace, single quotes, double quotes, and backslash escapes.
- [ ] Add `public enum AdvancedCommandLineOptions` with `parse(_:)` and `join(_:)`.
- [ ] Run `swift test --filter AdvancedCommandLineOptionsTests`.

### Task 2: Assembly

**Files:**
- Modify: `Sources/LungfishApp/Views/Assembly/AssemblyWizardSheet.swift`
- Modify: `Sources/LungfishCLI/Commands/AssembleCommand.swift`
- Modify: `Sources/LungfishApp/Views/Assembly/AssemblyConfigurationViewModel.swift`
- Modify: `Sources/LungfishWorkflow/Assembly/AssemblyProvenance.swift`
- Test: `Tests/LungfishCLITests/AssembleCommandTests.swift`
- Test: `Tests/LungfishWorkflowTests/Assembly/ManagedAssemblyPipelineTests.swift`
- Test: `Tests/LungfishWorkflowTests/Assembly/ManagedAssemblyArtifactTests.swift`

- [ ] Add failing tests for `--advanced-options "--k-min 21 --k-step 10"` parsing and command inclusion.
- [ ] Keep `--extra-arg` compatibility but combine it with parsed `--advanced-options`.
- [ ] Rename the dialog arbitrary field to "Advanced Options".
- [ ] Add explicit `advanced_arguments` to assembly provenance parameters.

### Task 3: Mapping

**Files:**
- Modify: `Sources/LungfishApp/Views/Mapping/MappingWizardSheet.swift`
- Modify: `Sources/LungfishCLI/Commands/MapCommand.swift`
- Test: `Tests/LungfishCLITests/MapCommandTests.swift`
- Test: `Tests/LungfishWorkflowTests/Mapping/ManagedMappingPipelineTests.swift`
- Test: `Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift`

- [ ] Add failing CLI tests for `--advanced-options "minid=0.97"` with BBMap and `--advanced-options "-A 2 --eqx"` with minimap2.
- [ ] Remove minimap2-specific advanced fields and validation.
- [ ] Parse the dialog and CLI string into `MappingRunRequest.advancedArguments`.
- [ ] Keep mapping provenance display using the existing `advancedArguments` row.

### Task 4: Variant Calling

**Files:**
- Modify: `Sources/LungfishWorkflow/Variants/BundleVariantCallingModels.swift`
- Modify: `Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift`
- Modify: `Sources/LungfishWorkflow/Variants/BundleVariantTrackAttachmentService.swift`
- Modify: `Sources/LungfishCLI/Commands/VariantsCommand.swift`
- Modify: `Sources/LungfishApp/Views/BAM/BAMVariantCallingDialogState.swift`
- Modify: `Sources/LungfishApp/Views/BAM/BAMVariantCallingToolPanes.swift`
- Modify: `Sources/LungfishApp/Services/CLIVariantCallingRunner.swift`
- Test: `Tests/LungfishWorkflowTests/Variants/ViralVariantCallingPipelineTests.swift`
- Test: `Tests/LungfishCLITests/VariantsCommandTests.swift`
- Test: `Tests/LungfishAppTests/BAMVariantCallingDialogRoutingTests.swift`
- Test: `Tests/LungfishAppTests/CLIVariantCallingRunnerTests.swift`

- [ ] Add failing tests that advanced args appear in LoFreq, iVar, and Medaka command lines.
- [ ] Add `advancedArguments` to request models and parse `--advanced-options`.
- [ ] Append advanced args at caller-safe positions.
- [ ] Store `advancedArguments` in caller parameters JSON and `variant_caller_command_line` metadata.

### Task 5: Verification and build

**Files:**
- Build script: `scripts/build-app.sh`

- [ ] Run focused tests for workflow, CLI, and app targets touched above.
- [ ] Run a debug build with `scripts/build-app.sh --configuration Debug` or the repo-supported equivalent.
- [ ] Inspect `git diff --check` and `git status --short`.
