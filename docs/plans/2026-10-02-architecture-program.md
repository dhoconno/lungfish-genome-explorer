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

Entry criteria. Phase 0 merged and green. Golden fixtures captured for mapping (SARS-CoV-2 fixture), EsViritu and Kraken2 (virtual-bundle input, read counts and provenance with timestamps masked), genotype workbook and matrix exports from the demo MHC projects, and `lungfish-cli --help` for every command. These captures live under Tests/Fixtures/golden and are the oracle for Phases 1 to 4.

| Task | Finding | Files | Model | Lane | Acceptance |
|---|---|---|---|---|---|
| OperationReporting protocol and RecordingOperationReporter | R4 | Sources/LungfishKit/OperationReporting.swift (new), OperationCenter.swift, Tests/Support/LungfishTestSupport/RecordingOperationReporter.swift | Opus | 1a | Lock semantics untouched (existing lock tests pass), a test asserts a recorded item has non-nil cliCommand |
| Remove operationType and cliCommand defaults, migrate 58 start() sites to begin() | R4 | OperationCenter.swift and the 27 files with start( calls | Sonnet in batches of 5 files, Fable review | 1a (after the protocol) | unchecked-operation-start ratchet reaches 0, each migrated site has a test that a refused lock launches no subprocess |
| Route TaxTriage, PBAA and NextflowRunner through WorkflowEngineLaunch.resolve, remove `which nextflow` | R7 | TaxTriagePipeline.swift, PBAAClusteringPipeline.swift, Engines/NextflowRunner.swift | Opus | 1b | TaxTriage and Viral Recon smoke runs pass before and after, Docker profile and NXF_CONDA_CACHEDIR stay as explicit overrides, a test asserts JAVA_HOME is set when no system JDK exists |
| Audit tag rewrite (396 tags become self-contained sentences) and lint against new tags | R5 | Sources files holding tags, scripts/checks/audit-tags.py (new) | Sonnet | 1c | Zero `[A-Z]{2,4}-[0-9]+` tags in Sources, SCI and GEN rationale text preserved verbatim |
| Docs retention sweep and staleness check | R5 | docs/superpowers, docs/plans, docs/issues, docs/product-specs, docs/verification, scripts/checks/working-memory-staleness.py (new) | Sonnet | 1d | Each deletion cites the shipping commit, reports cited by ratchets or tests are kept |
| Specialist docs rewritten as role prompts pointing at module AGENTS.md | R5 | agents/specialists/*.md, agents/process/*.md | Opus | 1d | doc-path-references.py enforced on agents/specialists |
| SequencingPlatform reconciliation | R15 | LungfishIO/Formats/FASTQ/SequencingPlatform.swift, LungfishWorkflow/Recipes/SequencingPlatform.swift and their switches | Opus | 1e | Cases and every switch diffed first, a test pins platform-specific recipe parameters, allowlist entry removed |
| ToolProvisioning deletion | R15 | Sources/LungfishWorkflow/Native/ToolProvisioning, ProvisionToolsCommand | Sonnet | 1e | release scripts grep clean for provision-tools, CLI --help golden updated deliberately |
| ScopedEventFilter and scope classification | R9 | Sources/LungfishKit/ScopedEventFilter.swift (new), the 7 copies, LungfishCore/Models/Notifications.swift (each name classified window or application) | Opus | 1f | Two-window test fixture shows an unscoped window event is dropped and an application event arrives |
| Test doubles out of production | R10 | AppDelegate.swift:2723, MainSplitViewController+Testing.swift, LungfishKit/TestHarnessDetection.swift users, Tests/Support | Sonnet | 1g | No TestHarness.isRunning branch in Sources, XCUI Viral Recon fixtures still exercise real primer staging |

Exit criteria. All of the above merged, ratchets at or below Phase 0 baselines, golden fixtures byte-identical. Rollback. Each task is one commit and reverts cleanly, the protocol task is reverted with its migration batches.

## Phase 2, one executor, one process primitive, one provenance recorder (weeks 3 to 5)

Entry criteria. Phase 1 exit. Golden outputs for every tool's stdout and exit code on fixtures (the per-tool conformance tier under LUNGFISH_REQUIRE_TOOLS).

| Task | Finding | Files | Model | Lane | Acceptance |
|---|---|---|---|---|---|
| ToolProcess primitive and adapters | R7 | Sources/LungfishWorkflow/Native/ToolProcess.swift (new), NativeToolRunner.swift, CondaManager.swift, ProcessManager.swift, CLISubprocessTransport | Fable | 2a | Per-tool golden stdout byte-identical, cancellation kills the tree (nextflow and BBTools java children), Process() outside Native/ ratchet only falls |
| ProvenanceRecorder, writers frozen, legacy readers under fixture tests | R8 | Provenance/ProvenanceRecorder.swift (new), the 25 writeProvenance sites, the 39 path helpers | Opus | 2b | Round-trip tests for every legacy sidecar filename, demo projects load unchanged, envelope-only files written |
| AnalysisToolDescriptor and registry decoded from the lock | R2 | LungfishIO/Analysis/AnalysisToolDescriptor.swift (new), NativeToolRunner switch tables, PluginPack.swift, the 12 lookup tables one PR each | Opus for the descriptor, Sonnet per table | 2c | Manifest-driven smoke test runs every descriptor's version probe, sidebar scan snapshot over fixture projects unchanged |
| AnalysisRunExecutor with EsViritu, Kraken2 and TaxTriage migrated, GUI calls it through CLISubprocessTransport | R3 | LungfishWorkflow/Analysis/AnalysisRunExecutor.swift (new), EsVirituCommand.swift, ClassifyCommand.swift, TaxTriageCommand.swift, AppDelegate+Classification.swift | Fable | 2d (after 2a to 2c) | Same request through CLI and GUI yields identical output trees and provenance with timestamps masked, virtual-bundle input test checks read counts, ensure*IfPossible backfills deleted |
| AppKit-free Services moved to a UI-free target | R3 | New target LungfishOperations in Package.swift, the 114 AppKit-free files under LungfishApp/Services | Sonnet, pure moves | 2e (after 2d) | Build passes, LungfishAppTests files that only test moved code move with them, NativeToolRunner-in-App ratchet reaches 0 |
| CLIEvent v2 and BundleKind registry | R16 | CLIEvents/CLIEvent.swift, the 15 private schemas, LungfishIO/Bundles/BundleKind.swift (new), docs/formats specs | Opus | 2f | Every subcommand's --help passes a decoder test, pathExtension parity on TestData bundles |

Exit criteria. Classifier CLI parity test green, Process() count outside Native/ at the adapter sites only, one provenance writer. Rollback. Executor migration is per tool behind the old path kept until its parity test is green for one release, then the old path is deleted.

## Phase 3, the surface contract in code (weeks 5 to 8)

Entry criteria. Phase 2 exit and the routing table test from R1 captured against current behaviour.

| Task | Finding | Files | Model | Lane | Acceptance |
|---|---|---|---|---|---|
| ResultViewport protocol, ViewportHost with one activeViewport slot, SurfaceRegistry | R1 | LungfishKit/Surfaces/*.swift (new), ViewerViewController.swift | Fable | 3a | Switch matrix test over every pair of viewport kinds leaves exactly one child installed |
| Migrate TwelveS and PrimerAnalysis, then Nvd, NaoMgs, EsViritu, TaxTriage, then genotype, MSA, phylo, then mapping and reference last | R1 | One ViewerViewController+<Feature>.swift and leaf per PR | Opus | 3a sequential | hide*() count falls per PR, routing table test unchanged, drawer state read from the viewport |
| Sidebar routing registry and AppDelegate prefix table retired | R1 | SidebarItem.swift, MainSplitViewController+ContentDisplay.swift, MainWindowController.swift, AppDelegate.swift 301 to 305, SidebarProjectScanner.swift | Opus | 3b | Exhaustive switch over kinds, single fallback function for manifest-less legacy bundles covered by demo-project tests |
| Typed AppEvent layer with NotificationCenter bridge, 82 raw-string sites migrated | R9 | LungfishKit/Events/*.swift (new), LungfishCore/Models/Notifications.swift, the posting and observing files | Opus | 3c | Round-trip test per event, lint rejects new Notification.Name outside the allowlist |
| OperationSpec and OperationLauncher, leaves submit specs directly | R4 | LungfishKit/Operations/*.swift (new), the leaf row-command files | Opus | 3d (after 2d) | Two specs on one bundle serialize, every launched item has cliCommand and provenance |
| ClassifierResultActions shared component | R14 | LungfishKit/Classifiers/ClassifierResultActions.swift (new), the five classifier controllers | Sonnet | 3e | Per-classifier extraction tests diff read IDs unchanged |

Exit criteria. One surface registration adds no App code beyond registry registration. Rollback. The bridge keeps legacy observers alive, and each viewport migration is one revertible PR.

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
