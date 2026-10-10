# Adding an analysis surface

This contract binds all new result surfaces in Lungfish Genome Explorer (LGE). Part of the contracts index in `docs/contracts/README.md`. Findings R1, R2, R6, R13 and R17 in `docs/reports/2026-10-02-architecture-review/REVIEW.md` explain why it exists.

An analysis surface is everything a user sees for one kind of result. It has a result type on disk, a viewport that shows it, Inspector sections, a sidebar entry, row commands, and the operations that produce it. Each operation follows `docs/contracts/ADDING-AN-OPERATION.md`. This document covers the rest.

New surface code lives in a leaf UI module. Today a leaf still needs hand edits in LungfishApp, the composition root. The second section lists every one of those edits with its file, so an agent adding a surface before Phase 3 has the complete list. The last section walks the whole recipe for RNA-seq. The copyable per-surface checklist is `docs/contracts/analysis-surface-checklist.md`.

## The leaf-module recipe

The model to copy is the 12S amplicon leaf. Its target is `Sources/LungfishTwelveSUI`, its tests are `Tests/LungfishTwelveSUITests`, and its App glue is `Sources/LungfishApp/Views/Viewer/ViewerViewController+TwelveS.swift`.

### 1. Leaf target and test target

Declare the leaf in `Package.swift` next to `LungfishTwelveSUI`. A leaf depends on LungfishCore, LungfishIO, LungfishWorkflow and LungfishKit, and never on LungfishApp or another leaf. Add a library product, a `Lungfish<Name>UITests` test target that depends on the leaf, LungfishKit and LungfishTestSupport, and the leaf to LungfishApp's dependency list. Run only the new tests with `swift test --filter Lungfish<Name>UITests` while iterating, and run the unit tier of `scripts/full-suite-gate.sh` before merge.

### 2. Domain code and result type

Scientific logic and the on-disk result type do not belong in the leaf. Put the computation in a domain folder under `Sources/LungfishWorkflow/` and the result reader in LungfishIO or the domain, so the CLI can produce and read the same result. Phase 4d turns domains into separate targets, and code moves when its target exists. A leaf reads results and presents them. It never runs a tool.

### 3. Viewport class

The viewport is an `NSViewController` subclass in the leaf, like `TwelveSAmpliconResultViewController` in `Sources/LungfishTwelveSUI/TwelveSAmpliconResultViewController.swift`. Keep its state in a `@MainActor @Observable` model type named `<Name>SurfaceModel`, injected into the controller, so tests can drive the state without building a window. Keep every new file at or under 800 lines. Export, eligibility and selection logic go in their own types, never in the controller (finding R6 records what happens otherwise).

### 4. Inspector sections, sidebar entry and row commands

Inspector sections are views in the leaf that the Inspector hosts. The sidebar entry is a recognised folder or bundle extension plus an icon and a display name. Row commands (copy, export, BLAST, extract reads, open in another viewport) live in the leaf as a command type, like `Sources/LungfishTaxTriageUI/TaxTriageRowCommands.swift` and `Sources/LungfishTwelveSUI/TwelveSResultMenuActions.swift`. Every row action has a keyboard and VoiceOver route.

### 5. Registry entry

Add a feature entry to `docs/user-manual/features.yaml` that names every source file, the CLI command and the entry points.

### 6. Notifications and window scope

A new surface avoids new `Notification.Name` declarations, because Phase 3c replaces them with typed events. When one is unavoidable, follow these rules from finding R9. Several project windows can be open at once, and an event that reaches the wrong window changes that window's Inspector, selection or display.

1. Classify the name in `ScopedEventFilter.classifications` in `Sources/LungfishKit/ScopedEventFilter.swift`. A window event changes the state of one project window, such as a selection, an Inspector request or a viewer display setting. An application event concerns the whole app, such as a saved preference, a managed resource change or an operation finishing. `ScopedEventClassificationTests` in `Tests/LungfishKitTests` fails until the name is classified.
2. Post a window event with the window's scope. Build the payload with `ScopedEventFilter.scopedUserInfo` and the scope the App handed the poster. A view that a container embeds without a scope uses `ScopedEventFilter.hostingWindowScope` to find the scope of the window that shows it. A window event posted without a scope reaches no window.
3. Observe a window event by calling `ScopedEventFilter.accept` with the observer's own scope, and return early when it refuses. An application event needs no check.
4. A poster that runs outside any window, such as a service or an operation completion, finds its window through the operation's `OperationRouteContext`. When no window can be named, the event is an application event, and its observers match on the content it carries, such as a bundle URL or a request ID.
5. Test the poster by triggering the real post and checking the scope in the payload, as `WindowEventPosterScopeTests` does. Test the observer with two windows, as `TwoWindowScopedEventTests` does.

## Adding an analysis kind

An analysis kind is a result type stored under `Analyses/`, such as `kraken2` or `ont-genotyping`. It has an `AnalysisToolID`, the typed form of the string in the folder name and in `analysis-metadata.json`. It is not the same thing as a managed tool, which is an entry of the tool lock and has a `ManagedToolID`. `bbmap` is an analysis kind and `bbtools` is its lock entry. See "Adding a managed tool" in `docs/contracts/RUNNING-A-TOOL.md` for the other half. This is review finding R2.

The kind has one descriptor in `Sources/LungfishIO/Analysis/`. It is static Swift data, because IO never reads the lock. Do these steps in one commit.

1. Add a static id beside the others in `Sources/LungfishIO/Analysis/AnalysisToolRegistry.swift` and one `AnalysisToolDescriptor` to `AnalysisToolRegistry.all`. The fields are the id, the display name, whether imported results use `{id}-{sampleName}` naming, the sidebar symbol (nil falls back to the generic circle), the classifier batch badge (nil for none) and the provisioning. Provisioning names the lock entry with `.managedTool(ManagedToolID(rawValue: "<lock id>"))` or `.lockedPipeline("<pipeline id>")`, or says why there is none with `.container`, `.importedResult` or `.builtIn`. When the kind runs a new tool, add the lock entry and its probe first, as "Adding a managed tool" says.
2. Put the descriptor where the order is right. `all` is the order name parsing tries each kind in, so an id whose name plus a hyphen starts another id breaks recognition. An id `ont` would claim every `ont-genotyping-` folder, for example. `testNoIDPlusHyphenPrefixesAnotherIDPlusHyphen` in `Tests/LungfishIOTests/Analysis/AnalysisToolRegistryTests.swift` fails when that happens.
3. Update the pins on purpose. Each of these holds its own literal copy so that a registry change shows as a failing test, and updating them is the review of the change.
   - `AnalysisToolRegistryTests.frozenIDs`, `expectedBadges` and `expectedSymbols`.
   - `Tests/LungfishIOTests/Analysis/AnalysesFolderDisplayNamePinTests.swift` for the display name and the known id set.
   - `Tests/LungfishAppTests/SafetyNets/SidebarPresentationPinTests.swift` for the badge and the icon.
   - The literal id list in `Tests/LungfishAppTests/SafetyNets/SidebarScanSafetyNetProjects.swift`, which builds the sidebar snapshot project. The five sidebar snapshots change only when the new kind appears in them, and a snapshot is never regenerated to make a test pass. Review the diff and accept it by hand.
4. Update the agreement test's expectation. `ToolRegistryAgreementTests` in `Tests/LungfishWorkflowTests/Dependencies/` checks that every `.managedTool` and `.lockedPipeline` link resolves in the bundled lock and holds the kinds with no link to an exact set (`expectedUnlinkedAnalysisIDs`). A new kind with a lock entry passes once the entry exists. A new kind with no link is added to that set with its reason.
5. Do not copy the id into a `switch`, an `==` or a `hasPrefix` elsewhere. `scripts/ratchets/tool-identity.sh` counts those literals and the count may only fall. Read the descriptor instead, and add a descriptor field in IO when a consumer needs a fact the descriptor lacks.

The registry keeps today's strings exactly. A display name is also a CLI token (`build-db`), an output folder stem and a saved label, and a symbol or badge is pinned by the sidebar snapshots. Renaming one is a behaviour change that needs its own ruling.

Not every table reads the registry yet. `AnalysesFolder.knownTools`, `displayName(for:)`, the imported-result naming, the directory prefixes and the sidebar badge and icon do. Item types, result titles, batch subtitles, the Inspector icon, classifier database routing, search kinds and the legacy prefix ladders still hold their own strings and move in 2.6 and later. They are the arms the touch point table below lists, and a new kind still edits each one that applies.

## Touch points that exist today

Until Phase 3 lands the `ResultViewport` protocol and the surface registry in LungfishKit, a new surface edits the files below. A missed row does not fail the build. It shows up as a stale viewport, a gearshape icon, a generic Inspector tab or a hidden result. The phase column names the program task that retires each row.

| Touch point | File | What to add | Retired by |
|---|---|---|---|
| Sidebar kind | `Sources/LungfishApp/Views/Sidebar/SidebarItem.swift` | a `SidebarItemType` case, plus its arms in the color and grouping switches in the same file | Phase 3b, sidebar routing registry |
| Content routing | `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift` | a branch in `displayContent(for:)` that calls your display method | Phase 3b |
| Classifier routing, if the result is a classifier | `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ClassifierDisplay.swift` and `Sources/LungfishApp/Views/MainWindow/ClassifierDatabaseRouter.swift` | a `routeClassifierDisplay(url:)` arm and a `toolDefinitions` row | Phase 2c and Phase 3b |
| Viewport slot | `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift` | an optional controller property beside the others, and the property in `isNativeBundleViewportInstalled` when the viewport fills the viewer | Phase 3a, one `activeViewport` slot |
| Display and hide methods | a new `ViewerViewController+<Name>.swift` in `Sources/LungfishApp/Views/Viewer/` | a display method that hides every other viewport, a hide method, and a call to your hide method in every other display method | Phase 3a |
| Drawer and toolbar state | `Sources/LungfishApp/Views/MainWindow/MainWindowController.swift` | an arm in `toggleAnnotationDrawer` if the viewport has its own drawer | Phase 3a |
| Inspector document | `Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift` | an update method like `updateTwelveSAmpliconResultDocument` | Phase 3a, sections come from the viewport |
| Tools menu and FASTQ dialog, if the operation reads FASTQ | `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift`, `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift` and `Sources/LungfishApp/Views/FASTQ/FASTQOperationsCatalog.swift` | a `FASTQOperationToolID` case with its arms and a `toolIDs(for:)` entry. The menu is generated from these, so never add a menu item by hand. A new category also needs a `displayName` arm and an entry in `ToolsMenuLayout.groups` in `Sources/LungfishApp/App/ToolsMenuLayout.swift`, which `Tests/LungfishAppViewTests/ToolsMenuStructureTests.swift` enforces. The full list is in "What a new FASTQ-input tool adds" in `docs/contracts/ADDING-AN-OPERATION.md` | Phase 3d `OperationLauncher` |
| Provenance policy | `Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift` | the CLI command and every new `NativeTool` case, or the coverage test fails and the tool refuses to run | stays |
| Launch glue | an `AppDelegate+<Area>.swift` file in `Sources/LungfishApp/App/` or an `InspectorViewController+<Area>.swift` file in `Sources/LungfishApp/Views/Inspector/` | the dialog presentation and the operation launcher | Phase 2d executor and Phase 3d `OperationLauncher` |
| Inspector tab by filename prefix | `Sources/LungfishApp/App/AppDelegate.swift`, lines 301 to 305 | a `hasPrefix` arm if the result should keep its own Inspector tab after download | Phase 3b |
| Analyses folder recognition | `Sources/LungfishIO/Analysis/AnalysisToolRegistry.swift` and `Sources/LungfishIO/Bundles/AnalysesFolder.swift` | the descriptor, as "Adding an analysis kind" says. `knownTools` and `displayName(for:)` derive from it. A `probeToolType(in:)` signature is still a hand edit | A later sub-phase |
| Sidebar scan | `Sources/LungfishApp/Views/Sidebar/SidebarProjectScanner.swift` | arms in `buildAnalysisNode`, `analysisItemType(for:)` and for batches `classifierBatchSubtitle(for:)`, or a `directoryExtension` arm for a bundle. `analysisIcon(for:)` and `classifierBatchBadge(for:)` read the descriptor and need no arm | Phase 3b |
| Analyses list icon | `Sources/LungfishApp/Views/Inspector/Sections/AnalysesSection.swift` | an `iconName(for:)` arm. Its symbols differ from the sidebar's and a UX ruling comes first, so it does not read the descriptor yet | Phase 3b |
| Tool availability | `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`, `Sources/LungfishWorkflow/Conda/PluginPack.swift`, `Sources/LungfishWorkflow/Dependencies/ManagedToolVersionProbe.swift`, `Sources/LungfishWorkflow/Native/NativeToolRunner.swift`, `Sources/LungfishWorkflow/Native/NativeTool+ManagedTool.swift` | the lock entry, the plugin pack package list, one probe table entry, and a `NativeTool` case with its `managedToolID` arm if the tool runs natively. `docs/contracts/RUNNING-A-TOOL.md` lists the steps and the tests that fail until each exists | stays |
| Notifications | `Sources/LungfishCore/Models/Notifications.swift` and `Sources/LungfishKit/ScopedEventFilter.swift` | avoid new names. If one is unavoidable, classify it and scope it as step 6 of the recipe says | Phase 3c typed events |
| Module wiring | `Package.swift` | the leaf, its product, its test target, and the LungfishApp dependency | stays |

An agent that cannot find where a branch goes should search for an existing surface's identifier (for example `twelveSAmpliconResultBundle` or `esvirituResult`) across `Sources/LungfishApp` and add the new surface beside every hit.

## RNA-seq, the reference surface

RNA-seq is the first surface the program builds on the finished contracts. It covers reference index build, spliced alignment, transcript quantification, gene-level counting, differential expression (DE, the statistical comparison of expression between groups of samples) and splice-aware viewing. The examples use human GRCh38 and rhesus macaque Mmul_10 references.

### Prerequisites that must exist first

Do not write STAR, HISAT2, salmon, kallisto, featureCounts or R code until these land. Each one is a program task with its own acceptance test.

| Prerequisite | Why RNA-seq needs it | Program task |
|---|---|---|
| `ReferenceIndexCache` keyed by reference checksum, annotation checksum, tool, tool version and index parameters | A STAR index for a human-sized genome takes about 30 GB of disk and about an hour to build. Today mapper indexes are rebuilt per run inside the output folder (`Sources/LungfishWorkflow/Mapping/ManagedMappingPipeline.swift`). | Phase 5a (R17) |
| An annotation input type with a checksum and contig-name validation against the FASTA | A GTF from a different build or naming scheme silently produces zero or wrong counts. `Sources/LungfishIO/Formats/GFF/GTFReader.swift` reads GTF, but no request type carries one. | Phase 5b (R17) |
| `CountMatrix`, `ExperimentDesign` and a recorded strandedness value | featureCounts, salmon and DE must share one matrix and one sample sheet, and the strandedness used must be in provenance. | Phase 5c (R17) |
| Resource classes with admission that blocks or queues, and an R activation profile | STAR genome generation needs about 32 GB of RAM for a human-sized genome and runs past the 3600 s default timeout of `CondaManager.runTool` in `Sources/LungfishWorkflow/Conda/CondaManager.swift`. R needs `R_HOME`, an isolated `R_LIBS` and no user `~/.Rprofile`. | Phase 5d (R17) |
| Tool descriptor registry, run executor, operation launcher, envelope-only provenance, `ResultViewport` and `TrackRenderer` | Without them the surface repeats every touch point above. The `rna-seq` plugin pack in `Sources/LungfishWorkflow/Conda/PluginPack.swift` lists packages, but the lock manifest has no RNA-seq entries yet. | Phases 2c, 2d, 2b, 3a, 3d and 4c, plus the empty LungfishRNASeq target from Phase 4d |

### Targets and commands

LungfishRNASeq is the RNA-seq domain target. Phase 4d creates it empty when it splits LungfishWorkflow into domain targets, and Phase 5e builds the surface in it, so RNA-seq code never starts as a folder under `Sources/LungfishWorkflow/`. Any other new domain is still a folder there until Phase 4d. LungfishRNASeq holds request types, pipelines, the count-matrix builder and the DE runner, with no AppKit. LungfishRNASeqUI is a leaf on LungfishKit that holds the viewports, Inspector sections and row commands. The CLI gets one command group with a subcommand per stage (index, align, quant, count, de). Each subcommand is a complete operation under `docs/contracts/ADDING-AN-OPERATION.md`, so a user can rerun any stage from the copied command.

### Stage 1. Reference index build

The inputs are a genome FASTA and a GTF annotation, each carried as a typed input with its checksum. Before building, the operation checks that every sequence name in the GTF exists in the FASTA. Ensembl names human chromosome 1 `1` and the mitochondrion `MT`, while UCSC hg38 uses `chr1` and `chrM`, and the macaque Ensembl Mmul_10 and UCSC rheMac10 assemblies differ the same way. A mismatch fails the request with an error that lists the unmatched names. The operation never renames contigs silently. A user-supplied alias table is allowed only as its own input with its own checksum, recorded in provenance.

The cache key includes every parameter that changes the index. For STAR these are `--sjdbOverhang` (read length minus one), `--genomeSAindexNbases` (smaller for small genomes) and `--genomeSAsparseD`. For salmon they are the k-mer size and the decoy sequence list. The key is recorded in the provenance of every run that uses the index. Admission for this stage blocks or queues until memory is available, and it never lowers an index parameter to fit the machine. If the owner offers a lower-memory option, the user picks it, and it becomes part of the key.

### Stage 2. Spliced alignment

Inputs are FASTQ datasets (materialized first if they are virtual bundles) and a cached index. Read layout (paired or single, interleaved or split) is resolved the same way the mapping operation resolves it, and the resolved layout is recorded. Output is a coordinate-sorted, indexed BAM per sample with a read group, never SAM. The run records how multi-mapping reads are reported (the `NH` tag and the aligner's limit) and whether spliced reads carry an `XS` strand attribute, which unstranded libraries need for strand-aware viewing (STAR writes it with `--outSAMstrandField intronMotif`).

### Stage 3. Strandedness and quantification

Strandedness says which DNA strand a read came from relative to the transcript. Most dUTP-based stranded kits produce reverse-stranded reads, which is featureCounts `-s 2` and salmon library type `ISR` for paired reads. A wrong setting assigns reads to the antisense gene or discards about half of them. The request carries strandedness as an explicit value (unstranded, forward, reverse, or detect). Detect runs a detector on the data, records the detected value and the evidence fraction, and asks the user when the result is ambiguous. The detector's thresholds live in code and are recorded in provenance, never assumed by the UI.

Salmon or kallisto quantify against a transcriptome. That transcriptome FASTA and the transcript-to-gene table both come from the same GTF used for counting, and both checksums are recorded. Per-sample outputs keep estimated counts and TPM (transcripts per million, a within-sample abundance) side by side. TPM is for display only and is never DE input.

### Stage 4. Gene-level counting

featureCounts (from the subread package) counts aligned reads per gene from the BAMs and the GTF. The request names the feature type and attribute (`-t exon -g gene_id` for gene counts), the strandedness (`-s 0`, `1` or `2`), fragment counting for paired data (`-p --countReadPairs` in subread 2.0.2 and later), and the multi-mapping and overlap policy (`-M`, `-O`, `--fraction`). The result is a `CountMatrix` of integer counts with genes as rows and samples as columns, plus the assignment summary.

A count matrix carries its own provenance, so a matrix copied out of the project still says how it was made. It records the following for every column and for the whole matrix:

- the sample identifier and the checksum of the source BAM or quantification file
- the strandedness value used for that sample, and how it was chosen
- the GTF checksum, feature type and attribute
- the tool name, version and full argument list
- the checksum of the `ExperimentDesign` sample sheet it was built against

### Stage 5. Differential expression

The `ExperimentDesign` sample sheet maps each sample to its condition, batch and covariates, and to its subject when samples are paired (for example the same macaque before and after infection). The sample identifiers in the sheet must match the matrix columns exactly, or the request fails with a named error. The request records the design formula, the contrast, the reference level, the significance threshold, and any fold-change shrinkage or independent filtering.

DE input is raw integer counts, or salmon estimated counts imported with transcript-length offsets. TPM, FPKM and normalized values are never DE input. The surface does not run a test for a group that has no biological replicates unless the owner approves a documented method. An R-based engine runs under the R activation profile, and provenance records the R version and every package version.

### Stage 6. Splice-aware viewing

The viewer adds a junction track built from the aligner's junction output or from CIGAR `N` operations, with counts split into uniquely and multiply mapped reads and a flag for annotated junctions. Coverage never counts CIGAR `N` skips or `D` deletions, which `Sources/LungfishApp/Views/Viewer/ReadTrackRenderer.swift` already respects. Strand-specific coverage uses the recorded strandedness of each sample, so a reverse-stranded read 1 counts toward the opposite strand. Junction arcs and sashimi plots arrive as a `TrackRenderer` in the genome browser leaf from Phase 4c, not as new branches in the read renderer.

### Rules that hold across all six stages

- A scientific parameter is never changed for UI convenience. The surface never downsamples reads for a preview count, drops multi-mapping reads to speed up a table, or switches strandedness to make a table non-empty.
- Resource admission may block or queue a run. It never alters a parameter, and every admission decision is logged in provenance.
- Every stage writes a provenance envelope that names its inputs by checksum, so a DE result traces back through the matrix and BAMs to the FASTQ, FASTA and GTF.
- The CLI and the GUI produce identical output trees and provenance, with timestamps masked, on the same fixture.

### Open decisions for the owner

The aligner (STAR or HISAT2), the quantifier (salmon or kallisto) and the DE engine (DESeq2 or edgeR in R, or a native method) are open. The choice sets the resource classes, the activation profiles and the lock entries, so Phase 5 does not start until the owner decides. This contract holds for any of those choices.
