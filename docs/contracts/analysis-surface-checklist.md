# New operation and surface

This is the one path for a new operation that has a `lungfish-cli` command and a result surface in Lungfish Genome Explorer (LGE). Work the steps in order and tick each box in the commit that satisfies it. A box that does not apply gets a one-line reason. Each box names a file and symbol to copy and the one contract section, by heading, that explains it. Read that section only when the box leaves a question. Search `docs/architecture/MODULES.md` for a type and never read it whole.

## 1. Workflow service

- [ ] The service and its request type sit in a domain folder under `Sources/LungfishWorkflow/` and import no AppKit. Copy `TwelveSAmpliconMatchingWorkflow` in `Sources/LungfishWorkflowTwelveS/TwelveSAmpliconMatchingWorkflow.swift`. Section "Where a new domain goes" in `docs/contracts/ADDING-AN-OPERATION.md`.
- [ ] A domain becomes its own target, declared in `Package.swift` like `LungfishWorkflowTwelveS`, only when no other Workflow folder names its types.
- [ ] The result type on disk and its reader sit in `Sources/LungfishIO/`, so the CLI writes and reads the same result.
- [ ] Each scientific parameter, default and threshold has a cited source, and none is invented for the UI.
- [ ] A tool the service runs has a lock manifest entry and starts through `ToolProcess`. Section "Adding a managed tool" in `docs/contracts/RUNNING-A-TOOL.md`.

## 2. CLI command and provenance policy

- [ ] One `AsyncParsableCommand` sits in `Sources/LungfishCLI/Commands/`. A new group joins `subcommands` in `Sources/LungfishCLI/LungfishCLI.swift`. A subcommand of an existing group is a new file and one entry in that group's `subcommands`, as `FastqTwelveSMatchSubcommand` is for `FastqCommand`. Section "The recipe of a new CLI route" in `docs/contracts/ADDING-AN-OPERATION.md`.
- [ ] The command reports progress as `CLIEvent` lines through `CLIEventEmitter` and prints its output path, so a runner can follow it. Copy `Sources/LungfishCLI/Commands/TreeCommand.swift`.
- [ ] The command has an entry in `cliCommandPolicies` or `cliCommandPathPolicies` of `ScientificProvenancePolicy`, and a new group joins `canonicalCLICommandNames`, all in `Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift`. `ScientificCLIProvenanceCoverageTests` fails without it.
- [ ] The app route and the command run the same Workflow service, so one result needs no second implementation. Section "The rule" in `docs/contracts/CLI-EQUIVALENCE.md`.

## 3. GUI runner

- [ ] A `CLI<Name>Runner` in `Sources/LungfishApp/Services/` runs the command through `CLISubprocessTransport` and maps its events with `OperationCenterCLIBridge`, so a row gets both `update` and `log`. Copy `CLITreeRunner` in `Sources/LungfishApp/Services/CLITreeRunner.swift`.
- [ ] The launch site calls `OperationCenter.shared.begin` with an explicit `operationType`, a `cliCommand` built from the argv that runs, and a declared lock scope. Add an `OperationType` case in `Sources/LungfishKit/OperationCenter.swift` if none fits. The launch site is a new `AppDelegate+<Area>.swift` in `Sources/LungfishApp/App/` or `InspectorViewController+<Area>.swift` in `Sources/LungfishApp/Views/Inspector/`. Copy `Sources/LungfishApp/Views/Viewer/ViewerViewController+TreeInference.swift`. Section "Registering an operation with begin()" in `docs/contracts/ADDING-AN-OPERATION.md`.
- [ ] Cancel reaches the subprocess without waiting on the running task, and a cancelled or failed run discards its folder.
- [ ] A virtual FASTQ input is materialized before any tool runs. A FASTQ-input tool is a `FASTQOperationToolID` case with no hand-written menu item. Section "What a new FASTQ-input tool adds" in `docs/contracts/ADDING-AN-OPERATION.md`.

## 4. Provenance record

- [ ] The command makes its folder with `AnalysesFolder.createAnalysisDirectory` in `Sources/LungfishIO/Bundles/AnalysesFolder.swift` without `try?` and ends with `AnalysesFolder.markAnalysisComplete`. The GUI calls `trackAnalysisOutput` on the operation.
- [ ] The command writes one `ProvenanceEnvelope` with `CLIProvenanceSupport.recordSingleStepRun` in `Sources/LungfishCLI/Support/CLIProvenanceSupport.swift`, holding argv, tool versions, input and output checksums, exit status and wall time. Copy `Sources/LungfishCLI/Commands/TranslateCommand.swift`. Section "How to write a record today" in `docs/contracts/RECORDING-PROVENANCE.md`.
- [ ] A run on a project bundle calls `AnalysisManifestStore.recordAnalysis` in `Sources/LungfishIO/Bundles/AnalysisManifest.swift`, so the bundle's Inspector lists it.

## 5. Leaf module, viewport and registration

- [ ] The leaf target `Lungfish<Name>UI`, its library product and its `Lungfish<Name>UITests` target sit in `Package.swift` beside `LungfishTwelveSUI`, and LungfishApp depends on the leaf. The leaf imports only LungfishCore, LungfishIO, LungfishWorkflow and LungfishKit.
- [ ] The viewport is an `NSViewController` in the leaf, with its state in an injected `@MainActor @Observable` model, wrapped by a `ResultViewport` factory. Copy `Sources/LungfishTwelveSUI/TwelveSSurface.swift` and `Sources/LungfishTwelveSUI/TwelveSAmpliconResultViewController.swift`. Section "The leaf-module recipe" in `docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md`.
- [ ] One `registry.register` line sits in `makeSurfaceRegistry()` in `Sources/LungfishApp/Views/Viewer/ViewerViewController+Surfaces.swift`. The display method sits in a new `ViewerViewController+<Name>.swift`, starts with `clearSurfaceForNewContent()` and ends in `showSurface(_:input:as:)`. Copy `Sources/LungfishApp/Views/Viewer/ViewerViewController+TwelveS.swift`.
- [ ] Inspector sections and row commands live in the leaf, and every row action has a keyboard and VoiceOver route. The Inspector document is an update method in `Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift`, like `updateTwelveSAmpliconResultDocument`.
- [ ] Background results carry a generation counter, as the patterns in `docs/contracts/CONCURRENCY-PLAYBOOK.md` say. A new `Notification.Name` is avoided, and a needed one is classified in `ScopedEventFilter.classifications`.

## 6. Sidebar kind

- [ ] One `SidebarKindDescriptor` is added with `SidebarKindRegistry.register` in `Sources/LungfishIO/Bundles/SidebarKindRegistry.swift`, with row type `.registeredBundle`, so the kind opens from the sidebar with no App edit beyond step 5. Copy the stub kind in `Tests/LungfishAppTests/SidebarKindRegistryRouteTests.swift`. Section "Touch points that exist today" in `docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md`.
- [ ] A result under `Analyses/` also has one `AnalysisToolDescriptor` in `AnalysisToolRegistry.all` in `Sources/LungfishIO/Analysis/AnalysisToolRegistry.swift`, placed so no id plus a hyphen starts another, and the pins are updated by hand in the same commit, which are `AnalysisToolRegistryTests`, `AnalysisToolRunsToolsTests`, `AnalysesFolderDisplayNamePinTests`, `SidebarPresentationPinTests`, `InspectorAnalysesIconPinTests` and `SidebarScanSafetyNetProjects`. Section "Adding an analysis kind" in the same contract.
- [ ] The recognition tables take a hand edit. They are a `probeToolType(in:)` signature in `Sources/LungfishIO/Bundles/AnalysesFolder.swift` and the arms of `buildAnalysisNode` in `Sources/LungfishApp/Views/Sidebar/SidebarProjectScanner.swift`.
- [ ] No analysis id literal appears in a `switch`, `==` or `hasPrefix` outside `Sources/LungfishIO/Analysis/`. `scripts/ratchets/tool-identity.sh` passes without a baseline change.

## 7. Tests and ratchets

- [ ] An argv round-trip test parses the GUI's recorded command through the real subcommand. Copy `Tests/LungfishAppTests/CLIRunnerArgvRoundTripTests.swift`. Section "Tests that enforce it" in `docs/contracts/CLI-EQUIVALENCE.md`.
- [ ] A Workflow test and a CLI test check the scientific output by value on a small fixture. A parity replay test shows that the GUI route and the CLI make the same output tree and provenance with timestamps masked. Copy `Tests/LungfishAppTests/TwelveSResultExportCLIGUIParityReplayTests.swift`.
- [ ] A routing test shows the surface opens for its result, as `Tests/LungfishAppViewTests/SurfaceRegistrationStubTests.swift` does, and the new kind joins `Tests/LungfishAppTests/SafetyNets/ViewSwitchKinds.swift`.
- [ ] `docs/user-manual/features.yaml` names every source file, the CLI command and the entry points.
- [ ] Each new Swift file is at most 800 lines (`scripts/ratchets/file-size.sh`). The ratchets under `scripts/ratchets/` pass without a baseline change, and the surface was used through the GUI, not only through code review.
