# Architecture program, phased implementation plan (2026-10-02)

Status: active. Companion to docs/reports/2026-10-02-architecture-review/REVIEW.md (finding IDs R1 to R18 below refer to it). Delete both together when the program closes.

## Goals

Remove the carrying cost of accumulated one-off hotfixes. Make the codebase cheap for LLM agents to navigate through indices, ownership files, small files and discoverable contracts. Put written contracts in place so that the RNA-seq surface (STAR or HISAT2 alignment, salmon or kallisto quantification, featureCounts, differential expression, splice-aware viewing) can be added next month with minimal trial and error. Never break genomics behaviour to satisfy a UI idiom. Every operation keeps OperationCenter, logging, provenance and CLI parity.

## Execution model

The program manager (Fable) owns the plan, reviews every lane's diff before merge, and runs the gate. Lanes are dispatched to sub-agents in isolated worktrees branched from the program branch `claude/arch-maintainability`. A lane owns an explicit file set and may not touch files outside it. Two lanes may run in parallel only when their file sets are disjoint. When a lane lands, the manager merges it into the program branch in the primary checkout and runs the gate there, serialized, before the next merge. Gate evidence must be in the primary checkout. The gate command for every task is

    bash scripts/full-suite-gate.sh --tier unit --quiet

run from the primary checkout, never from a worktree, and never two at once. A lane that changes only documentation or scripts still runs the gate once at merge, because the pre-push hook will run it anyway and a broken script fails the push.

Model tiers. Design-sensitive and scientific-output tasks go to Opus or Fable. Mechanical tasks (generators, ratchets, pure moves, literal replacement) go to Sonnet with Fable review. A Sonnet lane that discovers a judgment call stops and reports instead of deciding.

Commit conventions. One commit per task, subject in the imperative, body naming the finding ID. Pure moves and deletions carry no logic edits in the same commit. Every commit ends with the Co-Authored-By line the session requires.

Prose conventions. All documentation written by this program follows the project prose rules (no em dashes, no semicolons, no colons inside a sentence, no AI-tell words, lists capped at five items).

## Phase 0, tonight

Phase 0 is safe, high-leverage work that changes no scientific output. It contains documentation, indices, scripts and a small set of mechanical consolidations that existing tests already cover. Six lanes. Lanes A, B, C, D and F are disjoint and run in parallel. Lane E depends on A, B and D because its doc-path check must see their files, so it starts after they land, and it is the only lane that edits scripts/install-git-hooks.sh.

### Lane A. Root entry point and generated module map (Sonnet for the generator, Opus for the prose)

Files. AGENTS.md (new, root), CLAUDE.md (new, root, one line that points at AGENTS.md), docs/architecture/ARCHITECTURE.md (new), docs/architecture/MODULES.md (generated), scripts/index/generate-module-map.py (new), scripts/checks/module-map-current.py (new), scripts/tests/test_generate_module_map.py (new).

Tasks. AGENTS.md stays under 120 lines and holds the layering rule (each product imports only rows above it, Kit and leaves never import App, CLI never imports Kit), where to find things, links to ARCHITECTURE.md, MODULES.md, docs/contracts and features.yaml, the gate commands, and the binding rules (OperationCenter.begin not start, CLI parity, provenance envelope mandatory, BAM not SAM, virtual FASTQ materialized before classifiers, Viral Recon binds .lungfishref). ARCHITECTURE.md is the narrative map, at most 300 lines, with a "where to add X" table (a file format, a CLI command, an operation, a viewport, a sidebar kind, a tool environment) that names the owning file today and the contract that will replace it. generate-module-map.py reads Package.swift and walks Sources to emit MODULES.md with, per target, its dependencies, line and file counts, subdirectories, public top-level types with file and line, and its test target. module-map-current.py regenerates to a temp file and diffs, exit 1 on drift.

Acceptance. `python3 scripts/index/generate-module-map.py` is idempotent (running twice produces no diff). `python3 scripts/checks/module-map-current.py` exits 0 after generation and 1 after an injected edit. `python3 -m pytest scripts/tests/test_generate_module_map.py` passes. ARCHITECTURE.md names every Sources target and cites only paths that exist.

Gate. Unit tier at merge.

### Lane B. Per-module AGENTS.md files (Opus)

Files. Sources/<Module>/AGENTS.md for each of the 16 targets under Sources (LungfishCore, LungfishIO, LungfishWorkflow, LungfishKit, LungfishApp, LungfishCLI, LungfishCLIExecutable, Lungfish, and the nine leaf UI modules), plus Tests/AGENTS.md.

Tasks. Each file is under 80 lines and holds purpose, allowed imports, entry-point types with paths, contracts the module owns, its test target and how to run only that target, and known traps. Traps must come from the review evidence or from the project memory files, with the file and line named. LungfishWorkflow's file names the authoritative implementation for each scientific computation (mapping through ManagedMappingPipeline, classification through ClassificationPipeline and EsVirituPipeline, provenance through ProvenanceEnvelope, materialization through FASTQCLIMaterializer) and the domain subtrees. LungfishApp's file names the six composition-root families and says new feature logic belongs in a leaf. LungfishKit's file names OperationCenter.begin, CLISubprocessTransport and OperationCenterCLIBridge as the operation path. Tests/AGENTS.md explains the tiers in scripts/full-suite-gate.sh and the PARALLEL_HAZARD rule.

Acceptance. Every path cited resolves (Lane E's check enforces this). A reader can answer "where does a Kraken2 run start in the GUI, in the CLI and in Workflow" from the Workflow, App and CLI files alone.

Gate. Unit tier at merge.

### Lane C. Feature-to-file registry and its currency check (Sonnet)

Files. docs/user-manual/features.yaml, scripts/checks/features-yaml-sources.py (new), scripts/tests/test_features_yaml_sources.py (new).

Tasks. Fix the seven source paths that no longer exist (BAMImportService.swift, MappingViewerBundlePreparer.swift, FolderMetadataEditorSheet.swift, SampleGroupSheet.swift, VariantQueryBuilderSheet.swift, ViralReconWizardSheet.swift, BundleManifest.swift) by pointing at the file that replaced each one or removing the entry when the feature was removed, with the replacement found by git log, not guessed. Extend the schema comment and entries with optional fields `module`, `cli`, `operation_type`, `provenance` and `tests`, filling `module` for every entry tonight and the other fields where the review already names them (mapping, EsViritu, Kraken2, TaxTriage, MSA, primer trim, variant calling). features-yaml-sources.py verifies that every `sources:` and `tests:` path exists and that every `module` is a Sources target. Check first that docs/user-manual/build scripts that consume features.yaml ignore unknown keys, and stop if they do not.

Acceptance. `python3 scripts/checks/features-yaml-sources.py` exits 0. The existing `scripts/checks/features-yaml-entry-points.py` still exits 0. The manual build's features consumer still runs (`python3 docs/user-manual/build/scripts/<consumer>` as named in that directory's README). pytest for the new check passes.

Gate. Unit tier at merge.

### Lane D. Written contracts with the RNA-seq surface as the example (Fable or Opus)

Files. docs/contracts/README.md (new index), docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md (new), docs/contracts/ADDING-AN-OPERATION.md (new), docs/contracts/analysis-surface-checklist.md (new), docs/contracts/CONCURRENCY-PLAYBOOK.md (new), agents/process/PROJECT-LEAD-AGENT.md (line 146, start to begin, plus a pointer to the contracts), agents/specialists/16-workflow-builder.md (delete).

Tasks. ADDING-AN-OPERATION.md traces one existing CLI runner path end to end (CLIVariantCallingRunner is the recommended example) through the Workflow service, the CLI command that emits CLIEvent, the App runner using OperationCenter.begin plus OperationCenterCLIBridge, the provenance envelope, the output bundle, the features.yaml entry and the tests, naming each file. It states the rules as requirements (begin not start, operationType and cliCommand always passed, lock scope declared, createAnalysisDirectory never under `try?`, trackAnalysisOutput and markAnalysisComplete always called, provenance written through the envelope, virtual FASTQ materialized before tool execution). ADDING-AN-ANALYSIS-SURFACE.md is the leaf-module recipe (leaf target, viewport class, inspector sections, sidebar registration, row commands, test target, features.yaml entry) and states today's touch points honestly (SidebarItemType, ContentDisplay, ViewerViewController slot and hide list, AppDelegate extension, Inspector extension, AnalysesFolder and SidebarProjectScanner tables, AppDelegate prefix table) so an agent adding a surface before Phase 3 has a complete list, and marks each touch point with the phase that retires it. The checklist is a copyable list an agent ticks per surface. The RNA-seq section walks the whole thing for a LungfishRNASeq Workflow domain and a LungfishRNASeqUI leaf (index build, alignment, quantification, counting, DE, splice viewing) and lists the prerequisites from R17 that must exist first. CONCURRENCY-PLAYBOOK.md gives the MainActor dispatch, progress callback and generation-counter patterns from the project memory and marks assumeIsolated, @unchecked Sendable and nonisolated(unsafe) as ratcheted.

Acceptance. Every file path in the four documents resolves. An Opus reviewer not involved in writing reads only AGENTS.md and the contracts and produces a correct file list for adding a hypothetical "salmon quant" operation, judged by the manager against the review evidence. Prose lint (`LUNGFISH_MANUAL_STRICT=1 bash docs/user-manual/build/scripts/lint-chapter.sh <file>`) reports no issues for each contract file.

Gate. Unit tier at merge.

### Lane E. Ratchets and checks, wired into the pre-push hook (Sonnet, starts after A, B and D land)

Files. scripts/ratchets/file-size.sh and file-size.baseline (new), scripts/ratchets/concurrency-hatches.sh and .baseline (new), scripts/ratchets/source-text-assertions.sh and .baseline (new), scripts/checks/doc-path-references.py (new), scripts/checks/duplicate-public-types.py (new), scripts/install-git-hooks.sh, scripts/tests/test_ratchets_phase0.py (new).

Tasks. Model every ratchet on scripts/ratchets/unchecked-operation-start.sh (Python with a .sh name, --print and --update modes, baseline file, exit 1 over baseline). file-size: new Swift files at or under 800 lines, baselined files may not grow past their recorded length. concurrency-hatches: counts of MainActor.assumeIsolated, @unchecked Sendable, nonisolated(unsafe) and nonisolated(unsafe) static var may only fall. source-text-assertions: the count of `.contains("` assertions against source text in Tests may only fall. doc-path-references.py: every `Sources/...swift` or `Tests/...swift` path and every bare `Foo.swift` name in AGENTS.md files, docs/architecture, docs/contracts and agents/process must resolve (agents/specialists is reported but not enforced tonight, because its rewrite is Phase 1). duplicate-public-types.py: public and open type names must be unique across Sources targets, with an allowlist seeded with SequencingPlatform until R15 resolves it. Wire all five into install-git-hooks.sh after the existing ratchets and before the gate, with the same message style, then reinstall the hook.

Acceptance. Each script exits 0 on the merged program branch and 1 on an injected violation, covered by the pytest file. `bash scripts/install-git-hooks.sh` reinstalls without error and `.git/hooks/pre-push` lists the new checks.

Gate. Unit tier at merge.

### Lane F. Mechanical consolidations that tests already cover (Sonnet, Fable review of each diff)

The sub-tasks run sequentially inside the lane because F2 and F4 share AppDelegate+ToolsMenu.swift.

F1. Delete the dead App copy of the alignment filter builder. Files. Sources/LungfishApp/Services/AlignmentFilterCommandBuilder.swift, Sources/LungfishApp/Services/AlignmentFilterModels.swift, Tests/LungfishAppTests/AlignmentFilterCommandBuilderTests.swift. Precondition. `grep -rn "AlignmentFilterCommandBuilder\|AlignmentFilterRequest" Sources/LungfishApp` shows no other user after the deletion. Acceptance. The build passes and Tests/LungfishWorkflowTests/Alignment/AlignmentFilterCommandBuilderTests.swift still passes.

F2. Delete the unreachable minimap2 launch path. Files. Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift (pendingMinimap2Config, captureMinimap2Config and the two resets), Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift (the pendingMinimap2Config branch at line 215 and runMinimap2Mapping at line 725). Precondition. `grep -rn "pendingMinimap2Config\|captureMinimap2Config\|runMinimap2Mapping" Tests` is empty. If it is not, the sub-task is skipped and reported, because retiring tests needs a judgment call. Minimap2Pipeline.swift and AlignmentResultViewController stay untouched. Acceptance. Build passes, ManagedMappingPipelineTests and MappingResultViewControllerTests pass.

F3. Replace the "core_nt" literal with one constant. Files. Sources/LungfishCore/Models/BlastDatabaseID.swift (new, an enum with a `coreNT` case whose rawValue is "core_nt"), and the 11 files that hold the literal (three *+BlastVerification.swift in LungfishIO, the three leaf files that carry the "Matches the database" comment, four ViewerViewController+<Feature>.swift extensions and ViewerViewController.swift). The comments are deleted because the constant replaces them. Acceptance. `grep -rn '"core_nt"' Sources` returns only BlastDatabaseID.swift. Existing BLAST verification tests pass unchanged. The submitted database string is byte-identical, so no scientific output changes.

F4. Label mapping operations correctly. Files. Sources/LungfishKit/OperationCenter.swift (add `case mapping = "Mapping"` to OperationType), Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift (pass `operationType: .mapping` at the live mapping launch near line 1351). Precondition. `grep -rn "\.download" Tests | grep -i mapping` finds no test that pins the old label. Acceptance. Build passes, OperationCenter tests pass, the Operations panel shows Mapping for a mapping run (verified by a unit test on the item's operationType, not by GUI).

Gate. Unit tier at merge, once for the whole lane.

### What must NOT be changed tonight

No file under Sources/LungfishWorkflow except through zero-logic deletions explicitly listed above (there are none). No pipeline, runner, CondaManager, NativeToolRunner, provenance writer or reader, materializer or bundle manifest code. No change to any ONTGenotyping, PrimerDesign, Metagenomics, Variants or Mapping code path. No change to third-party-tools-lock.json, PluginPack.swift or any version string. No OperationCenter semantics beyond the added enum case. No start-to-begin migration. No file splits or moves of Swift code. No change to full-suite-gate.sh tiers or PARALLEL_HAZARD_SUITES. No deletion of plans, specs or reports under docs (the retention sweep is Phase 1 and needs the shipping commit for each). No edit to agents/specialists beyond the one deletion. No change to screencasts, release scripts or the user manual chapters.

## Phase 1, foundations (weeks 1 to 2)

Phase 1 started on 2026-10-02. This section was rewritten then to add the work agreed with the owner. Phase 0 above is the historical record.

### How Phase 1 runs

An Opus 5.5 session is the program manager. The program branch is `claude/lungfish-phase-1-orchestration-d7a1c6`, created from main at 1f70a13ea. The Phase 0 branch `claude/arch-maintainability` is not used. Each lane runs in its own worktree branched from the program branch and owns an explicit file set that no other running lane shares. A lane that needs a file outside its set asks the owning lane or the manager and never edits that file. The manager reviews every diff, merges it into the program branch, fast-forwards the primary checkout's local main, and runs the unit gate there, one gate at a time and never in a worktree. Doc-only lanes share one gate. The golden compare runs after every code merge. main is not pushed until the release.

Sonnet 5.5 takes the mechanical lanes, which are the start to begin batches after an Opus exemplar, the audit tags, the docs sweep, ToolProvisioning, the type moves and the release chain. Opus 5.5 takes the design and scientific lanes, which are the goldens, OperationReporting, the Nextflow environments, SequencingPlatform, ScopedEventFilter, the test doubles, the specialist docs, the dead minimap2 path and the routing and sidebar safety nets. A stuck lane, or a judgment call with scientific risk, goes to Fable. Sonnet lanes stop and report judgment calls instead of deciding them.

At most four lanes build Swift at once, and free disk stays above 40 GiB.

### Entry criteria, golden fixtures (lane 1.0, Opus)

The goldens are captured from main at 1f70a13ea and merge before any other Phase 1 code. They cover four outputs.

- Mapping on the SARS-CoV-2 fixture.
- EsViritu and Kraken2 on a virtual FASTQ bundle input, with read counts and provenance.
- Genotype workbook and matrix exports from the mhc-genotyping demo project or another de-identified MHC project. Demo projects hold inputs only, so one genotyping run produces the result. 32566_MS267_Williams1.lungfish is never touched.
- `lungfish-cli --help` for every command and subcommand.

Normalized outputs live under Tests/Fixtures/golden with one re-runnable compare command. Normalization masks only timestamps and run IDs, and replaces the run's scratch root with a fixed token so the rest of each path is still compared. Everything else is compared byte for byte. Any other field that differs between two runs on main goes to the manager before it is masked. No BAM or other large file is committed (docs/development/large-files.md). Acceptance is that the compare passes on unmodified main, fails on an injected one-byte change, and records its own runtime.

### Tasks

| Lane | Task | Finding | Files | Model | Acceptance |
|---|---|---|---|---|---|
| 1a.1 | OperationReporting protocol, RecordingOperationReporter and an exemplar migration batch | R4 | Sources/LungfishKit/OperationReporting.swift (new), OperationCenter.swift, Tests/Support/LungfishTestSupport/RecordingOperationReporter.swift (new), five exemplar files | Opus | Lock tests pass unchanged, a test asserts a recorded item has a non-nil cliCommand, the exemplar sites carry the per-site tests, and the test pattern is written into docs/contracts/ADDING-AN-OPERATION.md |
| 1a.2 | Migrate the remaining start() sites to begin() | R4 | The files that call start( on OperationCenter, five files per batch | Sonnet, Opus review | Per-site tests as below |
| 1a.3 | Delete start() and remove the operationType and cliCommand defaults | R4 | OperationCenter.swift and any caller that relied on a default | Sonnet | The unchecked-operation-start ratchet reaches 0 and its baseline is lowered to 0 |
| 1b | Route TaxTriage, PBAA and NextflowRunner through WorkflowEngineLaunch.resolve and remove `which nextflow` | R7 | TaxTriagePipeline.swift, PBAAClusteringPipeline.swift, Engines/NextflowRunner.swift, WorkflowEngineLaunch.swift and their tests | Opus | TaxTriage and Viral Recon smoke runs pass before and after on Docker Desktop, the Docker profile and NXF_CONDA_CACHEDIR stay explicit overrides, and a test asserts JAVA_HOME is set when no system JDK exists |
| 1c | Audit tag rewrite and its lint | R5 | Comments that carry audit tags in Sources, Tests and scripts, and scripts/checks/audit-tags.py (new) | Sonnet | No audit-report tag remains in Sources, Tests or scripts, the lint matches only the audit report's tag prefixes so UTF-8 and SHA-256 pass, SCI and GEN rationale text is preserved verbatim, and the diff is shown to be comment-only |
| 1d.1 | Docs retention sweep and staleness check | R5 | docs/superpowers, docs/plans, docs/issues, docs/product-specs, docs/verification, finished reports under docs/reports, scripts/checks/working-memory-staleness.py (new) | Sonnet | Each deletion cites its shipping commit, reports cited by ratchets, tests or contracts are kept, and the 2026-09-23 audit report is deleted only after 1c merges |
| 1d.2 | Specialist docs rewritten as role prompts that point at the module AGENTS.md files | R5 | agents/specialists/*.md, agents/process/*.md, scripts/checks/doc-path-references.py | Opus | doc-path-references.py is enforced on agents/specialists and exits 0 |
| 1e.1 | SequencingPlatform reconciliation | R15 | LungfishIO/Formats/FASTQ/SequencingPlatform.swift, LungfishWorkflow/Recipes/SequencingPlatform.swift and their switches | Opus | Cases and every switch are diffed first, a test pins the platform-specific recipe parameters before the change, and the duplicate-public-types allowlist entry is removed |
| 1e.2 | ToolProvisioning deletion | R15 | Sources/LungfishWorkflow/Native/ToolProvisioning, ProvisionToolsCommand.swift and their tests | Sonnet | Release scripts grep clean for provision-tools, and the CLI help golden is updated deliberately in the same commit |
| 1f | ScopedEventFilter and scope classification | R9 | Sources/LungfishKit/ScopedEventFilter.swift (new), the seven filter copies, LungfishCore/Models/Notifications.swift, and the posters of window events | Opus | Every Notification.Name is classified as window or application, every poster of a window event attaches its scope before the filter fails closed, and a two-window test shows an unscoped window event is dropped while an application event arrives |
| 1g | Test doubles out of production | R10 | AppDelegate.swift (test process runner), MainSplitViewController+Testing.swift, LungfishKit/TestHarnessDetection.swift and its users, Tests/Support | Opus | No TestHarness.isRunning branch in Sources, the launch-argument XCUI backends still work, and the XCUI Viral Recon fixtures still exercise real primer staging |
| 1h | Delete the unreachable minimap2 launch path (F2, carried over from Phase 0) | R15 | FASTQOperationDialogState.swift, AppDelegate+ToolsMenu.swift, UnifiedClassifierRunnerTests.swift, ViralReconWorkflowExecutionServiceTests.swift, FASTQOperationDialogRoutingTests.swift | Opus | The virtual-input provenance guarantee has a behavioural test on the live mapping path before the deletion, the three source-scan tests are retargeted, and ManagedMappingPipelineTests and MappingResultViewControllerTests pass |
| 1i | Type-per-file moves for the oversized files that hold several types | R6 | FastqCommand.swift, FetchCommand.swift and the other files over 800 lines with several top-level types | Sonnet | Pure moves only, files that tests read as source text are skipped, and the file-size baseline is lowered |
| 1j | Routing-table and sidebar-scan safety nets | R1, R2 | New test files only | Opus | The routing table covers every fixture bundle kind and asserts which surface opens and what it binds (Viral Recon binds .lungfishref), the sidebar-scan snapshot covers the fixture projects, and both pass on main |

Per-site tests for 1a. A migrated site that declares a bundle lock gets a test that a refused lock launches no subprocess. Every migrated site gets a test that its recorded item carries the right operationType and a cliCommand. Each site keeps its existing lock targets, so the migration changes no lock behaviour.

CLI parity. The owner asked that every command the GUI runs be CLI driven with no drift between the GUI and the CLI. Phase 1 enforces this in three ways. Every operation records a `lungfish-cli` command built from the configuration the GUI executes. The defaults that allowed a missing command are removed. A test parses each recorded command with the real CLI parser. Operations that still execute in process in the GUI are listed in the Phase 1 report against the Phase 2 task that moves them behind the CLI.

Order. 1.0 merges first and the golden compare runs after every later code merge. 1c edits comments in about 300 files, so it runs on files no running lane owns, and a second pass covers the rest. 1i runs after the code lanes merge.

Not in Phase 1. No RNA-seq work, because RNA-seq is only the yardstick for the contracts. No genotype controller decomposition, which stays in Phase 4a. The Phase 1 report says whether to bring it forward.

Exit criteria. Every task above is merged. Every ratchet is at or below its baseline, with unchecked-operation-start at 0. The golden compare is byte-identical. GUI checks on a debug app pass for operation launches and the Operations panel types, two-window Inspector scoping, and the screens touched by the test-double removal. An independent Opus reviewer finds no blocker. Preview 2026.10.1 is then cut as a rewind point.

Rollback. Each task is one commit, or one commit per batch, and reverts cleanly. The protocol task is reverted with its migration batches.

## Phase 2, one executor, one process primitive, one provenance recorder (weeks 3 to 5)

Entry criteria. Phase 1 exit. Golden outputs for every tool's stdout and exit code on fixtures (the per-tool conformance tier under LUNGFISH_REQUIRE_TOOLS).

| Task | Finding | Files | Model | Lane | Acceptance |
|---|---|---|---|---|---|
| ToolProcess primitive and adapters | R7 | Sources/LungfishWorkflow/Native/ToolProcess.swift (new), NativeToolRunner.swift, CondaManager.swift, ProcessManager.swift, CLISubprocessTransport | Fable | 2a | Per-tool golden stdout byte-identical, cancellation kills the tree (nextflow and BBTools java children), Process() outside Native/ ratchet only falls |
| ProvenanceRecorder, writers frozen, legacy readers under fixture tests | R8 | Provenance/ProvenanceRecorder.swift (exists, extend it in place), the 25 writeProvenance sites, the 39 path helpers | Opus | 2b | Round-trip tests for every legacy sidecar filename, demo projects load unchanged, envelope-only files written |
| AnalysisToolDescriptor and registry decoded from the lock | R2 | LungfishIO/Analysis/AnalysisToolDescriptor.swift (new), NativeToolRunner switch tables, PluginPack.swift, the 12 lookup tables one PR each | Opus for the descriptor, Sonnet per table | 2c | Manifest-driven smoke test runs every descriptor's version probe, sidebar scan snapshot over fixture projects unchanged |
| AnalysisRunExecutor with EsViritu, Kraken2 and TaxTriage migrated, GUI calls it through CLISubprocessTransport | R3 | LungfishWorkflow/Analysis/AnalysisRunExecutor.swift (new), EsVirituCommand.swift, ClassifyCommand.swift, TaxTriageCommand.swift, AppDelegate+Classification.swift | Fable | 2d (after 2a to 2c) | Same request through CLI and GUI yields identical output trees and provenance with timestamps masked, virtual-bundle input test checks read counts, ensure*IfPossible backfills deleted |
| AppKit-free Services moved to a UI-free target | R3 | New target LungfishOperations in Package.swift, the 114 AppKit-free files under LungfishApp/Services | Sonnet, pure moves | 2e (after 2d) | Build passes, LungfishAppTests files that only test moved code move with them, NativeToolRunner-in-App ratchet reaches 0 |
| Genotype first slice: characterization tests per responsibility (export coordinator, review eligibility, matrix projection, haplotype-band disclosure), the type-per-file moves Phase 1 skipped in LungfishGenotypeUI, and the export coordinator extracted | R6 | LungfishGenotypeUI/*, new characterization tests | Fable for the tests and extraction, Sonnet for pure moves | 2g (parallel, no shared files with 2a to 2f) | Genotype goldens byte-identical, every move commit passes verify_pure_move.py, GenotypeResultViewController shrinks, attended GUI pass on genotype screens |
| CLIEvent v2 and BundleKind registry | R16 | CLIEvents/CLIEvent.swift, the 15 private schemas, LungfishIO/Bundles/BundleKind.swift (new), docs/formats specs | Opus | 2f | Every subcommand's --help passes a decoder test, pathExtension parity on TestData bundles |

Exit criteria, read literally as the owner ruled on 2026-10-17 ("Literal, 2.12 + 2.13."). On 2026-10-22 the owner moved the exit to the end of 2.14, a short session that the 2.13 walk asked for (2.13 plan O30 and MD110). The classifier CLI parity classes are green with no declared difference that names a Phase 2 sub-phase. No Process() and no raw .terminate() remain outside Sources/LungfishCore/Process/, with no exemption list. One provenance writer, so no envelope is encoded and no record is written outside ProvenanceWriter. Every hidden route key and every ensure*IfPossible backfill is deleted. Every operation records a lungfish-cli command, and every viewer export that begins no Operations row gets a row and a command, or a recorded reason when it writes no file a record could name ("Yes, close them in Phase 2."). Phase 2 ends with a Preview ("No, Preview only."), and the owner check list keeps blocking Stable. The measures are in the exit criteria table of the 2.12 and 2.13 plan. Rollback. Executor migration is per tool behind the old path kept until its parity test is green for one release, then the old path is deleted. A route whose parity declares no difference deletes its old path in the same change (2.10 C4), and no route flips behind a key in 2.13, since that key could not go inside Phase 2 (2.12 R-A1).

Phase 1.5 (owner decisions of 2026-10-03, shipped before Phase 2 in Preview 2026.10.2). A read-pairing contract (unmerged pairs go to every tool as pairs, merged reads and singletons single-end), Kraken2 classifying pairs as pairs alongside merged reads in one result, platform inference at import, and a CLI equivalent for every operation by contract (docs/contracts). Phase 2 builds on those contracts. Its 2d migration keeps the pairing and CLI-equivalence tests green, and the genotype first slice (2g) was brought forward from Phase 4a by the owner. The rest of the genotype decomposition stays in 4a.

Sub-phases (owner directive of 2026-10-05). Phase 2 runs as fourteen small sub-phases, one session each, and each sub-phase ends with a Preview release that serves as its rewind point. The thirteenth, 2.13, follows from the owner's ruling of 2026-10-17 that the exit criteria read literally ("Literal, 2.12 + 2.13."), since a key that 2.12 ships can be deleted only one release later. The fourteenth, 2.14, follows from the 2.13 walk: the panel voted 4 to 1 for a short session before 3.1, and the owner accepted it ("Accept the panel: run a short 2.14 before 3.1 ... and end Phase 2 there.", 2026-10-22).

| Id | Scope | Depends on | Owner decisions needed first |
|---|---|---|---|
| 2.1 | Phase 1.5 follow-ups that change results: SRA `--split-3` and download checks, bundle and import follow-ups, 12S fragment counting, primer read-through trim, demultiplexing (mate-aware and `--no-trim`), Kraken2 wrapper edges | Phase 1.5 | none |
| 2.2 | Per-tool golden outputs (the Phase 2 entry criterion), then 2a: one ToolProcess primitive with adapters | 2.1 | none |
| 2.3 | 2g: genotype characterization tests, LungfishGenotypeUI type-per-file moves, export coordinator extracted | 2.1 (any time after) | [6] GEN tags, only if the lane touches those notes |
| 2.4 | 2b: one provenance recorder, legacy sidecar readers under fixture tests | 2.2 | none |
| 2.5 | 2c: AnalysisToolDescriptor and a registry decoded from the lock | 2.2 | none |
| 2.6 | 2f: CLIEvent v2 and a BundleKind registry, plus sidebar routing fixes | 2.2 | [12] `classify` alias |
| 2.7 | 2d, part 1: AnalysisRunExecutor with Kraken2 and EsViritu, the GUI through the CLI | 2.2, 2.4, 2.5 | none |
| 2.8 | 2d, part 2: TaxTriage, the operations dialog's dispatcher, `assemble` provenance | 2.7 | [5] joined input copies |
| 2.9 | 2e: AppKit-free services into a UI-free target, leftover moves, one path per operation | 2.8 | [12] target or folders (required), [7], [8] |
| 2.10 | CLI commands for in-process operations, batch 1 (L1, L5, L6, L2, L3, L10) | 2.9 | none |
| 2.11 | Batch 2 (L4, L7, L8a, L8b) | 2.10 | none |
| 2.12 | Batch 3 (L9, L11, QR) and every remaining recorded-command gap as a flip, the viewer exports with Operations rows and commands, decision [9], and the deletion of 2.11's three hidden keys | 2.11 | none, the owner answered on 2026-10-17 |
| 2.13 | The deletion of every key 2.12 ships, no Process() outside the process primitive, one provenance writer, the record-fact rows and the rows 2.12 cut, then the Phase 2 exit review last | 2.12 | none |
| 2.14 | The owner's Linux FASTQ preprocessing work (O29) with an ARCH intake and a review per field, and the walk's fixes: W1-T (Viral Recon staging off the main actor), the Stable blockers rows 69 and 20, obs-6, obs-11 and obs-14, and obs-13 and obs-10 if checks C2 and C4 confirm them. Its Preview is the Stable candidate, and Phase 2 ends with it (2.13 plan MD110 to MD116, MD120) | 2.13 | none, the owner answered on 2026-10-22 (O30) |

## Phase 3, the surface contract in code (weeks 5 to 8)

Entry criteria. Phase 2 exit, and the routing table test from R1 captured against current behaviour. That test exists (`Tests/LungfishAppTests/SafetyNets/RoutingTableSafetyNetTests.swift`) and pins what each kind opens and binds, but it observes no drawer, toolbar, Inspector tab or switch between two kinds, so 3.1 widens it at the base before any host code.

| Task | Finding | Files | Model | Lane | Acceptance |
|---|---|---|---|---|---|
| ResultViewport protocol, ViewportHost with one activeViewport slot that owns one load task and one token, SurfaceRegistry keyed by BundleKind | R1 | LungfishKit/Surfaces/*.swift (new, with ResultExportFormat and BlastRequest moved in from ResultViewportController.swift as a pure move), ViewerViewController.swift | Opus | 3a | Switch matrix test over every pair of viewport kinds, frozen at the base with today's leaks declared, leaves exactly one child installed and refuses a commit from an old token |
| Migrate TwelveS and PrimerAnalysis, then Nvd, NaoMgs, EsViritu, TaxTriage, then Kraken2's taxonomy view (moved into a leaf first) and CzId, then genotype, MSA, phylo and assembly, then the FASTA collection, FASTQ dataset, VCF dataset, MHC reference and Quick Look views, then mapping and reference last | R1 | One ViewerViewController+<Feature>.swift and leaf per PR | Opus | 3a sequential | The viewport-hides and viewport-slots ratchets fall per PR, routing table test unchanged, drawer state read from the viewport, and each PR types the events whose poster and observers sit in its files |
| Sidebar routing registry and the prefix tables retired | R1 | SidebarItem.swift (27 kinds), MainSplitViewController+ContentDisplay.swift, MainWindowController.swift, AppDelegate.swift 302 to 306, SidebarProjectScanner.swift 993 and 1047, LungfishOperations/ProjectDeletionPlanner.swift 455 to 456 | Opus | 3b | Exhaustive switch over kinds, single read-only fallback function for manifest-less legacy bundles covered by demo-project tests and renamed-folder rows |
| Typed AppEvent layer with NotificationCenter bridge, extending ScopedEventFilter, raw userInfo keys migrated | R9 | LungfishKit/Events/*.swift (new), LungfishCore/Models/Notifications.swift, the posting and observing files | Opus | 3c | Round-trip test per event, lint rejects new Notification.Name outside the allowlist, the userinfo-literal-keys ratchet at 0 |
| OperationSpec and OperationLauncher, leaves submit specs directly | R4 | LungfishKit/Launch/*.swift (new), the leaf row-command and export files | Opus | 3d (after 2d) | A second spec on a locked bundle is refused and names the holder, every launched item has cliCommand and provenance, and the cli-parity ratchet counts specs |
| ClassifierResultActions shared component | R14 | LungfishKit/Classifiers/ClassifierResultActions.swift (new), the five classifier controllers | Opus for the component and TaxTriage, Sonnet per adoption | 3e (after 2.12's K1, A65-M3 and A66-M3) | Per-classifier extraction tests diff read IDs against lists frozen in 3.1, and showBlastResults and presentUnifiedExtractionDialog are defined once |

Exit criteria. One surface registration adds no App code beyond registry registration, measured by a stub surface in a test target that the routing net opens with no App edit and by the viewport-hides, viewport-slots and name-prefix-routing ratchets at 0. No golden and no cli-help capture moves in any Phase 3 commit. Rollback. The bridge keeps legacy observers alive, each viewport migration is one revertible PR, and no Phase 3 change adds a hidden key.

Owner decisions of 2026-10-17. For a second operation on a locked bundle the owner chose "Refuse and name the holder", so the OperationLauncher keeps refuse-with-holder and the queue question stays with 5d. For GUI checks the owner chose "XCUI gate and your walk", so XCUI is runnable in a gate from 3.1, which fixes the ui profile's entry for the missing scripts/release/app-smoke-gate.sh (config/test-catalog.json:237, the script is scripts/release/app_smoke_gate.py), and each Phase 3 Preview gets a short owner walk of the migrated views.

Premises corrected on 2026-10-17, read at 65539ddcd. The votes and the memo and inventory ids cited here are in `docs/plans/2026-10-17-phase-2-12-panel-decisions.md`.

| Task | Premise | At 65539ddcd | Source |
|---|---|---|---|
| Entry | The R1 routing table test still to capture | It exists and pins bindings, Viral Recon on its .lungfishref included, but no drawer, toolbar, Inspector tab or switch | BIO memo correction 1, UX inventory 2.1, QA inventory 2.1 |
| 3a | 270 hide*() calls and eleven kinds | 277 to 415 calls by pattern, so 3.1 writes the pattern into a ratchet. Eight kinds with a hide function had no place, among them Taxonomy, CzId, Assembly and Quick Look | QA memo 0, ARCH inventory 2.1, vote Q-A9 5 to 0 |
| 3a | LungfishKit/Surfaces is wholly new | ResultViewportController.swift (68 lines) holds ResultExportFormat and BlastRequest, which move into Surfaces | ARCH ruling R-A6 |
| 3a | Drawer state re-derived in MainWindowController.swift 480 to 492 | That chain is gone. isActiveDrawerOpen is a four-arm chain in ViewerViewController+MSABottomPane.swift 12 to 18 | ARCH inventory 2.1 |
| 3b | AppDelegate.swift 301 to 305, and 71 SidebarItemType cases | The table is at 302 to 306, two more routing tables exist, line 1958 is a temp sweep and not routing, and the enum has 27 cases (SidebarItem.swift 41 to 67) | ARCH ruling R-A7, QA memo 0 |
| 3c | 82 raw-string sites and seven copied scope filters | The 82 cannot be reproduced. One written pattern counts 85, and ScopedEventFilter.swift replaced the seven filters in 1f | ARCH, SWIFT, BIO, UX and QA memos |
| 3d | 58 start() calls, LungfishKit/Operations | start() has 0 callers. Operations would share a name with the LungfishOperations target, so the folder is Launch. "Serialize" now reads "refused, naming the holder" | Vote Q-A8 3 to 0, owner decision of 2026-10-17 |
| 3d | Leaf exports reach specs in Phase 3 | Phase 2.12 gives every viewer export a row and a command, so 3d wraps rows that already record a command | Owner decision of 2026-10-17, "Yes, close them in Phase 2." |
| 3e | Sonnet, four controllers of 14,675 lines, 8 copies of showBlastResults | Five controllers of 16,634 lines and 10 copies, with the BLAST and extraction rows rewritten in 2.12 | ARCH memo 5.3, BIO inventory 2.1 |

Sub-phases (owner direction of 2026-10-17, subdivision voted by the panel 4 to 1). Phase 3 runs as six sub-phases, one session each, and each ends with a Preview and a short owner walk of the views it migrated. Every sub-phase keeps golden.py compare and the cli-help capture unmoved, keeps the routing, sidebar and switch nets green, and lowers each ratchet by exactly the sites of each PR.

| Id | Scope | Depends on | Owner decisions needed first |
|---|---|---|---|
| 3.1 | Pins and meters at the base, then the cores and two exemplars. Lane 1 is scripts/checks/module-imports.py. The routing net gains the Inspector tab, the drawer, the toolbar and an accessibility snapshot per kind, and the switch matrix runs over every pair of kinds with today's leaks declared. Each classifier gets read-ID, unique-count and export byte pins, and row texts are frozen. Ratchets count viewport hides, viewport slots, literal userInfo keys, Notification.Name declarations and name-prefix routing. XCUI runs in a gate and the NAO-MGS loads leave the main actor. Then ResultViewport, ViewportHost and SurfaceRegistry, the typed event core and bridge with no site moved, and TwelveS and PrimerAnalysis | Phase 2 exit (2.13's Preview) | none |
| 3.2 | 3a for Nvd, NaoMgs, EsViritu and TaxTriage, one revertible PR each | 3.1 | none |
| 3.3 | Kraken2's TaxonomyViewController into a leaf by pure move and migrated, CzId, then 3e over the five classifiers with one ruled label set | 3.2 | none (the label set is a panel ruling at entry) |
| 3.4 | 3a for genotype, MSA, phylogenetics and assembly, then the FASTA collection, FASTQ dataset, VCF dataset, MHC reference and Quick Look views | 3.3 | [6] GEN tags, only if a lane touches those notes |
| 3.5 | 3a for mapping and reference last, the hide list and optional slots deleted, then 3b over BundleKindRegistry with one read-only fallback and the three prefix tables retired | 3.4 | none |
| 3.6 | 3c's remaining raw sites and the lint, then 3d with the cli-parity ratchet moved onto specs first, the failure, cancel and progress words on the launcher, and a design ruling on an on-disk bundle lock for CLI runs, then the Phase 3 exit review | 3.5 | none |

## Carry-in from Phase 2.13

Written at the end of Phase 2.13 from its records, at the program head `8190b9000` that Preview 2026.10.22 is published from. The full rows are in `docs/plans/2026-10-20-phase-2-13.md`, which holds the Moved out rows in `## Moved out of 2.13`, the decisions MD1 to MD108 and the owner directions O23 to O26 in `### Decisions` and the publish in `## Release`. The walk of 2.13 ended on 2026-10-22 and added O27 to O30, MD109 to MD120 and the walk rows at the end of `## Moved out of 2.13` (MD119). Phase 2.14 runs before 3.1 (MD110), and the walk rows join this carry-in for the Phase 3 start vote. The carry-in has four parts, the Moved out rows by field, the held tier 3 lanes, the Known limits that end "This is a Phase 3 candidate" and the standing directions. Two rows name a sub-phase, S-13.14-Q1 and K10-S8, and both say Phase 3d. S-M3-Q2 says a later plan. Every other row says Phase 3 or Phase 3 candidate, and the panel places it at the start of the Phase 3 session.

### Moved out rows by field

The 2.13 plan holds 56 rows, the 51 rows of the fixed `moved-out-213.md` and five tier 3 lanes. The table lists the 51 rows under each field that the row's Where cell names, or that its ruling or review file is named for, so a row with two fields appears twice. A row whose record names no field is listed last. The tier 3 lanes are in the next table.

| Field | Rows |
|---|---|
| ARCH (12) | A-13.13-Q2, Q-LEGACY-RESOLVED, U-BAR-GAP, GENBANK-INTERNAL-KEYS, DURABLE-ATOMICALLY, 13.27-R2, 13.27-LABELS, 13.27-REPLAY-ANNOT-ADD, REPLAY-WORKFLOW-OUTDIR, REPLAY-UNMAPPED-OLD-PATH, GATE-CONDA-ROOT, APP-RECORDS-OFF-MAIN |
| BIO (19) | B-13.12-Q2, Q-SW26-OBS, Q-SW26-K2EXPLICIT, Q-13.09-FAILSTEP, CALLSDB-BOOKMARK-SIDECAR, Q-LEGACY-RESOLVED, TT-FUZZY-NAME, GFF3-MULTIVALUE, GFF3-SIDEBAR-ORDER, GENBANK-INTERNAL-KEYS, VARIANT-IMPACT-KEYS, CDS-CUT-NUMBERING, 13.27-R2, 13.27-REPLAY-ANNOT-ADD, REPLAY-WORKFLOW-OUTDIR, REPLAY-UNMAPPED-OLD-PATH, RECEIPT-ONT-BARCODE-NAME, LOCALE-READSET, FIXTURE-SKIP |
| QA (16) | Q-LEGACY-RESOLVED, MIGRATE-SUMMARY-SEAM, COPY-CANCEL-SIDECAR, TT-FUZZY-NAME, GFF3-MULTIVALUE, QA6-NONLAYOUT-KEYS, PREFS-ROUTED-SEAM, DOMAIN-CHECK-GATE, B6-PIN-RED, LAYOUT-SPINS, GATE-CONDA-ROOT, LOCALE-READSET, FIXTURE-SKIP, BARE-SKIP-AUDIT, UNIT-TIER-CADENCE, HOOK-STEP-23 |
| SWIFT (8) | S-M3-Q2, MIGRATE-SUMMARY-SEAM, COPY-CANCEL-SIDECAR, DURABLE-ATOMICALLY, PREFS-ROUTED-SEAM, B6-PIN-RED, PRESENT-VERIFIED-MAIN, APP-RECORDS-OFF-MAIN |
| UX (6) | U-BAR-GAP, GFF3-SIDEBAR-ORDER, VARIANT-IMPACT-KEYS, ESV-EXPORT-MENU-REACH, LOAD-FAIL-WORDS, EXPORT-NO-SAMPLE-MENUS |
| None named (11) | GENO-ARTIFACT-MODE, Q-13.36-1, S-13.14-Q1, VIRALRECON-STREAM, K10-S8, TIER1-EXPERIMENTAL-PACKS, HIGH-IMPACT-TIMING, PREFS-LEAKERS-2, PYTEST-ONLY-SCAN, NOTICES-CURRENT, RELEASE-BODY-LIMIT |

UNIT-TIER-CADENCE is a standing direction and not a task (see Standing directions below). GENBANK-INTERNAL-KEYS must be re-read before Phase 3 takes it, as the ARCH inventory asked. Its premise is that the GenBank export of a bundle writes an internal Lungfish key as a qualifier and that `SequenceExportPinConformanceTests` pins it. MD90 says `ae59eec3e` removed the internal keys from exports, and landing 25 recaptured the pin with one removed line, `/annotation_db_row_id="1"`. At `8190b9000` an `rg` for `annotation_db_row_id`, `annotation_db_track_id`, `lungfish_gff_phase` and `lungfish_cds_phase` over the Tests files named `SequenceExportPin*` prints nothing, so the row may already be closed. A row DMG-CREATE-RETRY (retry `hdiutil create` once when the eject is busy) was proposed by the second publish and has no ruling, so it is in no table.

### Held tier 3 lanes

MD83 held these lanes, the owner left the question unanswered in O23, and none of them ran. Each is also a row of `## Moved out of 2.13`.

| Lane | Scope in one line | Written in |
|---|---|---|
| 13.57 UNIT-FLAKES M2 | The NSAPP-GUARD milestone (M884), the guard at `AppDelegate.swift:37` (H8). M1 landed in landing 22 | `votes/tally.md` M884 |
| 13.58 COLLECTION-PERF | M841, a release-build timing of the 10 targets beside the 2.11 base of 16.0 s and the per-taxon write path of the resolver, with every payload byte unchanged. It waited for 13.02, which landed in landing 2 | `votes/tally.md` M841 |
| 13.59 OLIVAR-REPLAY | M844, the record names the `.olvd` and `.olvr` pickles as outputs that a replay does not regenerate, with that reason as a degraded fact | `votes/tally.md` M844 |
| 13.60 TRAP-RES | M845, a missing bundled resource throws and nothing traps (`AIHaplotypingPromptRegistry.swift:143` and `:55`), and a CLI leaf that meets it exits 64 | `votes/tally.md` M845 |
| 13.61 U-INSPECT | H6 (Q-U6), the Inspector sites of `ProvenanceSection.swift` and `ViralReconDocumentSection.swift` show a value whole where it fits and offer Copy Path where it stays truncated. It has no owner check row of its own (MD86) | `votes/tally.md` 13.61 |

### Known limits that end "This is a Phase 3 candidate"

MD84 accepted these 40 Known limits as worded, with no named task, and sent them to this carry-in from `lanes/13.25/known-limit-table.md`. They are Known limit lines of `docs/reports/2026.10.22-technical.md`, and the line numbers are those of that file at `8190b9000`. Each line ends with the sentence "This is a Phase 3 candidate", and the line holds the full limit. The labels below are short.

| Line | Limit |
|---|---|
| 139 | A cancelled or failed EsViritu run keeps its working files in its folder under Analyses |
| 141 | A large sample rich in one virus can take an EsViritu run several hours, and the run has no time limit |
| 145 | A Viral Recon run keeps an unsigned copy of its record in its results folder on purpose |
| 151 | After a Kraken2 batch run shows its first sample, the sidebar and the Inspector's Provenance tab stay on the earlier selection |
| 153 | A download from the Database Browser needs a project and shows the No Project Open sheet without one |
| 155 | MEGAHIT 1.2.9 can end a run on Apple silicon with a segmentation fault (exit -11) or an abort (exit -6) |
| 157 | A copy of an open project, such as a Finder Duplicate or a restored backup, still shows the sheet that says the project may already be open |
| 159 | A database that shows Unverified cannot be checked in place, so Update downloads the whole database again |
| 161 | When the integration-tier gate kills a class at its time bound, its report names the XCTest case that was running, and the line says what it reports for a Swift Testing function |
| 163 | A CZ-ID import that is cancelled while it converts the report can leave a half-written bundle |
| 165 | A killed or out-of-memory VCF import leaves a hidden staging folder in the bundle's `variants` folder that `--resume` cannot use |
| 167 | A region extracted to a new bundle from a project sequence keeps none of the sequence's annotations, and the record does not say so |
| 169 | An extraction of a region from a document keeps a FASTA copy of the whole sequence in the project's `.tmp` folder |
| 171 | Extracting a region from a document whose sequence name holds a space fails with Sequence 'x y' not found |
| 173 | Each Export Sequences of an open document, or of a file named `.seq` or `.txt`, keeps a copy in the project's `.tmp` folder |
| 175 | Export Sequences and `lungfish-cli convert` stop with No sequences found only for a file of no bytes or only white space |
| 177 | A changed feature, a feature from a GFF3 or BED source or a captured selection, and a feature of a `.lungfishref` bundle still print the key in a form the line describes |
| 179 | Copy CLI Command on Save Primer FASTA Bundle and Extract Reference Amplicon records the folder that the app wrote, and `lungfish-cli primers analysis export-selection` stops |
| 181 | An AI Haplotyping run that cannot resolve a provider, such as one with no API key, still shows a row with no command |
| 183 | The record of a 12S BLAST search names no sample, since its sequences are pooled across samples |
| 185 | Running a taxa collection again after a taxon is removed or renamed leaves the earlier file of that taxon in the extracted folder |
| 187 | Copy CLI Command on a clipboard extraction replays into a scratch folder of the project and leaves the file there |
| 189 | A replay of one taxon's file record runs `lungfish-cli extract taxa-collection` for that taxon alone and rewrites the collection's root record |
| 193 | A replay of the record of a copy between projects needs the source project to be on this Mac |
| 195 | With an empty Sample Filter in a TaxTriage result, the Export Batch Report item is disabled |
| 197 | A viewer export keeps its inputs in a hidden `.lungfish-export-inputs` folder beside the export |
| 199 | If the app stops while a provenance export replaces files in an existing folder, some files can be new and some old |
| 201 | A replay of an XLSX annotation table export gives back the recorded digest only on the Mac and with the `/usr/bin/zip` build that wrote it |
| 205 | A few routes that display a reference bundle still build its browser summary in memory on the main thread |
| 213 | A legitimate archive whose link has an absolute target is refused even when the target lies inside the folder |
| 217 | The NAO-MGS duplicate marking is one internal step plus five samtools stages, and a failed marking lists all five without saying which ran |
| 227 | An exported image sets bases in Menlo, feature labels and notes on omitted rows in Helvetica Neue, and its scale, counts and sample names in the system font |
| 229 | An exported image draws its read track 200 points high with at most 75 rows and its annotation track 60 points high |
| 235 | A signal track is left out of exported images |
| 241 | A provenance record with a workflow name directly in the temp, home, Downloads, Desktop or Documents folder is not found for a file in a subfolder |
| 243 | The first open of a Kraken2 result after its sample metadata table was added or changed stores the table's values inside `kraken2.sqlite` once |
| 249 | A database imported before this release answers the High Impact filters from its stored INFO rows, so filters can run slower and the chips show no count |
| 251 | A FASTQ file copied out of its bundle without its metadata, and a derived bundle whose parent is lost, carry no recorded platform |
| 255 | A Cancel that lands just after an analysis run or an export wrote its file still reads Cancelled by user |
| 263 | When some selected TaxTriage rows have no accession, the Extract Reads dialog names at most four of the rows it leaves out |

### Standing directions

O26 (2026-10-21 16:07) is a standing direction for every release. Release notes are written for users and the technical record is kept apart. The readable notes `docs/release-notes/<version>.md` are for bench scientists (about 10 to 15K characters, grouped by task, only the limits a person is likely to hit, with the header lines and the Dependency versions kept for the preflight). The full technical record is `docs/reports/<version>-technical.md` and the owner check list is `docs/reports/<version>-owner-checks.md`, both linked by absolute GitHub URLs at the tag. The reason is the first publish of 2026.10.22, whose release body of 132,811 characters passed GitHub's limit of 125,000 (row RELEASE-BODY-LIMIT).

UNIT-TIER-CADENCE. No unit tier ran between 2026-10-20 and the 2.13 candidate, and five stale tests reached it (MD94). `docs/contracts/RUNNING-A-PHASE-SESSION.md` gets the rule that a unit tier runs after about every 10 landings, which the closing monitor of 2.13 writes (`exit/QA.md:156`). MD90 also added a habit for landings, that a landing that changes export text runs the Conformance pins of that export (`rg -l` on the changed literal in Tests) and not only its unit suites.

## Phase 4, god-object splits and module splits (weeks 8 to 12)

Entry criteria. Phase 3 exit, characterization tests captured per extracted responsibility, byte-identical genotype export fixtures in place.

| Task | Finding | Files | Model | Lane | Acceptance |
|---|---|---|---|---|---|
| Genotype extraction by responsibility (export coordinator, review eligibility, matrix projection, haplotype-band disclosure), instrumentation behind one protocol | R6 | LungfishGenotypeUI/* | Fable, pure moves | 4a | Workbook and matrix exports byte-identical, testing* identifiers fall, files at or under 1,500 lines |
| ViewerViewController and AnnotationTableDrawer collaborator extraction | R6 | LungfishApp/Views/Viewer/* | Opus | 4b | Source-text assertion ratchet falls as behavioural tests replace them |
| LungfishGenomeBrowserUI leaf with TrackRenderer protocol | R13 | New target, SequenceViewerView family, ReadTrackRenderer.swift, LungfishAlignmentUI | Fable | 4c | Renderer tests on spliced and deleted reads pass before and after, coverage ignores N and D |
| LungfishWorkflow split into WorkflowCore and domain targets, LungfishRNASeq created empty | R12 | Package.swift, folder moves only | Sonnet | 4d | Build times measured before and after with scripts/measure-build-times.sh, CLI --help and provenance schemas unchanged |
| Test tree mirrors source tree, tests move to their module's target, TEST-MAP generated | R11 | Tests/* | Sonnet | 4e | Parity suites and LUNGFISH_REQUIRE_TOOLS runs still find every suite |
| Concurrency hatch reduction, @TaskLocal probes, CommandEnvironment | R10 | The 23 static seams, CLI override sites | Opus | 4f | Hatch ratchet falls, VariantDatabase rollback tests pass through the injected observer, PARALLEL_HAZARD_SUITES shrinks |

Exit criteria. No file over 3,000 lines in UI modules, build-time measurement published. Rollback. Every move is a pure-move commit, reverted as a unit.

## Phase 5, RNA-seq prerequisites and the first surface built on the contracts (weeks 10 to 14, overlaps Phase 4)

Entry criteria. Phases 2 and 3 exit. The owner has chosen the aligner (STAR or HISAT2) and quantifier (salmon or kallisto) and confirmed the DE engine (R with DESeq2 or edgeR, or a native alternative).

| Task | Finding | Files | Model | Lane | Acceptance |
|---|---|---|---|---|---|
| ReferenceIndexCache keyed by reference checksum, tool, version, parameters, GTF checksum | R17 | LungfishWorkflow/Indexes/* (new), ManagedMappingPipeline.swift | Opus | 5a | Minimap2 index reuse across runs proven by a test, cache key recorded in provenance |
| Annotation input type with checksum and contig-name validation against the FASTA | R17 | LungfishIO/Formats/GFF, request types | Opus | 5b | GTF and FASTA contig mismatch fails the request with a named error |
| CountMatrix result, ExperimentDesign sample sheet, strandedness detection recorded | R17 | LungfishIO/Analysis/* (new) | Fable | 5c | Round-trip tests, strandedness value present in provenance |
| Resource admission (resourceClass, block or queue, logged in provenance) and R activation profile | R17 | OperationCenter admission, descriptor resourceClass, Conda activation profiles | Opus | 5d | Admission never changes scientific parameters, STAR genomeGenerate class runs past the old 3600 s timeout |
| LungfishRNASeq domain target and LungfishRNASeqUI leaf built strictly through the registries, executor, launcher, recorder and ResultViewport | R1 to R4, R17 | New targets only | Fable | 5e (after 5a to 5d) | Zero edits to LungfishApp beyond registration, CLI and GUI parity test, junction track as a TrackRenderer |

Exit criteria. The RNA-seq surface ships with CLI parity, provenance and OperationCenter coverage and the add-a-surface checklist fully ticked without any App composition-root edit.

## Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| A pure move silently changes behaviour through access control or initialization order | Medium | High | No logic edits in move commits, golden fixtures and the unit gate per merge |
| Golden fixtures mask timestamps too loosely and hide a provenance regression | Medium | High | Mask only RFC 3339 timestamps and run IDs, diff everything else byte for byte |
| Source-text tests break on every rename and get deleted instead of replaced | High | Medium | Ratchet freezes the count, deletion allowed only with a behavioural replacement named in the commit |
| Lanes collide on shared files | Medium | Medium | Disjoint file sets per lane, install-git-hooks.sh owned by one lane, F2 and F4 serialized |
| The unit gate takes 12 to 14 minutes and serial merges stretch the night | High | Low | Merge documentation lanes first, batch F1 to F4 into one gate run |
| TaxTriage or PBAA break on Macs with a system JDK once JAVA_HOME is set | Low | High | Phase 1 smoke runs on both a JDK and a no-JDK machine before merge |
| Executor migration changes classifier result layout for existing projects | Medium | High | Legacy layout recognised by the scanner snapshot test, migration behind the old path until parity is green |
| Genotype extraction alters calls or ambiguity tokens | Low | Very high | Byte-identical workbook and matrix exports required per commit, notebook-parity fixtures |
| The agent indices drift as code moves | High | Medium | module-map-current.py, doc-path-references.py and features-yaml-sources.py in the pre-push hook |
| Primer legacy salvage removed while still scientifically used | Low | High | Owner confirmation required before any removal, CLI and dialog kept identical |

## Open decisions for the owner

Which aligner, quantifier and DE engine the RNA-seq surface uses, since the activation profiles and resource classes depend on it. Whether primer "legacy salvage" is still a user-facing mode. Whether the UI-free operations code becomes a new LungfishOperations target or folders inside LungfishWorkflowCore. Whether Kraken2's CLI command moves to a top-level `classify` with `conda classify` kept as an alias.
