# Operation-Intent Matrix — Amplicon Genotyping + 12S (consolidated)

**Date:** 2026-05-30 · **Branch:** `codex/12s-amplicon-matching`
**Sources:** `ux-researcher` (30-intent matrix, owner) + `frontend-developer` (widget-level columns).
This is the canonical consolidated matrix. The completeness gate is satisfied: every intent has an
explicit DIVERGENT/CONSISTENT verdict, surfaces are enumerated below, and domain-justified
divergences are stated rather than left silent.

## Surfaces enumerated (completeness ledger)

**12S:** `TwelveSAmpliconResultViewController.swift`, `TwelveSResultDisplayState.swift`,
`TwelveSResultDisplaySection.swift`, `TwelveSAmpliconResultExportService.swift`,
`ViewerViewController+TwelveS.swift`; CLI `FastqTwelveSMatchSubcommand`,
`FastqTwelveSExportSubcommands`, `FastqTwelveSReferenceBundleSubcommand`,
`FastqTwelveSReferenceMetadataSubcommand`; `WorkflowOperationsDialog` (`Create 12S Reference…`).
**MHC genotype:** `GenotypeResultViewController.swift`, `GenotypeQuickFilterBarView.swift`,
`GenotypeComparisonMatrixView.swift`, `GenotypeOutlineView.swift`, `GenotypeCohortSummaryPanelView.swift`,
`GenotypeSampleDetailSheet.swift`, `GenotypeResultDisplayState.swift`, the genotype Inspector sections
(`GenotypeResultDisplaySection`, `GenotypeDropoutThresholdSection`, `GenotypeSmartCohortSection`,
`GenotypeStatusFlagSection`, …), `HaplotypeDefinitionManagerWindowController.swift`; CLI
`FastqGenotypingSubcommand`, `GenotypeCommandGroup`, `HaplotypeDefinitionsCommand`,
`FastqMHCReferenceBundleSubcommand`.
**Shared:** `WorkflowOperationsDialog`/`WorkflowOperationDialogState`, `WorkflowLibrary`,
`InspectorViewController`, `SidebarViewController`, `FormatIdentifier`, the shared BLAST drawer.
**Compared against existing LGE:** classifier results (`ClassifierActionBar`, BLAST drawer,
`TaxTriageResultViewController` search), variant smart-filter, NSTableView header-sort,
`ReferenceSequencePickerView`.

## Matrix (30 intents)

Verdict legend: **DIV** = divergent (true convergence target), **DIV*** = divergent but
domain-justified (accepted), **CONS** = consistent.

| # | Operation intent | 12S control | MHC genotype control | Existing LGE idiom | Verdict | Target shared idiom |
|---|---|---|---|---|---|---|
| I1 | Suppress low-abundance reads (count) | Editable `TextField`+`Stepper` "Minimum Exact Reads", live, `minimumExactReads`, CLI `--min-exact-reads` | Hardcoded `5_000` flag-only `belowThresholdValue` (not editable, not a filter) | None canonical | **DIV** | Editable Inspector reads-threshold on `GenotypeResultDisplayState` mirroring 12S; cohort flag tracks it |
| I2 | Suppress low-support calls (%) | n/a | "Hide Low Support" toggle + Slider + `TextField`, live, `minimumSupportPercent` | None | **DIV*** | Genotype-only; if 12S adds %, reuse this pairing |
| I3 | Dropout / per-locus thresholds | n/a | Stepper reads + Sliders, **Apply**-gated | None | **DIV*** | Genotype-only; but unify live-vs-apply (see D3) |
| I4 | Free-text search | Inspector-only `TextField` "Filter species or matches" | In-viewport `NSSearchField` (debounced) | Classifier in-viewport `NSSearchField` (TaxTriage) | **DIV** | In-viewport `NSSearchField` in header for both |
| I5 | Switch result view/lens | Header `NSSegmentedControl` Targets/Unresolved | Header `NSSegmentedControl` Summary/Review/Audit | Classifier segmented mode switch | **CONS** | — |
| I6 | Sort result rows | Static columns, no sort | Column-header `NSSortDescriptor` sort | NSTableView header-sort (app-wide) | **DIV** | Add `sortDescriptorPrototype` to 12S columns |
| I7 | Group results by category | Implicit (mode only) | Outline by sample; matrix by genotype×locus | None | **DIV*** | Domain difference; accepted |
| I8 | Include/exclude by category | Dual `Menu`s of `Toggle`s (taxon groups) | Pill `NSButton`s (`pushOnPushOff`) | None canonical | **DIV** | One pill-row idiom for both |
| I9 | Boolean attribute filters | SwiftUI `Toggle`s (Exclude Human, Only With Alternates) | Pills (Has errors, Homozygous, …) | None canonical | **DIV** | Pills in the same row as categories |
| I10 | Filter unmatched by status | Stepper "Min Unresolved Reads" + chimera `Picker`, live | Segmented status set (Unflagged/Needs Review/…) | None | **DIV*** | Different intent shape; accepted (12S threshold is internally consistent with I1) |
| I11 | Save/recall a named filter set | Absent | "Smart Cohorts" save/recall + saved-chip | None | **DIV** | Generic saved-filter service added to 12S |
| I12 | Build a reference bundle | "Create 12S Reference…" sheet in run dialog | "Create Project Bundle…" in Haplotype Manager | `.lungfishref` built by import/orient flows | **DIV** | Surface both from the run-dialog reference picker |
| I13 | Select a reference for a run | Shared run-dialog `referencePicker` | Same shared `referencePicker` (accepts `.lungfishref`/`.lungfishmhcref`) | The shared dialog (note: not `ReferenceSequencePickerView`) | **CONS** | (P2: both should use `ReferenceSequencePickerView`) |
| I14 | Prepare/launch a run | Shared `WorkflowOperationsDialog` | Same shared dialog, per-tool fields | App-wide run dialog | **CONS** | — |
| I15 | Set matching/mapping params | "Min Soft Clip"/"Max Indels"/vsearch toggle | "Min Support"/"Threads"/mode/minimap2 args | Shared `labeled*TextField` helpers | **CONS** | — |
| I16 | Export the current view | `ClassifierActionBar.onExport` → CSV/TSV/Excel menu → shells `fastq 12s-export` (provenance verified) | Bespoke "Export Excel View…" button → in-process XLSX (`lungfish-gui` argv, no CLI) | `ClassifierActionBar.onExport` (12S + 5 classifiers) | **DIV** | Genotype routes through `genotype export-xlsx` via a ClassifierActionBar-style bar |
| I17 | Export full bundle (CLI) | `fastq 12s-export` with `--export-format` + filter flags | `genotype export-xlsx` + `export-pivot-xlsx` + `export-labkey` (3 cmds, no filters) | None | **DIV** | One `genotype export --format …` with shared filter flags |
| I18 | Drill into per-item evidence | Detail pane + disclosure rows (sample evidence / alternates) | Detail pane + `GenotypeSampleDetailSheet`/`GenotypeCallEvidenceView` | Split-view master+detail | **CONS** | (sheet for deep edit is MHC-only, accepted) |
| I19 | Selection-detail empty state | "Select a target…" prompt label | "Select a genotype row…" prompt label | Plain prompt label | **CONS** | — |
| I20 | Empty/zero-results state | "X of Y" counter | Placeholder text | Manager uses `ContentUnavailableView`; result tables use labels | **DIV*** | Minor copy difference; accepted |
| I21 | Error state on action | `NSAlert(error:)` | `NSAlert(error:)` | App-wide `NSAlert` | **CONS** | — |
| I22 | Provenance / run-summary surface | `ClassifierActionBar.onProvenance` → `NSPopover` | No viewport affordance; Inspector Document tab + audit timeline | `ClassifierActionBar.onProvenance` popover | **DIV** | One canonical location (recommend Inspector Document tab for both, or action-bar popover for both) |
| I23 | Result launch from sidebar | `.twelveSAmpliconResultBundle`, teal | `.genotypeResultBundle`, orange | Sidebar bundle-type registration | **CONS** | — |
| I24 | Reference-bundle format registration | `lungfish12SRef` FormatIdentifier | `lungfishMHCRef` FormatIdentifier (parallel to `lungfishRef`) | `lungfishRef` template | **CONS** | — |
| I25 | Manage definition library (CRUD) | n/a | Haplotype Manager New/Import/Export/Duplicate/Delete/Edit, scoped, CLI-backed | None | **DIV*** | MHC-only; accepted |
| I26 | Manage-library entry point | n/a | "Manage…" in run dialog → manager window | menu-action-to-window | **CONS** (within MHC) | — |
| I27 | Cancel a long-running sub-action | BLAST drawer Cancel → `OperationCenter.cancel` | Runs via OperationCenter; export synchronous | `OperationCenter` cancel | **CONS** | — |
| I28 | External sequence verification (BLAST) | Full BLAST flow via shared bottom drawer | None | Shared classifier BLAST drawer | **DIV*** | MHC has no unknown-sequence need; accepted |
| I29 | Adjust result layout (panes) | Fixed vertical split | Configurable List/Detail layouts | None | **DIV*** | MHC richer panes; accepted |
| I30 | Color / visual encoding | None (plain cells) | Cell-color mode + highlight color wells | None | **DIV*** | Haplotype coloring domain-specific; accepted |

**Totals:** 30 intents. **CONSISTENT: 11** (I5, I13, I14, I15, I18, I19, I21, I23, I24, I26, I27).
**DIVERGENT: 19** — of which **8 domain-justified/accepted** (I2, I3, I7, I10, I20, I25, I28, I29, I30
— note I10 accepted as different-shape) and **11 true convergence targets**:
I1, I4, I6, I8, I9, I11, I12, I16, I17, I22, and the cross-cutting argv/executable-name drift.

## Convergence targets → synthesis findings (cross-reference)

| Matrix intent | Convergence (ux D#) | Synthesis finding |
|---|---|---|
| I1 low-abundance filter | D1 | S-P1-3 |
| I4 search placement | D2 | S-P1-9 |
| I16 export CLI-backed | D4 | S-P1-4 |
| I17 export CLI shape | D9 | S-P1-11 |
| I6 table sort | D5 | S-P2-5 |
| I8/I9 include/exclude + boolean | D6 | S-P1-10 |
| I11 saved filter set | D7 | S-P2-6 |
| I12 reference-bundle builder entry | D8 | S-P2-7 |
| I22 provenance surface | D10 | S-P2-8 |
| (cross-cutting) argv drift | D11 | S-P1-8 |
| live-vs-apply thresholds | D3 | folded into S-P1-3 |

## Root cause for several genotype divergences

The frontend review identifies a single structural root for I16/I22 (and contributing to the
"two different apps" feel): the genotype viewport does **not** adopt `ClassifierActionBar` or the
shared BLAST drawer, unlike 12S and the five classifiers. Adding a `ClassifierActionBar` (with the
BLAST button hidden where N/A — already precedented in 12S via `extractButton.isHidden = true`) would
give genotype a CLI-backed export and a provenance popover in one move, collapsing two divergences.
Tracked as synthesis S-P1-4 (export) and S-P2-8 (provenance).
