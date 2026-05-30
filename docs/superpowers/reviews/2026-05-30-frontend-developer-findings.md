# Frontend-Developer Findings — UI Idiom Reuse + Widget-Level Operation Matrix

**Reviewer lens:** AppKit/SwiftUI idiom reuse + the widget-level side of the
operation-intent matrix.
**Surfaces:** 12S amplicon matching (viewport + Inspector + workflow dialog) and
MHC/KIR genotype (viewport + Inspector + haplotype manager), compared against each
other and against the rest of LGE (classifiers, mapping, assembly).
**Mode:** Read-only. No code changed.

---

## 1. Summary

The two new/changed surfaces sit on **opposite ends of the idiom-reuse spectrum**, and
that is the headline finding.

- **12S is a faithful classifier clone.** `TwelveSAmpliconResultViewController` reuses
  the canonical metagenomics idiom almost verbatim: title + `NSSegmentedControl` mode
  switch, `NSSplitView(table | detail)`, `ClassifierActionBar` (BLAST/Export/Provenance),
  and the shared bottom `BlastResultsDrawerContainerView`/`BlastResultsDrawerTab`. Its
  Inspector section (`TwelveSResultDisplaySection`) mirrors the `@Observable` view-model +
  `DisclosureGroup` pattern and reuses `SampleMetadataSection`. This is the reuse bar the
  rest of the work should be measured against.
- **The genotype viewport is almost entirely bespoke.** `GenotypeResultViewController`
  reinvents nearly every shared idiom: a lens `NSSegmentedControl` (3 lenses) instead of
  the classifier mode control, a custom `GenotypeQuickFilterBarView` (in-viewport
  `NSSearchField` + pill buttons + saved-cohort chip) for search/include-exclude, a
  hand-built `GenotypeCohortSummaryPanelView` for the detail pane, a bespoke
  "Export Excel View..." `NSButton` instead of `ClassifierActionBar.onExport`, and **no
  `ClassifierActionBar` and no BLAST drawer at all**. Some of this is justified by the
  genuinely richer genotype problem (three lenses, manual haplotyping, annotation sidecar);
  much of it is not.
- **The low-abundance filter is one of at least six diverging intents.** The candidate
  finding (12S editable `minimumExactReads` TextField+Stepper vs MHC hardcoded ~5K
  `belowThresholdValue`) is real, but the same class of divergence recurs in free-text
  search placement, include-exclude controls, export affordance, threshold-breach accent
  color, and the detail/selection pane. The full matrix is in section 2.

Net: 12S needs only polish (P2) on idiom reuse plus one P1 (in-viewport search placement);
the genotype surface carries the bulk of the P1 idiom-mismatch debt, and the two workflows
diverge on most shared operation intents.

Two surfaces reviewed and found **idiom-clean for my lens** (stated explicitly so silence
is not mistaken for an omission):
- The **12S workflow dialog** (`WorkflowOperationsDialog`) correctly rides the shared
  `DatasetOperationsDialog` scaffold and matches the ONT-genotyping detail-pane layout
  field-for-field. Its one reuse gap (reference picker) is shared with the genotyping path,
  so it is a pre-existing cross-cutting issue, not a 12S regression (F-09, P2).
- The **haplotype manager** (`HaplotypeDefinitionManagerWindowController`) uses the standard
  master/detail `Table` + `HSplitView` + toolbar idiom and is internally consistent. One
  P2 (delete-button color token drift) noted.

---

## 2. Widget-Level Operation-Intent Table

Columns: Operation intent | 12S control | MHC/genotype control | Existing LGE idiom | Verdict | Target shared idiom.

"Existing LGE idiom" names the surface that already solves this elsewhere (classifiers,
mapping, assembly) so convergence has a concrete anchor.

| # | Operation intent | 12S control | MHC/genotype control | Existing LGE idiom | Verdict | Target shared idiom |
|---|---|---|---|---|---|---|
| A | **Suppress low-abundance noise (primary)** | Editable `minimumExactReads` `TextField`+`Stepper` (Inspector, `TwelveSResultDisplaySection` L234-254) → live row filter | Hardcoded ~5K `belowThresholdValue` (`GenotypeCohortSummaryPanelView` L13-15,99); only *flags* samples, not editable. Separate `GenotypeDropoutThresholdSection` exposes editable absolute-reads `Stepper` (L34-44) but feeds the analyzer, not a display filter | Inspector `@Observable` filter view-model + `TextField`+`Stepper` (12S) | **DIVERGENT** | Editable Inspector reads-threshold control (`TextField`+`Stepper`) on `GenotypeResultDisplayState`, mirroring 12S `minimumExactReads`. Genotype's flag-only ~5K should become a user-editable display threshold. |
| B | **Suppress low-support reads (% based)** | None (12S has no % control) | `minimumSupportPercent` `TextField`+`Slider` + `hideLowSupport` toggle (`GenotypeResultDisplaySection` L271-311) and `sampleFraction`/`locusFraction` `Slider`s (`GenotypeDropoutThresholdSection`) | Inspector `TextField`+`Slider` (genotype) | N/A (genotype-only intent) | Keep genotype's `TextField`+`Slider`; if 12S ever adds a % threshold, reuse this exact pairing rather than a new one. |
| C | **Free-text search across rows** | Inspector `TextField` "Filter species or matches" (`TwelveSResultDisplaySection` L257, id `twelve-s-filter-field`) | In-**viewport** `NSSearchField` with debounce + query DSL (`GenotypeQuickFilterBarView` L91,115-118,229-242) | Classifier in-viewport `NSSearchField` (`TaxTriageResultViewController.organismSearchField` L1030-1032, "Filter organisms…") | **DIVERGENT (3-way)** | In-viewport `NSSearchField` is the established classifier idiom. 12S should host search in the viewport header (next to its mode control) like TaxTriage, not in the Inspector. Genotype already matches the classifier idiom. |
| D | **Include/exclude by category** | Taxon-group `Menu` of `Toggle`s — separate "Include" + "Exclude" menus (`TwelveSResultDisplaySection` L281-305) | Pill `NSButton`s (`pushOnPushOff`) for `hasErrors`/`homozygous`/`recombinant`/`bw6Positive`/etc. (`GenotypeQuickFilterBarView` L15-44,167-174) | None canonical — two new patterns | **DIVERGENT** | Pick one category-toggle idiom. Pill row (genotype) is the more discoverable, viewport-resident pattern; 12S taxon-groups would read better as an inline pill row than as two hamburger menus. Converge both on the pill-row idiom. |
| E | **Boolean attribute filter** | `Toggle("Exclude Human")` + `Toggle("Only Rows With Alternates")` (Inspector, L269-279) | Boolean predicates expressed as pills (`Has errors`, `Has comments`) in viewport bar | None canonical | **DIVERGENT** | Same as D: a boolean attribute filter is just a category pill. "Exclude Human" and "Only With Alternates" should be pills in the same row as the taxon groups, matching genotype's pill model. |
| F | **Secondary reads threshold (unmatched/unresolved)** | `minimumUnresolvedReads` `TextField`+`Stepper` (Inspector, L315-335) — identical widget to intent A | (no analog; genotype has no "unresolved" tier) | Inspector `TextField`+`Stepper` (12S) | **CONSISTENT (internal)** | Already shares 12S's own threshold idiom. No change; verifies the threshold idiom is reusable. |
| G | **Status/category enum picker** | Chimera `Picker(.menu)` (`TwelveSResultDisplaySection` L338-347) | Support-`Denominator` `Picker(.menu)` + `cellColorMode` `Picker(.segmented)` (`GenotypeResultDisplaySection` L323-351) | SwiftUI `Picker` (both menu + segmented used across app) | **CONSISTENT** | Both use SwiftUI `Picker`. Minor: standardize on `.menu` for >3 options, `.segmented` for ≤3. No structural divergence. |
| H | **Mode / lens switch in viewport** | `NSSegmentedControl` Targets/Unresolved (`TwelveSAmpliconResultViewController` L15-20,210-214) | `NSSegmentedControl` Summary/Review/Audit (`GenotypeResultViewController` L18-23,501-507) | Classifier `NSSegmentedControl` mode switch | **CONSISTENT** | Both use a header `NSSegmentedControl`. Aligned with the classifier idiom. No change. |
| I | **Export current view** | `ClassifierActionBar.onExport` → `NSMenu` with CSV/TSV/Excel (`TwelveSAmpliconResultViewController` L685-704; formats in `TwelveSAmpliconResultExportFormat`) | Bespoke "Export Excel View..." `NSButton` embedded in a lens stack → single `.lungfishexport` package (`GenotypeResultViewController` L3323-3361) | `ClassifierActionBar` Export button + format `NSMenu` (12S, NAO-MGS, EsViritu, TaxTriage) | **DIVERGENT** | Genotype should route export through a `ClassifierActionBar`-style bottom bar Export button with a format menu, not a button buried in lens content. (Tied to finding F-02: genotype has no action bar.) |
| J | **Provenance access** | `ClassifierActionBar.onProvenance` → `NSPopover` with `TwelveSProvenanceSummaryView` (`TwelveSAmpliconResultViewController` L290-292,711-720) | No viewport provenance affordance; provenance shown only as an Audit-lens artifact row + Inspector `ProvenanceSection` (`GenotypeResultViewController` L1471) | `ClassifierActionBar` Provenance `info.circle` button + popover | **DIVERGENT** | Genotype should expose the same `ClassifierActionBar` Provenance button/popover for parity with every classifier and with 12S. |
| K | **Selection-detail pane** | `NSStackView` of labels + two `NSButton` disclosure rows (`TwelveSAmpliconResultViewController` L233-269,504-540) | `GenotypeCohortSummaryPanelView` (custom `NSView`) for Outline + a `detailStack` of section rows for Matrix (`GenotypeResultViewController` L1253-1317) | Classifier detail pane = `NSStackView` of rows (matches 12S) | **DIVERGENT** | The genotype Outline cohort summary is a legitimately distinct artifact, but the Matrix `detailStack` and 12S detail pane are the same "labelled rows for the selected item" idiom built twice. Extract a shared detail-rows builder (P2). |
| L | **Disclosure-group usage** | SwiftUI `DisclosureGroup` (Inspector) **and** AppKit `NSButton(.disclosure)` (viewport detail, L271-278) | SwiftUI `DisclosureGroup` (Inspector + haplotype manager + dropout per-locus EQ) | SwiftUI `DisclosureGroup` (app-wide Inspector standard) | **DIVERGENT (internal to 12S)** | The viewport's two hand-rolled `NSButton` disclosure buttons (`detailSampleDisclosureButton`/`detailAlternatesDisclosureButton`) are a one-off. AppKit detail panes elsewhere use plain sections; if collapsibility is needed, match the classifier pattern rather than inventing disclosure buttons (P2). |
| M | **Threshold-breach / danger accent** | None (12S surfaces no danger color) | `NSColor.lungfishDanger` for below-threshold count + read-only banner (`GenotypeCohortSummaryPanelView` L131,153-154); `Color.accentColor` for active per-locus override (`GenotypeDropoutThresholdSection` L129) | Palette: Lungfish Orange `#D47B3A` accent; `lungfishDanger` for destructive/error | **MOSTLY CONSISTENT** | `lungfishDanger` for unreliable samples is correct. But `Color.accentColor` (system blue) at `GenotypeDropoutThresholdSection` L129 is **not** the Lungfish Orange accent — see F-07. 12S has no accent to check. |
| N | **Sample-metadata display** | `SampleMetadataSection` (reused) **plus** a parallel `sampleMetadataSourceSummary` text + sources/warnings block (`InspectorViewController` L4913-4958; VM L45-67) | `SampleMetadataSection` (reused, `GenotypeResultDocumentSection` + `InspectorViewController`) | `SampleMetadataSection` (shared) | **CONSISTENT (with 12S extra)** | Both reuse `SampleMetadataSection` — good. 12S layers an extra provenance-summary block that genotype lacks; harmless but a minor asymmetry (P2, F-08). |
| O | **Reference selection (dialog)** | Bespoke `Picker` + Choose/Replace/Clear buttons (`WorkflowOperationsDialog.referencePicker` L117-153) | Same bespoke `Picker` + buttons (shared dialog path) + haplotype `Picker`s | `ReferenceSequencePickerView` (used by `OrientWizardSheet`, `FASTQOperationToolPanes`) | **DIVERGENT (pre-existing, shared)** | The workflow dialog reinvents reference picking instead of using `ReferenceSequencePickerView`. Affects both workflows equally (it is one shared control), so it is cross-cutting, not 12S- or MHC-specific (F-09, P2). |
| P | **Export/Import/Duplicate/Delete management (manager window)** | (12S has no manager window; reference build is a one-shot `TwelveSReferenceBundleBuilderSheet`) | `HaplotypeDefinitionManagerView` toolbar `Button`/`Menu` (`HaplotypeDefinitionManagerWindowController` L498-528) + detail-pane action buttons | Master/detail `Table` + `HSplitView` + toolbar (manager-window idiom) | **CONSISTENT** | Manager window matches the standard idiom; 12S's builder sheet is a different (simpler) intent. No divergence, but see F-06 (delete color token). |

### Coverage statement

Every user-facing operation surfaced on either workflow is represented above. Intents that
are **already consistent** are stated as such (F, G, H, N partial, P). Intents that
**diverge** are A, C, D, E, I, J, K, L, M (partial), O. No operation was left unjudged.

---

## 3. Findings (brief schema)

Schema: `ID | Severity | Surface | Location | Problem | Evidence | Suggested fix | Effort`

---

**F-01 | P1 | cross-cutting (12S ↔ MHC) | `Sources/LungfishApp/Views/Results/Genotype/GenotypeCohortSummaryPanelView.swift:13-15,99-103` + `Sources/LungfishApp/Views/Inspector/Sections/TwelveSResultDisplaySection.swift:234-254`**

- **Problem:** The "suppress low-abundance noise" intent (matrix row A) uses two
  incompatible idioms. 12S exposes an editable Inspector `TextField`+`Stepper`
  (`minimumExactReads`) that live-filters target rows; genotype uses a *fixed*, hardcoded
  ~5K `belowThresholdValue` that only flags samples as unreliable and is not user-editable.
- **Evidence:** 12S — `TextField(value: minimumExactReads)` + `Stepper(in: 0...1_000_000)`
  (L234-254), filter applied at `TwelveSAmpliconResultViewController.targetMatchesDisplayState`
  L405. Genotype — `let belowThresholdValue: Int` defaulted to 5K, rendered as a read-only
  "Below 5.0K reads" count label (`GenotypeCohortSummaryPanelView` L99,131); no binding on
  `GenotypeResultDisplayState` exists for it.
- **Suggested fix:** Add an editable reads-threshold control to `GenotypeResultDisplayState`
  + `GenotypeResultDisplaySection` using the **same** `TextField`+`Stepper` pairing as 12S,
  driving the below-threshold flag (and ideally a live row filter). Converge both surfaces
  on one Inspector threshold idiom.
- **Effort:** M

---

**F-02 | P1 | MHC | `Sources/LungfishApp/Views/Results/Genotype/GenotypeResultViewController.swift` (whole viewport; cf. absence of `ClassifierActionBar`/`BlastResultsDrawerContainerView`)**

- **Problem:** The genotype viewport does not use `ClassifierActionBar` or the shared BLAST
  drawer, so its Export and Provenance affordances (matrix rows I, J) are reinvented and
  inconsistent with 12S and every classifier. Export is a lone "Export Excel View..."
  `NSButton` (L3328) embedded in lens content; provenance has no viewport entry point.
- **Evidence:** `grep` shows `ClassifierActionBar` used by 12S + 5 classifiers but **not**
  `GenotypeResultViewController`; `BlastResultsDrawerContainerView` likewise. Genotype
  export = `exportExcelView` (L3337-3361); 12S export = `ClassifierActionBar.onExport` →
  format `NSMenu` (L287-289,685-704). `ClassifierActionBar.swift` L1-18 documents itself as
  the "unified bottom action bar for all classifier result views."
- **Suggested fix:** Add a `ClassifierActionBar` (or a thin genotype-specific subclass) to
  the genotype viewport bottom for Export (format menu) + Provenance, matching 12S. The
  bar's BLAST button can be hidden where not applicable (12S already hides `extractButton`
  via `actionBar.extractButton.isHidden = true`, L281), so partial reuse is precedented.
- **Effort:** M

---

**F-03 | P1 | 12S | `Sources/LungfishApp/Views/Inspector/Sections/TwelveSResultDisplaySection.swift:257-264` vs `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift:1030-1032`**

- **Problem:** Free-text search (matrix row C) is placed in the **Inspector** for 12S but is
  an in-**viewport** `NSSearchField` for both the genotype surface and the canonical
  classifier (TaxTriage). The same intent lives in two different windows depending on
  workflow, so users learn the control twice.
- **Evidence:** 12S filter = `TextField("Filter species or matches")` in the Inspector
  section (L257, id `twelve-s-filter-field`). TaxTriage = `organismSearchField`
  (`NSSearchField`, "Filter organisms…") added to the viewport (`view.addSubview`).
  `GenotypeQuickFilterBarView` = viewport `NSSearchField` (L115). 12S viewport has **no**
  `NSSearchField` (confirmed: zero matches in `TwelveSAmpliconResultViewController`).
- **Suggested fix:** Move (or mirror) the 12S free-text filter into the viewport header as
  an `NSSearchField` next to the mode control, matching the classifier/genotype placement.
- **Effort:** S

---

**F-04 | P1 | cross-cutting (12S ↔ MHC) | `Sources/LungfishApp/Views/Inspector/Sections/TwelveSResultDisplaySection.swift:281-305` vs `Sources/LungfishApp/Views/Results/Genotype/GenotypeQuickFilterBarView.swift:15-44,167-174`**

- **Problem:** Include/exclude-by-category and boolean attribute filters (matrix rows D, E)
  use two unrelated idioms: 12S uses paired hamburger `Menu`s of `Toggle`s plus standalone
  `Toggle`s; genotype uses a horizontal row of `pushOnPushOff` pill `NSButton`s. Equivalent
  intent, divergent widget.
- **Evidence:** 12S — two `Menu { ForEach … Toggle }` blocks labelled "Include"/"Exclude"
  (L281-305) and `Toggle("Exclude Human")` (L269). Genotype — `Pill` enum + `makePillButton`
  producing `roundRect` toggle buttons in a scrollable `pillStack` (L126-130,167-174).
- **Suggested fix:** Converge on the pill-row idiom (more discoverable, viewport-resident).
  Render 12S taxon groups and the boolean toggles ("Exclude Human", "Only With Alternates")
  as pills in a shared pill bar. If the pill bar moves into the viewport, this also resolves
  C and E together.
- **Effort:** M

---

**F-05 | P2 | 12S | `Sources/LungfishApp/Views/Results/TwelveS/TwelveSAmpliconResultViewController.swift:28-31,271-278,349-357,561-568`**

- **Problem:** The 12S detail pane builds its own collapsible sections with hand-rolled
  `NSButton(bezelStyle:.disclosure, .pushOnPushOff)` buttons and manual `isHidden`
  bookkeeping (matrix row L). No other AppKit detail pane in LGE does this; the app-wide
  collapsible idiom is SwiftUI `DisclosureGroup`, and classifier detail panes use plain
  stacked rows.
- **Evidence:** `detailSampleDisclosureButton`/`detailAlternatesDisclosureButton`
  (L28-31), `configureDetailDisclosureButton` (L271-278), toggle handlers (L349-357),
  `setTargetDetailSectionsHidden` (L561-568). Compare the genotype/classifier detail panes
  which are flat `NSStackView` rows.
- **Suggested fix:** Drop the bespoke disclosure buttons in favor of plain sections (as the
  classifier detail panes do) or, if collapsibility is required, factor a small shared
  AppKit disclosure-section helper used by both surfaces.
- **Effort:** S

---

**F-06 | P2 | MHC | `Sources/LungfishApp/Views/WorkflowOperations/HaplotypeDefinitionManagerWindowController.swift:604-605`**

- **Problem:** The manager's Delete button colors itself with `Color.lungfishDangerFallback`
  via `.foregroundStyle` **and** `.tint`. Elsewhere destructive SwiftUI buttons use a single
  channel (usually `.tint` or `role: .destructive`); doubling fill + tint is a one-off and
  can render inconsistently across control styles.
- **Evidence:** `.foregroundStyle(Color.lungfishDangerFallback).tint(Color.lungfishDangerFallback)`
  (L604-605). Other destructive buttons (e.g. `StorageSettingsTab` L207) use only `.tint`.
- **Suggested fix:** Use a single danger channel (prefer `role: .destructive` or `.tint`
  alone) for consistency with other destructive buttons.
- **Effort:** S

---

**F-07 | P2 | MHC | `Sources/LungfishApp/Views/Inspector/Sections/GenotypeDropoutThresholdSection.swift:129`**

- **Problem:** The per-locus EQ override value uses `Color.accentColor` (system blue) to
  signal an active override (matrix row M). Project memory mandates Lungfish Orange
  `#D47B3A` (`lungfishOrange`, dark `#E8A06A`) for GUI accents. System `accentColor` is not
  guaranteed to be the Lungfish accent.
- **Evidence:** `.foregroundStyle(override != nil ? Color.accentColor : Color.secondary)`
  (L129). Brand rule: "All GUI accents must use" Lungfish Orange (project memory + brand
  style guide).
- **Suggested fix:** Replace `Color.accentColor` with the Lungfish Orange accent token
  (e.g. `Color.lungfishOrangeFallback`) so the active-override indicator matches the brand
  accent used elsewhere.
- **Effort:** S

---

**F-08 | P2 | 12S | `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift:4913-4958`; VM `Sources/LungfishApp/Views/Inspector/Sections/TwelveSResultDisplaySection.swift:45-67`**

- **Problem:** 12S reuses `SampleMetadataSection` (good, matrix row N) but also renders a
  parallel metadata-source summary + sources + warnings block that the genotype surface does
  not have. The asymmetry means the two workflows present sample metadata provenance
  differently.
- **Evidence:** `twelveSSamplesMetadataSection` builds `metadataRow("Metadata", …)`,
  `sampleMetadataSourceDetails`, `sampleMetadataWarnings` (L4916-4943) on top of
  `SampleMetadataSection`. Genotype shows only `SampleMetadataSection`.
- **Suggested fix:** Either promote the metadata-source/warnings summary into a shared
  component both workflows render, or drop it to a tooltip/footnote so the metadata section
  reads identically across workflows. Low urgency; it is additive, not contradictory.
- **Effort:** S

---

**F-09 | P2 | cross-cutting | `Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsDialog.swift:117-153` vs `Sources/LungfishApp/Views/Shared/ReferenceSequencePickerView.swift`**

- **Problem:** The workflow-operations dialog reinvents reference selection (matrix row O)
  with a bespoke `Picker` over `projectReferenceCandidates` + Choose/Replace/Clear buttons,
  rather than reusing `ReferenceSequencePickerView`, which already scans the project for
  `.lungfishref` bundles and handles ad-hoc browse. Both the 12S and ONT-genotyping paths go
  through this same dialog, so the divergence is shared.
- **Evidence:** `referencePicker` (L117-153) + `browseForReference` (L520-536) duplicate the
  scan/select/browse behavior of `ReferenceSequencePickerView` (`loadReferences` L89-111,
  `browseForReference` L115-137). `ReferenceSequencePickerView` is used by `OrientWizardSheet`
  and `FASTQOperationToolPanes` but not here.
- **Suggested fix:** Replace the dialog's reference picker with `ReferenceSequencePickerView`
  (it already supports a `projectURL` + `selectedReferenceURL` binding). Note: the dialog
  also needs FASTA-or-bundle directory selection and the 12S "Create 12S Reference..." entry,
  so `ReferenceSequencePickerView` may need a small extension rather than a drop-in swap.
  Pre-existing and shared, hence P2.
- **Effort:** M

---

**F-10 | P2 | MHC | `Sources/LungfishApp/Views/Results/Genotype/GenotypeResultViewController.swift:1253-1317` vs `Sources/LungfishApp/Views/Results/TwelveS/TwelveSAmpliconResultViewController.swift:504-559`**

- **Problem:** Both viewports build a "labelled rows for the selected item" detail pane
  (matrix row K) from scratch — genotype via `detailRows([...])` helpers, 12S via manual
  label assembly. Same idiom, two implementations.
- **Evidence:** Genotype `showSharedCall` assembles `detailRows([(String,String)])` sections
  (L1262-1316); 12S `updateTargetDetail`/`updateUnresolvedDetail` build label strings by hand
  (L524-558). The genotype Outline cohort summary (`GenotypeCohortSummaryPanelView`) is a
  genuinely distinct artifact and is **not** part of this finding.
- **Suggested fix:** Extract a shared AppKit "detail rows" builder (label/value `NSStackView`
  rows) used by both viewports' selection panes. Purely a maintainability/consistency
  refactor.
- **Effort:** M

---

## 4. Explicitly-clean items (no finding)

- **12S viewport idiom reuse:** `ClassifierActionBar`, `BlastResultsDrawerContainerView`/
  `BlastResultsDrawerTab` (with `presentationStyle = .sequenceBlast`), header
  `NSSegmentedControl`, and `NSSplitView(table|detail)` are all reused correctly
  (`TwelveSAmpliconResultViewController` L32-37,280-293,610-655). This is the model the rest
  of the work should follow.
- **Mode/lens segmented control (row H):** consistent across both viewports and the
  classifier idiom.
- **Enum pickers (row G):** both use SwiftUI `Picker`; no structural divergence.
- **`SampleMetadataSection` reuse (row N):** both workflows reuse it (the 12S extra block is
  F-08, additive only).
- **Workflow dialog scaffold:** `WorkflowOperationsDialog` correctly uses the shared
  `DatasetOperationsDialog`; its detail pane matches the ONT-genotyping field layout.
- **Haplotype manager window:** standard master/detail `Table` + `HSplitView` + toolbar
  idiom; internally consistent (one P2 color nit, F-06).
- **`@Observable` + `@MainActor` Inspector view-model pattern:** both
  `TwelveSResultDisplaySectionViewModel` and `GenotypeResultDisplaySectionViewModel` follow
  the same pattern with `onDisplayStateChanged` callbacks; structurally aligned.

---

## 5. Severity roll-up

- **P1 (idiom mismatch / cross-workflow divergence):** F-01 (abundance threshold), F-02
  (genotype lacks `ClassifierActionBar`/BLAST drawer → divergent export+provenance), F-03
  (12S search in Inspector vs viewport), F-04 (include/exclude menus vs pills).
- **P2 (polish / reuse refactor):** F-05 (bespoke disclosure buttons), F-06 (delete color
  doubling), F-07 (system accent vs Lungfish Orange), F-08 (parallel metadata summary),
  F-09 (dialog reference picker vs `ReferenceSequencePickerView`), F-10 (duplicated detail-
  rows builder).
- **No P0** for this lens (P0 = correctness/concurrency/provenance/crash, owned by Team A).
