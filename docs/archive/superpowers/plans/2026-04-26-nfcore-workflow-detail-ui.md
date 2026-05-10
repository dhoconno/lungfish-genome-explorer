# nf-core Workflow Detail UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the compact nf-core dialog with an assembler-style workflow list and detail pane, including pinned nf-core versions and workflow-specific guidance.

**Architecture:** Extend the nf-core workflow catalog with deterministic pinned versions, input requirements, key parameters, and explanatory text. Teach the dialog model to derive selected-workflow details, version defaults, filtered project inputs, and CLI parameter values. Rebuild the AppKit dialog as a two-pane panel while preserving the existing `lungfish-cli` execution service and Operations Panel tracking.

**Tech Stack:** Swift 6, AppKit, SwiftPM tests, Xcode UI tests, existing Lungfish workflow models.

---

### Task 1: Catalog Metadata And Version Pinning

**Files:**
- Modify: `Sources/LungfishWorkflow/nf-core/NFCoreSupportedWorkflowCatalog.swift`
- Modify: `Sources/LungfishWorkflow/nf-core/NFCoreRunRequest.swift`
- Modify: `Sources/LungfishCLI/Commands/WorkflowCommand.swift`
- Test: `Tests/LungfishCLITests/CLIRegressionTests.swift`

- [ ] Add pinned versions, usage copy, accepted input extensions, primary input parameter, and key parameters to `NFCoreSupportedWorkflow`.
- [ ] Make `NFCoreRunRequest` resolve an empty version to `workflow.pinnedVersion`.
- [ ] Make CLI prepare and run commands include `-r <pinnedVersion>` when the user omits `--version`.
- [ ] Add a CLI regression test that parses an nf-core command without `--version` and verifies the generated request/arguments use the pinned version.

### Task 2: Dialog Model For Workflow Details

**Files:**
- Modify: `Sources/LungfishApp/Views/Workflow/NFCoreWorkflowDialogModel.swift`
- Test: `Tests/LungfishAppTests/NFCoreWorkflowDialogModelTests.swift`

- [ ] Add selected-workflow detail properties: title, overview, when-to-use text, required input description, expected outputs, pinned version label, command preview, and key parameter rows.
- [ ] Filter input candidates by selected workflow accepted extensions.
- [ ] For `fetchngs`, treat `.csv`, `.tsv`, and `.txt` accession/sample sheets as valid inputs and explain that FASTQ files are outputs, not inputs.
- [ ] Build request params from editable key parameter defaults.

### Task 3: Two-Pane AppKit Dialog

**Files:**
- Modify: `Sources/LungfishApp/App/XCUIAccessibilityIdentifiers.swift`
- Modify: `Sources/LungfishApp/Views/Workflow/NFCoreWorkflowDialogController.swift`
- Test: `Tests/LungfishXCUITests/NFCoreWorkflowXCUITests.swift`

- [ ] Replace the workflow popup with a left `NSTableView` of workflows.
- [ ] Add a right detail pane with overview, usage, inputs, outputs, version, executor, selected files, key parameters, and command preview.
- [ ] Preserve run/cancel buttons and Operations Panel execution.
- [ ] Add accessibility identifiers for the workflow list, selected detail fields, parameter fields, and command preview.

### Task 4: Verification And Integration

**Files:**
- Verify all touched files.

- [ ] Run focused SwiftPM tests for CLI, dialog model, and execution service.
- [ ] Run focused XCUI for nf-core dialog selection and deterministic execution.
- [ ] Run `swift build --product Lungfish`.
- [ ] Commit the branch if all verification passes.
