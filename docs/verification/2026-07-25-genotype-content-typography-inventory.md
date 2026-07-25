# Genotype Content Typography Inventory

This inventory records the Task 4 audit of fixed and semantic fonts in
`Sources/LungfishGenotypeUI`. The content text-size preference applies to
ordinary result lists, matrices, detail text, and evidence. It does not change
scientific drawing scale or Inspector/control chrome.

## Adopted primary content

| Source | Surface | Resolution and geometry |
| --- | --- | --- |
| `GenotypeQuickFilterBarView.swift` | Matrix search field | Body role; field height follows resolved line metrics. Search text and focus survive live updates. |
| `GenotypeComparisonMatrixView.swift` | Search, allele/gene/note rows, read counts, sample headers, retained-read totals, and review legend | Body, caption, table-header, and monospaced roles. Row height, two-band headers, selection/check indicators, annotation folds, false-negative borders, and comment/review geometry are remeasured from stable baselines through 200 percent. Selection, scroll, column order, and user widths remain unchanged. |
| `GenotypeOutlineView.swift` | Animal and haplotype list labels | Body, emphasized-body, table-header, and monospaced roles. Row height follows content metrics without rebuilding the outline. |
| `GenotypeResultTableView.swift` | Ordinary sample result table | Uses the shared `BatchTableView` path for search, headers, cells, and row/header geometry. The semibold sample override records its canonical baseline and is scaled by the shared table. |
| `GenotypeCohortSummaryPanelView.swift` | Cohort summary headings, labels, values, and explanations | Registered semantic roles are reapplied from stable baselines. The update does not recalculate cohort content. |
| `GenotypeHaplotypeDefinitionMatrixView.swift` | Definition title, subtitle, empty state, headers, and allele cells | Emphasized-body, caption, body, table-header, and monospaced roles. Row/header geometry and the current scroll position remain stable. |
| `GenotypeKnownAlleleDetailView.swift` | Allele identity, metadata, evidence, feature text, summaries, and ordinary sequence text | The persistent detail subtree is updated in place from captured canonical fonts. Labels wrap or expand, and current selection/detail state remains unchanged. |
| `GenotypeCandidateAlleleDetailView.swift` | Candidate identity, stable IDs, reference context, summaries, and sequence/difference explanations | The persistent detail subtree is updated in place from captured canonical fonts. Labels wrap or expand without recomputing candidate evidence. |
| `GenotypeAlleleSequenceDetailView.swift` | Standalone allele sequence reader | Its stable monospaced baseline follows the shared content scale. Text storage, selection, scroll origin, and render count are preserved. |
| `GenotypeResultViewController.swift` | Controller-generated Detail, Haplotype, Consumer, Anchor, and Audit/artifact text | Each generated stack receives a bounded typography observer. All ordinary fields update in place, wrap, expose complete accessibility values/tooltips, and preserve detail identity, selection state, and exact scroll origin. Persistent specialized detail views are excluded from the generic observer to prevent double scaling. |
| `GenotypeCallEvidenceView.swift` | Call header, haplotype support, animal genotype evidence, candidate alternatives, allele/read metrics, and pending overrides | SwiftUI semantic emphasized-body, caption, and monospaced roles update live. Haplotype cards use a horizontal layout when it fits and a vertical fallback at large text or narrow widths. Evidence and actions are not recomputed. |
| `GenotypeSampleDetailSheet.swift` | Sample heading, per-locus calls/status, override history, and explanatory footer | SwiftUI semantic roles update live. Rows fall back from side-by-side content/actions to a stacked layout, and the sheet has adaptive ideal geometry. Row identity and override state remain unchanged. |

The View Inspector's `A−`, current value, `A+`, and `Default` controls are the
entry point for this shared preference. They intentionally retain native
control fonts.

## Control and workflow chrome retained

The following fixed or SwiftUI semantic font sites are Inspector sections,
forms, manager/editor workflows, or native controls rather than primary
viewport list/detail content. Their typography continues to be owned by SwiftUI
or AppKit:

- `GenotypeResultDisplaySection.swift`, including labels around the new
  content-size controls.
- `GenotypeCandidateEvidenceSection.swift`,
  `GenotypeDropoutThresholdSection.swift`,
  `GenotypeManualHaplotypingSection.swift`,
  `GenotypeSmartCohortSection.swift`,
  `GenotypeMatrixAnnotationSection.swift`,
  `GenotypeStatusFlagSection.swift`, `GenotypeOverrideSection.swift`,
  `GenotypeAuditTimelineSection.swift`, and
  `GenotypeResultDocumentSection.swift`.
- `GenotypeHaplotypeDefinitionEditor.swift`, which is a separate Tools-window
  editor rather than result viewport content.
- Buttons, segmented controls, pop-up buttons, menus, color wells, sliders,
  steppers, and search-field control chrome inside adopted views.
- The fixed 11-point error glyph inside the 22-point status swatch in
  `GenotypeSampleDetailSheet.swift`. This is icon geometry, not prose.

## Scientific rendering exclusions

- `GenotypeHaplotypeTapeView.swift` derives its 7–11-point labels from tape
  segment height. Tape labels, tracks, hit geometry, and scientific zoom remain
  unchanged.
- `GenotypeKnownAlleleOverviewView.swift` owns coordinate-ruler, nucleotide,
  feature-lane, and overview geometry. Its fixed 9-point drawing labels and
  small overview labels remain tied to that scientific rendering.
- `GenotypeCandidateDifferenceTrackView.swift` owns difference-track drawing
  and hit geometry. It is excluded from generic detail scaling.
- Candidate/known overview and difference-track subtrees are explicitly
  excluded from the surrounding detail observers, preventing double scaling
  or scientific-layout changes.
- Matrix support colors, review tint semantics, read values, selection
  identity, comment state, threshold state, genotype calls, haplotype calls,
  and workbook/audit data are unchanged by typography notifications.

All fixed-font-bearing files in `Sources/LungfishGenotypeUI` are covered above
as adopted primary content, control/workflow chrome, or scientific rendering.
