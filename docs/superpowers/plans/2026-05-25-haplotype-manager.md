# Haplotype Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a CLI-backed haplotype definition manager that is available before ONT genotyping and supports built-in, global, and project-scoped definitions.

**Architecture:** Add a shared haplotype definition command/catalog layer over the existing `HaplotypeDefinitionStore`. The CLI and app call the same command service, while the workflow dialog consumes scoped catalog records to expose assay, species, reference-library, haplotyping-mode, and definition-source choices.

**Tech Stack:** Swift, Swift Argument Parser, SwiftUI/AppKit, LungfishIO bundle models, LungfishWorkflow provenance helpers, XCTest.

---

### Task 1: CLI-Backed Definition Catalog and Command Service

**Files:**
- Create: `Sources/LungfishIO/Bundles/HaplotypeDefinitionLibrary.swift`
- Create: `Sources/LungfishWorkflow/ONTGenotyping/HaplotypeDefinitionCommandService.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift`
- Test: `Tests/LungfishIOTests/GenotypeHaplotypeRegistryTests.swift`
- Test: `Tests/LungfishWorkflowTests/HaplotypeDefinitionCommandServiceTests.swift`

- [ ] **Step 1: Write failing catalog tests**

Add tests asserting that built-in, global, and project records merge in project > global > built-in precedence, that shadowed records are reported, and that filtering by assay/species/scope returns only compatible active records.

- [ ] **Step 2: Run tests to verify RED**

Run: `swift test --filter GenotypeHaplotypeRegistryTests/testHaplotypeDefinitionLibrary`

Expected: compile failure because `HaplotypeDefinitionLibrary` does not exist.

- [ ] **Step 3: Implement catalog records**

Create `HaplotypeDefinitionScope`, `HaplotypeDefinitionRecord`, and `HaplotypeDefinitionLibrary`. Reuse `HaplotypeDefinitionStore(projectRoot:)` for global and project roots. Add `mergedRegistry()` and `activeRecords(assayID:speciesCode:scope:)`.

- [ ] **Step 4: Write failing command-service tests**

Add tests for `validate`, `importDefinition`, `exportDefinition`, `duplicateDefinition`, `updateDefinition`, and `deleteDefinition`. Tests must verify provenance sidecars include argv, input/output file records, checksums, and exit status.

- [ ] **Step 5: Run tests to verify RED**

Run: `swift test --filter HaplotypeDefinitionCommandServiceTests`

Expected: compile failure because `HaplotypeDefinitionCommandService` does not exist.

- [ ] **Step 6: Implement command service**

Create a service that validates definitions, resolves scope roots, writes through `HaplotypeDefinitionStore.save/delete`, exports JSON plus export provenance, duplicates read-only definitions into user scope, and rejects built-in mutations.

- [ ] **Step 7: Update ONT pipeline registry resolution**

Replace `HaplotypeDefinitionStore(projectRoot: projectURL).mergedRegistry()` with `HaplotypeDefinitionLibrary(projectRoot: projectURL).mergedRegistry()` so CLI/workflow runs can see global definitions.

- [ ] **Step 8: Run tests to verify GREEN**

Run:

```bash
swift test --filter GenotypeHaplotypeRegistryTests/testHaplotypeDefinitionLibrary
swift test --filter HaplotypeDefinitionCommandServiceTests
```

Expected: all new tests pass.

### Task 2: `lungfish haplotypes` CLI

**Files:**
- Create: `Sources/LungfishCLI/Commands/HaplotypeDefinitionsCommand.swift`
- Modify: `Sources/LungfishCLI/LungfishCLI.swift`
- Test: `Tests/LungfishCLITests/HaplotypeDefinitionsCommandTests.swift`

- [ ] **Step 1: Write failing CLI registration and parse tests**

Assert `LungfishCLI` registers command name `haplotypes`; assert subcommands are `list`, `validate`, `import`, `export`, `duplicate`, `create`, `update`, and `delete`; assert each parses scope/project/global-root/options correctly.

- [ ] **Step 2: Run tests to verify RED**

Run: `swift test --filter HaplotypeDefinitionsCommandTests`

Expected: compile failure because the command file does not exist.

- [ ] **Step 3: Implement CLI command group**

Add `HaplotypeDefinitionsCommand` and subcommands. Each subcommand delegates to `HaplotypeDefinitionCommandService` and prints deterministic JSON for machine use.

- [ ] **Step 4: Add CLI behavior tests**

Test importing a definition into project scope, listing it, exporting it, duplicating a built-in to project scope, updating it from JSON, deleting it, and validating malformed JSON failure.

- [ ] **Step 5: Run tests to verify GREEN**

Run: `swift test --filter HaplotypeDefinitionsCommandTests`

Expected: all haplotype CLI tests pass.

### Task 3: Workflow Setup Options

**Files:**
- Modify: `Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationDialogState.swift`
- Modify: `Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsDialog.swift`
- Test: `Tests/LungfishAppWorkflowTests/WorkflowOperationDialogStateTests.swift`

- [ ] **Step 1: Write failing state tests**

Add tests that global definitions are selectable before a run, species options derive from the selected assay, definition options filter by species and scope, and launch requests retain selected assay/definition.

- [ ] **Step 2: Run tests to verify RED**

Run: `swift test --filter WorkflowOperationDialogStateTests/testHaplotype`

Expected: failures for missing global catalog/scope/species state.

- [ ] **Step 3: Implement state additions**

Add selected haplotyping mode, species code, and definition scope/source state. Use `HaplotypeDefinitionLibrary` records for `haplotypeDefinitionOptions`.

- [ ] **Step 4: Update workflow dialog controls**

Expose controls for haplotyping mode, assay, species, source/scope, definition, compatibility note, and `Manage...`.

- [ ] **Step 5: Run tests to verify GREEN**

Run: `swift test --filter WorkflowOperationDialogStateTests/testHaplotype`

Expected: updated workflow setup tests pass.

### Task 4: Haplotype Manager UI

**Files:**
- Create: `Sources/LungfishApp/Views/Haplotypes/HaplotypeDefinitionManagerViewModel.swift`
- Create: `Sources/LungfishApp/Views/Haplotypes/HaplotypeDefinitionManagerView.swift`
- Create: `Sources/LungfishApp/Views/Haplotypes/HaplotypeDefinitionManagerWindowController.swift`
- Modify: `Sources/LungfishApp/App/MainMenu.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Test: `Tests/LungfishAppTests/HaplotypeDefinitionManagerViewModelTests.swift`
- Test: `Tests/LungfishAppTests/HaplotypeDefinitionsMenuTests.swift`

- [ ] **Step 1: Write failing manager view-model tests**

Test loading grouped records, importing through command service, exporting, duplicate-to-project/global, delete rejection for built-ins, and refresh after mutation.

- [ ] **Step 2: Run tests to verify RED**

Run: `swift test --filter HaplotypeDefinitionManagerViewModelTests`

Expected: compile failure because the view model does not exist.

- [ ] **Step 3: Implement view model**

Create a `@MainActor @Observable` view model around `HaplotypeDefinitionCommandService`. It should expose filtered records, selected record detail, actions, and error messages.

- [ ] **Step 4: Implement manager view and window controller**

Build a compact SwiftUI manager: search, scope filter, grouped list, detail pane, compatibility metadata, validation/provenance summary, and action buttons. Built-ins are read-only and offer duplicate actions.

- [ ] **Step 5: Write failing menu gating tests**

Assert `Tools > Haplotype Definitions...` exists only when ONT Genotyping is enabled in the Workflow Library.

- [ ] **Step 6: Implement menu and workflow integration**

Add the Tools menu item, AppDelegate action, validation gating, and workflow dialog `Manage...` presentation. Refresh workflow dialog state after manager closes.

- [ ] **Step 7: Run tests to verify GREEN**

Run:

```bash
swift test --filter HaplotypeDefinitionManagerViewModelTests
swift test --filter HaplotypeDefinitionsMenuTests
swift test --filter WorkflowOperationDialogStateTests/testHaplotype
```

Expected: manager, menu, and workflow setup tests pass.

### Task 5: Verification and Cleanup

**Files:**
- Modify only files touched by Tasks 1-4 if verification reveals defects.

- [ ] **Step 1: Run focused test suite**

Run:

```bash
swift test --filter HaplotypeDefinition
swift test --filter WorkflowOperationDialogStateTests/testHaplotype
swift test --filter FastqONTBarcodeGenotypingCommandTests
```

Expected: all focused tests pass. Document any unrelated pre-existing failures separately.

- [ ] **Step 2: Verify CLI manually**

Run:

```bash
.build/debug/lungfish haplotypes list --scope all --format json
.build/debug/lungfish haplotypes validate /path/to/example.lungfishhaplotypedef.json
```

Expected: list emits JSON and validate exits 0 for known-good JSON.

- [ ] **Step 3: Inspect git diff**

Run:

```bash
git diff --check
git status --short
```

Expected: no whitespace errors; only intended files modified.
