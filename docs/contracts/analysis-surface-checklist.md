# Analysis surface checklist

Copy this file into the plan for a new surface in Lungfish Genome Explorer (LGE) and tick each box in the commit that satisfies it. The reasons and file paths behind every box are in `docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md` and `docs/contracts/ADDING-AN-OPERATION.md`. A box that does not apply gets a one-line reason instead of a tick.

## Before writing code

- [ ] The surface has a plan under `docs/plans/` that names the leaf target, the Workflow domain and every operation.
- [ ] Every scientific parameter, default and threshold is named in the plan with its source, and none is invented for the UI.
- [ ] Golden outputs or fixtures exist for any existing behaviour the surface will touch.
- [ ] The prerequisites the surface depends on (index cache, annotation input, count matrix, resource admission, registries) have landed.

## Module and result type

- [ ] The leaf target, its library product and its test target are declared in `Package.swift`, and LungfishApp depends on the leaf.
- [ ] The leaf imports only LungfishCore, LungfishIO, LungfishWorkflow and LungfishKit.
- [ ] Scientific logic and the result reader live in Workflow or IO, so the CLI can produce and read the result.
- [ ] Every new Swift file is at or under 800 lines.

## Each operation the surface launches

- [ ] One Workflow service, one CLI command and one GUI runner built on `CLISubprocessTransport`.
- [ ] `OperationCenter.shared.begin` with an explicit `operationType`, a non-nil `cliCommand` built from the executed argv, and declared lock scope.
- [ ] Progress mapped through `OperationCenterCLIBridge`, so the row gets both `update` and `log`.
- [ ] Cancellation reaches the subprocess without waiting on the running task.
- [ ] Virtual FASTQ inputs are materialized before any tool runs.

### Outputs and provenance

- [ ] `AnalysesFolder.createAnalysisDirectory` is called without `try?`, and a failed or cancelled run discards the folder.
- [ ] The producer calls `AnalysesFolder.markAnalysisComplete` and the GUI calls `trackAnalysisOutput`.
- [ ] Provenance is a `ProvenanceEnvelope` written by `ProvenanceWriter`, with argv, versions, input and output checksums, exit status and wall time.
- [ ] Alignments are sorted, indexed BAM, and no SAM is left behind.

## Viewport, Inspector and sidebar

- [ ] The viewport controller lives in the leaf and keeps its state in an injected `@MainActor @Observable` surface model.
- [ ] Inspector sections and row commands live in the leaf, and every row action has a keyboard and VoiceOver route.
- [ ] Results arriving from background work go through the patterns in `docs/contracts/CONCURRENCY-PLAYBOOK.md`, with a generation counter on every fetch that can be superseded.
- [ ] No new `MainActor.assumeIsolated` outside pattern 1, no new `@unchecked Sendable` without a lock, and no new `nonisolated(unsafe)`.

## App touch points until Phase 3

Tick each one or write "retired" once its program task has landed.

- [ ] `SidebarItemType` case and the switches in `Sources/LungfishApp/Views/Sidebar/SidebarItem.swift`.
- [ ] `displayContent(for:)` branch in `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift`.
- [ ] Viewport slot, `isNativeBundleViewportInstalled` and the hide calls in every other display method in `Sources/LungfishApp/Views/Viewer/`.
- [ ] Drawer arm in `toggleAnnotationDrawer` in `Sources/LungfishApp/Views/MainWindow/MainWindowController.swift`.
- [ ] Inspector update method in `Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift`.

### Recognition tables until Phase 2c and Phase 3b

- [ ] `knownTools`, `displayName(for:)` and `probeToolType(in:)` in `Sources/LungfishIO/Bundles/AnalysesFolder.swift`.
- [ ] Scanner arms in `Sources/LungfishApp/Views/Sidebar/SidebarProjectScanner.swift` and the icon in `Sources/LungfishApp/Views/Inspector/Sections/AnalysesSection.swift`.
- [ ] The Inspector filename-prefix arm in `Sources/LungfishApp/App/AppDelegate.swift`, if the result keeps its own Inspector tab.
- [ ] Classifier routing in `Sources/LungfishApp/Views/MainWindow/ClassifierDatabaseRouter.swift`, if the result is a classifier.
- [ ] Lock manifest, plugin pack and `NativeTool` entries for every new tool.

## Tests and registry

- [ ] An argv round-trip test proves the GUI's argv parses through the real CLI subcommand.
- [ ] A CLI test and a Workflow test check scientific output by value on a fixture.
- [ ] A CLI and GUI parity test shows identical output trees and provenance with timestamps masked.
- [ ] A routing test shows the surface opens for its result and binds the right inputs.
- [ ] `docs/user-manual/features.yaml` names every source file, the CLI command and the entry points.

### Before merge

- [ ] `swift test --filter` on the new test targets passes.
- [ ] The unit tier of `scripts/full-suite-gate.sh` passes in the primary checkout.
- [ ] The ratchets under `scripts/ratchets/` pass without a baseline change, or the commit explains the change.
- [ ] The app was launched and the surface exercised through the GUI, not only through code review.
