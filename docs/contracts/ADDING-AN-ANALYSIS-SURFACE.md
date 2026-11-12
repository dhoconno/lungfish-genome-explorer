# Adding an analysis surface

This contract binds all new result surfaces in Lungfish Genome Explorer (LGE). Part of the contracts index in `docs/contracts/README.md`. Findings R1, R2, R6, R13 and R17 in `docs/reports/2026-10-02-architecture-review/REVIEW.md` explain why it exists.

An analysis surface is everything a user sees for one kind of result. It has a result type on disk, a viewport that shows it, Inspector sections, a sidebar entry, row commands, and the operations that produce it. Each operation follows `docs/contracts/ADDING-AN-OPERATION.md`. This document covers the rest.

New surface code lives in a leaf UI module that exports a surface factory, and the App registers it with one line. The hand edits that remain in LungfishApp are listed with their files under "Touch points that exist today". The last section walks the whole recipe for RNA-seq. The one path for a new operation and surface is `docs/contracts/analysis-surface-checklist.md`, and each of its boxes names the section of this contract that explains it.

## The leaf-module recipe

The model to copy is the 12S amplicon leaf. Its target is `Sources/LungfishTwelveSUI`, its tests are `Tests/LungfishTwelveSUITests`, its surface is `Sources/LungfishTwelveSUI/TwelveSSurface.swift`, and its App glue is `Sources/LungfishApp/Views/Viewer/ViewerViewController+TwelveS.swift`. The saved primer analysis has no leaf, so its surface stays in the App (`Sources/LungfishApp/Views/Viewer/PrimerAnalysisSurface.swift`) and registers the same way.

### 1. Leaf target and test target

Declare the leaf in `Package.swift` next to `LungfishTwelveSUI`. A leaf depends on LungfishCore, LungfishIO, LungfishWorkflow and LungfishKit, and never on LungfishApp or another leaf. Add a library product, a `Lungfish<Name>UITests` test target that depends on the leaf, LungfishKit and LungfishTestSupport, and the leaf to LungfishApp's dependency list.

### 2. Domain code and result type

Scientific logic and the on-disk result type do not belong in the leaf. Put the computation in a domain folder under `Sources/LungfishWorkflow/` and the result reader in LungfishIO or the domain, so the CLI can produce and read the same result. A folder whose types no other Workflow folder names can become its own target, as TwelveS did in `LungfishWorkflowTwelveS`. A leaf reads results and presents them. It never runs a tool.

### 3. Viewport class, surface and registration

The viewport is an `NSViewController` subclass in the leaf, like `TwelveSAmpliconResultViewController` in `Sources/LungfishTwelveSUI/TwelveSAmpliconResultViewController.swift`. Keep its state in a `@MainActor @Observable` model type named `<Name>SurfaceModel`, injected into the controller, so tests can drive the state without building a window. Keep every new file at or under 800 lines. Export, eligibility and selection logic go in their own types, never in the controller.

Wrap the controller in a `ResultViewport` (`Sources/LungfishKit/Surfaces/ResultViewport.swift`) and export a factory, as `TwelveSSurface` does. Its kind is `.bundle(BundleKindID)` for a saved bundle, `.analysis(AnalysisToolID)` for a result under `Analyses/`, or `.view(SurfaceViewID)` for the viewer of a file that is neither, such as the FASTA collection. A surface whose view has no toolbar space of its own answers `pinsTopToSafeArea` with true, and the host then pins its top to the container's safe area in place of its edge. `load(input:token:)` reads the input with `expectInput(_:as:)`, and `ViewportHost` installs the controller as the viewer's one child only while the token is current. A surface with its own drawer answers `isDrawerOpen` and `toggleDrawer()`, which View > Show Drawer reads first. `willDeactivate(replacedBy:)` runs before the host removes the controller, with the kind that replaces it or nil on a clear. Stop the surface's work there and take its parts out of the Inspector, skipping its own kind only when the route gave the Inspector the new result before the display.

Register the factory with one line in `makeSurfaceRegistry()` in `Sources/LungfishApp/Views/Viewer/ViewerViewController+Surfaces.swift`. The display method ends in `showSurface(_:input:as:)`, which installs the surface in place of the one before it, hides the genomics viewer and throws an error that `surfaceFailureWords` turns into words with a next step. A surface whose load suspends, which today is only the alignment viewer, goes through `showSurfaceAfterLoad(_:input:as:canCommit:)` instead. It hides the genomics viewer before the load, returns nil when something newer took over, and shows no words for a load that failed after that, so the display wires its callbacks only after it returns a surface. The display starts with `clearSurfaceForNewContent()`, which removes whatever surface is shown and brings back the genomics chrome, and the kind adds no hide method. A display that sets `surfaceKindBeingDisplayed` to its kind for its run, as the 12S one does, keeps that clear from removing the surface that its own show replaces. A route that takes one kind away calls `clearSurface(ifShowing:)` with that kind, as the `contentMode` observer in `ViewerViewController.swift` does for the primer kinds. The file preview keeps the viewer's status bar for its words, so its display shows the bar again after the show and ends its content at the bar's top. The host's bottom pin has no handle, so a surface whose content must end at something else, as the FASTQ dashboard ends at its drawer, gives the host a small container controller that owns that constraint. A test registers a stand-in with `viewer.surfaceHost.registry.register`, as `SurfaceRegistrationStubTests` does.

### 4. Inspector sections, sidebar entry and row commands

Inspector sections are views in the leaf that the Inspector hosts. The sidebar entry is one `SidebarKindDescriptor` in `Sources/LungfishIO/Bundles/SidebarKindRegistry.swift`. It names how the sidebar recognises a folder of the kind (its manifest or its `analysis-metadata.json` first, and a legacy name prefix only in the read-only fallback), its row type, icon and display name, the viewport it opens, its Inspector tab after an import and whether a project deletion treats it as an analysis. A new bundle kind registers its descriptor with `SidebarKindRegistry.register` and row type `.registeredBundle`, and then opens from the sidebar with no App edit beyond that and its surface's `register` line, as the stub kind in `Tests/LungfishAppTests/SidebarKindRegistryRouteTests.swift` does. Row commands (copy, export, BLAST, extract reads, open in another viewport) live in the leaf as a command type, like `Sources/LungfishTaxTriageUI/TaxTriageRowCommands.swift` and `Sources/LungfishTwelveSUI/TwelveSResultMenuActions.swift`. Every row action has a keyboard and VoiceOver route.

### 5. Registry entry

Add a feature entry to `docs/user-manual/features.yaml` that names every source file, the CLI command and the entry points.

### 6. Notifications and window scope

A new surface avoids new `Notification.Name` declarations. When one is unavoidable, follow these rules from finding R9. Several project windows can be open at once, and an event that reaches the wrong window changes that window's Inspector, selection or display.

1. Classify the name in `ScopedEventFilter.classifications` in `Sources/LungfishKit/ScopedEventFilter.swift`. A window event changes the state of one project window, such as a selection, an Inspector request or a viewer display setting. An application event concerns the whole app, such as a saved preference, a managed resource change or an operation finishing. `ScopedEventClassificationTests` in `Tests/LungfishKitTests` fails until the name is classified.
2. Post a window event with the window's scope. Build the payload with `ScopedEventFilter.scopedUserInfo` and the scope the App handed the poster. A view that a container embeds without a scope uses `ScopedEventFilter.hostingWindowScope` to find the scope of the window that shows it. A window event posted without a scope reaches no window.
3. Observe a window event by calling `ScopedEventFilter.accept` with the observer's own scope, and return early when it refuses. An application event needs no check.
4. A poster that runs outside any window, such as a service or an operation completion, finds its window through the operation's `OperationRouteContext`. When no window can be named, the event is an application event, and its observers match on the content it carries, such as a bundle URL or a request ID.
5. Test the poster by triggering the real post and checking the scope in the payload, as `WindowEventPosterScopeTests` does. Test the observer with two windows, as `TwoWindowScopedEventTests` does.

## Adding an analysis kind

An analysis kind is a result type stored under `Analyses/`, such as `kraken2` or `ont-genotyping`. It has an `AnalysisToolID`, the typed form of the string in the folder name and in `analysis-metadata.json`. It is not the same thing as a managed tool, which is an entry of the tool lock and has a `ManagedToolID`. `bbmap` is an analysis kind and `bbtools` is its lock entry. See "Adding a managed tool" in `docs/contracts/RUNNING-A-TOOL.md` for the other half. This is review finding R2.

The kind has one descriptor in `Sources/LungfishIO/Analysis/`. It is static Swift data, because IO never reads the lock. Do these steps in one commit.

1. Add a static id beside the others in `Sources/LungfishIO/Analysis/AnalysisToolRegistry.swift` and one `AnalysisToolDescriptor` to `AnalysisToolRegistry.all`. The fields are the id, the display name, whether imported results use `{id}-{sampleName}` naming, the sidebar symbol (nil falls back to the generic circle), the classifier batch badge (nil for none) and the provisioning. Provisioning names the lock entry with `.managedTool(ManagedToolID(rawValue: "<lock id>"))` or `.lockedPipeline("<pipeline id>")`, or says why there is none with `.container`, `.importedResult` or `.builtIn`. When the kind runs a new tool, add the lock entry and its probe first, as "Adding a managed tool" says. A classifier also names the word `lungfish-cli build-db` takes in `buildDatabaseToken` and its output folder stem in `outputStem`. A descriptor also carries `runsTools`, the lock ids of the managed tools the kind's pipeline launches and names in its record. It defaults to the provisioned managed tool, so a kind whose pipeline also records another tool, such as samtools beside a mapper or Bracken beside Kraken2, lists it in the registry. `AnalysisRunsToolsAgreementTests` in `Tests/LungfishWorkflowTests/Dependencies/` holds each listed id to the lock and the version probe table.
2. Put the descriptor where the order is right. `all` is the order name parsing tries each kind in, so an id whose name plus a hyphen starts another id breaks recognition. An id `ont` would claim every `ont-genotyping-` folder, for example. `testNoIDPlusHyphenPrefixesAnotherIDPlusHyphen` in `Tests/LungfishIOTests/Analysis/AnalysisToolRegistryTests.swift` fails when that happens.
3. Update the pins on purpose. Each of these holds its own literal copy so that a registry change shows as a failing test, and updating them is the review of the change.
   - `AnalysisToolRegistryTests.frozenIDs`, `expectedBadges` and `expectedSymbols`, and the `runsTools` table in `Tests/LungfishIOTests/Analysis/AnalysisToolRunsToolsTests.swift`, which needs a row for the new kind even when its list is empty.
   - `Tests/LungfishIOTests/Analysis/AnalysesFolderDisplayNamePinTests.swift` for the display name and the known id set.
   - `Tests/LungfishAppTests/SafetyNets/SidebarPresentationPinTests.swift` for the badge and the icon.
   - `Tests/LungfishAppTests/SafetyNets/InspectorAnalysesIconPinTests.swift` for the Inspector icon and the sidebar symbol beside it.
   - The literal id list in `Tests/LungfishAppTests/SafetyNets/SidebarScanSafetyNetProjects.swift`, which builds the sidebar snapshot project. The five sidebar snapshots change only when the new kind appears in them, and a snapshot is never regenerated to make a test pass. Review the diff and accept it by hand.
4. Update the agreement test's expectation. `ToolRegistryAgreementTests` in `Tests/LungfishWorkflowTests/Dependencies/` checks that every `.managedTool` and `.lockedPipeline` link resolves in the bundled lock and holds the kinds with no link to an exact set (`expectedUnlinkedAnalysisIDs`). A new kind with a lock entry passes once the entry exists. A new kind with no link is added to that set with its reason.
5. Do not copy the id into a `switch`, an `==` or a `hasPrefix` elsewhere. `scripts/ratchets/tool-identity.sh` counts those literals and the count may only fall. Read the descriptor instead, and add a descriptor field in IO when a consumer needs a fact the descriptor lacks.

The registry keeps today's strings exactly. A display name is also a saved label, and the sidebar snapshots pin each symbol and badge. The `build-db` word and the classify output stem are their own fields, so a new display name never changes a command or a folder name. Renaming one is still a behaviour change that needs its own ruling.

Not every table reads the registry yet. The touch point table below says which rows read the descriptor. Item types, result titles, batch subtitles and the Inspector icon still hold their own strings. The sidebar's legacy prefixes are in `SidebarKindRegistry` since 3.2. They are the arms the touch point table below lists, and a new kind still edits each one that applies.

## Touch points that exist today

Since Phase 3.2 a new surface adds no viewer slot, no drawer arm and no hide method. It still edits the files below. A missed row does not fail the build. It shows up as a stale viewport, a gearshape icon, a generic Inspector tab or a hidden result.

| Touch point | File | What to add |
|---|---|---|
| Sidebar kind | `Sources/LungfishIO/Bundles/SidebarKindRegistry.swift` | one `SidebarKindDescriptor`, added with `SidebarKindRegistry.register` as a `.registeredBundle` row. A built-in row type instead adds a `SidebarRowType` case, its `SidebarItemType` case in `Sources/LungfishApp/Views/Sidebar/SidebarItem.swift` and that case's arms in the color and grouping switches there |
| Content routing | `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+SidebarKindRoute.swift` | nothing for a `.registeredBundle` kind, which opens the viewport its descriptor names through `surfaceHost`. A built-in row type adds its arm in `displaySidebarKind` |
| Classifier routing, if the result is a classifier | `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ClassifierDisplay.swift` and `Sources/LungfishApp/Views/MainWindow/ClassifierDatabaseRouter.swift` | a `routeClassifierDisplay(url:)` arm and a `toolDefinitions` row naming the analysis id and its database file. The router reads the display name and `buildDatabaseToken` from the descriptor |
| Universal search, if the result is indexed | `Sources/LungfishIO/Search/ProjectUniversalSearchModels.swift` | a `ProjectUniversalSearchResultKind` case with its stored kind, analysis id, CLI group and sidecar file, so `type:` queries and folder recognition find it |
| Surface registration | `Sources/LungfishApp/Views/Viewer/ViewerViewController+Surfaces.swift` | one `register` line in `makeSurfaceRegistry()` |
| Display method | a new `ViewerViewController+<Name>.swift` in `Sources/LungfishApp/Views/Viewer/` | the display method of recipe step 3, which starts with `clearSurfaceForNewContent()` and ends in `showSurface(_:input:as:)` |
| Inspector document | `Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift` | an update method like `updateTwelveSAmpliconResultDocument` |
| Tools menu and FASTQ dialog, if the operation reads FASTQ | `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift`, `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift` and `Sources/LungfishApp/Views/FASTQ/FASTQOperationsCatalog.swift` | a `FASTQOperationToolID` case with its arms and a `toolIDs(for:)` entry, never a menu item by hand. The full list is in "What a new FASTQ-input tool adds" in `docs/contracts/ADDING-AN-OPERATION.md` |
| Provenance policy | `Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift` | the CLI command and every new `NativeTool` case, or the coverage test fails and the tool refuses to run |
| Launch glue | an `AppDelegate+<Area>.swift` file in `Sources/LungfishApp/App/` or an `InspectorViewController+<Area>.swift` file in `Sources/LungfishApp/Views/Inspector/` | the dialog presentation and the operation launcher |
| Inspector tab after an import | `Sources/LungfishIO/Bundles/SidebarKindRegistry.swift` | `inspectorTab: .setByViewer` on the kind's descriptor if the result keeps the tab its viewer sets. `AppDelegate` reads it through `inspectorTab(afterImportOf:)` |
| Analyses folder recognition | `Sources/LungfishIO/Analysis/AnalysisToolRegistry.swift` and `Sources/LungfishIO/Bundles/AnalysesFolder.swift` | the descriptor, as "Adding an analysis kind" says. `knownTools` and `displayName(for:)` derive from it. A `probeToolType(in:)` signature is still a hand edit |
| Sidebar scan | `Sources/LungfishApp/Views/Sidebar/SidebarProjectScanner.swift` | arms in `buildAnalysisNode` and for batches `classifierBatchSubtitle(for:)`. A bundle's extension, `analysisItemType(for:)`, `analysisIcon(for:)` and `classifierBatchBadge(for:)` read the registries and need no arm |
| Tool availability | `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json` and the Swift files that "Adding a managed tool" in `docs/contracts/RUNNING-A-TOOL.md` names | each step of that section, whose tests fail until it exists |
| Notifications | `Sources/LungfishCore/Models/Notifications.swift` and `Sources/LungfishKit/ScopedEventFilter.swift` | avoid new names. If one is unavoidable, classify it and scope it as step 6 of the recipe says |
| Module wiring | `Package.swift` | the leaf, its product, its test target, and the LungfishApp dependency |

## RNA-seq, the reference surface

RNA-seq is the first surface the program builds on the finished contracts. It covers reference index build, spliced alignment, transcript quantification, gene-level counting, differential expression (DE, the statistical comparison of expression between groups of samples) and splice-aware viewing. The examples use human GRCh38 and rhesus macaque Mmul_10 references.

### Prerequisites that must exist first

This section dates from 2026-10-02 and no longer binds. The route, the stages and the prerequisites of RNA-seq are set by `docs/plans/2026-10-02-architecture-program.md` under The trust session and Phase 5, and lane SURFACE-RECIPE of that plan rewrites this section. Phase 4 dropped the TrackRenderer protocol and the empty LungfishRNASeq target, and no lane waits for them. The science rules further down still hold (contig names are never renamed, the library type is explicit and recorded, TPM is never DE input, no test runs without replicates).

| Prerequisite | Why RNA-seq needs it |
|---|---|
| `ReferenceIndexCache` keyed by reference checksum, annotation checksum, tool, tool version and index parameters | A STAR index for a human-sized genome takes about 30 GB of disk and about an hour to build. Today mapper indexes are rebuilt per run inside the output folder (`Sources/LungfishWorkflow/Mapping/ManagedMappingPipeline.swift`). |
| An annotation input type with a checksum and contig-name validation against the FASTA | A GTF from a different build or naming scheme silently produces zero or wrong counts. `Sources/LungfishIO/Formats/GFF/GTFReader.swift` reads GTF, but no request type carries one. |
| `CountMatrix`, `ExperimentDesign` and a recorded strandedness value | featureCounts, salmon and DE must share one matrix and one sample sheet, and the strandedness used must be in provenance. |
| Resource classes with admission that blocks or queues, and an R activation profile | STAR genome generation needs about 32 GB of RAM for a human-sized genome and can run for hours. `CondaManager.runTool` in `Sources/LungfishWorkflow/Conda/CondaManager.swift` has no time limit by default. R needs `R_HOME`, an isolated `R_LIBS` and no user `~/.Rprofile`. |
| A lock entry for each RNA-seq tool | The `rna-seq` plugin pack in `Sources/LungfishWorkflow/Conda/PluginPack.swift` lists packages, and a managed tool needs its lock entry as "Adding a managed tool" in `docs/contracts/RUNNING-A-TOOL.md` says. |

### Targets and commands

RNA-seq code belongs in a domain target, LungfishRNASeq, and a leaf on LungfishKit, LungfishRNASeqUI. Neither exists today. SwiftPM wants a source file in every target, so each is created with its first code in it. LungfishRNASeq holds request types, pipelines, the count-matrix builder and the DE runner, with no AppKit. LungfishRNASeqUI holds the viewports, Inspector sections and row commands. The CLI gets one command group with a subcommand per stage (index, align, quant, count, de). Each subcommand is a complete operation under `docs/contracts/ADDING-AN-OPERATION.md`, so a user can rerun any stage from the copied command.

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

The viewer adds a junction track built from the aligner's junction output or from CIGAR `N` operations, with counts split into uniquely and multiply mapped reads and a flag for annotated junctions. Coverage never counts CIGAR `N` skips or `D` deletions, which `Sources/LungfishWorkflow/ViewerExport/Graphics/ReadTrackRenderer.swift` already respects. Strand-specific coverage uses the recorded strandedness of each sample, so a reverse-stranded read 1 counts toward the opposite strand. Junction arcs and sashimi plots get their own renderer type and add no branch to the read renderer.

### Rules that hold across all six stages

- A scientific parameter is never changed for UI convenience. The surface never downsamples reads for a preview count, drops multi-mapping reads to speed up a table, or switches strandedness to make a table non-empty.
- Resource admission may block or queue a run. It never alters a parameter, and every admission decision is logged in provenance.
- Every stage writes a provenance envelope that names its inputs by checksum, so a DE result traces back through the matrix and BAMs to the FASTQ, FASTA and GTF.
- The CLI and the GUI produce identical output trees and provenance, with timestamps masked, on the same fixture.

### Open decisions for the owner

The aligner (STAR or HISAT2), the quantifier (salmon or kallisto) and the DE engine (DESeq2 or edgeR in R, or a native method) are open. The choice sets the resource classes, the activation profiles and the lock entries, so Phase 5 does not start until the owner decides. This contract holds for any of those choices.
