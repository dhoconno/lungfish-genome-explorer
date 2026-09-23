# Cross-feature consistency, UX/HIG conformance and accessibility audit

Reviewer area: cross-feature consistency, macOS HIG conformance, accessibility. Finding prefix: **UX**.
Repo state: worktree at HEAD `a1f439076` (Preview 2026.9.38 prep). Date: 2026-09-23.

## Scope

- Sibling result viewers: Kraken2 (`TaxonomyViewController`), CZ-ID (wrapper), EsViritu, TaxTriage, NAO-MGS, NVD, 12S, Genotype, Assembly, Mapping.
- Shared kernel components in `Sources/LungfishKit` (`BatchTableView`, `ClassifierActionBar`, `GenomicSummaryCardBar`, `ColumnFilter`, `ContentTypography`, `WarningPresenter`, `ResultViewportController`).
- Wizard and dialog shells, alerts, the main menu, keyboard shortcuts, undo, window restoration, toolbars.
- Accessibility of custom-drawn views, color-only encodings, dark mode, text size.
- First-run and empty states.

## Method

- Read the brief. Did not read the excluded 2026-09-05 audit material.
- Treated `docs/archive/design/viewport-interface-classes.md` and the project-memory conventions as claims to check. Checked each one against the code.
- Used read-only grep, find and small Python counting scripts across `Sources/`. Opened and traced every cited call site. No build, no test run, no GUI session.
- Built the comparison matrix (below) from source for each viewer: which table class it uses, where search, column filtering, copy, export and failure feedback come from.

## Limits

- Nothing here is **Confirmed** by running the app. Findings are **Traced** (control flow followed in source) or **Suspected**.
- AppKit event-dispatch behaviour (UX-03, UX-17) is reasoned from documented AppKit semantics, not reproduced. Both are marked Suspected and each gets an acceptance test that settles it.
- Genotype (≈11.8K-line controller plus a 9K-line matrix view) was sampled, not audited in full.
- Visual layout, spacing and real contrast ratios need screenshots. Only code-level signals were checked.

## Executive summary

LGE has already built the right shared pieces: `BatchTableView`, `GenomicSummaryCardBar`, `ClassifierActionBar`, `ColumnFilterSet`, `ContentTypography`, `DatasetOperationsDialog` and `ScientificFileExportProvenance`. Several features use them well. CZ-ID reuses the entire Kraken2 viewer, and the FASTQ operations dialog hosts all the tool wizards in one shell. The trouble is that adoption stopped partway. The oldest viewers (Kraken2's outline table, EsViritu's single-sample table, NAO-MGS and NVD) still carry hand-copied table plumbing. The column-header filter menu exists in four near-identical copies that have already drifted. The same user action has up to five different menu labels, and error handling ranges from a proper alert to silence. On five of six classifier export paths, a failed export is written to the log and nothing else, so the user believes the file was written. The worst single defect is annotation deletion: two of the three "Delete Annotation" entry points do nothing when viewing a reference bundle, which is the normal mode, even after a confirmation dialog warns the action "cannot be undone". Standard Mac commands are thin in data views. Edit > Copy (⌘C) works in only two views app-wide, and Edit > Find (⌘F) has no handler anywhere. Accessibility is uneven. The MSA, phylogenetic tree, TaxTriage confidence cells and the Genotype matrix are good, but the core sequence viewer is one opaque "group" with a fixed label. The "five viewport interface classes" contract is mostly ceremony. The protocol is never used polymorphically, the documented base classes do not exist, and several of the dialog conventions recorded in project memory are stale. The recommended path is to converge on six small shared contracts (listed under Proposed work packages). Migrate NAO-MGS and the export-error path first, because they are the most divergent and the cheapest to fix.

## Preserve (do not "fix" these away)

- **`DatasetOperationsDialog` shell with a default "Run" primary action.** It is used by 7 dialogs, including the FASTQ operations dialog that embeds `MappingWizardSheet`, `AssemblyWizardSheet`, `ClassificationWizardSheet`, `EsVirituWizardSheet` and `TaxTriageWizardSheet` ([DatasetOperationsDialog.swift:28](Sources/LungfishApp/Views/Operations/DatasetOperationsDialog.swift:28), [FASTQOperationToolPanes.swift:13](Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift:13)). This is the convergence the rest of the app should copy.
- **`BatchTableView`** ([BatchTableView.swift:93](Sources/LungfishKit/BatchTableView.swift:93)). It provides debounced filter, search-scope menu, column-header filters, selection-identity restore, `ContentTypography` fonts and single-line rows with inline secondary text. Seven tables already subclass it.
- **`GenomicSummaryCardBar`**, subclassed by Kraken2, EsViritu, TaxTriage, NAO-MGS, NVD, FASTQ and FASTA collection ([GenomicSummaryCardBar.swift:18](Sources/LungfishKit/GenomicSummaryCardBar.swift:18)).
- **`ClassifierActionBar`**, shared by the five classifier viewers ([ClassifierActionBar.swift:18](Sources/LungfishKit/ClassifierActionBar.swift:18)).
- **CZ-ID reusing `TaxonomyViewController` whole** ([CzIdResultViewController.swift:11](Sources/LungfishApp/Views/Metagenomics/CzIdResultViewController.swift:11)). This is the right pattern (but see UX-08).
- **`ScientificFileExportProvenance.writeAtomically`** on every table export. Exports are consistent in provenance even where UI feedback is not.
- **Sheets, not app-modal windows.** There are 244 `beginSheetModal` calls against only two `NSAlert.runModal()` calls. Window-level modality is used correctly.
- **`ContentTypography` + View > Content Text Size** ([MainMenu.swift:493](Sources/LungfishApp/App/MainMenu.swift:493)). This is a real, app-owned text-size system. Extend it, do not replace it.
- **Accessibility references:**
  - The MSA view and the phylogenetic tree expose `accessibilityChildren` ([MultipleSequenceAlignmentViewController.swift:3411](Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift:3411), [PhylogeneticTreeViewController.swift:1537](Sources/LungfishPhylogeneticsUI/PhylogeneticTreeViewController.swift:1537)).
  - The TaxTriage confidence cell is a `valueIndicator` with a numeric value ([TaxTriageConfidenceCellView.swift:113](Sources/LungfishTaxTriageUI/TaxTriageConfidenceCellView.swift:113)).
  - The Genotype matrix honours Increase Contrast ([GenotypeComparisonMatrixView.swift:5200](Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift:5200)).
  - Taxa collections honour Reduce Motion.
- **Brand color tokens** in `LungfishColors` are dynamic light/dark `NSColor`s. The `AccentColor` asset is set to Lungfish Orange, so `controlAccentColor` and brand orange agree. The doc comment ("system controls keep accentColor") is a sound HIG policy.
- **Standard menu skeleton.** App/File/Edit/View/…/Window/Help, `NSApp.windowsMenu`, Open Recent with Clear Menu, frame autosave on every window.
- **Autosave model without Save/Revert.** "About Saving…" in the File menu ([MainMenu.swift:200](Sources/LungfishApp/App/MainMenu.swift:200)) explains it. For a project-folder app whose operations write through the CLI, this is defensible. Do not bolt on NSDocument Save/Revert.

## Cross-feature comparison matrix

Legend: ✓ = present and shared, ◐ = present but hand-rolled or partial, ✗ = absent.

| Viewer | Table class | Text search | Column-header filters | Column state persisted | ⌘C copy | Row context menu (first items) | Export and failure feedback | Content Text Size | Load-failure UI | Sample scope UI |
|---|---|---|---|---|---|---|---|---|---|---|
| Kraken2 | `TaxonomyTableView` (own outline) | ◐ "Filter taxa…" | ◐ own copy | ✗ | ✗ | Extract Reads…, Expand…, **BLAST Matching Reads…**, Look Up on NCBI ▸, Copy Taxon Name | CSV/TSV, **alert on failure** | **✗ fixed 12 pt** | n/c | inspector picker |
| CZ-ID | reuses Kraken2 | ◐ | ◐ | ✗ | ✗ | same as Kraken2, **Extract still enabled** | same | ✗ | modal alert | n/a |
| EsViritu | `ViralDetectionTableView` (own outline) + `BatchEsVirituTableView` | ◐ "Filter viruses..." | ◐ own copy / ✓ batch | ✗ | ✗ | Extract Reads…, **BLAST Verify…**, Look Up on NCBI ▸, Copy Virus Name, Copy Accession, Copy Row as TSV | CSV/TSV, **silent** | ✓ | n/c | inspector picker |
| TaxTriage | `TaxTriageTableView` + `BatchTaxTriageTableView` | ◐ **hidden for single sample** | ✗ single / ✓ batch | ✗ | ✗ | **Verify with BLAST…**, Copy Organism Name, Copy TaxID, Copy Row as TSV, **Look Up in NCBI Taxonomy**, Extract Reads… | CSV/TSV/batch report/matrix, **silent (3 paths)** | ✓ | n/c | **segmented control, one segment per sample** |
| NAO-MGS | raw `NSTableView` in controller | **✗ none** | ◐ own copy | ✗ | ✗ | BLAST 20/50/All Reads, **Copy Taxon ID**, Copy Top Accessions, **View on NCBI**, View Taxonomy on NCBI, Search PubMed, Extract Reads… | **TSV only, silent** | ✓ | modal alert | popover button |
| NVD | raw `NSOutlineView` in controller | ◐ "Search contigs…" | ✗ | ✗ | ✗ | Extract Reads…, Copy Contig Name, Copy Accession, **View Accession on NCBI**, Search PubMed (no BLAST) | **TSV only, silent** | ✓ | modal alert | popover button |
| 12S | `TwelveSTargetTableView` (Batch) | ✓ "Filter species or matches" | ✓ | ✗ | ✗ | copy provider | CSV/XLSX via CLI off-main, **alert on failure** | ✓ | **silent, shows "No sequence selected"** | inspector picker |
| Assembly | `AssemblyContigTableView` (Batch) | ✓ | ✓ | ✗ | ✗ (⌘-click cell copy) | action bar: BLAST Contigs, Copy FASTA, Export FASTA | FASTA | ✓ | status-bar text | n/a |
| Mapping | `MappingContigTableView` (Batch) | ✓ | ✓ | ✗ | ✗ (⌘-click cell copy) | n/c | CSV/TSV | ✓ | status-bar text | n/a |
| Genotype | own matrix/outline | ✓ (⌘F handled in controller) | ◐ own | ◐ pane width only | ✗ | n/c | XLSX etc. | ✓ | n/c | own |

n/c = not checked in this pass.

## Findings

| ID | Priority | Title | Confidence | Effort |
|---|---|---|---|---|
| UX-01 | P1 | "Delete Annotation" from the viewer and the Inspector silently does nothing on reference bundles | Traced | M |
| UX-02 | P1 | Export failures are logged but never shown in EsViritu, TaxTriage (3 paths), NAO-MGS and NVD | Traced | S |
| UX-03 | P2 | Keyboard shortcuts implemented in `NSViewController.performKeyEquivalent` are probably never reached, and ⌘0 collides with Zoom to Fit | Suspected | S |
| UX-04 | P2 | Edit > Copy and Edit > Find are dead in data views | Traced | M |
| UX-05 | P2 | Table search and column-filter UI copied four times and drifting. NAO-MGS has no search. TaxTriage hides search for one sample | Traced | L |
| UX-06 | P2 | No table column state is persisted. Four ad-hoc `UserDefaults` schemes exist elsewhere | Traced | M |
| UX-07 | P2 | Same action, different names: BLAST, NCBI lookup, Copy TaxID, Extract labels drift across viewers | Traced | S |
| UX-08 | P2 | CZ-ID disables Extract on the action bar but the table menu still offers Kraken2 Extract and BLAST | Traced | S |
| UX-09 | P2 | Result load failures are shown three different ways, one of them silent | Traced | S |
| UX-10 | P2 | Content Text Size is ignored by the Kraken2 table and most sequence-viewer chrome | Traced | S |
| UX-11 | P2 | Core sequence viewer and track headers are opaque to VoiceOver and keyboard | Traced | M |
| UX-12 | P2 | Inspector key/value rows reimplemented about 10 times with different layout and accessibility | Traced | M |
| UX-13 | P2 | The "viewport interface class" contract and dialog conventions are ceremonial or stale | Traced | S |
| UX-14 | P2 | No "no matches" or first-run empty states in result tables and empty projects | Traced | M |
| UX-15 | P3 | Alert and menu wording drift, success modals, dead "Not Yet Implemented" helper, ASCII ellipses | Traced | S |
| UX-16 | P3 | Hard-coded light fills in the read track reduce dark-mode contrast | Traced | S |
| UX-17 | P3 | `BatchTableView` ⌘-click quick-copy competes with standard ⌘-click multi-select | Suspected | S |
| UX-18 | P3 | Sample-scope control differs per viewer. TaxTriage's segmented control does not scale | Traced | M |

---

### UX-01 (P1) "Delete Annotation" from the viewer and the Inspector silently does nothing on reference bundles

**Evidence (Traced)**

- There are three entry points for deleting an annotation.
  1. **Annotation drawer.** Confirms with an `NSAlert`, then runs `lungfish-cli sequence delete-annotations` through `OperationCenter` against the bundle ([ViewerViewController+AnnotationDrawer.swift:425-462](Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift:425)). This path persists.
  2. **Viewer right-click > Delete Annotation** ([SequenceViewerView+Interaction.swift:1084](Sources/LungfishApp/Views/Viewer/SequenceViewerView+Interaction.swift:1084)). It posts `.annotationDeleted` and clears selection, with no confirmation ([SequenceViewerView+Interaction.swift:1679-1692](Sources/LungfishApp/Views/Viewer/SequenceViewerView+Interaction.swift:1679)).
  3. **Inspector > Delete Annotation.** A SwiftUI `confirmationDialog` says "This action cannot be undone." ([SelectionSection.swift:1222-1240](Sources/LungfishApp/Views/Inspector/Sections/SelectionSection.swift:1222)). It then goes through `onAnnotationDeleted` to [InspectorViewController+Editing.swift:35-50](Sources/LungfishApp/Views/Inspector/InspectorViewController+Editing.swift:35), which posts the same `.annotationDeleted` notification.
- The only observer is [AppDelegate.swift:1255-1269](Sources/LungfishApp/App/AppDelegate.swift:1255). It does `guard let document = viewerController?.currentDocument else { return }` and then removes the annotation from the in-memory `LoadedDocument` only.
- In bundle mode `currentDocument` is explicitly nil. The code comment reads "Bundle replaces regular document" ([ViewerViewController.swift:3641](Sources/LungfishApp/Views/Viewer/ViewerViewController.swift:3641)).

**Impact**

- A user viewing a `.lungfishref` bundle right-clicks an annotation and chooses Delete, or confirms the Inspector's "cannot be undone" dialog. The selection clears, so it looks as if something happened, but the annotation is still in the bundle and reappears on redraw.
- In loose-document mode the deletion is in-memory only and is lost on reload.
- The same verb has three behaviours: persistent with confirm, no-op with confirm, and in-memory without confirm.

**Recommendation**

- Route both the viewer context menu and the Inspector through the drawer's persistent path. Extract `runAnnotationRowDeletion` into an `AnnotationDeletionCoordinator` on `ViewerViewController` that accepts either `SequenceAnnotation` or `AnnotationSearchIndex.SearchResult`.
- Use one confirmation `NSAlert` with a destructive button.
- In document mode, either hide Delete or state plainly that the change is not saved.
- Check `.annotationUpdated` for the same gap. [AppDelegate.swift:1237-1252](Sources/LungfishApp/App/AppDelegate.swift:1237) also updates only the document plus the viewer cache. That half is Suspected.

**Acceptance test**

- App-view test: load a reference-bundle fixture, invoke `deleteAnnotationAction` and the Inspector `deleteAnnotation()`, and assert the bundle's annotation SQLite row count drops by one after the operation completes.
- Add a test that the viewer menu item is hidden or disabled when `currentDocument == nil` and no bundle row ID exists.

**Effort:** M

---

### UX-02 (P1) Export failures are logged but never shown in EsViritu, TaxTriage (3 paths), NAO-MGS and NVD

**Evidence (Traced)**

- In each case below, the save-panel completion runs `try write…` and the `catch` only calls `logger.error`:
  - EsViritu: [EsVirituResultViewController.swift:1831-1836](Sources/LungfishEsVirituUI/EsVirituResultViewController.swift:1831)
  - NAO-MGS: [NaoMgsResultViewController.swift:2671-2677](Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:2671)
  - NVD: [NvdResultViewController.swift:2178-2184](Sources/LungfishNvdUI/NvdResultViewController.swift:2178)
  - TaxTriage: organism matrix [TaxTriageResultViewController.swift:3734](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:3734), batch report [:3792](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:3792), CSV/TSV [:3860](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:3860)
- Two viewers already get this right:
  - Kraken2 beeps and presents "Export Failed" with the file name and reason ([TaxonomyViewController.swift:1564-1570](Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift:1564)).
  - 12S calls `presentExportError` ([TwelveSAmpliconResultViewController.swift:902-905](Sources/LungfishTwelveSUI/TwelveSAmpliconResultViewController.swift:902)).
- NAO-MGS also returns with no feedback when `displayedRows` is empty ([NaoMgsResultViewController.swift:2660-2661](Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:2660)).
- A shared helper already exists: `WarningPresenter.present` ([WarningPresenter.swift:37](Sources/LungfishKit/WarningPresenter.swift:37)).

**Impact**

- A read-only destination, full disk, or a provenance sidecar failure inside `ScientificFileExportProvenance` leaves the user believing the file was written.
- For lab reporting this is a silent data-loss path: the user closes the dialog and moves on, and the result file does not exist.

**Recommendation**

- Add `ResultExportCoordinator` in `LungfishKit`. It takes a panel factory, a write closure and a window. It presents the save panel as a sheet, runs the write, and on error beeps and calls `WarningPresenter.present(title: "Export Failed", message: "Could not write <name>: <reason>")`.
- Migrate all six paths, including Kraken2 and 12S, so they share it.
- Disable the Export button (via `ClassifierActionBar`) when there are no rows, instead of returning silently.

**Acceptance test**

- For each viewer, a unit test injects a `write` that throws and a `warningPresenter` spy, then asserts exactly one presentation with the file name.
- A grep-style lint test forbids `logger.error("…xport…")` inside a `catch` with no presenter call in `Sources/Lungfish*UI`.

**Effort:** S

---

### UX-03 (P2) Keyboard shortcuts implemented in `NSViewController.performKeyEquivalent` are probably never reached, and ⌘0 collides with Zoom to Fit

**Evidence**

- TaxTriage overrides `performKeyEquivalent` on the view controller for ⌘] and ⌘[ (next/previous sample) and ⌘0 (All Samples) ([TaxTriageResultViewController.swift:1000-1038](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:1000)).
- Genotype does the same for ⌘F (focus search), Esc (clear), and the review shortcuts ⌘R, ⌘K, ⇧⌘F and ⇧⌘O ([GenotypeResultViewController.swift:1112-1157](Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:1112)).
- Both controllers install a plain `NSView` as their root ([TaxTriageResultViewController.swift:531](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:531), [GenotypeResultViewController.swift:630](Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:630)), and no view forwards the call.
- AppKit dispatches key equivalents down the **view** hierarchy (`NSWindow` → `contentView` → subviews) and then to the main menu. View controllers are not visited.
- The tests call `controller.performKeyEquivalent(with:)` directly ([GenotypeResultViewportHaplotypeDefinitionSearchTests.swift:1474](Tests/LungfishGenotypeUITests/GenotypeResultViewportHaplotypeDefinitionSearchTests.swift:1474)), so they cannot catch this.
- Separately, ⌘0 is already bound to View > Zoom to Fit ([MainMenu.swift:555](Sources/LungfishApp/App/MainMenu.swift:555)). ⌘[ and ⌘] are the conventional Back/Forward keys.

**Confidence:** Suspected. This rests on AppKit dispatch semantics and is not reproduced. The collision itself is Traced.

**Impact**

- Genotype reviewers who were told to use ⌘R and ⌘K get a beep or a different menu action.
- TaxTriage sample stepping does not work, and would conflict with the menu if it did.

**Recommendation**

- Move these commands into real menu items, for example a "Review" submenu under Tools or a contextual "Sample" menu, validated by `validateMenuItem`, so they are discoverable and appear in Help search.
- If they must stay local, override `performKeyEquivalent` on the root **view** subclass and forward to the controller.
- Rebind TaxTriage's "All Samples" away from ⌘0. Use ⌥⌘0, or drop it.

**Acceptance test**

- An XCUITest, or an app-view test that sends an `NSEvent` through `window.sendEvent(_:)` (not directly to the controller), shows ⌘K changes the selected sample's status.
- ⌘0 in TaxTriage still triggers Zoom to Fit, or the menu is disabled there.

**Effort:** S

---

### UX-04 (P2) Edit > Copy and Edit > Find are dead in data views

**Evidence (Traced)**

- Edit > Copy sends `copy:` ([MainMenu.swift:371](Sources/LungfishApp/App/MainMenu.swift:371)). Only two responders in the whole app implement it: MSA ([MultipleSequenceAlignmentViewController.swift:3471](Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift:3471)) and the FASTQ metadata drawer ([FASTQMetadataDrawerView.swift:2106](Sources/LungfishApp/Views/Viewer/FASTQMetadataDrawerView.swift:2106)). `NSTableView` does not implement `copy:`, and neither does `BatchTableView`.
- Edit > Find sends `performFindPanelAction:` ([MainMenu.swift:401](Sources/LungfishApp/App/MainMenu.swift:401)). No view implements `performFindPanelAction` or `performTextFinderAction`, and there are no `NSTextFinder` clients. The only ⌘F handling is the Genotype controller override from UX-03.
- Every result table has an `NSSearchField` (except NAO-MGS, see UX-05), but none can be reached with ⌘F.

**Impact**

- On a Mac, a user who selects rows in a Kraken2 or EsViritu table and presses ⌘C expects TSV on the clipboard. Instead the menu item is disabled.
- ⌘F is the universal "filter this list" gesture. It does nothing.
- Copy is available only through per-viewer right-click items with drifting labels (UX-07), so keyboard-only and VoiceOver users have no copy path at all.

**Recommendation**

- In `BatchTableView`, and in a shared responder mixin for the outline tables, implement:
  - `@objc func copy(_:)`: selected rows as TSV of visible columns, using `columnValue(for:row:)`.
  - `performFindPanelAction(_:)` / `performTextFinderAction(_:)` for `.showFindInterface`: make the search field first responder.
  - `validateMenuItem` for both.
- Add the same to `TaxonomyTableView`, `ViralDetectionTableView`, the NVD outline and the NAO-MGS table, or retire them onto the shared component (UX-05).

**Acceptance test**

- For each result table: select 2 rows, send `NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)` with the table first responder, and assert the pasteboard holds 3 TSV lines (header plus 2).
- Send `performFindPanelAction` with tag `showFindInterface` and assert the search field has a field editor.

**Effort:** M

---

### UX-05 (P2) Table search and column-filter UI copied four times and drifting. NAO-MGS has no search. TaxTriage hides search for one sample

**Evidence (Traced)**

- The column-header "Sort / Filter / Combine / Clear" menu plus its "Column Filter" prompt alert exists four times, with private selector names in each copy:
  - [BatchTableView.swift:890](Sources/LungfishKit/BatchTableView.swift:890) and [:973](Sources/LungfishKit/BatchTableView.swift:973)
  - [TaxonomyTableView.swift:903](Sources/LungfishApp/Views/Metagenomics/TaxonomyTableView.swift:903) and [:986](Sources/LungfishApp/Views/Metagenomics/TaxonomyTableView.swift:986)
  - [ViralDetectionTableView.swift:1221](Sources/LungfishEsVirituUI/ViralDetectionTableView.swift:1221) and [:1308](Sources/LungfishEsVirituUI/ViralDetectionTableView.swift:1308)
  - [NaoMgsResultViewController.swift:3022](Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:3022) and [:3107](Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:3107)
- A diff of the Batch and NAO-MGS prompt builders already shows drift: field width 260 vs 240, a `.small` checkbox in one only, and different stack heights and spacing.
- All four copies share the model (`ColumnFilterSet`), which is good. Only the UI was copied.
- **NAO-MGS has no free-text search.** Its filter bar holds only the sample button ([NaoMgsResultViewController.swift:1694-1735](Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:1694)), and the table is a raw `NSTableView` ([:108](Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:108)).
- **TaxTriage hides its only search field when a result has one sample.** `rebuildSampleFilterSegments` sets `organismSearchField.isHidden = true` when `ids.count <= 1` ([TaxTriageResultViewController.swift:1342-1350](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:1342)), coupling search visibility to the sample control.
- Placeholder text drifts across viewers: "Filter taxa…", "Filter viruses...", "Filter organisms…", "Search contigs…", "Filter species or matches" (no ellipsis), "Search samples or alleles…".

**Impact**

- The same header click behaves slightly differently per viewer, and fixes land in one copy only.
- The two most common lab questions, "find my taxon" in NAO-MGS and "find my organism" in a single-sample TaxTriage run, have no search box.

**Recommendation**

- Extract `ColumnHeaderFilterMenu` (menu + prompt) into `LungfishKit`, parameterized by a small `ColumnFilterHost` protocol (`tableView`, `columnTypeHints`, `columnFilterSet`, `apply()`). Make `BatchTableView` its first client.
- Migrate NAO-MGS's taxon table onto `BatchTableView<NaoMgsTaxonSummaryRow>`. It is flat, so this is a direct fit, and it gains search, filters, typography and copy for free.
- Give `TaxonomyTableView` and `ViralDetectionTableView` the extracted menu. Do not force the outline tables into `BatchTableView`.
- Decouple the TaxTriage search field from the sample control.
- Standardize the placeholder as "Filter <noun>…" with a Unicode ellipsis.

**Acceptance test**

- `grep -c 'messageText = "Column Filter"' Sources` returns 1.
- NAO-MGS has a search field whose text reduces `displayedRows`.
- A single-sample TaxTriage fixture shows a visible search field.

**Effort:** L. The NAO-MGS migration alone is M.

---

### UX-06 (P2) No table column state is persisted. Four ad-hoc `UserDefaults` schemes exist elsewhere

**Evidence (Traced)**

- No `NSTableView.autosaveName` or `autosaveTableColumns` appears anywhere in `Sources/`. The only `autosaveName` assignments are on split views.
- `BatchTableView.rebuildStandardColumns` keeps widths and hidden state only for the current session ([BatchTableView.swift:522-550](Sources/LungfishKit/BatchTableView.swift:522)).
- Separate persistence schemes exist:
  - `ColumnPrefsKey` JSON per tab for the annotation drawer ([ColumnConfigurationPopover.swift:51-72](Sources/LungfishApp/Views/Viewer/ColumnConfigurationPopover.swift:51))
  - `blastResultsHiddenColumns` ([BlastResultsDrawerTab.swift:1022-1035](Sources/LungfishKit/BlastResultsDrawerTab.swift:1022))
  - `MetadataColumnController` for metadata columns ([MetadataColumnController.swift:63](Sources/LungfishKit/MetadataColumnController.swift:63))
  - Genotype pinned-pane width ([GenotypeComparisonMatrixView.swift:350-351](Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift:350))

**Impact**

- A user who widens "Name" and hides "RPKMF" in EsViritu has to redo it every time a result is opened.
- Mac users expect table columns to remember width, order, visibility and sort.

**Recommendation**

- Add `TableColumnStateStore` in `LungfishKit`, keyed by a stable table identity such as `"esviritu.batch"` (not per result). It stores width, order, hidden and sort descriptor.
- Adopt it in `BatchTableView.setupTableView()` and in the outline tables.
- Fold `ColumnPrefsKey` and `blastResultsHiddenColumns` into it later. Do not persist per-result sample columns.

**Acceptance test**

- Configure an EsViritu batch table, resize and hide a column, tear it down, build a new instance, and assert the width and hidden state are restored.

**Effort:** M

---

### UX-07 (P2) Same action, different names: BLAST, NCBI lookup, Copy TaxID, Extract labels drift across viewers

**Evidence (Traced)**

- **BLAST labels:**
  - "BLAST Matching Reads…" ([TaxonomyTableView.swift:734](Sources/LungfishApp/Views/Metagenomics/TaxonomyTableView.swift:734))
  - "BLAST Verify…" ([ViralDetectionTableView.swift:893](Sources/LungfishEsVirituUI/ViralDetectionTableView.swift:893))
  - "Verify with BLAST…" ([BatchTaxTriageTableView.swift:64](Sources/LungfishTaxTriageUI/BatchTaxTriageTableView.swift:64))
  - "BLAST 20 Reads" / "BLAST All N Reads" (NAO-MGS, [NaoMgsResultViewController.swift:2080-2095](Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:2080))
  - "BLAST Contigs" ([AssemblyActionBar.swift:10](Sources/LungfishAssemblyUI/AssemblyActionBar.swift:10))
  - "BLAST Verify" on the shared action bar ([ClassifierActionBar.swift:24](Sources/LungfishKit/ClassifierActionBar.swift:24))
- **NCBI lookup:**
  - "Look Up on NCBI ▸" (Kraken2, EsViritu)
  - "Look Up in NCBI Taxonomy" ([BatchTaxTriageTableView.swift:100](Sources/LungfishTaxTriageUI/BatchTaxTriageTableView.swift:100))
  - "View on NCBI" and "View Taxonomy on NCBI" (NAO-MGS)
  - "View Accession on NCBI" ([NvdResultViewController.swift:1979](Sources/LungfishNvdUI/NvdResultViewController.swift:1979))
  - Kraken2 and EsViritu use a submenu, NAO-MGS and NVD use flat items.
- **Copy ID:** "Copy TaxID" (TaxTriage) vs "Copy Taxon ID" (NAO-MGS).
- **Extract:** the action bar says "Extract FASTQ" ([ClassifierActionBar.swift:51](Sources/LungfishKit/ClassifierActionBar.swift:51)), while every context menu says "Extract Reads…".
- **Menu order:** Extract comes first in Kraken2, EsViritu and NVD, but last in TaxTriage and NAO-MGS.
- **Column names:** "Hits" (NAO-MGS, [:1642](Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:1642)) vs "Reads" elsewhere. "Taxon", "Name" and "Organism" are all used for the same column.

**Impact**

- Users and the manual cannot name the action consistently, and Help search misses variants.
- Moving between classifiers means relearning menus.

**Recommendation**

- Add `ClassifierRowActionMenuBuilder` in `LungfishKit`. It emits canonical items in a fixed order from a capability struct (`canExtract`, `blastModes`, `ncbiTargets`, `copyFields`) and callbacks.
- Suggested canonical labels: "Extract Reads…", "Verify with BLAST…", "Look Up on NCBI ▸", "Copy ▸ Name / Taxon ID / Accession / Row as TSV".
- Rename the action-bar button to "Extract Reads".
- Record the glossary in one Swift enum (`LungfishUIStrings.Classifier`) so the CLI help and the manual can cite it.

**Acceptance test**

- A snapshot test of each classifier's row menu titles asserts the canonical set and order, with viewer-specific omissions allowed only through the capability struct.

**Effort:** S (labels), M (full builder migration)

---

### UX-08 (P2) CZ-ID disables Extract on the action bar but the table menu still offers Kraken2 Extract and BLAST

**Evidence (Traced)**

- The CZ-ID wrapper calls `actionBar.setExtractEnabled(false)`, with a tooltip saying CZ-ID has no per-read IDs ([CzIdResultViewController.swift:46-49](Sources/LungfishApp/Views/Metagenomics/CzIdResultViewController.swift:46)).
- The embedded Kraken2 table's context-menu validation enables "Extract Reads…" whenever a row is clicked ([TaxonomyTableView.swift:785-787](Sources/LungfishApp/Views/Metagenomics/TaxonomyTableView.swift:785)).
- That menu item calls `presentUnifiedExtractionDialog`, which resolves `classificationResult.config.outputDirectory` and opens the extraction dialog with `tool: .kraken2` ([TaxonomyViewController.swift:747-761](Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift:747)).
- "BLAST Matching Reads…" is also offered.
- What happens downstream is Suspected: most likely a failed operation, because there is no Kraken2 per-read output.

**Impact**

- Two controls for the same action disagree.
- The user is led into a dialog that cannot succeed.

**Recommendation**

- Give `TaxonomyViewController` a capability flag, for example `readLevelActionsAvailable`. Feed it to both the action bar and `TaxonomyTableView.validateMenuItem`. CZ-ID sets it to false.
- This falls out naturally from UX-07's capability struct.

**Acceptance test**

- With a CZ-ID fixture, `validateMenuItem` for the Extract and BLAST selectors returns false.

**Effort:** S

---

### UX-09 (P2) Result load failures are shown three different ways, one of them silent

**Evidence (Traced)**

- **Modal `NSAlert`:** NAO-MGS, NVD, CZ-ID ([MainSplitViewController+ClassifierDisplay.swift:942](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ClassifierDisplay.swift:942), [:1045](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ClassifierDisplay.swift:1045), [:1091](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ClassifierDisplay.swift:1091)).
- **Status-bar text only:** assembly, mapping, tree, reference and MHC bundles, e.g. "Unable to load assembly result." ([MainSplitViewController+ContentDisplay.swift:844](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift:844), [:893](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift:893)).
- **Silent:** 12S logs the error and calls `showNoSequenceSelected()` ([MainSplitViewController+ContentDisplay.swift:587-593](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift:587)). The viewport then reads as if nothing were selected.
- The Kraken2 batch path uses a third style: an in-viewport placeholder with `showError` ([MainSplitViewController+ClassifierDisplay.swift:689](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ClassifierDisplay.swift:689)).

**Impact**

- A corrupt or partially written 12S bundle looks like "click something". Other failures appear as small status-bar text or as a blocking modal, depending on the tool.

**Recommendation**

- Add a `ViewportStatusView` in `LungfishKit` with states `.loading`, `.empty(message, action)`, `.noMatches(clear:)` and `.failed(title, detail, actions: [Reveal in Finder, Show Operation Log])`. It should be an accessible `NSView` with role and label set.
- Use it for all display failures. Keep modal alerts only when the user explicitly asked for an action.
- Start with 12S, the silent case.

**Acceptance test**

- For each display function, inject a loader that throws and assert the viewport contains a `ViewportStatusView` in `.failed` state whose accessibility label contains the bundle name.

**Effort:** S (12S fix), M (full adoption)

---

### UX-10 (P2) Content Text Size is ignored by the Kraken2 table and most sequence-viewer chrome

**Evidence (Traced)**

- View > Content Text Size (⌥⌘+ / ⌥⌘− / ⌥⌘0) drives `ContentTypography` ([MainMenu.swift:493-531](Sources/LungfishApp/App/MainMenu.swift:493)).
- EsViritu, TaxTriage, NAO-MGS, NVD, 12S, Genotype, Assembly and Phylogenetics all reference it.
- `Sources/LungfishApp/Views/Metagenomics` (Kraken2, CZ-ID, taxa collections) has **zero** references. `TaxonomyTableView` hard-codes `.systemFont(ofSize: 12)` and `.monospacedDigitSystemFont(ofSize: 12)` for cells and 11–12 pt for search and count ([TaxonomyTableView.swift:234-239](Sources/LungfishApp/Views/Metagenomics/TaxonomyTableView.swift:234), [:1265](Sources/LungfishApp/Views/Metagenomics/TaxonomyTableView.swift:1265), [:1333](Sources/LungfishApp/Views/Metagenomics/TaxonomyTableView.swift:1333)). Row height is fixed at 22 ([:318](Sources/LungfishApp/Views/Metagenomics/TaxonomyTableView.swift:318)).
- `Views/Viewer` has 258 fixed-size font calls against 7 typography references.

**Impact**

- The flagship classifier table does not respond to the app's own text-size command, while its siblings do.
- Low-vision users lose the one scaling control the app offers.

**Recommendation**

- Adopt `ContentTypography` in `TaxonomyTableView`: observe the notification, rebuild fonts, and derive row height from the font.
- Follow the pattern in [BatchTableView.swift:392](Sources/LungfishKit/BatchTableView.swift:392).
- Treat viewer chrome (status bar, ruler labels) as a second pass.

**Acceptance test**

- Post the typography-changed notification at "Larger" and assert that a `TaxonomyTableView` cell font's point size increased and `rowHeight` grew.

**Effort:** S

---

### UX-11 (P2) Core sequence viewer and track headers are opaque to VoiceOver and keyboard

**Evidence (Traced)**

- `SequenceViewerView.configureAccessibility` sets only element = true, role `.group` and label "Sequence viewer" ([SequenceViewerView.swift:1251-1256](Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift:1251)). There is no `accessibilityValue` (locus, zoom, selection) and no `accessibilityChildren` (tracks, annotations).
- The empty-state guidance "Select a file from the sidebar to view" is drawn text ([SequenceViewerView+AnnotationRendering.swift:1043](Sources/LungfishApp/Views/Viewer/SequenceViewerView+AnnotationRendering.swift:1043)), so VoiceOver never reads it.
- `TrackHeaderView` toggles annotation tracks by clicking drawn disclosure triangles in `mouseDown` ([TrackHeaderView.swift:268-286](Sources/LungfishApp/Views/Viewer/TrackHeaderView.swift:268)). It has no key handling and no accessibility at all.
- Other drawn views with no accessibility references: `CoordinateRulerView`, `MiniPileupView`, `SegmentCompletenessView`, `FASTAAnnotationMapCell`, `MetagenomicsDrawerView`.
- In contrast, MSA and the phylogenetic tree build `NSAccessibilityElement` children (see Preserve).

**Impact**

- A VoiceOver user cannot tell which region is shown, what annotations exist, or how to expand a track. The main genome browser is effectively unusable without sight.
- Keyboard-only users cannot toggle track annotations.

**Recommendation**

- Give `SequenceViewerView` a dynamic `accessibilityValue`, e.g. "chr1:10,000–20,000, 3 annotations visible, selection 12 bp". Update it wherever the status bar updates.
- Expose visible annotations as `NSAccessibilityElement` children with role `.button`, a label, and frames. Follow the MSA implementation.
- Make `TrackHeaderView` rows accessible disclosure elements (`.disclosureTriangle`) with `accessibilityPerformPress`, and add Space/Return handling.
- Replace the drawn empty-state text with the `ViewportStatusView` from UX-09.

**Acceptance test**

- An XCUI or accessibility-tree test: after loading a fixture, the viewer's accessibility value contains the chromosome name.
- A track-header element exists per track with a press action that toggles annotations.

**Effort:** M

---

### UX-12 (P2) Inspector key/value rows reimplemented about 10 times with different layout and accessibility

**Evidence (Traced)**

- Private row helpers found:
  - [DocumentSection.swift:1534](Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift:1534): label 100 pt, trailing, link support
  - [SelectionSection.swift:1422](Sources/LungfishApp/Views/Inspector/Sections/SelectionSection.swift:1422): 72 pt, **leading**, 2-line middle truncation
  - [BatchOperationDetailsSection.swift:80](Sources/LungfishApp/Views/Inspector/Sections/BatchOperationDetailsSection.swift:80): 80 pt, trailing
  - [ReadStyleSection.swift:1399](Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift:1399) and [:1622](Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift:1622): two copies in one file
  - [InspectorView.swift:1350](Sources/LungfishApp/Views/Inspector/InspectorView.swift:1350)
  - [GenotypeResultDocumentSection.swift:496](Sources/LungfishGenotypeUI/GenotypeResultDocumentSection.swift:496)
  - [GenotypeMatrixAnnotationSection.swift:384](Sources/LungfishGenotypeUI/GenotypeMatrixAnnotationSection.swift:384)
  - [GenotypeResultDisplaySection.swift:1949](Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift:1949)
- The public, adaptive, accessibility-combined version already exists but only Genotype uses it: `GenotypeInspectorValueRow` ([GenotypeInspectorValueRow.swift:5-30](Sources/LungfishGenotypeUI/GenotypeInspectorValueRow.swift:5)).

**Impact**

- Label columns jump between sections as the Inspector changes (100, 80, 72 pt, trailing vs leading).
- Only the Genotype rows read "label, value" as one VoiceOver element.
- Copy affordances differ: context menu in one, text selection in others.

**Recommendation**

- Promote `GenotypeInspectorValueRow` to `LungfishKit` as `InspectorKeyValueRow`, with optional `url` and copy context menu. Use `LungfishInspectorStyle` fonts and a single label-width token.
- Replace the private helpers section by section, starting with Document and Selection, the most visible.

**Acceptance test**

- `grep -E "func (metadataRow|detailRow|statRow|valueRow)" Sources` returns 0.
- A ViewInspector test asserts every Inspector section's rows carry `accessibilityLabel` and `accessibilityValue`.

**Effort:** M

---

### UX-13 (P2) The "viewport interface class" contract and dialog conventions are ceremonial or stale

**Evidence (Traced)**

- `ResultViewportController` has five conformances. None is consumed polymorphically: `exportResults(to:format:)` is called only from tests ([MappingResultViewControllerTests.swift:1239](Tests/LungfishAppViewTests/MappingResultViewControllerTests.swift:1239)). `TaxonomyViewController.summaryBarView` finds its bar by scanning subviews ([TaxonomyResultViewController.swift:69-71](Sources/LungfishApp/Views/Results/Taxonomy/TaxonomyResultViewController.swift:69)).
- The doc comment says Kraken2, EsViritu, TaxTriage and NAO-MGS conform to `BlastVerifiable` ([ResultViewportController.swift:135](Sources/LungfishKit/ResultViewportController.swift:135)). Only Assembly does ([AssemblyResultViewController.swift:678](Sources/LungfishAssemblyUI/AssemblyResultViewController.swift:678)).
- The design doc now lives in `docs/archive/design/` under a README saying it is not current guidance. It prescribes base classes such as `TaxonomyResultViewController` ([viewport-interface-classes.md:41](docs/archive/design/viewport-interface-classes.md:41)) that do not exist as base classes.
- Project-memory dialog conventions do not match the code:
  - `OrientWizardSheet` ([OrientWizardSheet.swift:49](Sources/LungfishApp/Views/Metagenomics/OrientWizardSheet.swift:49)) and `UnifiedMetagenomicsWizard` ([UnifiedMetagenomicsWizard.swift:24](Sources/LungfishApp/Views/Metagenomics/UnifiedMetagenomicsWizard.swift:24)) have zero production instantiations and are referenced only by tests.
  - `MapReadsWizardSheet` does not exist.
  - The live dialog is the 980×700 operations panel ([FASTQOperationsDialogPresenter.swift:58](Sources/LungfishApp/Views/FASTQ/FASTQOperationsDialogPresenter.swift:58)), not the claimed "480–520 px sheets".
- File > Export offers sequences, annotations, FASTQ, metadata, images and provenance ([MainMenu.swift:216-270](Sources/LungfishApp/App/MainMenu.swift:216)), but no "Export Table…" for the active result. The protocol that could power that is unused.

**Impact**

- New contributors and LLM agents follow documentation and memory that describe a different app.
- Dead wizard code is still tested and maintained.
- The one place a uniform contract would pay off, a File > Export Table command, is missing.

**Recommendation**

- Either make the protocol real or delete it.
  - Real: add File > Export > "Current Table…" that calls `(activeViewport as? any ResultViewportController)?.exportResults` through the `ResultExportCoordinator` from UX-02. This is the preferred option.
  - Otherwise remove `ResultViewportController` and `BlastVerifiable`.
- Delete `OrientWizardSheet`, `UnifiedMetagenomicsWizard` and their tests.
- Update the project memory's dialog-template line to name `DatasetOperationsDialog` as the template.

**Acceptance test**

- File > Export > Current Table… is enabled for every classifier viewer and writes the same file as the action-bar export.
- The dead wizard types no longer compile into the app target.

**Effort:** S

---

### UX-14 (P2) No "no matches" or first-run empty states in result tables and empty projects

**Evidence**

- No classifier table (`BatchTableView`, `TaxonomyTableView`, `ViralDetectionTableView`, NAO-MGS, NVD, TaxTriage, 12S) contains a "no matches" or empty-state view. Only the VCF and FASTA collection viewers have an `emptyStateLabel` ([VCFDatasetViewController.swift:175](Sources/LungfishApp/Views/Viewer/VCFDatasetViewController.swift:175)). Traced.
- A newly created project shows the drawn text "Select a file from the sidebar to view" ([SequenceViewerView+AnnotationRendering.swift:1043](Sources/LungfishApp/Views/Viewer/SequenceViewerView+AnnotationRendering.swift:1043)). A new project has nothing to select, and the sidebar has no empty state or "Import…" affordance ([SidebarViewController.swift:436-440](Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift:436)). Traced. That this stalls first-time users is Suspected, pending a GUI walkthrough.
- The Welcome window focuses on tool and storage setup plus "Create a project or open an existing one", with no "import your first FASTQ" step.

**Impact**

- A filter that matches nothing and a classifier run that detected nothing both show a blank grid. That can be read as a bug or as "no pathogens found".
- For a clinical-adjacent tool, "0 detections" deserves an explicit statement.
- A first-time lab scientist in an empty project gets no pointer to Import Center (⇧⌘I).

**Recommendation**

- Use `ViewportStatusView` (UX-09) inside `BatchTableView` and the outline tables:
  - `.noMatches(filter:)` with a "Clear Filter" button
  - `.empty("No taxa were classified in this sample")` with the result-specific text supplied by the subclass
- In an empty project, show an accessible empty state with "Import Files…" (Import Center) and "Download from NCBI/SRA…".

**Acceptance test**

- Filter a fixture table to zero rows and assert a visible status view with a Clear Filter action that restores the rows.
- A new empty project shows an Import button that opens Import Center.

**Effort:** M

---

### UX-15 (P3) Alert and menu wording drift, success modals, dead "Not Yet Implemented" helper, ASCII ellipses

**Evidence (Traced)**

- Same condition, two names: "No Project Open" in 4 places ([AppDelegate+ImportExport.swift:262](Sources/LungfishApp/App/AppDelegate+ImportExport.swift:262)) and "No Active Project" in 2 places ([MainSplitViewController+GenomicsDisplay.swift:157](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+GenomicsDisplay.swift:157), [WorkflowBuilderViewController.swift:364](Sources/LungfishApp/Views/WorkflowBuilder/WorkflowBuilderViewController.swift:364)).
- Success modals: "Export Successful" and "Export Complete" alerts ([AppDelegate+ImportCenter.swift:3482](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:3482), [WorkflowBuilderViewController.swift:911](Sources/LungfishApp/Views/WorkflowBuilder/WorkflowBuilderViewController.swift:911)). HIG discourages alerts that confirm success. Offer "Show in Finder" through a non-modal path instead.
- Sentence case in an alert title: "Extraction failed" ([TaxonomyReadExtractionAction.swift:447](Sources/LungfishApp/Views/Metagenomics/TaxonomyReadExtractionAction.swift:447)).
- Dead helper `showNotImplementedAlert` ("Feature Not Yet Implemented") ([AppDelegate+ImportExport.swift:246-255](Sources/LungfishApp/App/AppDelegate+ImportExport.swift:246)) with no callers.
- 21 menu and button titles use ASCII "..." (e.g. "Settings...", "Open Project Folder...", "Find...", [MainMenu.swift:111](Sources/LungfishApp/App/MainMenu.swift:111)) against 122 that use "…".
- The Tools submenu title "PCR primer design" is sentence case ([MainMenu.swift:704](Sources/LungfishApp/App/MainMenu.swift:704)).

**Recommendation**

- Add a `LungfishAlertCopy` enum for recurring conditions (no project, bundle busy, export failed).
- Replace success alerts with `ResultExportCoordinator`'s optional non-modal reveal.
- Run a mechanical `...` → `…` sweep on UI titles and apply title case to menu items.
- Delete the dead helper.

**Acceptance test**

- A lint test fails on `"[^"]*\.\.\."` inside `withTitle:`/`title:`/`addButton(withTitle:` in `Sources/LungfishApp` and `Sources/Lungfish*UI`.
- `messageText` values are unique per condition.

**Effort:** S

---

### UX-16 (P3) Hard-coded light fills in the read track reduce dark-mode contrast

**Evidence (Traced)**

- The "+N reads not shown" overflow bar fills with `NSColor(white: 0.88, alpha: 0.9)` and draws 9 pt `secondaryLabelColor` text on it ([ReadTrackRenderer.swift:2070-2082](Sources/LungfishApp/Views/Viewer/ReadTrackRenderer.swift:2070)). In Dark Aqua, `secondaryLabelColor` resolves to a light gray, so light text lands on a light bar.
- Similar fixed fills appear at [ReadTrackRenderer.swift:927](Sources/LungfishApp/Views/Viewer/ReadTrackRenderer.swift:927) and [SequenceViewerView+AnnotationRendering.swift:1002](Sources/LungfishApp/Views/Viewer/SequenceViewerView+AnnotationRendering.swift:1002).

**Impact**

- A truncation warning that matters for interpreting pileups is hard to read in dark mode.

**Recommendation**

- Use `NSColor.quaternarySystemFill` or a named dynamic token in `LungfishColors` with `labelColor` text.
- Sweep `Views/Viewer` for `NSColor(white:` and `NSColor(red:` fills behind text.

**Acceptance test**

- Render the overflow bar under `NSAppearance(named: .darkAqua)` and assert a contrast ratio of at least 4.5:1 between the resolved fill and text colors.

**Effort:** S

---

### UX-17 (P3) `BatchTableView` ⌘-click quick-copy competes with standard ⌘-click multi-select

**Evidence**

- `BatchQuickCopyTextField.mouseDown` copies the cell value when ⌘ is held ([BatchTableView.swift:16-26](Sources/LungfishKit/BatchTableView.swift:16)).
- The field spans the whole cell ([BatchTableView.swift:840-853](Sources/LungfishKit/BatchTableView.swift:840)).
- The feature is enabled for the Assembly and Mapping contig tables ([AssemblyContigTableView.swift:55](Sources/LungfishAssemblyUI/AssemblyContigTableView.swift:55), [MappingContigTableView.swift:48](Sources/LungfishApp/Views/Results/Mapping/MappingContigTableView.swift:48)).
- Those tables allow multiple selection ([BatchTableView.swift:350](Sources/LungfishKit/BatchTableView.swift:350)), and the Assembly action bar's "BLAST Contigs" and "Copy FASTA" act on the selection.

**Confidence:** Suspected. `NSTableView` may intercept label clicks before the field sees them. In that case the quick-copy feature is dead rather than harmful. Either outcome is a defect.

**Recommendation**

- Remove the ⌘-click gesture. Provide copy through `copy:` (UX-04) and a "Copy Value" context item.

**Acceptance test**

- In a UI test, ⌘-click on two contig rows selects both.

**Effort:** S

---

### UX-18 (P3) Sample-scope control differs per viewer. TaxTriage's segmented control does not scale

**Evidence (Traced)**

- TaxTriage builds one `NSSegmentedControl` segment per sample ([TaxTriageResultViewController.swift:1354-1370](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:1354)). Its own comment elsewhere concedes "it doesn't scale to large sample counts" ([:2962-2964](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:2962)).
- NAO-MGS and NVD use a toolbar button that opens `ClassifierSamplePickerView` in a popover ([NaoMgsResultViewController.swift:713-737](Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:713)).
- Kraken2, EsViritu and 12S use the Inspector picker.
- All of them share `ClassifierSamplePickerState`, which is good.

**Recommendation**

- Pick one surface. The Inspector picker is the natural choice, plus an optional compact popover button in the filter bar using the same view. Retire the segmented control.

**Acceptance test**

- A 24-sample TaxTriage fixture presents the shared picker with no per-sample segments.

**Effort:** M

---

## Recommended shared contracts (converge on these)

1. **`ResultExportCoordinator`** (Kit): save panel, write, failure alert, optional reveal. Also powers File > Export > Current Table… (UX-02, UX-13, UX-15).
2. **`ViewportStatusView`** (Kit): accessible loading, empty, no-matches and failed states with actions (UX-09, UX-11, UX-14).
3. **`ColumnHeaderFilterMenu` + `TableColumnStateStore`** (Kit): one filter UI and one persistence scheme for every table (UX-05, UX-06).
4. **`ClassifierRowActionMenuBuilder` + `LungfishUIStrings`** (Kit): canonical row actions, order and labels, driven by a capability struct (UX-07, UX-08).
5. **Standard responder contract for result tables**: `copy:`, `performFindPanelAction:` (focus filter), `selectAll:` and `validateMenuItem`, implemented once in `BatchTableView` and a small mixin for the outline tables (UX-04, UX-17).
6. **`InspectorKeyValueRow`** (Kit), promoted from `GenotypeInspectorValueRow` (UX-12).

**Migrate first:** the NAO-MGS taxon table and the export-error path. NAO-MGS is the most divergent viewer (no search, copied filter UI, silent export) and its table is flat, so moving it to `BatchTableView` is low-risk and proves contracts 3 and 5. The export-error fix is small and removes a silent-failure class across five viewers. After that, give Kraken2's `TaxonomyTableView` the shared filter menu and `ContentTypography`, since it is the most-used table.

## Proposed work packages

Order matters where noted. Each package is independently reviewable.

**WP1: Surface failures (S). UX-02, UX-09 (12S part).**
- Add `ResultExportCoordinator`.
- Migrate EsViritu, TaxTriage ×3, NAO-MGS and NVD, then Kraken2 and 12S.
- Fix the silent 12S load failure.
- Files: `LungfishKit/ResultExportCoordinator.swift` (new), the five `*ResultViewController.swift` files, `MainSplitViewController+ContentDisplay.swift`.
- Risk: low. No dependencies.

**WP2: Annotation deletion unification (M). UX-01.**
- Extract the drawer's persistent deletion into a coordinator and route the viewer menu and Inspector to it.
- Files: `ViewerViewController+AnnotationDrawer.swift`, `SequenceViewerView+Interaction.swift`, `InspectorViewController+Editing.swift`, `AppDelegate.swift`, `SelectionSection.swift`.
- Risk: medium. It touches a bundle write path, and the test must use a real bundle fixture. Independent of the other packages.

**WP3: Responder and keyboard contract (M). UX-03, UX-04, UX-17.**
- Implement `copy:` and find in `BatchTableView` plus the outline tables.
- Move controller-level shortcuts to menu items or the root view, and resolve the ⌘0 collision.
- Remove ⌘-click copy.
- Files: `BatchTableView.swift`, `TaxonomyTableView.swift`, `ViralDetectionTableView.swift`, `NvdResultViewController.swift`, `GenotypeResultViewController.swift`, `TaxTriageResultViewController.swift`, `MainMenu.swift`.
- Risk: medium, because of Genotype review-flow regressions. Settle UX-03 first with a real event-dispatch test.

**WP4: Table convergence (L). UX-05, UX-06, UX-10, UX-18. Depends on WP3 for the responder mixin.**
- Step a: extract `ColumnHeaderFilterMenu` and move `BatchTableView` onto it.
- Step b: migrate the NAO-MGS table to `BatchTableView`.
- Step c: give `TaxonomyTableView` and `ViralDetectionTableView` the menu, and give Kraken2 `ContentTypography`.
- Step d: add `TableColumnStateStore`.
- Step e: unify sample scope.
- Risk: medium-high (large files, many existing tests). Keep each step a separate PR.

**WP5: Vocabulary (S). UX-07, UX-08, UX-15.**
- Add the canonical labels enum, the row-action builder and the CZ-ID capability flag.
- Apply the alert-copy and ellipsis sweep.
- Risk: low. Update the manual and screenshots in the same pass.

**WP6: Accessibility of core viewer (M). UX-11, UX-16.**
- Viewer `accessibilityValue` and children, `TrackHeaderView` disclosure elements, dark-mode fills.
- Risk: medium (performance of child elements on dense tracks). Expose only visible annotations and cap the count.

**WP7: Inspector rows (M). UX-12.** Mechanical. Low risk. Independent.

**WP8: Contract and doc cleanup (S). UX-13, UX-14.**
- Implement File > Export > Current Table… on top of WP1.
- Delete the dead wizards.
- Add empty and no-matches states using `ViewportStatusView`.
- Update the memory conventions.
- Depends on WP1 (and on WP4 for the table empty states).

### Accept, do not fix

- **Window restoration disabled** ([MainWindowController.swift:162-167](Sources/LungfishApp/Views/MainWindow/MainWindowController.swift:162)). Projects reopen through the Welcome window and Open Recent, and frame autosave works. Full `NSWindowRestoration` would be costly and low-value for a project-folder app.
- **No Save/Revert.** The autosave model with "About Saving…" is coherent. Keep it.
- **Main toolbar customization off** (`allowsUserCustomization = false`). The toolbar is small and fixed-purpose. P3 at most.
- **The "480–520 px sheet" convention.** Retire it rather than enforce it. The shared operations dialog is the better template.
- **Hard-coded track palette colors in `LungfishCore`** (106 RGB literals). These are scientific encodings (bases, qualities) and should stay fixed. They are not theme tokens.
