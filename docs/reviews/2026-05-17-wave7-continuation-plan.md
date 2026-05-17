# Wave 7 Continuation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or an equivalent isolated worker flow. Keep write scopes disjoint, commit each slice, and preserve provenance requirements for every scientific-data workflow.

**Goal:** Continue remediation of the 2026-05-15 Claude review after Wave 6 by closing remaining actionable review debt in small, verifiable slices.

**Architecture:** Prefer narrow extractions and policy tests over large rewrites. Move pure workflow/provenance code toward `LungfishWorkflow`, keep AppKit-only presentation in `LungfishApp`, and replace source-level or modal anti-patterns with behavior-level seams where practical.

**Tech Stack:** Swift 6, SwiftPM, XCTest, AppKit, Lungfish workflow/provenance APIs.

---

## Current Evidence

- `Sources/LungfishApp/App/AppDelegate.swift` is still over 10k lines and owns unrelated operation routing, write-gate alerts, imports, exports, and workflow launches.
- `FASTQBundleMergeService` and `ReferenceBundleMergeService` create new scientific bundles without canonical final-bundle provenance.
- Production still has 10 `.runModal()` calls, all currently tolerated by legacy comments and a bounded source regression.
- `Sources/LungfishApp/Services/MetagenomicsBatchProvenanceWriter.swift` is pure provenance/workflow glue but lives in `LungfishApp` and is called by the provenance inspector.
- `Sources/LungfishApp/Services/FASTQDerivativeService.swift` is still over 5k lines; several reusable sidecar/parsing helpers are pure logic.
- `Sources/LungfishCLI` still contains generic `ExitCode.failure` throws in scientific commands outside Wave 6 scope.
- Many source-string tests remain; only replace batches where stable behavior seams already exist or can be introduced cheaply.

## Task A: Add Provenance To Bundle Merge Workflows

**Files:**
- Modify: `Sources/LungfishApp/Services/FASTQBundleMergeService.swift`
- Modify: `Sources/LungfishApp/Services/ReferenceBundleMergeService.swift`
- Modify: `Tests/LungfishAppTests/FASTQBundleMergeServiceTests.swift`
- Modify: `Tests/LungfishAppTests/ReferenceBundleMergeServiceTests.swift`

**Spec:**
- Every merge-created `.lungfishfastq` and `.lungfishref` bundle must get canonical `.lungfish-provenance.json` pointing at final stored payloads, not temporary staging files.
- Provenance must include source bundle inputs, final output records/checksums/sizes, workflow name/version, reproducible command/options, exit status, and wall time.
- If provenance writing fails after bundle creation, fail the merge and remove the partial output.
- Reference merges should reject non-sequence-only source bundles until annotation/variant/track merge semantics are implemented.

**Verification:**
- Decode provenance in merge tests and assert no temporary paths appear in reproducible command, input records, or output records.
- `swift test --filter FASTQBundleMergeServiceTests --filter ReferenceBundleMergeServiceTests`

## Task B: Remove Remaining Production `runModal()` Calls

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/PhylogeneticTreeViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift`
- Modify: `Tests/LungfishAppTests/AppKitConcurrencyModalSafetyTests.swift`

**Spec:**
- Replace no-window alert fallbacks with nonblocking behavior: sheet when a window exists, otherwise `NSApp.presentError`, `NSSound.beep()`, logged cancellation, or immediate `false` completion depending on existing semantics.
- Replace no-window save panel fallback with non-sheet `begin` or no-op cancellation. Do not block with `runModal()`.
- Update the modal safety test so production sources cannot contain `.runModal(` at all.

**Verification:**
- `swift test --filter AppKitConcurrencyModalSafetyTests`
- `rg -n '\.runModal\(' Sources/LungfishApp -g '*.swift'` must be empty.

## Task C: Extract App Write-Gate Presentation From AppDelegate

**Files:**
- Create: `Sources/LungfishApp/App/ProjectWriteGatePresenter.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: existing write-gate tests or add `Tests/LungfishAppTests/ProjectWriteGatePresenterTests.swift`

**Spec:**
- Centralize the duplicated "Project Is Open Read Only" alert construction and no-window fallback behavior.
- Keep project lock/read-only policy where it already lives; this slice only extracts the reusable presenter and reduces duplicated AppKit alert code.
- The presenter must be `@MainActor`, AppKit-only, and not introduce workflow dependencies.

**Verification:**
- Focused write-gate tests.
- `swift test --filter AppKitConcurrencyModalSafetyTests --filter ProjectLockWarningPresentationTests --filter MainWindowSessionRoutingTests`

## Task D: Move Metagenomics Batch Provenance Writer To Workflow

**Files:**
- Move/create: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsBatchProvenanceWriter.swift`
- Delete or leave shim: `Sources/LungfishApp/Services/MetagenomicsBatchProvenanceWriter.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/ProvenanceInspectorViewModel.swift`
- Modify/add: `Tests/LungfishWorkflowTests/MetagenomicsBatchProvenanceWriterTests.swift`
- Modify/add: app inspector tests if imports need adjusting.

**Spec:**
- Make the writer a workflow-layer utility with no AppKit imports.
- Preserve existing behavior: ensure EsViritu/TaxTriage batch provenance can be discovered/rehydrated and points at final bundle payloads.
- Do not weaken AGENTS provenance requirements; missing provenance for scientific outputs remains a blocking defect.

**Verification:**
- `swift test --filter MetagenomicsBatchProvenanceWriterTests --filter ProvenanceInspectorViewModelTests`
- `rg -n 'MetagenomicsBatchProvenanceWriter' Sources Tests`

## Task E: Extract Pure FASTQ Derivative Sidecar Helpers

**Files:**
- Create: `Sources/LungfishWorkflow/FASTQ/FASTQDerivativeSidecarIO.swift` or a more locally idiomatic path.
- Modify: `Sources/LungfishApp/Services/FASTQDerivativeService.swift`
- Modify/add: `Tests/LungfishWorkflowTests/FASTQDerivativeSidecarIOTests.swift`
- Modify focused app tests that exercise derivative sidecars.

**Spec:**
- Extract sidecar/trim-position/orient-map parsing and writing that does not depend on AppKit or UI state.
- Leave orchestration, OperationCenter integration, and app-specific bundle import behavior in `FASTQDerivativeService`.
- Keep public behavior and provenance output byte-for-byte compatible where tests already assert it.

**Verification:**
- `swift test --filter FASTQDerivativeSidecarIOTests --filter FASTQDerivativesTests --filter FASTQOperationExecutionServiceTests`

## Task F: Classify Remaining Scientific CLI Exit Codes

**Files:**
- Modify: targeted command files under `Sources/LungfishCLI/Commands/`
- Modify/add: `Tests/LungfishCLITests/CLIExitCodeProcessTests.swift`

**Spec:**
- Continue Wave 6 exit-code classification for scientific commands with clear mappings:
  - user input/config validation: `CLIExitCode.inputError`
  - output conflicts/write failures: `CLIExitCode.outputError`
  - scientific format parse failures: `CLIExitCode.formatError`
  - dependency/tool availability: `CLIExitCode.dependencyError`
  - runtime workflow failure after launch: `CLIExitCode.workflowError`
- Start with `ExtractReadsCommand`, `TaxTriageCommand`, `EsVirituCommand`, `NvdCommand`, and `NaoMgsCommand`.
- Do not remove or mask provenance for workflows that may have already produced outputs.

**Verification:**
- Red/green subprocess tests in `CLIExitCodeProcessTests`.
- `swift test --filter CLIExitCodeProcessTests --filter LungfishCLITests`

## Task G: Delete Quarantined BigBed Reader Implementations

**Files:**
- Modify/delete: `Sources/LungfishIO/Formats/BigBed/BigBedReader.swift`
- Modify/delete: `Sources/LungfishIO/Formats/BigBed/SyncBigBedReader.swift`
- Modify: any public re-exports or stale docs that describe BigBed reading as implemented.
- Modify: `Tests/LungfishIOTests/FormatRegistryTests.swift`

**Spec:**
- Keep BigBed format detection in the registry as unsupported/detection-only.
- Remove unavailable parser implementation bodies so dead code cannot be accidentally revived.
- Update user/developer-facing text to state that BigBed reading is intentionally unavailable pending a real UCSC/libBigWig-backed implementation.

**Verification:**
- `swift test --filter FormatRegistryTests`
- `swift build --target LungfishIO`

## Task H: Replace A High-Value Source-String Test Batch

**Files:**
- Modify: `Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift`
- Modify: `Tests/LungfishAppTests/MappingWizardSheetTests.swift`
- Modify: `Tests/LungfishAppTests/WelcomeSetupTests.swift`
- Add small presentation helpers only where behavior is not currently observable.

**Spec:**
- Replace source-string assertions that check user-visible labels, enabled states, or command-builder wiring with behavior-level assertions.
- Keep anti-pattern static tests where they enforce architecture boundaries and no better runtime seam exists.

**Verification:**
- `swift test --filter FASTQOperationDialogRoutingTests --filter MappingWizardSheetTests --filter WelcomeSetupTests`
- Warning-free `swift build --build-tests`.

## Integration Gates

- Merge slices only after focused tests pass and `git diff --check` is clean.
- After all merged: `swift build --build-tests`, `swift test`, static boundary greps, and debug app build via `scripts/build-app.sh --configuration debug`.
- Final debug app must be at `build/Debug/Lungfish.app` in the Wave 7 worktree and codesign-verified.
