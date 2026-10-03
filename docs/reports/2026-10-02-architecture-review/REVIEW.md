# Architecture review, consolidated findings (2026-10-02)

Status: active. Cited by docs/plans/2026-10-02-architecture-program.md. Delete both together when the program closes.

## Scope and method

Six architects reviewed the worktree at commit 25901700b through six lenses (module boundaries, hotfix archaeology, the add-a-tool contract, agent navigability, tool runtime, and state, concurrency and tests). This document merges their findings, removes duplicates, and ranks them by the cost they impose on future work, with the RNA-seq surface planned for next month as the reference workload. Every count below was re-measured in the worktree before it was kept. Where a measurement differed from a report, the measured number is used and the difference is noted in the verification table.

The ranking question for each finding is "how many tokens, files and retries does this cost the next agent that adds a feature, and how often does it cause a hotfix". Scientific risk is recorded separately so that no refactor trades genomics correctness for structure.

## Verification notes and corrections

| Claim as reported | Measured | Effect on the finding |
|---|---|---|
| 292 hide*() call sites | 270 | Kept, magnitude unchanged |
| 411 MainActor.assumeIsolated, 58 nonisolated(unsafe), 30 nonisolated(unsafe) static var | 407, 58, 23 | Kept |
| 79 Notification.Name declarations | 81 | Kept |
| 375 audit ticket tags in Sources | 396 | Kept |
| 111 test files and 633 source-text assertions | 94 files, 658 assertions | Kept |
| testing* identifiers 409 and 395 in the two genotype files | 356 and 244 distinct identifiers | Kept, numbers reduced |
| 288 sleep calls against 46 waitUntil in Tests | 288 sleep, 477 waitUntil | Corrected. The suite mostly follows the clock-wait rule. Sleep removal stays a low-priority ratchet, not a finding |
| NativeToolRunner 54 commits (24 fixes), CondaManager 35/19, TaxTriagePipeline 38/19 | 15 commits for NativeToolRunner since 2026-06-01 | Churn numbers for the runtime files are dropped as unverified. The structural finding stands on the code evidence |
| Genotype files 195 and 107 commits since June | 198 and 108 | Kept |
| MainSplitViewController+ContentDisplay 35 fix commits | 76 commits since June, all kinds | Kept |
| 135 of 172 Swift names cited in agents/ and docs/design do not exist | 135 of 173 | Kept |
| 16 GUI sites instantiate pipelines in-process | Not recounted. The named examples (AppDelegate+Classification.swift 822 and 1106, InspectorViewController+VariantWorkflow.swift:209) exist | Kept with the examples. The total is reported, not verified |
| Build-time savings from splitting LungfishWorkflow | Not measured | Kept as a hypothesis to measure with scripts/measure-build-times.sh before and after |
| "RNA-seq would touch 30 to 40 files" | Not measurable | Kept as an estimate |

No finding was dropped outright. Two were downgraded (sleep-based waits, runtime churn) because their evidence did not hold.

## Ranked findings

### R1. No feature-surface contract. Every surface is hand-wired through six composition-root god objects (high, large)

Evidence. SidebarItemType has 71 cases (Sources/LungfishApp/Views/Sidebar/SidebarItem.swift:40). MainSplitViewController+ContentDisplay.swift displayContent(for:) is a chain of sequential type checks (lines 16 to 222) followed by a second route switch. ViewerViewController.swift declares 13 per-viewport optional child controllers (lines 207 to 243) and isNativeBundleViewportInstalled is a hand-written OR of four of them (lines 248 to 253). There are 270 hide*() calls in LungfishApp with uneven coverage (hidePrimerAnalysisView 3 sites, hideTwelveSAmpliconResultView 6, hideNvdView 22). ViewerViewController+TwelveS.swift lines 8 to 32 contain 18 hide calls and omit hidePrimerAnalysisView. MainWindowController.swift lines 480 to 492 re-derive drawer state with a second type chain that has no native-bundle arm, so toolbar state can disagree with ViewerViewController+AnnotationDrawer.swift. AppDelegate.swift lines 301 to 305 pick the Inspector tab by filename prefix ("naomgs-", "kraken2-", "esviritu-", "taxtriage-", "nvd-"), one of 33 lastPathComponent.hasPrefix sites. LungfishKit declares 11 protocols and none describes a result viewport, its inspector sections or its sidebar entry. Leaf modules did not remove App coupling (App files mentioning EsViritu 51, Genotype 72, Assembly 86).

Cost. This is the main source of trial and error. An agent must read on the order of 57K lines of composition-root code to find every switch arm, hide list and prefix table, and a missed arm becomes a stale-viewport hotfix. MainSplitViewController+ContentDisplay.swift has 76 commits since June.

Recommendation. Define in LungfishKit a `ResultViewport` protocol (drawer kind, content mode, fills-viewer flag, inspector sections, toolbar capabilities, uniform teardown) and a `SurfaceRegistry` keyed by bundle kind. ViewerViewController keeps one `activeViewport` slot with a single install(_:) that tears down the current one. Routing, drawer state and the Inspector tab come from the registry. Migrate TwelveS and PrimerAnalysis first (least covered), mapping and reference last (they carry inspector wiring at ContentDisplay lines 840 to 873). The written contract lands in Phase 0, the code contract in Phase 3.

Genomics risk. Routing decides which reference, BAM and annotation set a viewport binds to. Viral Recon must bind a .lungfishref manifest, never a loose BAM. Guard with a table-driven test over every fixture bundle kind that asserts which surface opens and what it binds, before and after.

### R2. Tool identity is a bare string in at least 12 tables, and provisioning facts live in three places (high, medium)

Evidence. "esviritu" is a literal in 26 files, "kraken2" in 32, "minimap2" in 21 or more. Lookup tables include AnalysesFolder.knownTools (line 26), displayName (line 82, which names the tool "Minimap2" while MappingTool.displayName says "minimap2"), probeToolType (line 688), SidebarProjectScanner buildAnalysisNode, classifierBatchBadge, classifierBatchSubtitle, analysisIcon and analysisItemType, AnalysesSection.iconName, ClassifierDatabaseRouter.toolDefinitions, ProjectUniversalSearchModels.normalizeKind, AnalysesMigration, ProvenanceExporter, ImportCenterViewModel and BuildDbCommand+Provenance. The NativeTool enum has 34 cases over seven parallel switch tables (NativeToolRunner.swift 348 to 645) while Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json lists 44 environments, so 23 tools run through stringly CondaManager.runTool(name:environment:) with different PATH and timeout semantics (CondaManager.swift 1118 to 1157). PluginPack.swift repeats package lists and executables as Swift literals. The literal "core_nt" sits in 11 files across IO, three leaves and four ViewerViewController extensions, held in sync by comments ("Matches the database ViewerViewController+TaxTriage submits to", TaxTriageRowCommands.swift:103, NaoMgsResultViewController.swift:2322, ViralDetectionTableView.swift:1126).

Cost. Nothing fails when a table is missed. The tool then shows a gearshape icon, the generic route or no subtitle, and the agent finds out by running the app. Adding STAR, salmon, subread and R means editing the lock, a PluginPack literal, possibly seven NativeTool switches, and choosing a runner that silently changes PATH, JAVA_HOME and timeout.

Recommendation. Add `AnalysisToolDescriptor` (plain data in LungfishIO) and `AnalysisToolRegistry` with id, displayName, legacy aliases, family, badge, symbol, sidecar signature, viewport kind, CLI command path, conda environment, provenance policy key, features.yaml key, activation profile and resource class. Decode the descriptor from the lock manifest so the lock is the single source of truth. Turn every table above into a registry lookup, one table per PR, with a conformance test that iterates the registry. Replace "core_nt" with a `BlastDatabaseID` enum in LungfishCore tonight (Phase 0).

Genomics risk. Version pinning and version-probe quirks (ivar, lofreq and seqkit use a "version" subcommand, blastn uses -version) must carry into the data. Snapshot sidebar scan output over the fixture projects before and after so legacy directory names stay recognised.

### R3. GUI and CLI run different code for classifiers, and 38K lines of operation logic are stranded in the app target (high, large)

Evidence. For EsViritu the GUI path (AppDelegate+Classification.swift 1042 to 1290) runs EsVirituPipeline in-process, then writes the batch summary, builds esviritu.sqlite, saves the batch manifest, writes batch provenance and records AnalysisManifestStore. Sources/LungfishCLI/Commands/EsVirituCommand.swift contains no sqlite, provenance or manifest call. The recorded command (esVirituDetectCLIArguments, line 1035) omits --db, --output, --threads and --no-qc. Virtual FASTQ inputs are materialized only in the GUI path. Sources/LungfishApp/Services has 119 files and 38,566 lines, only 5 of which import AppKit or SwiftUI. 10 App files use NativeToolRunner in-process against 6 that use CLISubprocessTransport. View controllers run tools directly (FASTQDatasetViewController.swift 1378, 1535, 1643 and DatabaseBrowserViewController.swift 3458). The good counterexample is materialization, which delegates to Workflow's FASTQCLIMaterializer.

Cost. The reproducibility claim is weaker than the Operations panel suggests, because the displayed CLI command does not reproduce the GUI result tree. Every fix is made twice or not at all. Logic-only tests have to live in LungfishAppTests (515 files), so each iteration pays an App-sized build.

Recommendation. Create `AnalysisRunExecutor` in LungfishWorkflow that owns the lifecycle (create analysis directory, materialize inputs, run, finalize with SQLite and manifests, write provenance and analysis-metadata.json, record the source manifest, mark complete). Each tool supplies plan, run and finalize. CLI and GUI both call it, and the GUI only adapts progress into OperationCenter. Move AppKit-free Services files into a UI-free target behind the CLI. Ban NativeToolRunner from LungfishApp through a ratchet once the four view-controller call sites are fixed.

Genomics risk. High. Materialization order and paired versus interleaved layout resolution are scientifically load-bearing. An unmaterialized virtual bundle silently uses preview.fastq. Capture golden outputs (read counts, checksums, provenance JSON with timestamps masked) from the current GUI path on the SARS-CoV-2 and macaque fixtures before moving anything, and require the executor to reproduce them.

### R4. Operation launch has no spec, unsafe defaults and 58 deprecated start() calls (high, medium)

Evidence. OperationCenter.shared is referenced 627 times. There are 58 OperationCenter.shared.start( calls against 12 begin( calls, and start() is marked deprecated for the bundle-target overload (OperationCenter.swift:596). operationType defaults to .download and cliCommand to nil at lines 389, 398, 601, 605, 644 and 648. OperationType has 24 cases and no mapping case, and the live mapping launch (AppDelegate+ToolsMenu.swift:1351) passes no type, so a mapping run is logged as a Download. createAnalysisDirectory has 20 call sites, 10 of them `try?`, and a directory that is created but never tracked stays hidden (AnalysesFolder.swift 136 to 142). Bundle import after completion flows through a mutable closure AppDelegate sets once (OperationCenter.swift 432 to 435). There is a public init() but no protocol, so tests cannot inject a reporter. agents/process/PROJECT-LEAD-AGENT.md:146 still tells agents to call start().

Cost. Every tool repeats about 150 lines of start, log, progress, cancel, provenance and import wiring in a view controller, and copies the nearest example's hotfixes. Coverage of logging and provenance cannot be checked mechanically.

Recommendation. Tonight, add `.mapping` to OperationType, pass it at the live mapping launch, and fix the lead-agent doc. In Phase 1, extract `protocol OperationReporting` (begin, log, setCommand, updateProgress, complete, fail, cancel) with OperationCenter conforming and a RecordingOperationReporter in Tests/Support, remove the operationType and cliCommand defaults, add an `OperationSpec` value (argv, declared inputs and outputs, lock scope, provenance fields, output bundle kind) and an `OperationLauncher` that is the only caller of begin, and migrate the 58 start() sites.

Genomics risk. Bundle locks (canStartOperation(on:), activeLockHolder) stop concurrent writes to one bundle. Keep lock scope mandatory in the spec and keep lock semantics in the one shared implementation. Fake only the reporting surface.

### R5. No agent entry point, no module map, stale agent docs and a drifting feature index (high, small)

Evidence. No AGENTS.md or CLAUDE.md exists anywhere in the repo. The only ARCHITECTURE.md is docs/user-manual/ARCHITECTURE.md, a manual-chapter plan. The architecture overview is the 8-row table at docs/development.md lines 63 to 79. No Sources module has a README. 135 of 173 Swift file names cited in agents/process, agents/specialists and docs/design do not exist (agents/specialists/16-workflow-builder.md describes a removed feature). docs/user-manual/features.yaml lists 79 features and 246 source paths, 7 of which do not exist (BAMImportService.swift, MappingViewerBundlePreparer.swift, FolderMetadataEditorSheet.swift, SampleGroupSheet.swift, VariantQueryBuilderSheet.swift, ViralReconWizardSheet.swift, BundleManifest.swift). scripts/checks/features-yaml-entry-points.py checks menu titles only. Kraken2's CLI command lives under `conda classify`. 396 audit tags (GEN-, SCI-, FEA-, and others) in Sources resolve only to docs/reports/2026-09-23-best-practices-audit, which the retention rule will delete. 33 plans and 16 specs remain under docs/superpowers plus docs/plans, issues, product-specs and verification, some for work that shipped.

Cost. Every session pays a discovery tax of directory listings, greps and wrong files, and grep returns obsolete plans next to live code. Agents mirror what they read, so stale docs reproduce deprecated calls.

Recommendation. Phase 0 adds a root AGENTS.md (with CLAUDE.md pointing at it), docs/architecture/ARCHITECTURE.md, a generated docs/architecture/MODULES.md with a currency check, a Sources/<Module>/AGENTS.md per target, the contracts under docs/contracts, a source-path check for features.yaml, and a doc-path reference check wired into the pre-push hook. Phase 1 rewrites the audit tags as self-contained sentences, sweeps the finished plans, and rewrites the specialist files as role prompts that point at the module AGENTS.md files.

Genomics risk. None directly. The indices must name the authoritative implementation of each scientific computation and the domain invariants (BAM not SAM, virtual FASTQ materialized before classifiers, primer-scheme staging, .lungfishref binding) next to the owning module.

### R6. Giant files and god objects exceed agent read budgets and absorb most fix churn (high, large)

Evidence. 1,641 Swift files and 742,779 lines. 177 files are over 1,000 lines and hold about 44% of all lines. The largest are GenotypeResultViewController.swift (11,937 lines, about 125K tokens, 198 commits since June), GenotypeComparisonMatrixView.swift (9,386, 108 commits), TaxTriageResultViewController.swift (5,918), AnnotationTableDrawerView.swift (5,763), ONTBarcodeDemuxGenotypingPipeline.swift (5,718), ViewerViewController.swift (4,447, plus 21 extension files for 11,409 lines), and FastqCommand.swift (4,114). The two genotype files carry 356 and 244 distinct testing* identifiers and 54 `#if DEBUG` blocks. Only 12 ViewModel files exist, all in LungfishApp, and 8 of 9 leaf modules have no `@Observable` type. 100 test files construct an NSWindow.

Cost. Reading one file can consume most of a context window, so agents work from grep windows and miss invariants declared thousands of lines away. Export, review-eligibility and workbook logic in the view controller is why Excel parity keeps breaking (commits "Fix genotype Excel export parity", "fix filtered export viewport parity", "Unify exact matrix review eligibility").

Recommendation. A file-size ratchet tonight (new files at or under 800 lines, baselined files may not grow). Then extraction by responsibility, pure moves behind characterization tests, highest churn-to-size ratio first (GenotypeExportCoordinator, review-eligibility model, matrix projection, haplotype-band disclosure). A `<X>SurfaceModel` convention (`@MainActor @Observable`, injected reporter and event bus) for every new surface, RNA-seq first.

Genomics risk. High for genotype. Call status, ambiguity tokens and per-locus denominators are scientific. Freeze golden workbook and matrix exports from the demo MHC projects and require byte-identical exports after each extraction. Never rewrite logic while extracting it.

### R7. Process execution is fragmented across seven runners, and the Nextflow environment is built four ways (high, large for the primitive, small for Nextflow)

Evidence. Process() is created in 77 source files (Workflow 40, App 12, IO 9, CLI 9, Kit 3, Core 3). Runner abstractions include NativeToolRunner.runProcess, ProcessManager, CondaManager.runTool, LungfishCLIRunner, CLISubprocessTransport, ContainerProcess and about nine bespoke spawners in LungfishApp/Services. There are 17 private pipe-drain classes, readDataToEndOfFile appears 111 times, and raw .terminate() appears in 19 files against ProcessTreeTerminator in 5. Sources/LungfishWorkflow/WorkflowEngineLaunch.swift is the canonical Nextflow builder (managed bin, JAVA_HOME, NXF_HOME) and is used by CLI and App only. TaxTriagePipeline.swift builds two environments (lines 1500 to 1562) with no JAVA_HOME. PBAAClusteringPipeline.swift:551 runs `/usr/bin/env which nextflow` from the inherited PATH. Engines/NextflowRunner.swift (lines 240 to 250 and 486 to 490) builds a fourth environment with no JAVA_HOME. ReferenceSourcePreparer.swift:227 shells out to `zstd`, which macOS does not ship.

Cost. The bare-PATH class of bug has already been hit twice. A plain terminate() leaves nextflow's java and BBTools' java children running after cancel. Each new tool means picking a runner with its own timeout, framing and cancellation depth.

Recommendation. Phase 1 routes TaxTriage, PBAA and NextflowRunner through WorkflowEngineLaunch.resolve and removes the PATH-based which fallback (a probable defect on Macs without a system JDK). Phase 2 adds one `ToolProcess` primitive in LungfishWorkflow/Native (spawn, ProcessOutputLineFramer, ProcessTreeTerminator, heartbeat timeout, NativeProcessEvent) and turns the runners into adapters. A ratchet counts Process() outside Native/.

Genomics risk. Incorrect pipe draining truncates samtools and bcftools streams. Guard with byte-identical stdout and exit-code golden tests per tool before migrating. TaxTriage keeps its Docker profile and NXF_CONDA_CACHEDIR overrides as explicit options on the shared launch, verified by the TaxTriage and Viral Recon smoke runs.

### R8. Provenance has one envelope but dual writes, 25 copied writers and about 30 sidecar filenames (high, medium)

Evidence. ProvenanceEnvelope.swift encodes legacyName, legacyStatus and an embedded legacyWorkflowRun (lines 81, 82, 113, 139, 163), and legacyWorkflowRun is constructed in 32 files. `func writeProvenance` is defined 25 times and `func relativePath` or `projectRelativePath` 39 times. Five rehydrators exist. Filename literals include ".lungfish-provenance.json" (49), "provenance.json" (23), "lungfish-provenance.json" (20) and about 24 others. CondaManager.runTool has no missing-provenance policy, unlike NativeToolRunner.

Cost. Each new tool copies the nearest writer and picks a filename. RNA-seq would add four or more copies, and the legacy run must stay consistent forever because 32 sites emit it.

Recommendation. One `ProvenanceRecorder` API (tool identity, argv, version probe, environment lock hash, inputs and outputs, hashes) called automatically by the ToolProcess primitive, writing the envelope only. One filename rule per bundle kind. Keep every legacy reader behind round-trip tests built from real old bundles and the demo projects. Collapse the 39 path helpers into one LungfishCore utility.

Genomics risk. Provenance is the reproducibility record. Change only the write side, and only after fixture tests exist for each legacy filename.

### R9. Untyped NotificationCenter messaging, and window scoping that fails open through seven copied filters (high, medium and small)

Evidence. 81 Notification.Name declarations, 41 of them in LungfishCore/Models/Notifications.swift with payload shapes in doc comments only. 139 posts, 190 userInfo reads, 82 of them raw string keys (AppDelegate+MenuActions.swift 234 to 236, MainSplitViewController+MultiDocument.swift 341 to 363). shouldAcceptScopedNotification is defined 7 times (SidebarViewController, MainWindowController, MainSplitViewController, InspectorViewController+Notifications, ViewerViewController, AnnotationTableDrawerView, GenotypeResultViewController), each returning true when the scope key is absent. Only 17 posts attach windowStateScope.

Cost. A misspelled key fails silently at runtime. With two project windows open, an unscoped post switches every window's Inspector tab, a bug class that only shows up in multi-window GUI testing.

Recommendation. A typed `AppEvent` layer in LungfishKit with an EventBus, a NotificationCenter bridge during migration, scope as a required property (window or application), and one `ScopedEventFilter` that fails closed for window events. Migrate the 82 raw-string sites first. New surfaces use typed events only, enforced by a lint that rejects new Notification.Name outside an allowlist.

Genomics risk. Payloads carry selection state (annotation, region, bundle URL). Round-trip tests for each migrated event, and classify every existing name as window or application before switching the filter so app-wide refreshes still arrive.

### R10. Concurrency escape hatches and static test seams (medium, medium)

Evidence. 407 MainActor.assumeIsolated, 223 @unchecked Sendable, 58 nonisolated(unsafe), 23 nonisolated(unsafe) static var used as threading probes and fault gates (ProvenanceInspectorViewModel.swift 678 and 686, SequenceViewerView.swift 1758, VariantDatabase+CreateFromVCF.swift 18 and 19). The CLI holds global runner overrides (RunSubcommand.swift 32 to 36, CondaCommand.swift 50 to 52). TestHarness.isRunning branches exist at 3 production sites (for example GenotypeResultViewController.swift:8759 returns .cancel instead of showing the alert). AppDelegate.swift:2723 defines a test process runner inside production code. 26 suites sit in PARALLEL_HAZARD_SUITES (scripts/full-suite-gate.sh:151).

Cost. Guarantees are weaker than the Swift 6.2 setting implies, static probes are data races under parallel tests and drive the serial quarantine, and harness branches mean a passing test did not exercise the modal path.

Recommendation. A short concurrency playbook in docs/contracts, a hatch-count ratchet tonight, then constructor-injected probes or @TaskLocal values, a CommandEnvironment for CLI overrides, injected presenters in place of TestHarness checks, and test doubles moved into LungfishTestSupport.

Genomics risk. Low. The VariantDatabase fault injection guards transactional VCF rollback, so equivalent rollback tests must exist through the injected observer before the statics go.

### R11. Source-text test assertions and test layout block mechanical refactors (medium, medium)

Evidence. 94 test files read Sources through #filePath helpers (Tests/Support/LungfishTestSupport/ViewerViewSourceTestSupport.swift, AppDelegateSourceTestSupport.swift, MainSplitViewControllerSourceTestSupport.swift) with 658 `.contains("...")` assertions on source text. The Viewer helper exists because a file split broke these tests. Tests/LungfishAppTests has 515 files, 502 of them flat at the root, including 23 genotype test files that belong in LungfishGenotypeUITests. 197 App test files import LungfishWorkflow.

Cost. Every rename, split or move that the program needs breaks dozens of tests that check spelling, and finding "which tests cover Y" means grepping the whole tree.

Recommendation. Freeze the count with a ratchet (no new source-text assertions). Convert the highest-churn files to behavioural tests through the SurfaceModel and EventBus seams as those land. Mirror the source tree under Tests/<Target>Tests/<SourceSubdir>/ and move tests to the target of the module they test. Add a generated TEST-MAP.

Genomics risk. Some assertions guard menu routing to the correct FASTA operation. Map each to the behaviour it protects before deleting it, and keep ScientificCLIProvenanceCoverageTests.

### R12. LungfishWorkflow is a 215K-line monolith (medium, large)

Evidence. 467 files and 215,052 lines, 15 loose files at the root. Domain subtrees are ONTGenotyping 47,671, Metagenomics 18,342, PrimerDesign 10,078, with infrastructure in Provenance 13,377, Conda 8,661, Native 7,129. Genotype data types also sit in IO (ONTGenotypeResultBundle.swift 4,297 lines). Every downstream target depends on Workflow.

Cost. Any public change recompiles CLI, Kit, nine leaves, App and six test targets. "How is a tool run" is buried next to 48K lines of MHC genotyping. The build-time gain is unmeasured.

Recommendation. Split into LungfishWorkflowCore (runners, conda, containers, provenance, engines, ingestion) and domain targets (Genotyping, Metagenomics, Primers, FASTQOps) by moving folders only, and create LungfishRNASeq as a domain target from day one. Measure with scripts/measure-build-times.sh before and after.

Genomics risk. Low if purely mechanical. Diff `lungfish-cli --help` and provenance schemas after each move.

### R13. Genome browser core lives in LungfishApp with no track-plugin seam (medium, medium)

Evidence. Sources/LungfishApp/Views/Viewer holds 99 files and 65,657 lines, including the SequenceViewerView family (12,556 lines), ReadTrackRenderer.swift (2,432, with CIGAR N and skip handling at 312 to 328 and intron drawing at 1997) and the AnnotationTableDrawerView family (12,351). LungfishAlignmentUI is one 300-line file.

Cost. Splice-aware RNA-seq viewing (junction arcs, sashimi plots, strand-specific coverage) means editing the largest module and adding branches to ReadTrackRenderer.

Recommendation. Extract LungfishGenomeBrowserUI as a leaf on Kit with a `TrackRenderer` protocol, and fold or fill LungfishAlignmentUI.

Genomics risk. Coverage math depends on CIGAR handling (deletions and N skips must not count as coverage, MD-tag mismatches must render). Pin with renderer unit tests on spliced and deleted reads before extraction.

### R14. Classifier viewports duplicate BLAST, extraction and row-action plumbing (medium, medium)

Evidence. showBlastResults is defined 8 times, presentUnifiedExtractionDialog 7 times (private in each of EsViritu, NaoMgs, TaxTriage, Nvd and Taxonomy), showBlastLoading and showBlastFailure 6 each. The four classifier controllers total 14,675 lines. LungfishKit's only shared classifier protocol is ClassifierAlignmentViewerProviding.

Cost. A BLAST or extraction fix must be applied six times and usually is not.

Recommendation. A `ClassifierResultActions` component in LungfishKit parameterised by a row-selector protocol.

Genomics risk. Extraction selectors decide which reads are exported. Keep per-classifier tests that extract a fixed selection and diff read IDs.

### R15. Dead code, duplicate types and compatibility paths with no expiry (medium, small)

Evidence. captureMinimap2Config (FASTQOperationDialogState.swift:883) has zero callers, so pendingMinimap2Config and runMinimap2Mapping (AppDelegate+ToolsMenu.swift:725) are unreachable, while Minimap2Pipeline.swift (1,263 lines) survives as AlignmentResultViewController's view model. Sources/LungfishApp/Services/AlignmentFilterCommandBuilder.swift is a dead copy of LungfishWorkflow/Alignment/AlignmentFilterCommandBuilder.swift (production uses the Workflow one via BundleAlignmentFilterService.swift:125), exercised only by Tests/LungfishAppTests/AlignmentFilterCommandBuilderTests.swift. Two public enums are named SequencingPlatform (LungfishIO/Formats/FASTQ/SequencingPlatform.swift:12 and LungfishWorkflow/Recipes/SequencingPlatform.swift:42). Native/ToolProvisioning (2,014 lines) is reached only from ProvisionToolsCommand. "legacy" appears in 216 files. Legacy selector flags include legacySalvageOptions in primer design and allowLegacyMissingBuildState.

Cost. A grep returns two definitions. An agent can edit the dead copy, see its test pass, and change nothing in production.

Recommendation. Delete the App AlignmentFilter copy and its test tonight. Delete the dead minimap2 path tonight if no test references it. Reconcile SequencingPlatform in Phase 1 after diffing cases and switches. Confirm ProvisionToolsCommand is unused by release scripts, then delete ToolProvisioning. Require a `COMPAT(remove-after: <version>)` tag on compatibility paths and add a duplicate-public-type check.

Genomics risk. The two SequencingPlatform enums may encode different defaults (quality encoding, read length). Primer "legacy salvage" may be a user-facing scientific mode and must be confirmed with users before removal, with CLI and dialog kept identical.

### R16. CLI event protocol and bundle-kind registry are missing (medium, medium)

Evidence. CLIEvent (LungfishWorkflow/CLIEvents/CLIEvent.swift) is used by 9 of 104 CLI command files. At least 15 private NDJSON schemas exist (BAMImportHelper.swift:11, MetagenomicsImportHelper.swift:12, VCFImportHelper.swift:23, CLIImportRunner.swift:32, FASTQOperationExecutionService.swift:19, BAMCommand.swift and others). There are 12 lungfish* extensions, "lungfishref" is a literal 68 times, 67 files compare pathExtension directly, directoryExtension constants exist on 9 types and there is no BundleKind enum. docs/formats documents only the primer bundles.

Cost. Each new command invents an encoder and a matching decoder, and has no standard way to announce "I produced bundle X with provenance Y". Adding RNA-seq outputs touches the scanner, inspector, deletion planner and cross-project copier by grep.

Recommendation. CLIEvent v2 with typed artifact and provenance cases and a schema version. A BundleKind/AnalysisKind registry in LungfishIO (extension, manifest type, UTType, icon, deletion and copy policy) generated from the existing constants, plus format specs for .lungfishref, .lungfishfastq and the Analyses layout.

Genomics risk. Extension detection gates which viewer opens BAM and VCF tracks. Assert parity with current behaviour on the TestData bundles. Keep decoders tolerant of old fields because helper processes may be a different version from the app.

### R17. RNA-seq prerequisites are absent (medium, large)

Evidence. Mapper indexes are built per run inside the output directory (ManagedMappingPipeline.swift 521 to 539, ".mapping-index"). A GTFReader exists (LungfishIO/Formats/GFF/GTFReader.swift) but no request type carries an annotation input with a checksum. No count-matrix result type exists. Memory checks are scattered across 15 files, mostly wizards, disk preflight exists in 2 UI files, CondaManager.runTool defaults to a 3600 s timeout, and there are no Rscript or Bioconductor references.

Cost. A STAR human index is about 30 GB and about an hour, so per-run rebuilds are not workable, and differential expression without a design contract will be bolted on.

Recommendation. Before any STAR or salmon code, add a ReferenceIndexCache keyed by reference checksum, tool, version and parameters (including GTF checksum and sjdbOverhang), an annotation input type recorded in provenance, a CountMatrix result and ExperimentDesign contract shared by featureCounts, salmon and DE, a strandedness detector whose result is recorded, a resourceClass on each descriptor with admission that only blocks or queues, and an R activation profile (R_HOME, isolated R_LIBS, no ~/.Rprofile).

Genomics risk. A GTF that does not match the reference build, a wrong strandedness setting, and multi-mapper handling are the correctness points. Each must be explicit in the request and provenance, with contig-name agreement validated between GTF and FASTA.

### R18. Domain special cases hard-coded in analyzer code (low, medium)

Evidence. GenotypeHaplotypeAnalyzer.swift lines 709 to 722 hard-code an MCM MHC-A A1_063 rule described as a notebook-compatible special case. FullLengthONTMHCGenotypingPipeline and ONTBarcodeDemuxGenotypingPipeline share 16 same-named functions including the cleanup journal and provenance writers.

Cost. Every new haplotype panel needs a code change, and twin pipelines drift.

Recommendation. Move population rules into the haplotype definition data next to macaque-mhc-v1.json and extract a shared GenotypingRunScaffold. Judgment call, scheduled last.

Genomics risk. High if careless. The notebook-parity fixtures are the oracle and must produce identical calls for the A1_063 cases.

## Invariants every phase must protect

The program is structural, so these behaviours are frozen and tested rather than reasoned about. BAM never SAM. Virtual FASTQ bundles are materialized before any classifier sees them. Viral Recon binds a .lungfishref manifest, never a loose BAM. Coverage ignores CIGAR deletions and N skips. Human-scrub database aliasing and mixed paired and unpaired derivative semantics are unchanged. Bundle locks serialize operations on one bundle. Every operation records a non-nil CLI command and a provenance envelope. The lock manifest stays the single source of tool versions. Genotype workbook and matrix exports stay byte-identical across any move.
