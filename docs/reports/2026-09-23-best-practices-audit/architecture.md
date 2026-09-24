# Architecture and Module Design Audit (ARC)

Date: 2026-09-23. HEAD `a1f439076`. Reviewer area: architecture, module layering, composition roots, global state, duplicated subsystems, GUI/CLI parity, error and operation contracts.

## Scope, method, limits

**Read:** `Package.swift` (full target graph); import census of every module; `AppDelegate.swift` and its extensions (Classification, ImportCenter, MenuActions, ToolsMenu, ImportExport); `DocumentManager.swift`; `MainSplitViewController` extensions (GenomicsDisplay, FASTQImport, PrimerAnalysis); `InspectorViewController+Notifications.swift`; `SidebarViewController.swift`; `OperationCenter.swift`; all nine `App/Services/CLI*Runner.swift` files; `LungfishCLIRunner.swift`; `ClassifyCommand.swift`, `TreeCommand.swift`, `CondaCommand.swift`; `ClassificationPipeline.swift`; `MetagenomicsDatabaseRegistry.swift`; the FASTQ materializers (App and Workflow); `TaxTriageResultViewController.swift`; `ResultViewportController.swift`; the structure of `GenotypeResultViewController.swift` and `GenotypeComparisonMatrixView.swift`; `LungfishCore/Models/Notifications.swift`; the provenance file census.

**Ran:** read-only `grep`/`find`/`wc`/`diff` and small Python counting scripts (singletons, notifications and their window scoping, `Process()` spawn sites, `OperationCenter` call shapes, test hooks, `try?`, loggers). No builds or tests were run, as the brief requires.

**Limits:** Nothing here is **Confirmed** by execution. Findings are **Traced** (control flow followed in source) or **Suspected**. Counts come from grep and are approximate. Multi-line call sites can fool a regex, so every count used as evidence was spot-checked by hand. I sampled the 5K to 12K line files for structure and cohesion. I did not read them end to end.

## Executive summary

The module graph is sound, and SwiftPM enforces it. Core, IO and Workflow import no AppKit. The CLI does not import `LungfishKit`. No leaf can reach `LungfishApp`, because the package manifest makes that impossible, not because people remember the rule. The kernel-plus-leaves extraction worked. It should be kept.

The problems sit one level up, in how work gets done inside that graph. `LungfishApp` holds 234K lines, 44.7K of them in `Services/`, and much of that is UI-free business logic the CLI cannot reuse. The GUI runs analyses two different ways. Kraken2, EsViritu, TaxTriage, mapping, assembly, orient, demux and some FASTQ derivatives run the Workflow pipelines in-process. MSA, trees, variant calling, primer trim, imports and the FASTQ Operations dialog shell out to `lungfish-cli`. Each style has a hand-rolled copy per feature. There are nine near-identical `CLI*Runner` actors. About a dozen CLI JSON event schemas are parsed with `dict["message"] as? String`. There are 67 separate `OperationCenter.start` lifecycles. The replay command shown in the Operations panel is a hand-built string that can disagree with the real CLI (ARC-03 shows one that cannot be replayed).

Window-level state still leaks through globals. `AppDelegate.mainWindowController`, a `DocumentManager.shared` that mirrors the frontmost window, 122 `NSApp.keyWindow`/`mainWindow` lookups, and a fail-open notification scoping convention copied into three controllers all let one window's action land in another. Testability has been bought by putting about 1,290 `test*`/`testing*` hooks into production types, 286 of them in `GenotypeResultViewController` alone. That is the clearest sign that logic lives in view controllers rather than in models.

My recommendation is not a rewrite. Introduce three small seams: a typed **operation request/handle**, a single **CLI subprocess transport** with one Codable event schema, and a **per-window context** that replaces the global lookups. Then move logic behind those seams one feature at a time, deleting dead parallel code (ARC-08) as you go.

## Preserve (do not "fix" these away)

- **The SwiftPM target graph** ([Package.swift:205](Package.swift:205), [Package.swift:374](Package.swift:374), [Package.swift:434](Package.swift:434)). It makes App->leaf dependencies one-way and keeps the CLI free of AppKit. Every new layering rule should be enforced the same way, by the compiler.
- **No UI frameworks below Kit.** The import census shows zero `AppKit`/`SwiftUI` in Core, IO and Workflow. One small exception is noted in ARC-16.
- **The leaf pattern.** A leaf holds the view controller, display state and export service and exposes `on...` callbacks. The App glue (`ViewerViewController+<X>.swift`) wires services to those callbacks. This is the right inversion. It just has not been applied to the three large App-resident areas yet.
- **`OperationRouteContext` + `WindowStateScope`.** The concept is correct: each operation carries its project and window. ARC-04 and ARC-05 are about enforcing it, not replacing it.
- **`OperationCenter` bundle locks** ([OperationCenter.swift:381](Sources/LungfishKit/OperationCenter.swift:381)). Exact-versus-tree lock scopes checked before any key is acquired is a good design. Keep the semantics. Change only the API shape (ARC-04).
- **The out-of-process CLI model for mutating operations** (MSA, tree, primer trim, annotation delete). It isolates crashes, gives exact CLI parity, and produces provenance that says `lungfish-cli`. This should become *the* model (ARC-02). It should not be removed.
- **Convergence already under way.** `FASTQDerivativeService.materializeDatasetFASTQ` already delegates to Workflow's `FASTQCLIMaterializer` ([FASTQDerivativeService+Materialization.swift:16](Sources/LungfishApp/Services/FASTQDerivativeService+Materialization.swift:16)). That is the right direction.
- **`os.Logger` in library modules** (Core 17, IO 41, Workflow 56 loggers, with almost no `print`). The CLI's 1,068 `print` calls are user output, not logging, and are fine.
- **Generation counters and display-request tokens** (`beginDisplayRequest`/`canCommitDisplayRequest`) that reject stale async results.

## Findings

| ID | Priority | Title | Confidence | Effort |
|---|---|---|---|---|
| ARC-01 | P1 | Two execution models for GUI analyses, chosen per feature, with no shared service layer | Traced | L |
| ARC-02 | P1 | Nine copy-pasted CLI runner actors and about 12 ad-hoc, stringly-typed CLI event schemas | Traced | M |
| ARC-03 | P1 | Operations-panel "CLI command" strings are hand-built and drift from the real CLI (Kraken2 replay cannot run) | Traced | M |
| ARC-04 | P1 | `OperationCenter.start` can return an already-failed operation, and callers are not forced to notice | Traced | M |
| ARC-05 | P2 | Per-window state leaks through globals (`mainWindowController`, `DocumentManager.shared` mirror, `NSApp.keyWindow`) | Traced | L |
| ARC-06 | P2 | Window scoping of notifications is a fail-open convention reimplemented in three controllers | Traced | M |
| ARC-07 | P2 | GUI and CLI write different provenance for the same Kraken2 analysis | Traced (impact Suspected) | M |
| ARC-08 | P2 | Dead parallel FASTQ materializer (~1,100 lines) kept alive only by tests | Traced | S |
| ARC-09 | P2 | FASTQ derivative operations have two GUI code paths and two CLI-command builders | Traced | M |
| ARC-10 | P2 | `AppDelegate` extensions are the business-logic layer for import, export, downloads and classification | Traced | L |
| ARC-11 | P2 | About 1,290 test hooks in production types, a symptom of logic trapped in view controllers | Traced | L |
| ARC-12 | P2 | `GenotypeResultViewController` is a 9.8K-line god object (323 stored vars, 508 funcs) | Traced | L |
| ARC-13 | P1 | TaxTriage view controller runs samtools synchronously on the main actor, with a pipe-ordering hazard | Traced | S |
| ARC-14 | P3 | `ResultViewportController` / `BlastVerifiable` are premature abstractions with no polymorphic consumer | Traced | S |
| ARC-15 | P2 | Five external-process mechanisms, plus about 120 raw `Process()` sites across all layers | Traced | L |
| ARC-16 | P3 | Misplaced vocabulary: UI event names in Core, test harness in Kit, CGPoint graph model in Workflow, dead notifications | Traced | S |

---

### ARC-01 Two execution models for GUI analyses, chosen per feature, with no shared service layer (P1, Traced, L)

**Evidence.**
- In-process pipelines instantiated from App: `ClassificationPipeline()` at [AppDelegate+Classification.swift:848](Sources/LungfishApp/App/AppDelegate+Classification.swift:848), `EsVirituPipeline()` at [AppDelegate+Classification.swift:1110](Sources/LungfishApp/App/AppDelegate+Classification.swift:1110), `ManagedMappingPipeline()` at [AppDelegate+ToolsMenu.swift:1352](Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:1352), `OrientPipeline()` at [AppDelegate+ToolsMenu.swift:1640](Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:1640), `ManagedAssemblyPipeline()` at [AssemblyConfigurationViewModel.swift:407](Sources/LungfishApp/Views/Assembly/AssemblyConfigurationViewModel.swift:407), and `DemultiplexingPipeline()` at [ViewerViewController+FASTQDrawer.swift:128](Sources/LungfishApp/Views/Viewer/ViewerViewController+FASTQDrawer.swift:128).
- Subprocess to `lungfish-cli` for others: nine runners under `Sources/LungfishApp/Services/CLI*Runner.swift` (3,377 lines), `FASTQOperationExecutionService`, and `LungfishCLIRunner.run` from 11 files.
- The CLI runs the same Workflow pipelines, for example `ClassificationPipeline.shared` at [ClassifyCommand.swift:337](Sources/LungfishCLI/Commands/ClassifyCommand.swift:337) and `ManagedMappingPipeline()` at [MapCommand.swift:275](Sources/LungfishCLI/Commands/MapCommand.swift:275). Each side then wraps the pipeline with its own orchestration: input materialization, output directory choice, batch handling, failure provenance and manifest recording. Compare the GUI's `persistClassificationBatchFailureRoot` ([AppDelegate+Classification.swift:449](Sources/LungfishApp/App/AppDelegate+Classification.swift:449)) with the CLI's `writeFailureProvenance` ([ClassifyCommand.swift:527](Sources/LungfishCLI/Commands/ClassifyCommand.swift:527)). They are two implementations of the same responsibility.

**Impact.** "CLI parity" holds at the level of the pipeline actor but not at the level of the *run*. The run includes materialization, provenance wrapping, batch semantics and output layout. A fix to one side does not reach the other (ARC-07 is a concrete case). The in-process style also puts long-running native work and its memory into the GUI process. The OOM history in project memory shows that is not theoretical.

**Recommendation.** Adopt one rule: **every analysis the GUI launches runs as `lungfish-cli <cmd> --json-events`**, through the single transport from ARC-02. The GUI keeps dialogs, routing and result display. Move run orchestration that currently lives in App (materialization, batch loops, manifest recording) into Workflow "run services" such as `ClassificationRunService` and `MappingRunService`. The CLI commands call those services, so there is exactly one orchestration per analysis. Migrate one feature at a time, Kraken2 first because it has the worst drift. Keep in-process execution only for fast, read-only viewport queries such as region reads.

**Acceptance test.** For each migrated analysis, a test launches the GUI entry point with a stub transport and asserts the argv it produced. It then runs that argv through `LungfishCLI` in-process and asserts the resulting provenance envelope equals the CLI-only run's envelope, ignoring timestamps and paths. A grep gate fails CI if `Sources/LungfishApp` constructs any `*Pipeline(` type outside an allowlist.

---

### ARC-02 Nine copy-pasted CLI runner actors and about 12 ad-hoc, stringly-typed CLI event schemas (P1, Traced, M)

**Evidence.**
- `diff CLITreeInferenceRunner.swift CLITreeTransformRunner.swift` yields 36 changed lines out of 297. The only differences are type names, event-name strings and message text. Each file has its own `Process` setup, pipe handling, `StreamState`, cancellation, `isOperationCancelled` and `failOperation` ([CLITreeInferenceRunner.swift:86-160](Sources/LungfishApp/Services/CLITreeInferenceRunner.swift:86), [CLITreeInferenceRunner.swift:284-292](Sources/LungfishApp/Services/CLITreeInferenceRunner.swift:284)). The same shape is repeated in `CLIMSAActionRunner`, `CLIMSAAlignmentRunner`, `CLIVariantCallingRunner`, `CLIPrimerTrimRunner`, `CLIImportRunner`, `CLINativeBundleImportRunner` and `CLIApplicationExportImportRunner`.
- Events are parsed as untyped dictionaries: `case "treeInferenceStart": ... dict["message"] as? String ?? "Starting tree inference..."` ([CLITreeInferenceRunner.swift:57-80](Sources/LungfishApp/Services/CLITreeInferenceRunner.swift:57)).
- The CLI side declares a separate private `Event` struct per command: [TreeCommand.swift:749](Sources/LungfishCLI/Commands/TreeCommand.swift:749), [TreeCommand.swift:797](Sources/LungfishCLI/Commands/TreeCommand.swift:797), [TreeCommand.swift:845](Sources/LungfishCLI/Commands/TreeCommand.swift:845), [MSACommand.swift:2203](Sources/LungfishCLI/Commands/MSACommand.swift:2203), [ImportMSATreeSubcommands.swift:194](Sources/LungfishCLI/Commands/ImportMSATreeSubcommands.swift:194), [ApplicationExportImportSubcommands.swift:197](Sources/LungfishCLI/Commands/ApplicationExportImportSubcommands.swift:197), [BAMCommand.swift:19](Sources/LungfishCLI/Commands/BAMCommand.swift:19) (four structs), [AlignCommand.swift:14](Sources/LungfishCLI/Commands/AlignCommand.swift:14), [BAMPrimerTrimSubcommand.swift:30](Sources/LungfishCLI/Commands/BAMPrimerTrimSubcommand.swift:30), and [VariantsCommand.swift:108](Sources/LungfishCLI/Commands/VariantsCommand.swift:108). The App has yet another parser, `FASTQCLIProgressEvent` ([FASTQOperationExecutionService.swift:18](Sources/LungfishApp/Services/FASTQOperationExecutionService.swift:18)).

**Impact.** Nothing checks the wire contract between the two processes. If a CLI author renames an event or field, the GUI stops showing progress or never sees completion. That fails silently, because a parse failure only logs a warning ([CLITreeInferenceRunner.swift:158](Sources/LungfishApp/Services/CLITreeInferenceRunner.swift:158)). A bug fix to one runner (pipe drain, cancellation race, bare `PATH`) has to be made nine times.

**Recommendation.**
1. Add `LungfishWorkflow/CLIEvents/CLIEvent.swift` with one `Codable` enum: `start`, `progress(fraction, message)`, `log(level, message)`, `output(url, role)`, `complete(outputs)` and `failed(message, detail)`, plus a `schemaVersion`. Both the CLI and the App import Workflow, so the type can be shared without a new dependency.
2. Add a `CLIEventEmitter` for the CLI and a single `CLISubprocessTransport` actor in Kit, next to `LungfishCLIRunner`. The transport owns `Process`, both pipes (drained concurrently), cancellation and line framing, and yields `AsyncThrowingStream<CLIEvent, Error>`.
3. Add one `OperationCenterCLIBridge` that maps events onto an operation handle (ARC-04).
4. Reduce each `CLI*Runner` to an argv builder plus result interpretation, about 30 lines each. Delete the rest.

**Acceptance test.** A round-trip test encodes every `CLIEvent` case from the CLI emitter and decodes it with the transport. A contract test runs each converted CLI subcommand with `--json-events` on a fixture and asserts that the stream decodes with no unknown lines and ends with `complete` or `failed`. `CLI*Runner.swift` files contain no `Process()` (grep gate).

---

### ARC-03 Operations-panel "CLI command" strings are hand-built and drift from the real CLI (P1, Traced, M)

**Evidence.**
- GUI Kraken2 builds `lungfish conda classify --db <databasePath.path> <inputs>` ([AppDelegate+Classification.swift:860-864](Sources/LungfishApp/App/AppDelegate+Classification.swift:860)).
- The CLI's `--db` is a registry *name* ([ClassifyCommand.swift:79](Sources/LungfishCLI/Commands/ClassifyCommand.swift:79)). It is resolved by `registry.database(named:)` ([ClassifyCommand.swift:206-216](Sources/LungfishCLI/Commands/ClassifyCommand.swift:206)), which is a plain dictionary lookup by name ([MetagenomicsDatabaseRegistry.swift:507-510](Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseRegistry.swift:507)). A path therefore fails with "Database ... not found in registry".
- The string also omits `--preset`, `--confidence`, `--paired`, `--profile` and `-o`, so even with a correct name it would reproduce a different analysis.
- GUI mapping registers its operation with no `cliCommand` at all ([AppDelegate+ToolsMenu.swift:1299-1303](Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:1299)).
- `FASTQDerivativeRequest.cliCommand` shows a raw `seqkit grep` for text search, with the comment "No direct lungfish CLI subcommand" ([FASTQDerivativeServiceModels.swift:414-420](Sources/LungfishApp/Services/FASTQDerivativeServiceModels.swift:414)). `FastqSearchTextSubcommand.swift` exists in the CLI, so the comment is stale.
- There are 47 `buildCLICommand(` calls and 89 `cliCommand:` arguments, each assembled by hand.

**Impact.** The Operations panel presents these strings as the reproducible command, and failure reports copy them. A user who pastes the Kraken2 one gets an immediate error. For a scientific tool, a replay command that is wrong is worse than none.

**Recommendation.** Make the argv the *source* of execution, not a description of it. Each dialog produces a typed request. A per-command `CLIInvocationBuilder` (the pattern already exists as `FASTQOperationCLIInvocationBuilder`) turns the request into argv. The GUI executes that argv (ARC-01), and the display string is `shellEscape(argv)`. Until a feature migrates, add a test that parses its display string with `LungfishCLI.parseAsRoot` and fails on any parse error.

**Acceptance test.** For each GUI launch site, a test captures the `cliCommand` recorded in `OperationCenter` and asserts that `LungfishCLI.parseAsRoot(argv)` succeeds and that the parsed options equal the request's options. For Kraken2 specifically, `--db` equals the registry name and the preset appears.

---

### ARC-04 `OperationCenter.start` can return an already-failed operation, and callers are not forced to notice (P1, Traced, M)

**Evidence.**
- When a requested bundle lock is held, `start` inserts an item in state `.failed` ("Bundle is busy") and still returns a normal `UUID` ([OperationCenter.swift:401-427](Sources/LungfishKit/OperationCenter.swift:401)).
- Some callers guard beforehand with `canStartOperation(on:)` (for example [AppDelegate+SequenceMenu.swift:741](Sources/LungfishApp/App/AppDelegate+SequenceMenu.swift:741)). Others check `state.isActive` afterwards ([MainSplitViewController+PrimerAnalysis.swift:72](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+PrimerAnalysis.swift:72)).
- MSA export passes `targetBundleURL` and does neither ([ViewerViewController+MSAExport.swift:42-65](Sources/LungfishApp/Views/Viewer/ViewerViewController+MSAExport.swift:42)). Its runner's pre-flight check only looks for `.cancelling`/`.cancelled` ([CLIMSAActionRunner.swift:352-355](Sources/LungfishApp/Services/CLIMSAActionRunner.swift:352)), so the CLI process runs anyway while the panel shows "Bundle is busy".
- More broadly there are 67 `start(` sites, 92 `fail(`, 42 `acknowledgeCancellation(` and 53 `setCancelCallback(` sites across 28 files, plus 371 `MainActor.assumeIsolated` hops in App. Each lifecycle is written by hand. Project memory's rule "call BOTH `update()` AND `log()`" is itself a sign of a leaky contract. `updateWithLog` exists but has only 18 callers against 55 `update` and 80 `log`.

**Impact.** Locks that are advisory in practice. A long operation can run under a "failed" row, and its completion call is then rejected by the `guard ... complete(...)` pattern, so outputs appear with no operation record. Every new feature has to recreate the cancel/complete/fail choreography correctly, and several do not.

**Recommendation.** Keep `OperationCenter` as the store. Add a typed front door in Kit:

```swift
@MainActor func begin(_ spec: OperationSpec) -> Result<OperationHandle, OperationStartRefusal>
final class OperationHandle: Sendable { func progress(_:_:) ; func log(_:_:) ; func finish(_ outcome: OperationOutcome) ; var cancellation: CancellationSignal }
func run<T>(_ spec: OperationSpec, _ body: @Sendable (OperationHandle) async throws -> T) async -> OperationOutcome<T>
```

`run` owns the main-actor hops, maps `CancellationError` to cancellation, maps errors to `fail`, and makes progress also log. Make the old `start` `@available(*, deprecated)` and migrate call sites alongside ARC-02 and ARC-01.

**Acceptance test.** A unit test in `LungfishKitTests` takes a lock, calls `begin` for the same bundle, and asserts `.failure(.bundleBusy)` with no handle. An MSA-export test with a pre-held lock asserts that the transport is never invoked. A grep gate caps the count of raw `OperationCenter.shared.start(` and ratchets it down.

---

### ARC-05 Per-window state leaks through globals (P2, Traced, L)

**Evidence.**
- `AppDelegate.mainWindowController` is a single "current window" ([AppDelegate.swift:39](Sources/LungfishApp/App/AppDelegate.swift:39)), rewritten on activation, window close and `windowDidBecomeMain` ([AppDelegate.swift:1137](Sources/LungfishApp/App/AppDelegate.swift:1137), [AppDelegate.swift:1713](Sources/LungfishApp/App/AppDelegate.swift:1713), [AppDelegate.swift:1740](Sources/LungfishApp/App/AppDelegate.swift:1740)). It sits alongside the real registry `mainWindowControllers` ([AppDelegate.swift:42](Sources/LungfishApp/App/AppDelegate.swift:42)).
- `DocumentManager.shared` mirrors whichever window was last frontmost ([DocumentManager.swift:326-332](Sources/LungfishApp/App/DocumentManager.swift:326)).
- The download importer registers its document through that global, `DocumentManager.shared.registerDocument(document)` ([AppDelegate+Classification.swift:2682](Sources/LungfishApp/App/AppDelegate+Classification.swift:2682)), even though it holds the routed `targetController`. The document therefore lands in whichever session is frontmost when the load finishes.
- `MainSplitViewController` checks its document cache against the global mirror and sets the global active document ([MainSplitViewController+GenomicsDisplay.swift:86-93](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+GenomicsDisplay.swift:86)).
- There are 122 `NSApp.keyWindow`/`mainWindow` uses (111 in App), often as `mainWindowController?.window ?? NSApp.keyWindow` for sheets ([AppDelegate+ImportExport.swift:157](Sources/LungfishApp/App/AppDelegate+ImportExport.swift:157), [AppDelegate+MenuActions.swift:804](Sources/LungfishApp/App/AppDelegate+MenuActions.swift:804)).
- There are 24 `AppDelegate.shared` reach-backs from view controllers ([ViewerViewController.swift:798](Sources/LungfishApp/Views/Viewer/ViewerViewController.swift:798), [SidebarViewController.swift:780](Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift:780)).

**Impact.** With two project windows, a download started in window A that finishes after the user switches to B registers its document in B's session while A displays it. Sheets can attach to the wrong window. The existence of `ProjectSession`, `ProjectSessionRegistry` and `OperationRouteContext` shows the team knows the right model. The globals are leftovers that undercut it.

**Recommendation.** Introduce a `WindowContext` owned by `MainWindowController`. It holds the `ProjectSession`, `WindowStateScope`, presenting window and a per-window event bus (ARC-06), and is passed down at construction. Replace `DocumentManager.shared.registerDocument/setActiveDocument/documents` with `projectSession` calls, and delete the mirror once there are no readers. Replace `mainWindowController?.window ?? NSApp.keyWindow` with `activeMainWindowController(sender:)` or the routed controller. Replace `AppDelegate.shared?.X` in view controllers with an injected `AppCommands` protocol that App implements.

**Acceptance test.** A two-window test (the XCUI or the ViewInspector harness) starts a download routed to window A, activates B, completes the load, and asserts that A's `projectSession.documents` contains the document and B's does not. Grep gates cap `DocumentManager.shared` and `NSApp.keyWindow` in App and ratchet them down.

---

### ARC-06 Window scoping of notifications is a fail-open convention reimplemented in three controllers (P2, Traced, M)

**Evidence.**
- `shouldAcceptScopedNotification` is written three times ([InspectorViewController+Notifications.swift:402-408](Sources/LungfishApp/Views/Inspector/InspectorViewController+Notifications.swift:402), [SidebarViewController.swift:768-774](Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift:768), [MainSplitViewController.swift:817-822](Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift:817)). All three **return `true` when the scope key is missing**.
- Scoping therefore depends on every poster remembering `windowScopedUserInfo`. Most do. Some do not. `showOrToggleAIAssistant` posts `.showInspectorRequested` with only a tab key ([AppDelegate+MenuActions.swift:521-525](Sources/LungfishApp/App/AppDelegate+MenuActions.swift:521)), so every window's inspector switches to the AI tab, and it resolves the target through `mainWindowController` rather than `sender`. Its neighbour `showDocumentInspector` does it correctly ([AppDelegate+MenuActions.swift:477-487](Sources/LungfishApp/App/AppDelegate+MenuActions.swift:477)).
- Totals: 133 `NotificationCenter.default.post` sites and 103 observer registrations, all on the process-wide center with `object: nil`.

**Impact.** Cross-window UI events are fixed one site at a time, and the default for a forgotten key is to broadcast. The inspector, sidebar and viewer communicate through a global bus inside what is really one window's object graph.

**Recommendation.** Give each `WindowContext` its own `NotificationCenter` instance, or better a small typed `WindowEventBus` with enum events. Inspector, sidebar and viewer subscribe to their window's bus, and only true app-wide events (settings, storage location) stay on `.default`. That removes scoping as a concept. If an interim step is needed, make the three filters one shared function that **rejects** unscoped window-local events and logs a fault in DEBUG.

**Acceptance test.** A two-window test posts each window-local event from window A and asserts that B's inspector and sidebar state is unchanged. The AI-assistant menu item, invoked with window A key, leaves B's inspector tab untouched.

---

### ARC-07 GUI and CLI write different provenance for the same Kraken2 analysis (P2, Traced; impact Suspected, M)

**Evidence.**
- `ClassificationPipeline` writes its own envelope through `ProvenanceRecorder` ([ClassificationPipeline.swift:259](Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift:259)), with `ProvenanceRuntimeIdentity()` defaults ([ClassificationPipeline.swift:299](Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift:299)).
- The CLI then loads that envelope and writes a second, wrapper envelope (`workflowName: "lungfish.classify"`) with materialization steps, durable replay argv, explicit/default/resolved options and the app version ([ClassifyCommand.swift:946-1010](Sources/LungfishCLI/Commands/ClassifyCommand.swift:946)).
- The GUI single-sample path calls the pipeline and records an analysis manifest, but never calls a wrapper writer ([AppDelegate+Classification.swift:922-958](Sources/LungfishApp/App/AppDelegate+Classification.swift:922)).
- More broadly, 51 `ProvenanceRunBuilder(` sites in 44 files and 40 `ProvenanceWriter()` sites in 28 files each assemble envelopes by hand, including GUI-only writers inside `AppDelegate` (`writeSequenceExportProvenance` at [AppDelegate+ImportCenter.swift:2964](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:2964), `writeVCFImportProvenance`).

**Impact.** Two identical Kraken2 analyses have differently shaped provenance depending on whether they started in the GUI or the terminal. I did not diff real outputs, so the scientific consequence is Suspected. At minimum the GUI envelope lacks the wrapper's replay argv and option-provenance blocks. The provenance reviewer should confirm the field-level difference.

**Recommendation.** This is solved by ARC-01. Once the GUI launches `lungfish-cli conda classify`, there is one writer. Until then, move `ClassifyCommand.writeProvenance` into a Workflow `ClassificationRunService` and call it from both sides. The general rule: **the component that owns a run owns its envelope**. Pipelines emit steps. The run service writes the one envelope.

**Acceptance test.** Run the same fixture through the GUI path (stub UI) and the CLI. Normalize timestamps and absolute paths, then assert the envelopes are equal.

---

### ARC-08 Dead parallel FASTQ materializer (~1,100 lines) kept alive only by tests (P2, Traced, S)

**Evidence.**
- `materializeVirtualFASTQSubset` ([FASTQDerivativeService+Materialization.swift:62](Sources/LungfishApp/Services/FASTQDerivativeService+Materialization.swift:62)) and `materializeVirtualFASTASubset` ([:138](Sources/LungfishApp/Services/FASTQDerivativeService+Materialization.swift:138)) have **no callers** in `Sources` or `Tests`.
- Their helper chain is reachable only from them: `extractAndTrimReads` (:318, called only at :109), `extractAndTrimFASTAReads` (:425, only :185), `materializeOrientedReads` (:230, only :129), `materializeOrientedFASTAReads` (:514, only :198/:217), `extractTrimmedFASTAReads` (:570, only :169), and `extractReads` (:33, only from the dead chain).
- The live path already delegates to Workflow's `FASTQCLIMaterializer` ([:16-27](Sources/LungfishApp/Services/FASTQDerivativeService+Materialization.swift:16)), which has its own private copies of the same algorithms ([FASTQCLIMaterializer.swift:497-651](Sources/LungfishWorkflow/Extraction/FASTQCLIMaterializer.swift:497)).
- `MaterializationPipeline` (526 lines, [MaterializationPipeline.swift:64](Sources/LungfishApp/Services/MaterializationPipeline.swift:64)) has no production caller. Only `MaterializationPipelineTests` and `FASTQDerivativeServiceProvenanceTests` construct it.

**Impact.** Two implementations of trim-then-extract and orientation. The next person fixing a trim-coordinate bug has about even odds of fixing the copy that never runs, and the tests on the dead copy will say "green".

**Recommendation.** Delete the dead functions and `MaterializationPipeline` together with their tests. Keep `writeOrientedPreviewFASTQ` and `detectMateFromHeader`, which have live callers in `+MixedOutput`/`+SubsetHelpers`. Make sure `FASTQCLIMaterializer` has equivalent test coverage first. Port any dead-copy test that encodes a real edge case.

**Acceptance test.** Grep shows no `materializeVirtual*` or `MaterializationPipeline` symbols. `FASTQCLIMaterializer` tests cover trim, orient, FASTA subset and mixed. The unit tier stays green.

---

### ARC-09 FASTQ derivative operations have two GUI code paths and two CLI-command builders (P2, Traced, M)

**Evidence.**
- The FASTQ dataset viewer's `onRunOperation` calls `runFASTQOperation`, which runs **in-process** through `FASTQDerivativeService.shared.createDerivative/createBatchDerivative` ([MainSplitViewController+GenomicsDisplay.swift:770-845](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+GenomicsDisplay.swift:770); wired at :638, :677, :739). Its display command comes from `FASTQDerivativeRequest.cliCommand` ([FASTQDerivativeServiceModels.swift:394](Sources/LungfishApp/Services/FASTQDerivativeServiceModels.swift:394)).
- The FASTQ Operations dialog runs the **CLI** through `FASTQOperationExecutionService` and builds its command with `FASTQOperationCLIInvocationBuilder` ([MainSplitViewController+FASTQImport.swift:860-880](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+FASTQImport.swift:860)). That builder calls its own implementation `legacyBuildInvocation` ([FASTQOperationCLIInvocationBuilder.swift:10-20](Sources/LungfishApp/Services/FASTQOperationCLIInvocationBuilder.swift:10)).
- `FASTQDerivativeService*` totals 6,769 lines in App.

**Impact.** The same "subsample 10%" can produce different bundles, logs and provenance depending on which button was used. The two command builders already disagree (ARC-03's seqkit case).

**Recommendation.** Route `onRunOperation` through `FASTQOperationExecutionService`, converting `FASTQDerivativeRequest` to `FASTQOperationLaunchRequest`. Delete `FASTQDerivativeRequest.cliCommand`. Then shrink `FASTQDerivativeService` to whatever the CLI does not already cover, and move that part into Workflow.

**Acceptance test.** A test drives both entry points with the same subsample request and asserts identical argv and identical output manifest shape. Grep shows no `createDerivative(` callers in view controllers.

---

### ARC-10 `AppDelegate` extensions are the business-logic layer for import, export, downloads and classification (P2, Traced, L)

**Evidence.**
- `AppDelegate` plus its extensions total 13,399 lines.
- `AppDelegate+ImportCenter.swift` (3,491 lines) holds 14 import entry points, VCF helper orchestration, `performSequenceExport` (an export engine that writes FASTA/GenBank, [AppDelegate+ImportCenter.swift:2662](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:2662)), `writeSequenceExportProvenance` (:2964), GFF3 export, and image/PDF export.
- `AppDelegate+Classification.swift` (2,727 lines) holds Kraken2/EsViritu/TaxTriage orchestration, batch summary TSV writing, failure-provenance persistence, and also unrelated code: `showDatabaseBrowser` ([:2425](Sources/LungfishApp/App/AppDelegate+Classification.swift:2425)) and the whole download-import router `handleMultipleDownloadsSync` ([:2459](Sources/LungfishApp/App/AppDelegate+Classification.swift:2459)).
- `AppDelegate` stored state mixes window registry, storage-cleanup timers and tasks, AI services, debug timers and pending download URLs ([AppDelegate.swift:39-127](Sources/LungfishApp/App/AppDelegate.swift:39)).

**Impact.** None of this is reachable from the CLI or testable without an `NSApplication` delegate. Responsibilities are grouped by "who handles the menu item", not by domain, which is why downloads live in the classification file.

**Recommendation.** Split by responsibility, not line count. `AppDelegate` keeps only `NSApplicationDelegate` duties and a composition root that builds:
- `ProjectWindowCoordinator`: window registry, open/close, activation. This absorbs `mainWindowControllers`, `projectSessionRegistry` and `projectOpenCoordinator`.
- `ImportCoordinator` (App, thin) over Workflow import services, most of which already exist behind `CLIImportRunner`.
- `SequenceExportService` into Workflow, plus a CLI `export sequences` command if one is missing, giving parity for free.
- `DownloadImportRouter` out of the classification file.
- `ClassificationLaunchCoordinator` (App, thin) over the Workflow run services from ARC-01.
- `ProjectStorageMaintenance`: cleanup timers and tasks.

Menu actions become one-line forwards.

**Acceptance test.** `AppDelegate*.swift` contains no `FASTAWriter`, `GenBankWriter`, `ProvenanceRunBuilder` or `*Pipeline(` (grep gate). Each extracted service has a unit test that runs without `NSApplication`.

---

### ARC-11 About 1,290 test hooks in production types (P2, Traced, L)

**Evidence.**
- 960 declarations named `testing*` and 328 named `test*` in `Sources`. The largest holders: `GenotypeResultViewController` 286, `GenotypeComparisonMatrixView` 236, `MultipleSequenceAlignmentViewController` 74, `PhylogeneticTreeViewController` 59, `SequenceViewerView` 47, `NvdResultViewController` 42.
- The genotype controller's testing extension is 1,707 lines ([GenotypeResultViewController.swift:10076](Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:10076)). It exposes internal caches and "Task 7 instrumentation" counters.
- Some hooks are `public`, for example `testParseBamReferenceLengths` ([TaxTriageResultViewController.swift:4134](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:4134)). Leaf `public` surface is inflated accordingly (530 `public` declarations in `LungfishGenotypeUI`).

**Impact.** Tests are pinned to view-controller internals, so any restructuring breaks hundreds of tests. That makes ARC-12 expensive and pushes developers to keep adding to the controller. It also ships test surface in the release binary and widens module APIs. This is also where much of the "overtesting" noted in the brief comes from.

**Recommendation.** Do not delete the hooks wholesale. Pair each extraction (ARC-12, ARC-13) with moving the tested logic into a plain model or presenter type that tests call directly. Delete the corresponding hooks in the same change. New code rule: no `testing*` members on `NSViewController`/`NSView`. Where a view-level test is truly needed, use `@testable import` against `internal`, never `public`.

**Acceptance test.** A ratcheting CI count of `func testing|var testing|func test[A-Z]` under `Sources/`, which may only go down. Zero `public func test*`.

---

### ARC-12 `GenotypeResultViewController` is a 9.8K-line god object (P2, Traced, L)

**Evidence.**
- One class spans [GenotypeResultViewController.swift:138](Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:138) to about line 9988, with 323 stored properties and 508 functions. There are no `// MARK:` sections.
- Function prefixes show the mix: presentation (`show*`, `present*`), matrix orchestration (`matrix*`, `rebuild*`), haplotype analysis scheduling, manual-haplotype mutation, annotation retry scheduling (a protocol and a scheduler class declared in the same file, lines 44-92), AI-haplotyping requests (:93-112), file writes (:6878), and instrumentation snapshots.
- `GenotypeComparisonMatrixView.swift` (9,003 lines) follows the same pattern with 236 testing hooks.

**Impact.** This is the most active feature area (recent releases are genotype and haplotype fixes). Every change goes through one file that nobody can hold in their head, and merge conflicts concentrate there. Size alone is not the defect. The defect is that at least five independent state machines share 323 mutable fields.

**Recommendation.** Extract by state ownership, in this order, each as its own reviewable change:
1. `GenotypeMatrixAnnotationCoordinator` (retry scheduling and annotation store I/O).
2. `GenotypeHaplotypeAnalysisController` (analysis runs, effective-haplotype keys, invalidation).
3. `GenotypeManualHaplotypingSession` (manual mode and its mutations).
4. `GenotypeResultPresentationModel` (`@Observable`: view mode, included loci, cohort selection).

The view controller keeps layout, split view and forwarding. Move the matching testing hooks onto the extracted types (ARC-11). Apply the same approach to the matrix view: layout engine, data projection and rendering.

**Acceptance test.** Each extracted type has direct unit tests that do not instantiate an `NSViewController`. The controller's stored-property count drops below about 80. The existing genotype UI test suite stays green after each step.

---

### ARC-13 TaxTriage view controller runs samtools synchronously on the main actor (P1, Traced, S)

**Evidence.**
- `TaxTriageResultViewController` is `@MainActor` ([TaxTriageResultViewController.swift:174](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:174)). The dedup task is `Task { [weak self] ... }` created from a main-actor method ([:1851](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:1851)), so it inherits the main actor.
- It calls `self.parseBamReferenceLengths` ([:1856](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:1856)), and again **inside the per-accession loop** whenever a length is missing ([:1875-1877](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:1875)).
- That method synchronously spawns `samtools view -H` and `samtools idxstats` and waits for exit ([:2294-2340](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:2294)).
- The helper reads stdout to EOF *before* touching stderr ([:2327-2328](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:2327)). If samtools writes more than a pipe buffer of warnings, the child blocks on stderr and the main thread blocks on stdout forever.
- A second copy spawns samtools with an undrained `Pipe()` for stderr and `try? proc.run()` ([:1981-1989](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:1981)).
- `@SQ` header parsing is written again in `SAMParser`, `NaoMgsBamMaterializer`, `BAMRegionMatcher` and `ViralVariantCallingPipeline`.

**Impact.** The UI freezes while TaxTriage results load. It re-runs samtools once per accession that has no header entry, which is exactly the case where the header will never supply one. A hang is possible on BAMs whose headers produce warnings.

**Recommendation.** Move BAM reference-length and idxstats reading into LungfishIO (for example `BAMHeaderReader.referenceLengths(bam:)`) using the shared subprocess helper from ARC-15. Call it once, off the main actor, before the loop. Replace the loop re-parse with "missing means skip". Delete both inline copies.

**Acceptance test.** A unit test with a fixture BAM plus a stub samtools that writes 1 MB to stderr completes. A main-thread checker test (or an `MainActor.assertIsolated`-based assertion in the reader) shows the reader never runs on the main thread. The TaxTriage VC file contains no `Process()`.

---

### ARC-14 `ResultViewportController` / `BlastVerifiable` are premature abstractions (P3, Traced, S)

**Evidence.** `ResultViewportController` has an `associatedtype` ([ResultViewportController.swift:80-92](Sources/LungfishKit/ResultViewportController.swift:80)), so it cannot be used as an existential without `any` plus opening. No non-test code uses it polymorphically. `exportResults(to:format:)` is implemented five times (for example [NaoMgsResultViewController+ResultViewport.swift:73](Sources/LungfishNaoMgsUI/NaoMgsResultViewController+ResultViewport.swift:73), which throws for three of four formats), and no production call site invokes it. `BlastVerifiable` has one conformer ([AssemblyResultViewController.swift:678](Sources/LungfishAssemblyUI/AssemblyResultViewController.swift:678)). The Taxonomy file documents at length why it does *not* conform ([TaxonomyResultViewController.swift:18-21](Sources/LungfishApp/Views/Results/Taxonomy/TaxonomyResultViewController.swift:18)).

**Impact.** Low. It is ceremony that suggests a uniform viewport contract that does not exist, and new leaves copy it.

**Recommendation.** Delete both protocols and the unused `exportResults` conformances, or keep only `resultTypeName` if something reads it. The real shared surface among classifier viewers is `ClassifierActionBar`, `ClassifierRowSelector`, the BLAST drawer and `MetadataColumnController`, which are concrete Kit components. That is the right level of sharing. Do not build a generic base view controller for the five classifier viewers. Their data models differ too much, and the concrete-component approach is working.

**Acceptance test.** Grep shows no conformances. The build is green. No behaviour changes.

---

### ARC-15 Five external-process mechanisms, plus about 120 raw `Process()` sites across all layers (P2, Traced, L)

**Evidence.**
- Mechanisms: `ProcessManager` (895 lines, injected only into Nextflow/Snakemake/TaxTriage/WorkflowRunner: [WorkflowRunner.swift:270](Sources/LungfishWorkflow/WorkflowRunner.swift:270), [TaxTriagePipeline.swift:173](Sources/LungfishWorkflow/TaxTriage/TaxTriagePipeline.swift:173)); `NativeToolRunner.shared` (66 uses); `CondaManager.runTool` (29); Containerization (`ContainerImageRegistry`); and `LungfishCLIRunner` in Kit.
- Raw `Process()` sites outside those: App 22, Workflow 55, IO 20, CLI 11, Core 5, Kit 3, TaxTriageUI 2. These include LungfishIO shelling out to samtools ([AlignmentDataProvider.swift:343](Sources/LungfishIO/Bundles/AlignmentDataProvider.swift:343)) and Core spawning processes in `BlastService`/`SRAService`/`NCBIService`.
- Project memory records repeated defects of exactly this class: bare `PATH`, `/usr/bin/env`, undrained pipes, whitespace paths.

**Impact.** Each raw site re-decides environment, `PATH`, pipe draining, timeouts, cancellation and process-tree termination, and each has shown bugs. The layering is also muddy: IO, meant as the format layer, launches tools.

**Recommendation.** One Workflow-level `ToolProcess` API (Core if IO must use it) with a single implementation of environment construction (`ManagedStorageConfigStore().subprocessEnvironment()`), concurrent pipe draining, timeout, cancellation and `ProcessTreeTerminator` integration. `NativeToolRunner`, `CondaManager.runTool`, `ProcessManager` and the ARC-02 transport become thin front ends over it. Then migrate raw `Process()` sites, starting with IO and view controllers. Accept that containers keep their own runtime.

**Acceptance test.** A grep gate: `= Process()` appears only in the `ToolProcess` implementation (plus an allowlist, ratcheted). A shared test suite (stderr flood, cancel mid-run, path with spaces, empty `PATH`) runs against `ToolProcess` once.

---

### ARC-16 Misplaced vocabulary and dead notifications (P3, Traced, S)

**Evidence.**
- [LungfishCore/Models/Notifications.swift](Sources/LungfishCore/Models/Notifications.swift) (471 lines, 38 names) defines UI intents such as `showInspectorRequested`, `copyAnnotationAsFASTARequested` and `zoomToAnnotationRequested` in the lowest layer. `fastqOrientRequested` ([:273](Sources/LungfishCore/Models/Notifications.swift:273)) is never referenced.
- `DocumentManager.activeDocumentChangedNotification` is posted ([DocumentManager.swift:496](Sources/LungfishApp/App/DocumentManager.swift:496)) but never observed.
- Kit ships test-harness types (`AppUITestConfiguration.swift`, `TestHarnessDetection.swift`) in the production kernel.
- Workflow's `WorkflowNode` stores a `CGPoint` canvas position ([WorkflowNode.swift:695](Sources/LungfishWorkflow/Builder/WorkflowNode.swift:695)), which is editor view state in the engine layer.

**Impact.** Minor, but it blurs what each layer is for. It means every leaf can post window-UI intents without going through Kit.

**Recommendation.** Move UI intent names to Kit, alongside the ARC-06 window bus, which will replace most of them anyway. Delete the unused names. Move `position` into a builder-layout sidecar in App. Keep the test-harness types but put them behind `#if DEBUG` or a `LungfishTestHooks` target if feasible.

**Acceptance test.** Core contains no `*Requested` notification names. Grep shows no unused `Notification.Name`.

---

## Target architecture (end state)

```
LungfishCore      models, settings, pure services (no UI vocabulary)
LungfishIO        formats, bundles, readers (tool calls only via ToolProcess)
LungfishWorkflow  pipelines (emit steps) + RUN SERVICES (own orchestration, materialization,
                  batch, the one provenance envelope) + ToolProcess + CLIEvent schema
LungfishCLI       ArgumentParser shells over run services; emits CLIEvent JSON
LungfishKit       OperationCenter + OperationHandle/run; CLISubprocessTransport +
                  OperationCenterCLIBridge; WindowEventBus; shared UI components
leaf UI modules   VC + presentation models (logic testable without NSViewController)
LungfishApp       composition roots only: ProjectWindowCoordinator, WindowContext per window,
                  dialogs -> typed request -> argv -> transport; thin import/export coordinators
```

Invariants to enforce mechanically:
1. The GUI launches analyses only as CLI argv (allowlist for viewport reads).
2. There is one `Process()` implementation.
3. There is one CLI event schema.
4. Operation lifecycles only through `OperationHandle`.
5. No window-local state through `.shared`/`NSApp.keyWindow`.
6. Test hooks only ratchet down.

## Proposed work packages (ordered)

**WP1: Delete dead and parallel code (S, low risk).** ARC-08, ARC-14, and the ARC-16 dead notifications. Files: `FASTQDerivativeService+Materialization.swift`, `MaterializationPipeline.swift` and its tests, `ResultViewportController.swift` plus five conformance files, `Notifications.swift`, `DocumentManager.swift:198,496`. No dependencies. Do this first so later packages do not migrate dead code.

**WP2: Operation handle (M, medium risk).** ARC-04. Add `OperationSpec`/`OperationHandle`/`run` in `LungfishKit/OperationCenter.swift` and deprecate raw `start`. Migrate MSA export immediately, since it has the live lock bug. Depends on nothing.

**WP3: CLI event schema and single transport (M, medium risk).** ARC-02. New `LungfishWorkflow/CLIEvents/`, a `CLISubprocessTransport` in Kit, and a bridge to WP2's handle. Convert the two tree runners first (identical, lowest risk), then MSA, variants, primer trim and imports. The CLI emitters change in the same PR as each runner. Depends on WP2.

**WP4: Argv as source of truth (M).** ARC-03 and ARC-09. Typed request -> `CLIInvocationBuilder` -> argv for Kraken2, mapping and FASTQ derivative ops. Add the parse-the-display-string test for everything not yet migrated. Route FASTQ viewer ops through `FASTQOperationExecutionService`. Depends on WP3.

**WP5: Run services and GUI-to-CLI migration (L, highest value).** ARC-01 and ARC-07. Create Workflow `ClassificationRunService` (lift `ClassifyCommand` orchestration and provenance), then EsViritu, TaxTriage, mapping, assembly, orient and demux, one per PR. Delete the GUI-side orchestration in `AppDelegate+Classification.swift`/`+ToolsMenu.swift` as each lands. Depends on WP3 and WP4. Risk: behaviour drift. Mitigate with the envelope-equality test.

**WP6: Window context and scoped bus (L, medium risk).** ARC-05 and ARC-06. Add `WindowContext` owned by `MainWindowController`, a per-window bus, and removal of the `DocumentManager.shared` mirror readers, `mainWindowController` fallbacks and `AppDelegate.shared` reach-backs. Can run in parallel with WP3 to WP5 but touches the same App files, so sequence the PRs.

**WP7: AppDelegate decomposition (L).** ARC-10. After WP5 removes classification orchestration and WP6 removes window globals, what remains splits cleanly into `ProjectWindowCoordinator`, `DownloadImportRouter`, `SequenceExportService` (to Workflow plus CLI) and `ProjectStorageMaintenance`.

**WP8: Process consolidation (L).** ARC-15 and ARC-13. Build `ToolProcess`, fix TaxTriage first (small, user-visible), then IO and Core sites, then fold `NativeToolRunner`/`CondaManager.runTool`/`ProcessManager` onto it.

**WP9: Genotype decomposition with hook migration (L, ongoing).** ARC-12 and ARC-11. Four extractions in the listed order, each moving its testing hooks. Schedule between genotype feature releases, not during them.

**Accept (do not fix):**
- **UserDefaults usage** (53 sites, mostly drawer heights and per-view preferences, with secrets correctly in Keychain). It is not sprawl worth a project.
- **The number of Workflow singletons for registries and installers** (`MetagenomicsDatabaseRegistry`, `CondaManager`, `DatabaseRegistry`). They model genuinely process-wide resources on disk. Inject them where tests need to, but do not remove them.
- **The CLI's `print` volume.** It is the user interface.
- **Typed-but-stringly errors** (393 error types, 727 `String`-payload cases) are real drag but belong to the error-handling reviewer. Architecturally, the right fix is the `CLIEvent.failed(message, detail)` plus `OperationOutcome` path in WP2 and WP3, which gives a typed boundary where errors cross processes.
- **Large files that are cohesive** (for example `ONTGenotypeResultBundle.swift`, `NCBIService.swift`) are not findings on size alone.
