# Wave 5 Dead Workflow Prune Plan

> **For agentic workers:** Track the checklist below while pruning. Do not remove any nf-core catalog, run request, or run manifest type with live CLI or app callers.

**Goal:** Remove remaining unreferenced workflow surfaces without deleting live nf-core catalog/run-manifest behavior.

**Architecture:** The legacy workflow constraint API is isolated in `Sources/LungfishWorkflow/Constraints`. The old dynamic nf-core registry/client model is isolated in `Sources/LungfishWorkflow/nf-core/NFCoreRegistry.swift` and `Sources/LungfishWorkflow/nf-core/NFCorePipeline.swift`. The live nf-core path is the curated catalog plus run request/manifest model used by CLI and app workflow execution.

**Tech Stack:** Swift Package Manager, XCTest, `rg` for reference proof.

---

## Deadness Evidence

Run:

```bash
rg -n "BuiltInTools|NFCoreRegistry|GenericToolDefinition|InputSignature|LungfishWorkflow\\.ValidationResult|NFCorePipeline|ToolDefinition" Sources Tests -g '*.swift'
```

Observed before pruning:

- `BuiltInTools`, `GenericToolDefinition`, `InputSignature`, and workflow `ToolDefinition` only appear inside `Sources/LungfishWorkflow/Constraints`.
- `NFCoreRegistry` and `NFCorePipeline` only appear inside `Sources/LungfishWorkflow/nf-core/NFCoreRegistry.swift` and `Sources/LungfishWorkflow/nf-core/NFCorePipeline.swift`.
- `LungfishWorkflow.ValidationResult` only appears as the constraints implementation plus obsolete source-surface tests in `Tests/LungfishWorkflowTests/WorkflowRegressionTests.swift`.
- Unqualified `ValidationError` has unrelated live names in app, CLI, core, and workflow modules; only the constraints implementation and corresponding `WorkflowRegressionTests.swift` cases are part of this prune.
- `ToolDefinition` has unrelated live `AIToolDefinition` names and one explanatory comment in `Sources/LungfishWorkflow/Native/ToolProvisioning/ToolManifest.swift`; these are not part of the dead workflow surface.

Live nf-core evidence:

```bash
rg -n "NFCoreSupportedWorkflow|NFCoreRunBundleManifest|NFCoreRunRequest|NFCoreRunCommandBuilder|NFCoreResultAdapter" Sources Tests -g '*.swift'
```

Observed live callers include:

- `Sources/LungfishCLI/Commands/WorkflowCommand.swift`
- `Sources/LungfishApp/Services/ViralReconWorkflowExecutionService.swift`
- `Sources/LungfishApp/App/AboutAcknowledgements.swift`
- `Tests/LungfishWorkflowTests/NFCoreSupportedWorkflowCatalogTests.swift`
- `Tests/LungfishWorkflowTests/NFCoreRunRequestTests.swift`
- `Tests/LungfishWorkflowTests/NFCoreRunBundleManifestTests.swift`
- `Tests/LungfishCLITests/CLIRegressionTests.swift`

## Planned Changes

- [ ] Delete `Sources/LungfishWorkflow/Constraints/BuiltInTools.swift`.
- [ ] Delete `Sources/LungfishWorkflow/Constraints/InputSignature.swift`.
- [ ] Delete `Sources/LungfishWorkflow/Constraints/ToolDefinition.swift`.
- [ ] Delete `Sources/LungfishWorkflow/Constraints/ValidationResult.swift`.
- [ ] Delete `Sources/LungfishWorkflow/nf-core/NFCoreRegistry.swift`.
- [ ] Delete `Sources/LungfishWorkflow/nf-core/NFCorePipeline.swift`.
- [ ] Remove obsolete constraints-only `ValidationResultRegressionTests` and `ValidationErrorRegressionTests` from `Tests/LungfishWorkflowTests/WorkflowRegressionTests.swift`.
- [ ] Extend `Tests/LungfishWorkflowTests/DeadWorkflowSurfaceTests.swift` with a focused source hygiene test for the pruned workflow surface files.
- [ ] Keep `NFCoreSupportedWorkflowCatalog.swift`, `NFCoreRunRequest.swift`, and `NFCoreRunBundleManifest.swift` unchanged unless the compiler exposes a dependency.

## Verification

- [ ] Run the required reference scan:

```bash
rg -n "BuiltInTools|NFCoreRegistry|GenericToolDefinition|InputSignature|LungfishWorkflow\\.ValidationResult|NFCorePipeline|ToolDefinition" Sources Tests -g '*.swift'
```

Expected: no references to removed workflow constraints or old nf-core registry/pipeline types. Unrelated `AIToolDefinition` names and explanatory comments may remain.

- [ ] Run focused workflow tests:

```bash
swift test --filter LungfishWorkflowTests
```

- [ ] Run required builds:

```bash
swift build --product lungfish-cli
swift build --product Lungfish
```

- [ ] Run whitespace check:

```bash
git diff --check
```

- [ ] Commit the scoped change.
