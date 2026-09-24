# Feature completeness and dead ends, part A: data, viewers and app shell

Reviewer: senior product engineer and genomics desktop power user (IGV, Geneious, CLC background).
Finding prefix: FEA. Date: 2026-09-23. Tree: worktree at HEAD a1f439076.

## Scope

Projects, import (Import Center, sidebar drag and drop, viewer drop), download (NCBI, SRA), sidebar, the sequence, annotation, alignment (BAM), variant (VCF) and FASTQ viewers, Inspector, search and navigation, export, the Operations panel, Settings and Help. Analysis workflows (metagenomics, genotyping, primer design, assembly, MSA and phylogenetics, Viral Recon) belong to the sibling reviewer and are touched only where they share plumbing with the areas above.

## Method

- Built an entry-point inventory from [MainMenu.swift](Sources/LungfishApp/App/MainMenu.swift:161) (File, Edit, View, Sequence, Tools, Operations, Window, Help), the main toolbar identifiers in [MainWindowController.swift:33](Sources/LungfishApp/Views/MainWindow/MainWindowController.swift:33), the sidebar context menu in [SidebarViewController+MenuDelegate.swift](Sources/LungfishApp/Views/Sidebar/SidebarViewController+MenuDelegate.swift:150), the viewer annotation context menu, the Inspector buttons, the Import Center card catalog and the three drop targets (sidebar, viewer, Import Center card).
- Traced every menu selector to its `@objc` implementation, then to `validateMenuItem` in [AppDelegate.swift:1945](Sources/LungfishApp/App/AppDelegate.swift:1945), then into the service or CLI call it makes.
- Scripted an orphan scan: every `@objc func x(_ sender:)` under `Sources/LungfishApp/App/` whose name appears nowhere else in `Sources/` or `Tests/` except its own definition and the `MainMenu.swift` action protocols.
- Grepped for TODO, FIXME, "not yet supported", "not implemented", "coming soon", static `isEnabled = false` and `isHidden = true`, and for enums whose cases are only consumed by tests.
- Read `docs/user-manual/features.yaml` as a claim inventory and spot checked GUI entry-point claims against the menu code. I also skimmed the open-defect table in `docs/user-manual/reviews/fidelity-2026-09/RESULTS.md` as a list of leads. Every finding below was re-traced from source, and I cite only source.
- No build, no test run, no GUI launch.

## Limits

This pass is **source-traced only**. Nothing was reproduced in the running app, so the highest confidence label used is **Traced**. Where the control flow is clear but the visible outcome depends on AppKit rendering or timing, I say so and mark that part **Suspected**. I did not audit visual polish, accessibility, performance or the CLI's own correctness except where the GUI records or depends on a CLI command.

**Top 15 journeys that most need a hands-on GUI walkthrough** (in priority order):

1. Open a reference bundle that has a BAM track and a VCF track. Delete one variant row in the annotation drawer. Reopen the bundle and check that the alignment track is still listed (FEA-01).
2. Same bundle: sidebar right-click > Delete Variant Tracks. Reopen and check alignments and, for a GenBank-derived bundle, the record store (FEA-01).
3. Import `S1_L001_R1_001.fastq.gz` pair twice from Import Center, the second time from a different run folder with the same file names. Check whether a duplicate prompt appears and whether the first bundle's `derivatives/` survive (FEA-02).
4. Import a FASTQ sample sheet whose sample names differ from the file names. Check the resulting bundle names (FEA-02).
5. On a `.lungfishref` bundle, right-click an annotation > Delete Annotation, and separately rename one in the Inspector. Close and reopen the bundle (FEA-03).
6. Drag an aligned Illumina BAM onto the sidebar, then onto the viewer, then import it through Import Center > BAM/CRAM. Compare the three outcomes (FEA-04).
7. With reference A open, drop a VCF onto the viewer, then import the same VCF through Import Center. Compare where it lands (FEA-04).
8. Import Center > BAM/CRAM with three BAM files selected while a reference is open (FEA-05).
9. Start a long VCF import or classification, then press Cmd-Q, and separately Cmd-W on the window. Relaunch and look for the output in the sidebar and in Manage Project Storage (FEA-06).
10. Start a VCF import on a bundle, then immediately drop a GFF onto that bundle in the sidebar and delete an annotation row in the drawer (FEA-07).
11. In the BAM viewer, try to sort reads by base at a SNP and colour by insert size, as an IGV user would (FEA-08).
12. Copy the locus text from the ruler (`chr1:1,001-2,000`) and paste it into Sequence > Go to Location. Try `chr2` alone and a gene name in the ruler field (FEA-09).
13. With a taxonomy result, a FASTQ dataset and a genotype result displayed in turn, run File > Export > Image (PNG) with the default scope. Repeat with two project windows open, exporting from the second window (FEA-11).
14. Right-click a finished BAM import in the Operations panel > Copy CLI Command, and run it in Terminal (FEA-12).
15. Open a multi-sample VCF and try Het Only and the Query Builder's logic control (FEA-13).

## Executive summary

The app shell is broad and, at the level of menus, surprisingly well wired. Every main-menu selector resolves to a real handler, most menu items validate proactively, destructive sidebar actions go through the Trash, and the Operations panel is a strong piece of work (CLI copy, logs, failure reports, prefilled GitHub issues, Run Again). The weaknesses are one level deeper, where the same user intent reaches the data through different code paths that were written at different times.

The most serious problems are data safety. At least three code paths rebuild a reference bundle's `manifest.json` through a backward-compatible initializer that silently drops the alignment tracks and the GenBank record store (FEA-01). One of those paths runs automatically after a user deletes variant rows. The GUI FASTQ import always passes `--force` to the CLI while checking for duplicates in the wrong folder, so a same-named sample replaces an existing bundle and its derivatives with no prompt, and the backup is deleted (FEA-02). Annotation edits and deletes made from the viewer and the Inspector never reach the bundle on disk, even behind a "cannot be undone" confirmation (FEA-03).

The second theme is jagged import routing. A BAM becomes ONT reads when dropped and an alignment track when imported through Import Center. A VCF becomes a new variant-only bundle when dropped on the viewer and attaches to the open reference when imported from Import Center. BAM and VCF imports target "whatever is open" with no chooser, and multi-file BAM or VCF imports process only the first file (FEA-04, FEA-05). The bundle-lock contract in `OperationCenter.start` is advisory, so callers that skip the pre-check mutate locked bundles (FEA-07), and nothing warns before quitting with work in flight (FEA-06).

Third, there is finished code that users cannot reach: read sort and colour modes in the alignment renderer (FEA-08), about 27 orphaned action handlers, Settings controls that nothing reads, and a Het Only chip that is permanently disabled. The CLI-parity story is also weaker than it looks, because the Operations panel records non-runnable `lungfish-cli --bam-import-helper` commands (FEA-12). The overall judgment: menus and panels are in good shape, but the data-mutation paths behind them need consolidation behind a small number of bundle-mutation services before more features are added.

## Preserve

Do not "fix" these away.

- **Operations panel affordances** in [OperationsPanelController.swift:1540](Sources/LungfishApp/Views/Operations/OperationsPanelController.swift:1540): Run Again, Copy CLI Command, View/Reveal Log, Copy Failure Report, Open GitHub Issue, Reveal Failure Report, and the per-row Reveal output button at [line 1176](Sources/LungfishApp/Views/Operations/OperationsPanelController.swift:1176). This is better than IGV or Geneious offer.
- **Bundle locks as a concept** in [OperationCenter.swift:381](Sources/LungfishKit/OperationCenter.swift:381), including exact and tree scopes and the visible "Bundle is busy" failed row. FEA-07 asks to make the contract binding, not to remove it.
- **The write gate** `canWriteProjectOutputs(...)` is applied consistently before imports and mutations (for example [AppDelegate+ImportCenter.swift:25](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:25)). Keep it on every new path.
- **Proactive menu validation** with an explanation fallback, for example Export Sequences in [AppDelegate.swift:2092](Sources/LungfishApp/App/AppDelegate.swift:2092) and the sequence operations at [line 2029](Sources/LungfishApp/App/AppDelegate.swift:2029).
- **"(not enabled)" workflow items stay clickable** and prompt for enablement instead of being dead, in [MainMenu.swift:845](Sources/LungfishApp/App/MainMenu.swift:845). This is the right pattern for gated features.
- **Sidebar deletion uses the Trash** ([SidebarViewController+OutlineDataSource.swift:635](Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDataSource.swift:635)).
- **The annotation-track import chooser** honours the drop target and lets the user pick the target bundle ([MainSplitViewController+FASTQImport.swift:126](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+FASTQImport.swift:126)). It is the model for BAM and VCF in FEA-04.
- **Staged publication** in the FASTQ batch importer and the VCF import staging and recovery ([FASTQBatchImporter.swift:530](Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift:530), [AppDelegate+ImportCenter.swift:1106](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:1106)). The mechanism is sound. FEA-02 is about when it is told to replace.
- **Immutable manifest helpers** such as `addingAlignmentTrack` and `removingAnnotationTrack` in [BundleManifest.swift:639](Sources/LungfishCore/Bundles/BundleManifest.swift:639). FEA-01 asks for more of these, not fewer.
- **Go to Gene ranking** that prefers exact gene matches on the current chromosome ([AppDelegate+SequenceMenu.swift:170](Sources/LungfishApp/App/AppDelegate+SequenceMenu.swift:170)).
- **Help Book with in-app fallback** ([HelpWindowController.swift:41](Sources/LungfishApp/Views/Help/HelpWindowController.swift:41)). All four Help topics resolve to bundled pages.
- **Tolerant VCF import-profile parsing** ([AppDelegate+ImportCenter.swift:1501](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:1501)) maps the Settings tag `lowMemory` correctly, so the tag and enum mismatch that others have reported is harmless.

## Findings

| ID | Priority | Title | Confidence | Effort |
|---|---|---|---|---|
| FEA-01 | P0 | Manifest rewrites drop alignment tracks and the record store (variant deletion paths) | Traced | S |
| FEA-02 | P0 | GUI FASTQ import silently replaces same-named bundles, and ignores Keep Both and sample-sheet names | Traced | M |
| FEA-03 | P1 | Annotation edit and delete from the viewer and Inspector are not persisted for reference bundles | Traced | M |
| FEA-04 | P1 | The same BAM or VCF file does different things depending on the entry point, and BAM/VCF have no target chooser | Traced | M |
| FEA-05 | P1 | Multi-file BAM or VCF import into an open bundle imports only the first file | Traced | S |
| FEA-06 | P1 | Quit and window close do not warn about running operations, and interrupted outputs become invisible | Traced | M |
| FEA-07 | P1 | `OperationCenter.start` does not enforce the bundle lock, so unchecked callers mutate locked bundles | Traced | M |
| FEA-08 | P1 | Read sort and colour modes are implemented and tested but unreachable in the alignment viewer | Traced | M |
| FEA-09 | P2 | Two locus parsers with different grammar, and no gene lookup in the locus field | Traced | S |
| FEA-10 | P2 | Settings controls that nothing reads (default zoom window, max undo levels) | Traced | S |
| FEA-11 | P2 | Export Image/PDF can export a hidden view or the wrong window; some menu actions ignore the key window | Traced (render outcome Suspected) | S |
| FEA-12 | P2 | GUI BAM and VCF imports record a `lungfish-cli` command that the CLI cannot run | Traced | S |
| FEA-13 | P2 | Variant table dead controls: Het Only chip, single-option Match picker, silent preset rewrite | Traced | S |
| FEA-14 | P2 | Output placement differs by entry point (Imports, project root, drop folder, alignment-read-extractions with UUID names) | Traced | M |
| FEA-15 | P3 | About 27 orphaned action handlers, stale validation branches and invisible import history | Traced | S |
| FEA-16 | P3 | `features.yaml` GUI entry-point claims that do not exist in the menus | Traced | S |
| FEA-17 | P3 | Edit > Find (Cmd-F) is dead in the main window | Traced | S |

---

### FEA-01 (P0) Manifest rewrites drop alignment tracks and the record store

**Evidence**
- `BundleManifest` has a full initializer that takes `alignments`, `warnings`, `browserSummary`, `originBundlePath` and `recordStore` ([BundleManifest.swift:216](Sources/LungfishCore/Bundles/BundleManifest.swift:216)), and a backward-compatible initializer that hard-codes `recordStore: nil` ([BundleManifest.swift:255](Sources/LungfishCore/Bundles/BundleManifest.swift:255), [line 289](Sources/LungfishCore/Bundles/BundleManifest.swift:289)). Every omitted parameter falls back to `[]` or `nil`.
- **Sidebar > Delete Variant Tracks** rebuilds the manifest with that initializer and passes no `alignments`, `warnings`, `browserSummary`, `originBundlePath` or `recordStore` ([SidebarViewController+MenuDelegate.swift:817](Sources/LungfishApp/Views/Sidebar/SidebarViewController+MenuDelegate.swift:817)). It also uses the manifest captured when the menu opened ([line 713](Sources/LungfishApp/Views/Sidebar/SidebarViewController+MenuDelegate.swift:713)), so a track added in the meantime is also lost. It never checks the OperationCenter bundle lock.
- **Deleting variant rows in the annotation drawer** calls `syncVariantCountsToManifest()` ([ViewerViewController+AnnotationDrawer.swift:385](Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift:385)). That function rebuilds the manifest the same way, again without `alignments` or `recordStore` ([ViewerViewController+AnnotationDrawer.swift:837](Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift:837)).
- `mergeGenomeIntoBundle` (adding a downloaded reference to a variant-only bundle) keeps alignments but drops signal `tracks`, `warnings` and the source bundle's `recordStore` ([MainSplitViewController+GenomicsDisplay.swift:451](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+GenomicsDisplay.swift:451)).
- `recordStore` is what `ReferenceBundle.recordStoreDatabase()` reads ([ReferenceBundle.swift:260](Sources/LungfishIO/Bundles/ReferenceBundle.swift:260)).
- The immutable helpers that do preserve every field already exist for other mutations (`addingVariantTrack`, `removingAlignmentTrack` and others at [BundleManifest.swift:639](Sources/LungfishCore/Bundles/BundleManifest.swift:639)). There is no `removingVariantTracks` or `updatingVariantCounts` equivalent used here.

**Impact.** A user who deletes a few false-positive variant rows in the drawer loses every BAM track from the bundle's manifest. The BAM files stay on disk but disappear from the viewer, the Inspector, variant calling eligibility and exports. GenBank-derived bundles also lose their record-level metadata store. Nothing tells the user. Recovery requires hand-editing JSON.

**Recommendation.** Add `BundleManifest.removingAllVariantTracks()` and `updatingVariantCounts(_:)` (or a generic `with(variants:)`) built on the full initializer, and route both call sites through them. Make the backward-compatible initializers `internal` to decode-migration code or mark them deprecated so new call sites cannot use them. Put the sidebar deletion behind `OperationCenter` with `targetBundleURL` and reload the manifest inside the operation rather than using the menu-time snapshot. Fix `mergeGenomeIntoBundle` to carry `tracks`, `warnings` and the source `recordStore`.

**Acceptance test.** A unit test builds a manifest with one alignment, one variant, one signal track, a warning, a browser summary and a record store, applies each of the three mutations, and asserts every non-variant field round-trips unchanged. An app-level test deletes one variant row via the drawer delegate and asserts `manifest.alignments` is unchanged on disk.

**Effort.** S.

---

### FEA-02 (P0) GUI FASTQ import silently replaces same-named bundles, and ignores Keep Both and sample-sheet names

**Evidence**
- The GUI duplicate check looks for `<projectDirectory>/<sampleName>.lungfishfastq` ([MainSplitViewController+FASTQImport.swift:419](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+FASTQImport.swift:419), [line 423](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+FASTQImport.swift:423)). Import Center passes the project root as `projectDirectory` ([AppDelegate+ImportCenter.swift:199](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:199)).
- The CLI writes to `<project>/Imports/<sampleName>.lungfishfastq` ([FASTQBatchImporter.swift:434](Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift:434)). So the GUI check never sees the existing bundle.
- The GUI always passes `--force` ([CLIImportRunner.swift:136](Sources/LungfishApp/Services/CLIImportRunner.swift:136)). With `forceReimport`, publication calls `replaceItemAt` and then deletes the backup ([FASTQBatchImporter.swift:537](Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift:537), [line 551](Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift:551)).
- The "Keep Both" name is computed ([MainSplitViewController+FASTQImport.swift:434](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+FASTQImport.swift:434)) and passed as `bundleName`, but `_runCLIImport` never forwards it. `cliImportArguments` has no name argument ([FASTQIngestionService.swift:596](Sources/LungfishApp/Services/FASTQIngestionService.swift:596)), and `import fastq` has no sample-name option ([ImportFastqCommand.swift:69](Sources/LungfishCLI/Commands/ImportFastqCommand.swift:69)). The same applies to `sampleNameOverride` from a FASTQ sample sheet ([AppDelegate+ImportCenter.swift:226](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:226)). The GUI never uses the CLI's own `--samplesheet`.
- SRA downloads build the same arguments, including `--force` ([DatabaseBrowserViewController.swift:3176](Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift:3176)).
- FASTQ bundles hold user-created children: `derivatives/` subsets, trims and demux outputs, plus extracted-read bundles ([SidebarProjectScanner.swift:235](Sources/LungfishApp/Views/Sidebar/SidebarProjectScanner.swift:235)).
- Suspected: a sidebar drop onto the `Imports` folder sets `projectDirectory` to that folder ([MainSplitViewController+MultiDocument.swift:642](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+MultiDocument.swift:642)), which would make the CLI write to `Imports/Imports/`.

**Impact.** Illumina sample names such as `S1_L001` repeat across runs. Importing run 2 replaces run 1's bundle for that sample, together with its derivatives and extractions, with no prompt. The Replace, Keep Both and Skip dialog exists but is dead for the common path, and "Keep Both" would not work if it did fire. Sample-sheet names that a lab relies on are silently replaced by filename-derived names.

**Recommendation.** Add `--name <bundleName>` (single pair) to `lungfish-cli import fastq`, and have `FASTQIngestionService.cliImportArguments` pass the effective bundle name. Stop passing `--force` by default. Instead, compute the destination with `FASTQBatchImporter.bundleOutputURL(for:in:)` in the GUI, run the duplicate dialog against that path, and pass `--force` only when the user chose Replace. For Replace, move the old bundle to the Trash rather than deleting the backup. For sample sheets, either pass `--samplesheet` or pass the per-row name. Normalise `projectDirectory` to the project root whenever the destination is inside `Imports/`.

**Acceptance test.** An integration test imports the same pair twice through `FASTQIngestionService` into a temp project. Without user consent, the second import must not replace the first bundle, and a marker file in the first bundle's `derivatives/` must survive. A second test imports with Keep Both and asserts two bundles exist with the chosen names. A sample-sheet test asserts bundle names equal the sheet's sample names.

**Effort.** M.

---

### FEA-03 (P1) Annotation edit and delete from the viewer and Inspector are not persisted for reference bundles

**Evidence**
- Displaying a bundle sets `currentDocument = nil` ([ViewerViewController.swift:3641](Sources/LungfishApp/Views/Viewer/ViewerViewController.swift:3641)). Reference bundles are the main viewing mode.
- The viewer's annotation context menu offers Edit Annotation and Delete Annotation unconditionally ([SequenceViewerView+Interaction.swift:1065](Sources/LungfishApp/Views/Viewer/SequenceViewerView+Interaction.swift:1065)). Delete posts `.annotationDeleted` with no confirmation ([line 1679](Sources/LungfishApp/Views/Viewer/SequenceViewerView+Interaction.swift:1679)).
- The only observer, `handleAnnotationDeleted`, returns early when there is no `currentDocument` ([AppDelegate.swift:1262](Sources/LungfishApp/App/AppDelegate.swift:1262)). For a bundle, nothing is deleted, and the viewer just clears the selection.
- The Inspector shows a delete confirmation that says the action "cannot be undone" ([SelectionSection.swift:1220](Sources/LungfishApp/Views/Inspector/Sections/SelectionSection.swift:1220)), then posts the same notification ([InspectorViewController+Editing.swift:33](Sources/LungfishApp/Views/Inspector/InspectorViewController+Editing.swift:33)), with the same no-op result.
- Inspector edits to name, type and notes ([SelectionSection.swift:633](Sources/LungfishApp/Views/Inspector/Sections/SelectionSection.swift:633)) reach `handleAnnotationUpdated` ([AppDelegate.swift:1237](Sources/LungfishApp/App/AppDelegate.swift:1237)), which updates `viewerView.updateAnnotation`. That method changes only in-memory caches and persists only the colour override into view state ([SequenceViewerView.swift:1872](Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift:1872)).
- The only persistent delete path is the annotation drawer, which runs `lungfish-cli sequence delete-annotations` ([ViewerViewController+AnnotationDrawer.swift:425](Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift:425)). `ReferenceBundleManualAnnotationService` offers only `addAnnotation` ([ReferenceBundleManualAnnotationService.swift:24](Sources/LungfishApp/Services/ReferenceBundleManualAnnotationService.swift:24)).
- There is no undo for any of these. `registerUndo` appears only in the workflow canvas and the genotype colour highlight ([WorkflowCanvasView.swift:712](Sources/LungfishApp/Views/WorkflowBuilder/WorkflowCanvasView.swift:712), [GenotypeResultViewController.swift:9981](Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:9981)).

**Impact.** A user renames a gene or fixes a feature type in the Inspector, sees it change on screen, and loses the change when the bundle reloads. A user confirms "Delete" and the annotation comes back. Three entry points for the same intent behave three different ways.

**Recommendation.** Extend `ReferenceBundleManualAnnotationService` with `updateAnnotation` and `deleteAnnotation`, keyed by track id and row id as the drawer already does, and backed by CLI subcommands for parity. Route the viewer menu, the Inspector and the drawer through it, under OperationCenter with `targetBundleURL`. Until that lands, hide Edit and Delete in the viewer menu and disable the Inspector editor when the annotation comes from a bundle, with a note that points to the drawer. Register undo for the manual add, edit and delete on the window's `undoManager`.

**Acceptance test.** An app test displays a temp `.lungfishref`, invokes `deleteAnnotationAction` and the Inspector commit, reloads the bundle from disk and asserts the change persisted. A second test asserts Edit > Undo restores the deleted annotation.

**Effort.** M.

---

### FEA-04 (P1) The same BAM or VCF file does different things depending on the entry point

**Evidence**
- **BAM dropped on the sidebar**: `SequencingReadImportSource.isSupported` accepts any `.bam` ([SequencingReadImportSource.swift:16](Sources/LungfishIO/Formats/FASTQ/SequencingReadImportSource.swift:16)). The drop handler therefore routes BAM into the FASTQ path ([MainSplitViewController+MultiDocument.swift:658](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+MultiDocument.swift:658)). The import sheet is preset to Oxford Nanopore for any BAM ([MainSplitViewController+FASTQImport.swift:378](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+FASTQImport.swift:378)). The type's own doc comment says BAM is accepted only for the ONT importer ([SequencingReadImportSource.swift:9](Sources/LungfishIO/Formats/FASTQ/SequencingReadImportSource.swift:9)).
- **BAM dropped on the viewer**: forwarded to the same sidebar pipeline ([ViewerViewController.swift:3994](Sources/LungfishApp/Views/Viewer/ViewerViewController.swift:3994)), with the same result.
- **BAM through Import Center**: attached as an alignment track to whatever bundle the viewer shows, or refused with "No Bundle Loaded" and no chooser ([AppDelegate+ImportCenter.swift:18](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:18)).
- **VCF dropped on the viewer** while a reference is displayed: always creates a new variant-only bundle ([ViewerViewController.swift:3988](Sources/LungfishApp/Views/Viewer/ViewerViewController.swift:3988)). The method's doc comment still talks about a downloads folder ([line 3968](Sources/LungfishApp/Views/Viewer/ViewerViewController.swift:3968)).
- **VCF through Import Center**: attaches to the displayed bundle if there is one, otherwise creates a new bundle ([AppDelegate+ImportCenter.swift:38](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:38)). No contig-compatibility warning is shown before attaching. Name mapping happens silently ([AppDelegate+ImportCenter.swift:1264](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:1264)). Suspected: a VCF with no matching contigs imports with zero visible variants and no message.
- By contrast, annotation tracks use a chooser that honours the drop target ([MainSplitViewController+FASTQImport.swift:126](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+FASTQImport.swift:126)). The sidebar context menu on a reference bundle has no "Add Alignments" or "Add Variants" item ([SidebarViewController+MenuDelegate.swift:166](Sources/LungfishApp/Views/Sidebar/SidebarViewController+MenuDelegate.swift:166)). The menu actions that once did this, `importBAMToBundle` and `importVCFToBundle`, are orphaned (FEA-15).

**Impact.** For an IGV user, dragging an aligned BAM is the most basic action. Here it produces a reads-import sheet labelled Nanopore and, if accepted, a FASTQ bundle rather than an alignment track. VCF placement depends on which entry point was used and what happened to be open, so the same file can end up attached to the wrong reference.

**Recommendation.** Introduce one `GenomicsImportRouter` used by all three entry points. Classify BAM as alignment unless the header says unaligned (no `@SQ`) or the user picks "Import reads". For BAM and VCF, present a target-bundle chooser like `ReferenceBundleAnnotationImportConfigurationPresenter`, preselecting the drop target or the displayed bundle. Offer "New variant-only bundle" as an explicit VCF choice. Before attaching, compare VCF contigs and BAM `@SQ` names against the bundle and warn with the unmatched count. Add "Add Alignments…" and "Add Variants…" to the reference-bundle context menu.

**Acceptance test.** Router unit tests: an aligned BAM becomes `.alignment(target:)` for all three entry points, an unaligned BAM becomes `.reads`, and a VCF with a displayed bundle presents the chooser with that bundle preselected. An integration test with a VCF whose contigs match nothing in the bundle asserts a warning is produced.

**Effort.** M.

---

### FEA-05 (P1) Multi-file BAM or VCF import into an open bundle imports only the first file

**Evidence**
- The BAM/CRAM card allows multiple selection ([ImportCenterViewModel.swift:326](Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift:326)). Dispatch loops over the URLs and calls `importBAMFromURL` for each one synchronously ([ImportCenterViewModel.swift:724](Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift:724)). VCF does the same at [line 728](Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift:728).
- The first `performBAMImport` starts an operation that holds the bundle lock ([AppDelegate+ImportCenter.swift:2326](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:2326)). Each later call fails `canStartOperation` and shows an "Operation in Progress" alert ([AppDelegate+ImportCenter.swift:2309](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:2309)). VCF behaves the same ([line 1054](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:1054)).
- Import Center closes before dispatch ([ImportCenterViewModel.swift:711](Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift:711)) and records every URL as succeeded ([line 787](Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift:787)).

**Impact.** Loading a cohort of BAMs, the standard IGV workflow, silently imports one file and pops N-1 alerts. The user has to repeat the import file by file and wait for each one.

**Recommendation.** Queue per-bundle imports: either a single operation that imports the files sequentially with one lock and per-file progress and log lines, or an OperationCenter wait-for-lock queue. Do not close Import Center or record history until the delegate reports acceptance. The existing `ImportWizardRequest.onOutcome` pattern ([ImportCenterViewModel.swift:817](Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift:817)) can carry that.

**Acceptance test.** An app test dispatches three BAM fixtures to one bundle and asserts three alignment tracks in the manifest and no alert. A second test asserts a refused dispatch leaves Import Center open with the rejection message.

**Effort.** S.

---

### FEA-06 (P1) Quit and window close do not warn about running operations, and interrupted outputs become invisible

**Evidence**
- `applicationShouldTerminate` waits only for manual-haplotype edits and `ProjectTaskTerminationRegistry` tasks ([AppDelegate.swift:819](Sources/LungfishApp/App/AppDelegate.swift:819)). That registry is used for project and document loading only ([AppDelegate.swift:482](Sources/LungfishApp/App/AppDelegate.swift:482), [MainSplitViewController+MultiDocument.swift:20](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+MultiDocument.swift:20)). `OperationCenter.shared.items` is not consulted.
- `windowShouldClose` checks only manual-haplotype state ([MainWindowController.swift:837](Sources/LungfishApp/Views/MainWindow/MainWindowController.swift:837)).
- Output directories carry a `.processing` marker while running ([OperationMarker.swift:29](Sources/LungfishCore/Services/OperationMarker.swift:29)). The sidebar hides any directory with that marker ([SidebarProjectScanner.swift:368](Sources/LungfishApp/Views/Sidebar/SidebarProjectScanner.swift:368)). Nothing clears stale markers, and the storage scanner lists `.tmp` and workflow staging but not marked directories ([ProjectStorageScanner.swift:443](Sources/LungfishWorkflow/Storage/ProjectStorageScanner.swift:443), [line 517](Sources/LungfishWorkflow/Storage/ProjectStorageScanner.swift:517)).

**Impact.** Cmd-Q during a two-hour classification or a large VCF import ends the work with no prompt. The partial output stays on disk, hidden in the sidebar and absent from Manage Project Storage, so it consumes space the user cannot see or reclaim from the app.

**Recommendation.** In `applicationShouldTerminate` and `windowShouldClose` (for operations routed to that window's scope), if any `OperationCenter` item is active, show a sheet listing the active operations, with Cancel and Quit and Keep Running. On Quit, call the existing cancel callbacks and wait briefly for acknowledgement. Add an "Interrupted outputs" category to `ProjectStorageScanner` for directories with a `.processing` marker older than the app launch, with Reveal and Move to Trash. Consider showing them in the sidebar with an "interrupted" badge instead of hiding them.

**Acceptance test.** A unit test with a fake active OperationCenter item asserts `applicationShouldTerminate` returns `.terminateLater` and presents the sheet. A scanner test with a directory carrying a stale `.processing` file asserts it is listed.

**Effort.** M.

---

### FEA-07 (P1) `OperationCenter.start` does not enforce the bundle lock

**Evidence**
- When a lock conflicts, `start` inserts a failed "Bundle is busy" row and still returns a UUID ([OperationCenter.swift:400](Sources/LungfishKit/OperationCenter.swift:400)). The caller cannot distinguish that from a started operation without calling `canStartOperation` first.
- Sidebar annotation-track drop starts the operation and then runs `attachAnnotationTrack` unconditionally ([MainSplitViewController+FASTQImport.swift:140](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+FASTQImport.swift:140)). Import Center annotation import does the same ([AppDelegate+ImportCenter.swift:604](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:604)). The service serialises annotation imports per bundle but not against other operation types.
- Annotation drawer deletion starts the CLI delete with no pre-check ([ViewerViewController+AnnotationDrawer.swift:514](Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift:514)).
- The manual Add Annotation path takes no lock at all ([AppDelegate+SequenceMenu.swift:568](Sources/LungfishApp/App/AppDelegate+SequenceMenu.swift:568)). The sidebar variant-track deletion is not an operation at all (FEA-01).
- Correct callers do pre-check, for example `performBAMImport` ([AppDelegate+ImportCenter.swift:2309](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:2309)) and derived-alignment removal ([InspectorViewController+MetadataImport.swift:740](Sources/LungfishApp/Views/Inspector/InspectorViewController+MetadataImport.swift:740)).

**Impact.** A drawer delete or annotation import can rewrite the manifest while a VCF or BAM import is also rewriting it. Combined with FEA-01's snapshot-based rewrites, one writer's changes can be lost. The Operations panel shows "Bundle is busy" while the work actually ran.

**Recommendation.** Change the API so a refused start cannot be ignored: `startIfUnlocked(...) -> UUID?`, or a throwing `start`. Migrate every `targetBundleURL:` call site (about 35, listed by `grep -rn "targetBundleURL:" Sources`). Give every bundle mutation a target lock, including Add Annotation, Delete Variant Tracks and manifest count sync.

**Acceptance test.** A unit test holds a lock and asserts the new API returns nil. An app test drops a GFF on a locked bundle and asserts the manifest is unchanged and the user sees the busy message.

**Effort.** M.

---

### FEA-08 (P1) Read sort and colour modes are implemented and tested but unreachable

**Evidence**
- `ReadSortMode` has position, read name, strand, mapping quality, insert size and base-at-position ([AlignedRead.swift:491](Sources/LungfishCore/Models/AlignedRead.swift:491)). `ReadTrackRenderer` implements them ([ReadTrackRenderer.swift:700](Sources/LungfishApp/Views/Viewer/ReadTrackRenderer.swift:700)). Both production call sites hard-code `.position` ([SequenceViewerView+Rendering.swift:510](Sources/LungfishApp/Views/Viewer/SequenceViewerView+Rendering.swift:510), [line 832](Sources/LungfishApp/Views/Viewer/SequenceViewerView+Rendering.swift:832)).
- `ReadColorMode` has strand, insert size, MAPQ, read group, pair and base quality ([AlignedRead.swift:517](Sources/LungfishCore/Models/AlignedRead.swift:517)). `ReadTrackRenderer.readColors(for:colorMode:)` ([ReadTrackRenderer.swift:178](Sources/LungfishApp/Views/Viewer/ReadTrackRenderer.swift:178)) is called only from tests ([ReadTrackRendererTests.swift:1061](Tests/LungfishAppTests/ReadTrackRendererTests.swift:1061)).
- The Inspector read-style section exposes strand colouring, MAPQ, flags, soft clips and indels, but no sort or colour-by control ([ReadStyleSection.swift:1976](Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift:1976)).

**Impact.** "Sort by base at this position" and "colour by insert size" are among the most-used IGV actions for reviewing a SNP or a structural variant. LGE has the engine for both and no way to use it. The tests give false assurance that the feature ships.

**Recommendation.** Add `readSortMode` and `readColorMode` to the read-style view model and bundle view state. Add a "Sort reads by" and "Colour reads by" picker to the Inspector, plus "Sort by Base Here" and "Group/Colour by…" to the alignment context menu at the clicked position. Pass them through the two rendering call sites and include them in the `ReadTrackLayoutCache` key (the key already has a `sortMode` string, [ReadTrackLayoutCache.swift:35](Sources/LungfishApp/Views/Viewer/ReadTrackLayoutCache.swift:35)).

**Acceptance test.** A view-model test changes sort to `.baseAtPosition(p)` and asserts the renderer receives it and the layout cache key changes. A snapshot or pixel test asserts reads carrying the ALT base pack first.

**Effort.** M.

---

### FEA-09 (P2) Two locus parsers with different grammar, and no gene lookup in the locus field

**Evidence**
- The ruler locus field displays coordinates with thousands separators ([EnhancedCoordinateRulerView.swift:335](Sources/LungfishApp/Views/Viewer/EnhancedCoordinateRulerView.swift:335)). Its parser strips commas, accepts a chromosome name alone, opens a 10 kb window for a single position, and beeps on any failure without a message ([EnhancedCoordinateRulerView.swift:1046](Sources/LungfishApp/Views/Viewer/EnhancedCoordinateRulerView.swift:1046)). The chromosome-only check rejects any name containing "-" ([line 1053](Sources/LungfishApp/Views/Viewer/EnhancedCoordinateRulerView.swift:1053)).
- Sequence > Go to Location has its own parser. It does not strip commas, rejects a bare chromosome name, opens a 1 kb window, validates bounds and reports errors ([AppDelegate+SequenceMenu.swift:255](Sources/LungfishApp/App/AppDelegate+SequenceMenu.swift:255), [line 401](Sources/LungfishApp/App/AppDelegate+SequenceMenu.swift:401)).
- Neither accepts a gene name. Gene lookup is a separate dialog ([AppDelegate+SequenceMenu.swift:100](Sources/LungfishApp/App/AppDelegate+SequenceMenu.swift:100)). Both split on the first ":", so contig names that contain ":" (HLA allele contigs such as `HLA-A*01:01:01:01`) cannot be addressed.
- The Settings "Default zoom window" value is never read (FEA-10).

**Impact.** Copying the ruler text `chr1:1,001-2,000` into Go to Location fails with "Invalid position format". Typing `chr2` works in one place and fails in the other. IGV users expect to type a gene symbol in the locus box.

**Recommendation.** Create one `LocusQueryParser` in LungfishCore that handles commas, bare chromosomes, `..` and `-`, 1-based input, a trailing `:` for contigs containing colons (match the longest known contig prefix), and a gene fallback through `AnnotationSearchIndex`. Use it in both places. Use `AppSettings.defaultZoomWindow` for single-position windows. Show inline error text in the ruler field instead of only beeping.

**Acceptance test.** Table-driven parser tests covering `chr1:1,000-2,000`, `chr2`, `1000`, `HLA-A*01:01:01:01:100-200` and `BRCA1`. An app test pastes the ruler's own display string into Go to Location and asserts navigation.

**Effort.** S.

---

### FEA-10 (P2) Settings controls that nothing reads

**Evidence**
- `defaultZoomWindow` ([AppSettings.swift:208](Sources/LungfishCore/Models/AppSettings.swift:208)) and `maxUndoLevels` ([AppSettings.swift:211](Sources/LungfishCore/Models/AppSettings.swift:211)) are referenced only by `AppSettings` itself and the General tab steppers ([GeneralSettingsTab.swift:25](Sources/LungfishApp/Views/Settings/GeneralSettingsTab.swift:25), [line 43](Sources/LungfishApp/Views/Settings/GeneralSettingsTab.swift:43)). A repo-wide grep finds no other consumer. No code sets `levelsOfUndo`.
- The other rendering and display settings I checked (tooltip delay, max annotation rows, max table items, fetch cap, zoom thresholds, retention hours, VCF profile) all have consumers.

**Impact.** Users adjust controls that change nothing. "Max undo levels" implies an undo system that, apart from the workflow canvas and genotype colours, does not exist (see FEA-03).

**Recommendation.** Wire `defaultZoomWindow` into the locus parser (FEA-09) and into the initial bundle view. Remove "Max undo levels" until the undo work in FEA-03 lands, then apply it to each window's `undoManager.levelsOfUndo`. Add a test that every `AppSettings` stored property shown in Settings has at least one non-Settings reader.

**Acceptance test.** A reflection or grep-based test over `AppSettings` keys, plus a behaviour test that changing `defaultZoomWindow` changes the single-position navigation window.

**Effort.** S.

---

### FEA-11 (P2) Export Image/PDF can export a hidden view or the wrong window

**Evidence**
- `exportImage` and `exportPDF` resolve the viewer through the global `mainWindowController` ([AppDelegate+ImportCenter.swift:3312](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:3312), [line 3325](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:3325)). That property is refreshed on app activation, window open and window close ([AppDelegate.swift:1135](Sources/LungfishApp/App/AppDelegate.swift:1135), [line 1712](Sources/LungfishApp/App/AppDelegate.swift:1712)), but not when focus moves between two LGE windows. Most other handlers use `activeMainWindowController(sender:)` ([AppDelegate.swift:375](Sources/LungfishApp/App/AppDelegate.swift:375)).
- Tools > Call Variants validates against the active window ([AppDelegate.swift:1999](Sources/LungfishApp/App/AppDelegate.swift:1999)) but acts on `mainWindowController` ([AppDelegate+ToolsMenu.swift:155](Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:155)).
- The default export scope is `.tracks` ([ViewerGraphicsExportPanelController.swift:72](Sources/LungfishApp/App/ViewerGraphicsExportPanelController.swift:72)), which exports `viewerController.viewerView` ([AppDelegate+ImportCenter.swift:3441](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:3441)). That view is hidden whenever a FASTQ dataset, taxonomy or other result viewport is shown ([ViewerViewController+Taxonomy.swift:299](Sources/LungfishApp/Views/Viewer/ViewerViewController+Taxonomy.swift:299), [ViewerViewController.swift:1409](Sources/LungfishApp/Views/Viewer/ViewerViewController.swift:1409)). The menu items have no validation branch, so they are always enabled. Suspected: the exported image is blank or shows the previous sequence.

**Impact.** Figure export, a core deliverable, can produce an empty or wrong image with a "success" alert. With two project windows open, the export or variant-calling dialog can come from the other project.

**Recommendation.** Use `activeMainWindowController(sender:)` in `exportImage`, `exportPDF`, `showBAMVariantCalling` and the other roughly 30 `mainWindowController?.` uses in `Sources/LungfishApp/App/`. Add a `ViewerGraphicsExportable` protocol implemented by each viewport controller (sequence, MSA, taxonomy, genotype and so on) that returns its own view and rect. Offer "Tracks" only when the sequence viewer is visible, and disable the menu items when the active viewport cannot export.

**Acceptance test.** With two windows, an app test makes window B key and asserts export targets B. With a taxonomy result displayed, assert `.tracks` is not offered and the exported PDF contains the taxonomy view.

**Effort.** S.

---

### FEA-12 (P2) GUI BAM and VCF imports record a `lungfish-cli` command that the CLI cannot run

**Evidence**
- BAM import records `lungfish-cli --bam-import-helper --bam-path … --bundle-path …` ([AppDelegate+ImportCenter.swift:2318](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:2318)). VCF import records `lungfish-cli --vcf-import-helper …` ([line 1077](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:1077)). `CLICommandIdentity.executableName` is `lungfish-cli` ([CLICommandIdentity.swift:8](Sources/LungfishCore/CLICommandIdentity.swift:8)).
- The helper flag is parsed only by the app target ([BAMImportHelper.swift:23](Sources/LungfishApp/App/BAMImportHelper.swift:23)). `LungfishCLI` has no such flag, but it does have `import bam` and `import vcf` ([ImportCommand.swift:51](Sources/LungfishCLI/Commands/ImportCommand.swift:51)).

**Impact.** Right-click > Copy CLI Command produces a command that fails. That undermines the project's CLI-parity promise and any provenance built from these strings.

**Recommendation.** Record the equivalent `lungfish-cli import bam <bam> --bundle <bundle>` and `lungfish-cli import vcf …` invocations (or run them, if they are equivalent). If the helper must stay, label the string as an internal helper and do not offer Copy CLI Command for it. Add a test that every recorded `cliCommand` parses with `LungfishCLI.parseAsRoot`.

**Acceptance test.** Parse-round-trip test over the commands built by `performBAMImport` and `performVCFImport`.

**Effort.** S.

---

### FEA-13 (P2) Variant table dead controls

**Evidence**
- `SmartToken.heterozygous` ("Het Only") always reports unavailable ([SmartFilterTokens.swift:139](Sources/LungfishApp/Views/Viewer/SmartFilterTokens.swift:139)), with the reason "Genotype filtering not yet supported" ([line 175](Sources/LungfishApp/Views/Viewer/SmartFilterTokens.swift:175)). It maps to `.postFilter(.heterozygousOnly)` ([line 281](Sources/LungfishApp/Views/Viewer/SmartFilterTokens.swift:281)), which no filter code handles ([AnnotationTableDrawerView+Filtering.swift:423](Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView+Filtering.swift:423)). The chip is still drawn, disabled, whenever its section has another available token ([AnnotationTableDrawerView+Columns.swift:985](Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView+Columns.swift:985)).
- `QueryLogic.allCases` is overridden to `[.matchAll]` ([QueryRule.swift:167](Sources/LungfishApp/Views/Viewer/QueryRule.swift:167)), but the Query Builder still renders a segmented picker with that single option ([VariantQueryBuilderSheet.swift:78](Sources/LungfishApp/Views/Viewer/VariantQueryBuilderSheet.swift:78)). Presets saved as Match Any are silently rewritten to Match All ([line 226](Sources/LungfishApp/Views/Viewer/VariantQueryBuilderSheet.swift:226)), and the only record is a log line ([line 244](Sources/LungfishApp/Views/Viewer/VariantQueryBuilderSheet.swift:244)).

**Impact.** A permanently disabled chip and a one-option picker read as broken UI. A user who loads a Match Any preset gets different rows with no notice, which can change a scientific filtering result.

**Recommendation.** Implement `heterozygousOnly` in the genotype post-filter (the per-sample genotype data is already loaded for the within-sample AF tokens), or remove the token. Remove the logic picker until OR groups exist. When loading a Match Any preset, show an inline banner that says it was applied as Match All.

**Acceptance test.** A filter test on a multi-sample VCF fixture asserts Het Only returns only rows where the selected sample is 0/1. A UI test asserts no segmented control with one segment is shown.

**Effort.** S.

---

### FEA-14 (P2) Output placement differs by entry point

**Evidence**
- CLI FASTQ import writes to `Imports/` ([FASTQBatchImporter.swift:435](Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift:435)). Sidebar drops of other files copy to the project root or the drop folder ([MainSplitViewController+MultiDocument.swift:642](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+MultiDocument.swift:642)). Variant-only VCF bundles go to the project root ([MainSplitViewController+GenomicsDisplay.swift:192](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+GenomicsDisplay.swift:192)).
- Sequence and classifier extractions go to `Extractions/` ([ViewerViewController+Extraction.swift:575](Sources/LungfishApp/Views/Viewer/ViewerViewController+Extraction.swift:575), [ClassifierReadResolver.swift:73](Sources/LungfishWorkflow/Extraction/ClassifierReadResolver.swift:73)). Alignment read extraction goes to `alignment-read-extractions/<name>-<UUID>.lungfishfastq` ([AlignmentScientificActionCoordinator.swift:43](Sources/LungfishApp/Views/Viewer/AlignmentScientificActionCoordinator.swift:43)). That puts a raw UUID into a name the user sees in the sidebar.
- There is no single project-layout type. Folder names are string literals at each site.

**Impact.** Users cannot predict where results land, and the project folder conventions that the team has settled on (Imports, Downloads, Extractions, Analyses) are not enforced in code.

**Recommendation.** Add a `ProjectLayout` type in LungfishCore with `imports`, `downloads`, `referenceSequences`, `extractions` and `analyses` URLs. Replace the literals. Route alignment read extraction to `Extractions/` with the same collision-suffix naming that other extractions use.

**Acceptance test.** A grep test that forbids the literals `"Imports"`, `"Extractions"` and `"alignment-read-extractions"` outside `ProjectLayout`. An integration test asserts alignment extraction output lands in `Extractions/` with no UUID in the name.

**Effort.** M.

---

### FEA-15 (P3) Orphaned action handlers, stale validation branches and invisible import history

**Evidence**
- A scripted scan finds these `@objc` actions with no menu item, button, `sendAction` or caller: `importONTRun`, `importProjectSampleMetadata`, `launchEsVirituDetection`, `launchKraken2Classification`, `launchMinimap2Mapping`, `launchTaxTriage`, `runSPAdes`, thirteen `showFASTQ…Operations` variants (for example [AppDelegate+ToolsMenu.swift:113](Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:113)), `showFreyjaDemix` ([AppDelegate+ToolsMenu.swift:146](Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:146)) and `showImportCenterClassification` ([line 1801](Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:1801)).
- Also unreachable, but referenced by `validateMenuItem` or a test: `importVCFToBundle` ([AppDelegate+MenuActions.swift:285](Sources/LungfishApp/App/AppDelegate+MenuActions.swift:285)), `importBAMToBundle` ([line 334](Sources/LungfishApp/App/AppDelegate+MenuActions.swift:334)), `importSampleMetadataToBundle` ([AppDelegate+ImportCenter.swift:826](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:826)), `exportGenBank` ([line 2396](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:2396)), and `clearProjectTempFiles` ([AppDelegate.swift:1562](Sources/LungfishApp/App/AppDelegate.swift:1562)), which a test pins by source text ([ProjectTempCleanupTests.swift:199](Tests/LungfishAppTests/ProjectTempCleanupTests.swift:199)). `validateMenuItem` still has branches for items that do not exist ([AppDelegate.swift:1987](Sources/LungfishApp/App/AppDelegate.swift:1987)).
- File > Export has "Project Sample Metadata (CSV)" but no matching import item in the main menu. The inverse is available only from the folder context menu.
- Import Center persists up to 50 history entries ([ImportCenterViewModel.swift:936](Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift:936)), always marked succeeded, and nothing displays `recentHistory` ([line 225](Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift:225)).

**Impact.** Dead code misleads maintainers and doc writers. For example, `features.yaml` claims "Tools > Freyja Demix" (FEA-16). Tests that pin dead functions slow cleanup.

**Recommendation.** Delete the orphaned handlers, their `MainMenu.swift` protocol declarations and the dead `validateMenuItem` branches, and update the pinning test. Keep `importBAMToBundle` and `importVCFToBundle` only if FEA-04's context-menu items reuse them. Either show import history in Import Center with real outcomes, or delete it.

**Acceptance test.** The orphan scan from this report, added as a CI script, reports zero results.

**Effort.** S.

---

### FEA-16 (P3) `features.yaml` GUI entry-point claims that do not exist

**Evidence.** The File menu has New Project, Open Project Folder, Open Recent, Close, About Saving, Import Center, Export and Manage Project Storage ([MainMenu.swift:163](Sources/LungfishApp/App/MainMenu.swift:163)). There is no "File > Open". Yet `features.yaml` lists "File > Open (filter: …)" for VCF, FASTA, FASTQ and BAM ([features.yaml:18](docs/user-manual/features.yaml:18), [184](docs/user-manual/features.yaml:184), [296](docs/user-manual/features.yaml:296), [519](docs/user-manual/features.yaml:519)). It also claims "Tools > Freyja Demix" ([line 595](docs/user-manual/features.yaml:595)), whose handler is orphaned. It lists "Tools > Operations > Workflow Builder" ([line 1034](docs/user-manual/features.yaml:1034)), but the real item is "Tools > Workflow Builder (Experimental)…" and appears only with experimental features on ([MainMenu.swift:741](Sources/LungfishApp/App/MainMenu.swift:741)). It places the Nextflow export at "File > Export" ([line 1080](docs/user-manual/features.yaml:1080)), but it is under File > Export > Provenance ([MainMenu.swift:260](Sources/LungfishApp/App/MainMenu.swift:260)). The "Tools > FASTQ/FASTA Operations > …" paths do not match the menu, where the categories sit directly under Tools ([MainMenu.swift:717](Sources/LungfishApp/App/MainMenu.swift:717)). The spot-checked claims that are correct include Sequence > Translate, Sequence > Add Annotation, Search NCBI, Search SRA, Search Pathoplexus, Plugin Manager and View > AI Assistant.

**Impact.** The manual pipeline treats this file as ground truth. Stale entry points propagate into chapters and screenshot recipes.

**Recommendation.** Generate the menu portion of `features.yaml` from `MainMenu` (for example, a debug CLI command that dumps the built `NSMenu` tree), and diff it in CI.

**Acceptance test.** A CI check that every `entry_points` string that starts with a top-level menu name resolves to an item in the dumped menu tree.

**Effort.** S.

---

### FEA-17 (P3) Edit > Find (Cmd-F) is dead in the main window

**Evidence.** Find, Find Next and Find Previous send `performFindPanelAction:` ([MainMenu.swift:399](Sources/LungfishApp/App/MainMenu.swift:399)). No view or controller in `Sources/` implements `performFindPanelAction` or `performTextFinderAction`, so the items are disabled unless a text view has focus. The sidebar search field ([SidebarViewController.swift:235](Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift:235)) and the drawer filter fields ([AnnotationTableDrawerView.swift:538](Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift:538)) are not reachable by keyboard shortcut.

**Impact.** Cmd-F is the first thing a Mac user tries when looking for a gene or sample. Here it does nothing.

**Recommendation.** Implement `performFindPanelAction` on `MainSplitViewController`. With `showFindInterface`, focus the most relevant search field: the drawer filter when the drawer is visible, otherwise the locus field (with gene lookup from FEA-09), otherwise the sidebar search.

**Acceptance test.** A UI test sends Cmd-F with the viewer focused and asserts the expected field becomes first responder.

**Effort.** S.

---

## Proposed work packages

Packages are ordered by risk to user data, then by leverage. Each can be reviewed on its own.

**WP-1 Bundle data safety (FEA-01, FEA-02).** Do this first.
- Files: `Sources/LungfishCore/Bundles/BundleManifest.swift`, `SidebarViewController+MenuDelegate.swift`, `ViewerViewController+AnnotationDrawer.swift`, `MainSplitViewController+GenomicsDisplay.swift`, `FASTQIngestionService.swift`, `CLIImportRunner.swift`, `MainSplitViewController+FASTQImport.swift`, `ImportFastqCommand.swift`, `FASTQBatchImporter.swift`, `DatabaseBrowserViewController.swift`.
- Risk: medium. Deprecating the convenience initializers touches about a dozen call sites. The CLI gains a `--name` flag, which needs CLI tests.
- Depends on nothing.

**WP-2 Operation lifecycle contract (FEA-07, FEA-06).**
- Files: `LungfishKit/OperationCenter.swift` and every `targetBundleURL:` call site, `AppDelegate.swift` (terminate), `MainWindowController.swift` (close), `ProjectStorageScanner.swift`.
- Risk: medium to high because of the breadth of call sites. Do it mechanically, one module per commit.
- Depends on WP-1 only for the new variant-deletion operation.

**WP-3 Annotation editing that persists (FEA-03, plus undo and the max-undo part of FEA-10).**
- Files: `ReferenceBundleManualAnnotationService.swift`, new CLI subcommands under `sequence`, `AppDelegate.swift` notification handlers, `SelectionSection.swift`, `SequenceViewerView+Interaction.swift`.
- Risk: medium.
- Depends on WP-2 (use the new lock API).

**WP-4 Import routing unification (FEA-04, FEA-05, FEA-12, FEA-14).**
- Files: new `GenomicsImportRouter` and `ProjectLayout`, `ImportCenterViewModel.swift`, `MainSplitViewController+MultiDocument.swift`, `ViewerViewController.swift` (`handleFileDrop`), `AppDelegate+ImportCenter.swift`, sidebar context menu, `AlignmentScientificActionCoordinator.swift`.
- Risk: medium. This is a behaviour change for drag and drop, so it needs a release note.
- Depends on WP-2.

**WP-5 Viewer navigation and alignment display (FEA-08, FEA-09, FEA-17, the zoom-window part of FEA-10).**
- Files: `LungfishCore` (new `LocusQueryParser`), `EnhancedCoordinateRulerView.swift`, `AppDelegate+SequenceMenu.swift`, `ReadStyleSection.swift`, `SequenceViewerView+Rendering.swift`, `MainSplitViewController`.
- Risk: low to medium. Rendering changes need snapshot tests.
- Depends on nothing.

**WP-6 Export correctness (FEA-11).**
- Files: `AppDelegate+ImportCenter.swift` export section, a new `ViewerGraphicsExportable` conformance per viewport, and the `mainWindowController?.` sweep in `Sources/LungfishApp/App/`.
- Risk: low.
- Depends on nothing.

**WP-7 Variant table honesty (FEA-13).**
- Files: `SmartFilterTokens.swift`, `AnnotationTableDrawerView+Filtering.swift`, `VariantQueryBuilderSheet.swift`, `QueryRule.swift`.
- Risk: low.
- Depends on nothing.

**WP-8 Cleanup and claim hygiene (FEA-15, FEA-16).**
- Files: `AppDelegate+*.swift`, `MainMenu.swift` protocols, `ImportCenterViewModel.swift`, `docs/user-manual/features.yaml`, and a new CI script.
- Risk: low.
- Do it after WP-4 so the handlers that WP-4 reuses are not deleted.

### Do not fix (accept)

- **The VCF import profile tag mismatch** (`lowMemory` in Settings against `low-memory` in the enum). The parser already maps it ([AppDelegate+ImportCenter.swift:1508](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:1508)), so a fix is cosmetic. Add `ultraLowMemory` to the picker only if users ask for it.
- **The small in-app Help (nine topics).** It is wired correctly. Growing it belongs to the manual effort, not this audit.
- **The static `isEnabled = false` on Cancel All Operations** ([MainMenu.swift:903](Sources/LungfishApp/App/MainMenu.swift:903)). It is redundant with `validateMenuItem` and harmless.
- **The absence of Save and Save As.** LGE writes through to the project folder and explains this in File > About Saving. That is a reasonable model for a project-folder app, as long as FEA-03 makes the write-through real for annotation edits.
