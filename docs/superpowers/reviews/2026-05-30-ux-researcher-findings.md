# UX Researcher Findings — Amplicon Genotyping + 12S

**Date:** 2026-05-30
**Lens:** End-to-end user flows + the exhaustive operation-intent matrix (owner)
**Mode:** Read-only source review (no running app). All paths absolute under
`/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching/`.

---

## Surfaces enumerated (completeness ledger)

Coverage is provable by this list. Every surface below was read in full or
grep-inventoried; the matrix in Part 2 has a cell for each.

**12S amplicon matching**
- Viewport: `Sources/LungfishApp/Views/Results/TwelveS/TwelveSAmpliconResultViewController.swift` (846 lines, read in full).
- Viewport display model: `Sources/LungfishApp/Views/Results/TwelveS/TwelveSResultDisplayState.swift`.
- Inspector section: `Sources/LungfishApp/Views/Inspector/Sections/TwelveSResultDisplaySection.swift`.
- Viewport export service: `Sources/LungfishApp/Views/Results/TwelveS/TwelveSAmpliconResultExportService.swift`.
- Viewer mount/BLAST wiring: `Sources/LungfishApp/Views/Viewer/ViewerViewController+TwelveS.swift`.
- CLI: `FastqTwelveSMatchSubcommand.swift`, `FastqTwelveSExportSubcommands.swift` (`12s-export`, `12s-export-unresolved`), `FastqTwelveSReferenceBundleSubcommand.swift`, `FastqTwelveSReferenceMetadataSubcommand.swift`.
- Reference-bundle builder UI: `WorkflowOperationsDialog.swift` (`Create 12S Reference…` -> `TwelveSReferenceBundleBuilderSheet`).

**MHC / KIR amplicon genotyping**
- Viewport: `Sources/LungfishApp/Views/Results/Genotype/GenotypeResultViewController.swift` (4145 lines; header/controls + export + cohort + threshold regions read).
- Viewport quick-filter bar: `Sources/LungfishApp/Views/Results/Genotype/GenotypeQuickFilterBarView.swift`.
- Viewport sub-views: `GenotypeComparisonMatrixView.swift`, `GenotypeOutlineView.swift`, `GenotypeCohortSummaryPanelView.swift`, `GenotypeSampleDetailSheet.swift`, `GenotypeCallEvidenceView.swift`, `GenotypeViewportExcelExportService.swift`.
- Viewport display model: `Sources/LungfishApp/Views/Results/Genotype/GenotypeResultDisplayState.swift`.
- Inspector sections: `GenotypeResultDisplaySection.swift`, `GenotypeDropoutThresholdSection.swift`, `GenotypeSmartCohortSection.swift`, `GenotypeStatusFlagSection.swift`, `GenotypeOverrideSection.swift`, `GenotypeManualHaplotypingSection.swift`, `GenotypeResultDocumentSection.swift`, `GenotypeAuditTimelineSection.swift`.
- Haplotype manager: `Sources/LungfishApp/Views/WorkflowOperations/HaplotypeDefinitionManagerWindowController.swift`.
- CLI: `FastqGenotypingSubcommand.swift` (`fastq genotype`), `GenotypeCommandGroup.swift` (`genotype list-samples`, `list-cohorts`, `apply-annotations`, `export-xlsx`, `export-pivot-xlsx`, `export-labkey`), `HaplotypeDefinitionsCommand.swift` (`haplotypes …`), `FastqMHCReferenceBundleSubcommand.swift` (`fastq mhc-reference-bundle`).

**Shared / cross-cutting**
- Run-prep dialog: `WorkflowOperationsDialog.swift` + `WorkflowOperationDialogState.swift` (shared by both workflows).
- Enablement: `Sources/LungfishApp/Services/WorkflowLibrary.swift`.
- Inspector mounting: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`.
- Sidebar: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`.
- Format registry: `Sources/LungfishIO/Registry/FormatIdentifier.swift`.
- Shared BLAST drawer: `BlastResultsDrawerContainerView` / `BlastResultsDrawerTab` (12S uses it; genotype does not).

**Reference LGE surfaces compared against** (for "does a shared idiom already exist?"):
classifier results (`ClassifierActionBar`, the BLAST drawer), variant results
(`VariantSmartFilter`/`VariantDatabase.query(smartFilter:)`), assembly/alignment
table views, and `ReferenceSequencePickerView`.

---

## PART 1 — End-to-end flow findings

Schema: `ID | Severity | Surface | Location | Problem | Evidence | Suggested fix | Effort`

### 12S amplicon matching

`UX-01 | P1 | 12S | Sources/LungfishApp/Services/WorkflowLibrary.swift:227-229`
**Problem:** 12S is ON by default, contradicting the opt-in product intent.
**Evidence:** `defaultEnabledWorkflowIDs` contains both `FASTQOperationToolID.ontGenotyping.rawValue` and `WorkflowLibraryCatalog.twelveSAmpliconMatchingID` (line 229), returned as the default at line 379. The spec ("Current State", gap 1) and brief both state 12S "IS its own Workflow-Manager opt-in entry." Shipping it pre-enabled means a user who never wanted 12S sees it in the workflow list and the run dialog. Friction: the very first thing the opt-in flow promises (deliberately turning it on) is bypassed.
**Suggested fix:** Remove `twelveSAmpliconMatchingID` from `defaultEnabledWorkflowIDs`; keep ONT genotyping enabled (it is an enhancement to an existing workflow, not a new opt-in). Confirm `WorkflowLibraryEnablementStore` migration does not silently re-enable for existing users.
**Effort:** S

`UX-02 | P1 | 12S | TwelveSAmpliconResultViewController.swift:15-20,345; TwelveSResultDisplaySection.swift:257-264`
**Problem:** Free-text search for the 12S result lives ONLY in the Inspector, while the equivalent genotype search is a prominent viewport bar. A user scanning 12S species rows has no on-canvas search; they must open the Inspector's "12S Results -> Target Rows" disclosure to find the filter field. Genotype users get a search bar pinned above the table. Same app, two mental models for "find a row."
**Evidence:** 12S viewport header has only a `Targets`/`Unresolved` `NSSegmentedControl` (lines 15-20) and no `NSSearchField` (grep for `NSSearchField` in the VC returns nothing); the filter field is `twelve-s-filter-field` inside the Inspector section (TwelveSResultDisplaySection.swift:263). Genotype has `GenotypeQuickFilterBarView` mounted above content (`GenotypeResultViewController.swift:33,527`).
**Suggested fix:** See divergence D2 — converge on one search placement. At minimum, surface the 12S filter as a viewport search field too.
**Effort:** M

`UX-03 | P2 | 12S | TwelveSAmpliconResultViewController.swift:454-468`
**Problem:** 12S result columns are not sortable; the genotype comparison matrix is. A user who wants 12S species by "Max %" or "Refs" descending cannot click the header. Minor friction but an inconsistency with every other table-bearing result surface in LGE.
**Evidence:** `addColumn(...)` never sets `sortDescriptorPrototype` and the table sets no `sortDescriptors` (lines 454-477); genotype matrix sets `NSSortDescriptor` prototypes and handles `sortDescriptorsDidChange` (`GenotypeComparisonMatrixView.swift:320,337,521`).
**Suggested fix:** See divergence D5.
**Effort:** M

`UX-04 | P2 | 12S | WorkflowOperationsDialog.swift:137-142,343-351`
**Problem:** Terminology/onboarding nit on the 12S run dialog. The advanced help text "paired-read merging should be handled before import" assumes a user already knows the amplicon import recipe path. There is no in-dialog pointer to that recipe.
**Evidence:** advancedSettings 12S branch (lines 343-351) states the expectation but offers no affordance; the spec confirms the merge happens on GUI import via the amplicon recipe (Out of Scope, last bullet).
**Suggested fix:** Add a one-line link/hint ("Use Import -> Illumina Amplicon Merge to produce merged FASTQ") or disable run with a clearer readiness message when inputs look paired.
**Effort:** S

**12S flow verdict:** The run -> explore -> export -> BLAST-unresolved loop is coherent and CLI-backed end to end (export shells to `fastq 12s-export`, BLAST shells to `fastq 12s-export-unresolved`; both verify canonical provenance — `TwelveSAmpliconResultExportService.swift:152-168`, `ViewerViewController+TwelveS.swift:196-215`). Friction is concentrated in search placement (UX-02) and the opt-in default (UX-01).

### MHC / KIR amplicon genotyping

`UX-05 | P1 | MHC | FastqGenotypingSubcommand.swift:21-22,65-66,107-111`
**Problem:** The `.lungfishmhcref` bundle is produced but the genotyping consume-side is half-wired, which breaks the promised flow "select the `.lungfishmhcref` bundle and run." `--reference` accepts the bundle and auto-fills the *default* haplotype definition, but a user who picked the bundle still sees the full assay/species/scope/definition picker stack and can desync the pairing.
**Evidence:** `--reference` help says "FASTA file or .lungfishref bundle" (line 21-22) — it does not mention `.lungfishmhcref`; the bundle's default definition is only applied when the explicit flags are nil (`effectiveHaplotypeDefinition = haplotypeDefinition ?? bundledDefaultHaplotype?.id`, lines 109-111). The run dialog still renders the assay/species/scope/definition pickers even when an MHC bundle is selected (`WorkflowOperationsDialog.swift:301-323` only swaps the *Source* row to a static label). Spec gap 2 flags this as a hard Phase-5 gate.
**Suggested fix:** When a `.lungfishmhcref` is selected, collapse the haplotype-definition pickers to a read-only "From bundle: <name>" summary (mirror the cohort/anchor summary style) and treat the bundle as the single source of FASTA+defs. Document `.lungfishmhcref` in `--reference` help.
**Effort:** M

`UX-06 | P1 | MHC | GenotypeResultViewController.swift:2506-2517; GenotypeCohortSummaryPanelView.swift:99-103`
**Problem:** "Suppress/flag low-abundance noise" is fixed and non-interactive on the MHC side, unlike 12S. A user cannot change the 5,000-read reliability line; it is a hardcoded constant used only to *label* samples, never to *filter*.
**Evidence:** `let belowThresholdValue = 5_000` (line 2506), fed into the cohort panel as a display-only flag (`GenotypeCohortSummaryPanelView.swift:99-103`, footnote "calls here may be unreliable"). Contrast 12S `minimumExactReads` (editable TextField+Stepper, `TwelveSResultDisplaySection.swift:235-254`) that live-filters rows. This is the brief's named example — captured as matrix row I1 and divergence D1.
**Suggested fix:** See divergence D1.
**Effort:** M

`UX-07 | P1 | MHC | GenotypeViewportExcelExportService.swift:111-117`
**Problem:** The genotype viewport Excel export does NOT shell out to `lungfish-cli`; it builds the XLSX in-process and stamps a synthetic `lungfish-gui` argv. 12S export shells to the real CLI and verifies the returned provenance came from `lungfish-cli`. Same user action ("Export current view"), two backing mechanisms — and the MHC one violates the binding rule "every scientific GUI action must shell out to `lungfish-cli`."
**Evidence:** `GenotypeViewportExcelExportService.export(...)` writes the workbook directly (`writeWorkbook`, line 97) and records `.argv(["lungfish-gui", "export-genotype-viewport", …])` (lines 111-117). Compare `TwelveSAmpliconResultExportService.swift:96-130` (real `LungfishCLIRunner.run`) and its provenance check requiring `envelope.toolName == "lungfish-cli"` (line 154). A CLI `genotype export-xlsx` already exists (`GenotypeExportXlsxSubcommand.swift`) but the viewport does not call it.
**Suggested fix:** See divergence D4. Route the viewport export through `genotype export-xlsx` (extend it to accept the visible-sample / lens filter set) so the GUI and CLI produce the same artifact and provenance.
**Effort:** M

`UX-08 | P1 | MHC | HaplotypeDefinitionManagerWindowController.swift:263-301 vs WorkflowOperationsDialog.swift:137-142`
**Problem:** "Build a reference bundle" has two unrelated entry points and two different sheets. To build a 12S reference bundle the user clicks "Create 12S Reference…" inside the run dialog; to build an MHC reference bundle they must leave the run dialog, open Tools -> Haplotype Definitions, select a definition, and click "Create Project Bundle…". A user who just selected a reference in the run dialog has no path to build an MHC bundle there.
**Evidence:** 12S builder launches from the dialog's reference picker (`WorkflowOperationsDialog.swift:138-141`, `TwelveSReferenceBundleBuilderSheet`); MHC builder lives only in the manager (`HaplotypeDefinitionManagerWindowController.swift:263`, `createMHCReferenceBundle`). Matrix row I12.
**Suggested fix:** See divergence D8. Offer "Create MHC Reference…" beside "Create 12S Reference…" in the run dialog (it can present the manager's create flow), or move both builders behind one consistent "Create reference bundle" affordance.
**Effort:** M

`UX-09 | P2 | MHC | HaplotypeDefinitionManagerWindowController.swift:135,156,253,311; HaplotypeDefinitionsCommand.swift:16-28; FastqMHCReferenceBundleSubcommand.swift:5-9`
**Problem:** Provenance-argv terminology drift confuses a user reading the audit trail. The manager records three different executable names and two different command namespaces for the same bundle-creation family.
**Evidence:** manager argvs use bare `"lungfish"` for import/export/duplicate (lines 135,156,182), `"lungfish-cli"` for bundle ops (lines 211,253,311); and the MHC bundle can be created via either `fastq mhc-reference-bundle` (`FastqMHCReferenceBundleSubcommand.swift:7`) or `haplotypes bundle-create` (`HaplotypeDefinitionsCommand.swift:21`) — the manager uses the latter (line 311). Per memory the canonical argv prefix is `lungfish-cli`.
**Suggested fix:** Normalize all manager argvs to `lungfish-cli`; pick ONE canonical CLI path for MHC bundle creation and deprecate/alias the other.
**Effort:** S

`UX-10 | P2 | MHC | GenotypeResultDisplaySection.swift:288-321 + GenotypeDropoutThresholdSection.swift:33-89 + GenotypeCohortSummaryPanelView.swift:99`
**Problem:** Within the MHC surface alone there are THREE different "low read / low support" controls a user must reconcile: (a) "Hide Low Support" % (live slider+field, Display section), (b) "Dropout thresholds" absolute-reads / %-sample / %-locus (Apply-button gated, Analyst section), (c) the fixed 5K cohort flag. They use three widget styles (live slider, apply-gated stepper+slider, static label) and three semantics. This is internal inconsistency that makes the threshold model hard to learn.
**Evidence:** Display section `minimumSupportPercent` Slider+TextField, live via `setMinimumSupportPercent` (lines 288-310); dropout section Stepper "X reads" + Sliders behind an "Apply thresholds" button (lines 38-89); cohort 5K label (GenotypeCohortSummaryPanelView.swift:99). Captured as matrix rows I1/I2/I3.
**Suggested fix:** See divergences D1 + D3 (unify live-vs-apply and labeling for all read/support thresholds).
**Effort:** M

**MHC flow verdict:** The genotype explore experience is rich (lens switch, quick filter, smart cohorts, manual haplotyping, override+audit). The friction is at the seams: the bundle does not yet feel like a single selectable input (UX-05), the export is not CLI-backed like its sibling (UX-07), and "low read" thresholds proliferate (UX-10). The haplotype manager itself is internally consistent and fully CLI-backed.

---

## PART 2 — THE OPERATION-INTENT MATRIX

Rows = operation intent. Columns = surface. Each cell records *widget/flag · label ·
live-or-apply · backing state/CLI flag · file:line*. Verdict column states
DIVERGENT or CONSISTENT explicitly (no silence). "Shared idiom exists?" notes
whether LGE already has a canonical pattern.

Legend: `live` = applies on change; `apply` = gated by a button; `n/a` = intent
not present on that surface.

| # | Intent | 12S surface(s) | MHC genotype surface(s) | Existing LGE idiom? | Verdict |
|---|--------|----------------|-------------------------|---------------------|---------|
| I1 | Suppress low-abundance reads (primary count threshold) | Inspector TextField+Stepper "Minimum Exact Reads", live, `displayState.minimumExactReads`, CLI `--min-exact-reads`. `TwelveSResultDisplaySection.swift:235-254`, `FastqTwelveSExportSubcommands.swift:23` | Fixed const `5_000` flag-only (no filter); `belowThresholdValue` label. `GenotypeResultViewController.swift:2506`, `GenotypeCohortSummaryPanelView.swift:99` | No single shared min-reads idiom; variant DB uses query `limit` not a UI filter | **DIVERGENT** (editable live filter vs hardcoded display flag) |
| I2 | Suppress low-*support* calls (% threshold) | n/a (12S has no support %) | "Hide Low Support" toggle + Slider + TextField "%", live, `minimumSupportPercent`/`hideLowSupport`. `GenotypeResultDisplaySection.swift:273-310` | none shared | **DIVERGENT** (present MHC-only; and disagrees with I3 on live-vs-apply within MHC) |
| I3 | Dropout / per-locus low-support thresholds | n/a | Stepper "reads" + Sliders %-sample/%-locus + per-locus EQ, **Apply** button, `GenotypeDropoutEvaluator`. `GenotypeDropoutThresholdSection.swift:34-89` | none shared | **DIVERGENT** (apply-gated vs every other threshold being live) |
| I4 | Free-text search of results | Inspector-only TextField "Filter species or matches", live, `displayState.filterText`, CLI `--filter`. `TwelveSResultDisplaySection.swift:257-263`; viewport has NO search field (VC grep empty) | Viewport `NSSearchField` "Search samples, haplotypes…", debounced-live, `quickFilterSearchText`. `GenotypeQuickFilterBarView.swift:91,115`; no Inspector search | Variant smart-filter is a text query box; classifier surfaces have search | **DIVERGENT** (Inspector field vs viewport bar; opposite placement) |
| I5 | Switch which result view is shown | `NSSegmentedControl` Targets/Unresolved, `modeControl`. `TwelveSAmpliconResultViewController.swift:15-20,345` | `NSSegmentedControl` Summary/Review/Audit, `lensControl`. `GenotypeResultViewController.swift:18-23,666` | Segmented mode switch is a standard LGE result idiom | **CONSISTENT** (same widget, same placement) |
| I6 | Sort result rows | Static columns, no sortDescriptor. `TwelveSAmpliconResultViewController.swift:454-477` | Column-header sort via `NSSortDescriptor` prototypes. `GenotypeComparisonMatrixView.swift:320,337,521` | NSTableView header-sort is the app-wide table idiom | **DIVERGENT** (no sort vs header sort) |
| I7 | Group results by category | Implicit grouping by mode only; taxon group used for filter not grouping | Outline groups by sample; matrix groups by genotype×locus. `GenotypeOutlineView`, `GenotypeComparisonMatrixView` | none shared | **DIVERGENT** (12S has no grouping; MHC has structural grouping) — accept as domain difference, see notes |
| I8 | Include/exclude rows by category | Two `Menu` pickers Include/Exclude taxon groups, live, `included/excludedTaxonGroups`, CLI `--taxon-group`/`--exclude-taxon-group`. `TwelveSResultDisplaySection.swift:281-305` | Toggle "pills" (Has errors, Homozygous, Recombinant, Bw6+, Has comments, Duplicate), live, `SmartCohortPredicate`. `GenotypeQuickFilterBarView.swift:15-44` | none shared | **DIVERGENT** (dual include/exclude menus vs single-state pill toggles) |
| I9 | Boolean attribute filters (human, alternates) | Toggles "Exclude Human", "Only Rows With Alternates", live, flags + CLI `--exclude-human`/`--require-alternate-matches`. `TwelveSResultDisplaySection.swift:269-279` | Pills (errors/homozygous/etc.) cover analogous boolean predicates. `GenotypeQuickFilterBarView.swift:15-44` | none shared | **DIVERGENT** (SwiftUI Toggle list vs AppKit pill buttons) |
| I10 | Filter unresolved/unmatched items by status | Inspector Stepper "Minimum Unresolved Reads" + `Picker` chimera status, live, CLI `--min-unresolved-reads`/`--chimera-status`. `TwelveSResultDisplaySection.swift:309-347` | Analyst status flags (Unflagged/Needs Review/Reviewed/Confirmed) segmented in Inspector Selection tab. `GenotypeStatusFlagSection.swift:50-55` | none shared | **DIVERGENT** (read-threshold+picker vs segmented status set; different intent shape but same "narrow by status") |
| I11 | Save / recall a named filter set | Not available (no saved-filter concept; `TwelveSResultDisplayState` has no persistence). `TwelveSResultDisplayState.swift:44-85` | "Smart Cohorts" save/recall with star + count + saved-chip in filter bar. `GenotypeSmartCohortSection.swift:14-58`, `GenotypeQuickFilterBarView.swift:187-197` | none shared | **DIVERGENT** (absent vs full saved-cohort system) — gap on 12S side |
| I12 | Build a reference bundle (.lungfish*ref) | Button "Create 12S Reference…" in run dialog -> `TwelveSReferenceBundleBuilderSheet`. `WorkflowOperationsDialog.swift:138-141,102-114` | Button "Create Project Bundle…" in Haplotype Manager -> NSOpenPanel+NSSavePanel flow. `HaplotypeDefinitionManagerWindowController.swift:263-301,588` | `.lungfishref` is built by import/orient flows, not a single shared builder | **DIVERGENT** (in-dialog sheet vs separate manager window) |
| I13 | Select a reference for a run | Shared run-dialog `referencePicker` (project Picker + Choose/Replace/Clear NSOpenPanel). `WorkflowOperationsDialog.swift:117-153,520-536` | Same shared `referencePicker`; accepts `.lungfishref` and `.lungfishmhcref`. `WorkflowOperationsDialog.swift:117-153`; `WorkflowOperationDialogState.setReference:453-470` | The dialog IS the shared idiom (note: not `ReferenceSequencePickerView`, but shared between the two) | **CONSISTENT** (identical control) |
| I14 | Prepare/launch a run | Shared `WorkflowOperationsDialog` sections (inputs/primary/advanced/output/readiness), Run button. `WorkflowOperationsDialog.swift:61-101` | Same shared dialog; per-tool `primarySettings`/`advancedSettings` branches. `WorkflowOperationsDialog.swift:226-369` | The dialog is the app-wide run idiom | **CONSISTENT** (same shell, per-tool fields) |
| I15 | Set run-time matching/mapping params | "Min Soft Clip", "Max Indels", "Run vsearch chimera review" — TextFields/Toggle, CLI `--min-soft-clip`/`--max-indels`/`--chimera-review`. `WorkflowOperationsDialog.swift:238-242,343-351` | "Min Support", "Threads", mode/read-type pickers, minimap2 extra-args, CLI `--min-support`/`--mode`/`--extra-args`. `WorkflowOperationsDialog.swift:228-237,330-342` | Shared `labeledCompactTextField`/`labeledTextField` helpers used by both | **CONSISTENT** (same field helpers; values differ by domain, expected) |
| I16 | Export the current view | Action-bar Export button -> `NSMenu` of CSV/TSV/Excel -> NSSavePanel -> shells to `fastq 12s-export` (provenance verified). `TwelveSAmpliconResultViewController.swift:287,685-709`; `TwelveSAmpliconResultExportService.swift:96-168` | `exportExcelView` -> NSSavePanel -> in-process `GenotypeViewportExcelExportService` (`lungfish-gui` argv, no CLI shell). `GenotypeResultViewController.swift:3337-3361`; `GenotypeViewportExcelExportService.swift:97,111-117` | `ClassifierActionBar.onExport` is the shared export affordance (12S uses it; genotype does not) | **DIVERGENT** (CLI-backed multi-format menu vs in-process single-format, different provenance) |
| I17 | Export full bundle (CLI) | `fastq 12s-export` (csv/tsv/xlsx via `--export-format`), single subcommand with filter flags. `FastqTwelveSExportSubcommands.swift:8-48` | `genotype export-xlsx` + `export-pivot-xlsx` + `export-labkey` — three subcommands, no filter flags. `GenotypeCommandGroup.swift:25-27`, `GenotypeExportXlsxSubcommand.swift:24-34` | none shared | **DIVERGENT** (one format-flag command vs three fixed-format commands; filters supported vs not) |
| I18 | Drill into per-item evidence | Detail pane (right split) + two disclosure rows "Sample Evidence (n)" / "Alternate Exact Matches (n)" listing per-sample reads/%. `TwelveSAmpliconResultViewController.swift:233-269,504-540` | Detail pane + `GenotypeSampleDetailSheet` / `GenotypeCallEvidenceView` (per-call support, overrides). `GenotypeResultViewController.swift:570-635`; `GenotypeSampleDetailSheet.swift:14-35` | Split-view detail pane is a common LGE pattern | **CONSISTENT** (both: master table + detail pane; sheet for deep edit is MHC-only and acceptable) |
| I19 | Selection-detail empty state | Body label "Select a target/cluster to review…". `TwelveSAmpliconResultViewController.swift:486,496` | Caption "Select a genotype row to review shared support." + "No haplotype calls available…". `GenotypeResultViewController.swift:1323`; `GenotypeOutlineView.swift:344` | Plain prompt label is common | **CONSISTENT** (same plain-prompt idiom; copy differs) |
| I20 | Empty/zero-results state (table) | Table shows 0 rows; summary "0 of N", action bar "0 of N target rows". `TwelveSAmpliconResultViewController.swift:580,388-401` | Outline placeholder text; lens still renders. `GenotypeOutlineView.swift:344` | Manager uses `ContentUnavailableView`; result tables use plain labels | **DIVERGENT (minor)** (12S "X of Y" counter vs MHC placeholder text; neither uses `ContentUnavailableView` the manager uses) |
| I21 | Error state on export/action | `NSAlert(error:)` "12S Export Failed". `TwelveSAmpliconResultViewController.swift:840-845` | `NSAlert(error:)` sheet on export/override failures. `GenotypeResultViewController.swift:2014-2018,3352-3357` | `NSAlert` is the app-wide error idiom | **CONSISTENT** |
| I22 | Provenance / run summary surface | Action-bar Provenance button -> `NSPopover` (SwiftUI summary). `TwelveSAmpliconResultViewController.swift:290-292,711-720` | Inspector Document tab: artifact rows + audit timeline (`GenotypeResultDocumentSection`, `GenotypeAuditTimelineSection`). `InspectorViewController.swift:1460-1481` | `ClassifierActionBar.onProvenance` popover is the shared idiom (12S uses it) | **DIVERGENT** (action-bar popover vs Inspector document tab) |
| I23 | Result-launch from sidebar | `.twelveSAmpliconResultBundle`, icon `tablecells`, teal tint. `SidebarViewController.swift:1438,3724` | `.genotypeResultBundle`, icon `tablecells.badge.ellipsis`, orange tint. `SidebarViewController.swift:1436,3723` | Sidebar bundle-type registration is the shared idiom | **CONSISTENT** (same registration mechanism; icon/tint differ per type, expected) |
| I24 | Reference-bundle format registration | `lungfish12SRef` FormatIdentifier (ext+mime). `FormatIdentifier.swift:331-335` | `lungfishMHCRef` FormatIdentifier (ext+mime), parallel to `lungfishRef`. `FormatIdentifier.swift:324-341` | `lungfishRef` is the template | **CONSISTENT** (identical declaration shape) |
| I25 | Manage definition library (CRUD) | n/a (12S reference has no managed-definition library) | Haplotype Manager: New/Import/Export/Duplicate/Delete/Edit, scope built-in/global/project, all CLI-backed. `HaplotypeDefinitionManagerWindowController.swift:120-348`; `HaplotypeDefinitionsCommand.swift` | none shared | **DIVERGENT (by domain)** (MHC-only; acceptable — 12S has no per-definition library) |
| I26 | Manage-library entry point | n/a | "Manage…" button in run dialog -> Tools menu action -> manager window. `WorkflowOperationsDialog.swift:282-285` | menu-action-to-window is a standard pattern | **CONSISTENT (within MHC)** / n/a for 12S |
| I27 | Cancel a long-running sub-action | BLAST drawer Cancel -> `onUnresolvedBlastCancelRequested` -> `OperationCenter.cancel`. `TwelveSAmpliconResultViewController.swift:651-653`; `ViewerViewController+TwelveS.swift:60-62,129` | Genotyping runs via run dialog/OperationCenter; no in-viewport long-action cancel (export is synchronous). | `OperationCenter` cancel is the shared idiom | **CONSISTENT** (both defer to OperationCenter; 12S additionally surfaces a drawer cancel because it has an in-viewport async action) |
| I28 | External sequence verification (BLAST) | Full BLAST flow: action-bar Verify -> `BlastResultsDrawerContainerView`/`BlastResultsDrawerTab` bottom drawer, CLI-prepared FASTA. `TwelveSAmpliconResultViewController.swift:182-198,610-655`; `ViewerViewController+TwelveS.swift:31-130` | No BLAST affordance (grep for `BlastResultsDrawer`/`onBlast` in Genotype views returns nothing). | The bottom BLAST drawer is the shared classifier idiom | **DIVERGENT (by domain)** (12S verifies unknowns via BLAST; MHC genotyping has no unknown-sequence verification need — acceptable, stated explicitly) |
| I29 | Adjust result layout (panes) | Vertical `NSSplitView` table|detail, not user-reconfigurable beyond drag. `TwelveSAmpliconResultViewController.swift:302-306` | Inspector `Picker` List|Detail / Detail|List / List-over-Detail, `GenotypeResultPanelLayout`. `GenotypeResultDisplaySection.swift:254-264` | none shared | **DIVERGENT** (fixed split vs configurable layout) — accept (MHC has richer panes) |
| I30 | Color/visual-encoding controls | None (plain table cells). `TwelveSAmpliconResultViewController.swift:825-838` | Cell-color mode (Support/Highlights/None) + per-cell highlight color wells. `GenotypeResultDisplaySection.swift:336-425` | none shared | **DIVERGENT (by domain)** (MHC haplotype coloring is domain-specific; 12S has no analog — acceptable) |

**Totals:** 30 intents enumerated. **CONSISTENT: 11** (I5, I13, I14, I15, I18, I19, I21, I23, I24, I26, I27). **DIVERGENT: 19** (I1, I2, I3, I4, I6, I7, I8, I9, I10, I11, I12, I16, I17, I20, I22, I25, I28, I29, I30). Of the 19 divergent, **8 are domain-justified** (I2, I3, I7, I25, I28, I29, I30, and the MHC-only half of I11/I10) and **11 are true convergence targets** (see Part 3).

---

## PART 3 — Divergence list (P1 convergence items)

Each is a DIVERGENT intent that is NOT purely domain-justified. Recommended
shared idiom given for each. Ordered by user impact.

`D1 — Low-abundance/min-read filter (I1)`
**Surfaces:** 12S editable live `minimumExactReads` (`TwelveSResultDisplaySection.swift:235-254`) vs MHC hardcoded `5_000` display flag (`GenotypeResultViewController.swift:2506`).
**Recommended shared idiom:** A reusable Inspector "minimum reads" control (TextField+Stepper, live) bound to display state on BOTH surfaces. On MHC, add `minimumReads` to `GenotypeResultDisplayState` and have the cohort panel's flag track that same value (default 5,000) instead of a constant. The brief's named row.

`D2 — Free-text search placement (I4)`
**Surfaces:** 12S Inspector-only filter field vs MHC viewport search bar.
**Recommended shared idiom:** Adopt the viewport search bar as the canonical "find a row" surface for both (genotype's `GenotypeQuickFilterBarView` pattern, or a shared `ResultSearchFieldView`). Keep the Inspector field as a mirror or remove it. Pick ONE primary placement so the two workflows teach the same gesture.

`D3 — Live-vs-apply inconsistency for thresholds (I2+I3 within MHC)`
**Surfaces:** "Hide Low Support" % is live (`GenotypeResultDisplaySection.swift:288-310`); "Dropout thresholds" is Apply-gated (`GenotypeDropoutThresholdSection.swift:85`).
**Recommended shared idiom:** Choose one interaction contract for all threshold controls. Recommend live-with-debounce (matches 12S and Hide-Low-Support); if dropout must batch for cost reasons, make that explicit and apply the same batched pattern anywhere else expensive. Document the contract once.

`D4 — Viewport export not CLI-backed (I16)`
**Surfaces:** 12S shells to `fastq 12s-export` and verifies `lungfish-cli` provenance (`TwelveSAmpliconResultExportService.swift:96-168`); MHC builds XLSX in-process with a `lungfish-gui` argv (`GenotypeViewportExcelExportService.swift:111-117`).
**Recommended shared idiom:** Route the genotype viewport export through the existing `genotype export-xlsx` CLI (extended to take the visible-sample/lens filter projection), exactly as 12S routes through its CLI exporter. Same provenance verification (`toolName == "lungfish-cli"`). Satisfies the binding "every scientific GUI action shells to lungfish-cli" rule.

`D5 — Result table sorting (I6)`
**Surfaces:** 12S static columns vs genotype matrix header-sort.
**Recommended shared idiom:** Add `sortDescriptorPrototype` to the 12S columns and implement `sortDescriptorsDidChange`, matching `GenotypeComparisonMatrixView` and every other NSTableView result surface in LGE.

`D6 — Include/exclude + boolean filters (I8+I9)`
**Surfaces:** 12S dual Include/Exclude `Menu`s + SwiftUI `Toggle`s vs MHC AppKit pill buttons.
**Recommended shared idiom:** A shared "filter chip/pill row" component used by both viewports for categorical include/exclude and boolean predicates. Either generalize `GenotypeQuickFilterBarView`'s pill row into a reusable control, or give both the same SwiftUI multi-select. One categorical-filter idiom, two predicate sets.

`D7 — Saved filter / cohort recall (I11)`
**Surfaces:** MHC has full Smart Cohorts save/recall (`GenotypeSmartCohortSection.swift`); 12S has none.
**Recommended shared idiom:** Extract a generic "saved filter set" service (name + scope + serialized predicate + match count + saved-chip) and add it to 12S so a user can save "freshwater fish, ≥50 reads" the way they save a genotype cohort. Reuse the saved-chip UI from the quick-filter bar.

`D8 — Reference-bundle builder entry point (I12)`
**Surfaces:** 12S builder in the run dialog (`WorkflowOperationsDialog.swift:138-141`) vs MHC builder in the manager window (`HaplotypeDefinitionManagerWindowController.swift:263`).
**Recommended shared idiom:** Surface both builders from the same place. Add "Create MHC Reference…" beside "Create 12S Reference…" in the run dialog's reference picker (it can drive the manager's create flow), so "I need to make a reference bundle" is one consistent affordance regardless of workflow.

`D9 — Bundle-export CLI command shape (I17)`
**Surfaces:** 12S one `12s-export` with `--export-format` + filter flags vs MHC three fixed-format subcommands with no filter flags.
**Recommended shared idiom:** Converge on one shape. Recommend a single `genotype export --format xlsx|pivot-xlsx|labkey` that accepts the same filter flags 12S exposes (min-reads, search, include/exclude), mirroring `12s-export`. Keeps the CLI mental model identical across workflows and unblocks D4.

`D10 — Provenance/run-summary surface (I22)`
**Surfaces:** 12S action-bar provenance popover (`TwelveSAmpliconResultViewController.swift:711-720`) vs MHC Inspector Document tab.
**Recommended shared idiom:** Pick one canonical "where do I see provenance for this result" location. Recommend the Inspector Document tab as the richer home and add a 12S Document-tab section (artifacts + provenance) so both match; or give both the action-bar popover. Today a user learns two different places.

`D11 — Argv executable-name / command-namespace drift (UX-09)`
**Surfaces:** manager argvs mix `lungfish` and `lungfish-cli`; MHC bundle creation has two CLI paths.
**Recommended shared idiom:** Normalize every recorded argv to `lungfish-cli` (memory rule) and designate one canonical MHC-bundle-create subcommand. Pure provenance-consistency cleanup.

**Domain-justified divergences explicitly accepted (not convergence targets):**
I2/I3 existence (MHC has support/dropout concepts 12S lacks), I7 grouping, I25
managed-definition library, I28 BLAST verification, I29 configurable panes, I30
haplotype color encoding, and I20's minor counter-vs-placeholder copy. These are
called out so their consistency status is *stated*, per the spec's "silence is
not allowed" rule.

---

## Notes for synthesis

- The brief's three pre-identified findings all reproduce: opt-in default (UX-01),
  `.lungfishmhcref` consume-side gap (UX-05), abundance-filter divergence (D1/I1).
- The single highest-leverage convergence is **D4 (CLI-backed export)** because it
  also fixes a binding-rule violation and unblocks **D9**.
- The most user-visible "two different apps" feeling comes from **D2 (search
  placement)** and **D10 (provenance location)** — a user moving between the two
  result viewports has to relearn where to search and where to find provenance.
- 11 of 30 intents are already consistent, largely because both workflows share the
  run-prep dialog (I13/I14/I15), the segmented view switch (I5), `NSAlert` (I21),
  and the format registry (I24). The shared run dialog is the strongest existing
  convergence and a good template for the rest.
