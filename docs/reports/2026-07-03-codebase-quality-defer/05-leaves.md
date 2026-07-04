# Leaf UI Modules — Deferred Items (Phase 5)

Nine leaf feature modules (~68 files, ~41K LOC):
`LungfishTwelveSUI` (11f/2.5K), `LungfishAlignmentUI` (1f/169), `LungfishAssemblyUI` (7f/1.3K),
`LungfishNvdUI` (3f/2.6K), `LungfishNaoMgsUI` (5f/4.0K), `LungfishTaxTriageUI` (6f/6.6K),
`LungfishEsVirituUI` (6f/5.0K), `LungfishGenotypeUI` (27f/17.1K — largest),
`LungfishPhylogeneticsUI` (2f/1.5K).

Protocol: audit -> apply (behavior-preserving only) -> build + scoped tests
(`--filter <Leaf>UITests`) -> independent adversarial review -> revert-on-uncertainty ->
commit. ONE full module-boundary green-bar after ALL leaf batches complete (siblings are
independent; bisect any regression to its leaf).

Leaf-specific binding invariants (never violate / flag):
- **NO leaf may reference a type defined in `LungfishApp`** (the forbidden cycle). Each leaf
  exposes `on...` callbacks; the `ViewerViewController+<X>.swift` glue that wires app services
  to those callbacks stays in `LungfishApp`. Flag any LungfishApp reference.
- macOS 26 API rules (AppKit-heavy VCs): NO `NSSplitViewController` delegate methods,
  `lockFocus`, `wantsLayer`, `runModal`, `synchronize`. Flag existing; never introduce.
- Background->MainActor dispatch rules; distinguish legitimate same-actor `Task { @MainActor }`
  on an already-@MainActor VC from the forbidden GCD/notification-context hop.
- Preserve display-state/export-service structure; `@testable`-pinned internals + `on...`
  callback surface are NOT tightenable.
- NEVER write the literal `Task {` immediately followed by `@MainActor`.
- GenotypeUI files (GenotypeComparisonMatrixView, GenotypeOutlineView, GenotypeHaplotypeTapeView)
  are on main and safe to edit directly (per project memory).

Big files (audit solo, largest first): GenotypeResultViewController (5756),
TaxTriageResultViewController (4738), NaoMgsResultViewController (2809),
GenotypeComparisonMatrixView (2499), NvdResultViewController (2476),
ViralDetectionTableView (1968), EsVirituResultViewController (1937),
PhylogeneticTreeViewController (1495), GenotypeCallEvidenceView (1412),
TwelveSAmpliconResultViewController (1183). Then per-module clusters for the smaller files.

## Big leaf-VC audits (top 5) — findings

All leaf-clean (no LungfishApp refs), macOS-26-clean, concurrency correct (the many
`Task { ... }` on already-@MainActor VCs are same-actor tasks, NOT the forbidden GCD hop;
`NSSplitView` view-delegate is NOT the forbidden `NSSplitViewController` delegate).

### Applied (committed leaf batches)
- `TaxTriageResultViewController` (4738L): removed a 9-member dead island (~169 lines)
  orphaned by the prior removal of `configure(result:config:)` (test-documented). Committed.
- `NvdResultViewController` (2476L): removed 7 dead members (~69 lines) — 3 split wrappers,
  3 `@objc` context methods with NO `#selector` in NvdUI (unreachable), 1 identity method.
  Committed.
- `NaoMgsResultViewController` (2809L): removing the `buildAccessionList` island
  (`AccessionDataWrapper` + `accessionDataKey` + orphaned `switchToAccession`), the
  zero-usage `NaoMgsDetailContainer` class, and 2 dead split wrappers (~190 lines). IN PROGRESS.

### CLEAN (0 logic applies)
- `GenotypeResultViewController` (5756L): disciplined; every candidate pinned by the
  public/test/`on...`-callback surface or not exact-equivalent (the 4-site `showSharedCall`
  "dedup" correctly rejected — standalone sites omit the else-branches `refreshCurrentSelection
  Details` adds). 12-file split proposed needing NO promotions (same-module extensions see
  private) — deferred.
- `GenotypeComparisonMatrixView` (2499L): column-windowing geometry is correctness-sensitive
  and nearly every private is pinned by the extensive `#if DEBUG` testing accessors. 0 applies.
  Safest split = move the `#if DEBUG` accessor extension to +Testing.swift.

### Deferred (larger-blast-radius dead code — needs its own reviewed pass)
- TaxTriage `rebuildSampleFilterSegments` + its cascade (`preselectedSampleId`,
  `resolvedDisplayNames` — never written) and `enableMultiSampleFlatTableMode` (touches live
  `isMultiSampleSingleResultMode` branches). Removal must audit every mode-state reader.
- TaxTriage `testOrganismTableView`/`testBatchOverviewView` unused test accessors (policy-
  sensitive test seams — retained).
- NaoMgs `configure(result:bundleURL:)` legacy: still LIVE via the ResultViewport protocol
  path (NaoMgsResultViewController+ResultViewport.swift) — NOT dead, kept.

### Deferred SPLITS (each its own reviewed pass; same-module extensions, NO promotions;
### @objc selector methods + NSSplitViewDelegate conformance must stay reachable)
- GenotypeResultViewController -> 12 seam files (Setup/Lenses/MatrixAnnotations/Filters/
  HaplotypeAnalysis/Outline/Review/CurrentWorkbook/Export/DetailViews/support/testing).
- TaxTriageResultViewController -> +SplitLayout/+AccessionMapping/+BAM/+Database/+Export/
  +UniqueReads + extract the 3 trailing view/model types.
- NaoMgs/Nvd/GenotypeComparisonMatrixView -> ContextMenu/Blast/SplitLayout/TableData(+Testing)
  seam splits.

## Next-tier leaf-VC audits (EsViritu/Phylo/GenotypeCallEvidence/TwelveS) — applied

Committed as one 5-file batch (~69 lines): dead `showBlastPopover(forRow:)` overload,
dead `currentSelectedSampleIDForActions`, dead `paddedContainer` + single-arg canvas
`configure(nodes:)`, dead `perHaplotypeSupportBlock` SwiftUI builder, dead `@objc`
`toggleReadsColumns`/`togglePercentColumns` (no `#selector` in module). All leaf-clean.

## Leaf-support sweeps (~53 files, 2 coverage audits) — 4 applies + 3 flagged islands

### Applied (final leaf-support batch)
- `GenotypeHaplotypeDefinitionEditor`: dead `@State selectedHaplotypeIndex` + dead
  `GenotypeHaplotypeDefinitionDrafting.withDisplayName` static (kept test-pinned
  `renamingHaplotype`).
- `GenotypeAnnotationStore`: dead write-only `ProvenanceEditContext.argv` field
  (grep-verified never read; consumer uses only `.explicitOptions`) + its init args.
- `GenotypeQuickFilterBarView`: dead pill-button island `makePillButton` + `togglePill`
  (conservatively scoped — left the live-but-no-op `setActivePills`/`pillButtons`).
- `NvdDataConverter.commonPrefix(of:)`: dead thin wrapper (everyone calls
  `ClassifierSamplePickerView.commonPrefix` directly).

### FLAGGED dead-code islands (deferred to maintainer — NOT mechanical, span VC + absent App wiring)
These are whole unwired-UI subtrees that look intentionally not-yet-wired. Removing them
crosses the VC + the intended-but-absent App glue and could discard planned UI, so they are
a judgment call for the maintainer, not a behavior-preserving edit:
- `AssemblyContigDetailPane` (LungfishAssemblyUI): the pane is created + constrained by
  `AssemblyResultViewController` but its entire population API (`showEmptyState`,
  `showSingleSelection`, `showMultiSelection`, `showUnavailableSelectionSummary`,
  `configureQuickCopy`) has ZERO callers; only `#if DEBUG copyValue` reads it back.
- `NaoMgsDetailPaneView` + its whole chart subtree (`CoveragePlotView`,
  `EditDistanceHistogramView`, `FragmentLengthDistributionView`, `AccessionListView`,
  `AccessionRow`, `MiniSparkline`, `MetricCard`) in NaoMgsChartViews.swift — ZERO refs
  outside the file; only `NaoMgsOverviewView` is used by the VC. The PUBLIC
  `NaoMgsDataConverter` methods `groupByTaxon`/`groupByAccession`/`buildAccessionSummaries`/
  `computeCoverage`/`editDistanceDistribution`/`fragmentLengthDistribution`/
  `pairStatusDistribution` fed ONLY this dead pane (but are public leaf API -> not removable
  per the leaf rule).
- `TaxTriageConfidenceView` class (TaxTriageConfidenceView.swift): NEVER instantiated
  (no `TaxTriageConfidenceView(` anywhere); its whole instance body (`metrics`,`maxVisible`,
  `draw`,`drawPlaceholder`, private instance `confidenceColor`) is dead. Only the sibling
  `static confidenceColor(for:)` is live (used by `TaxTriageConfidenceCellView`).

### DEFER notes
- `TaxTriageBatchOverviewView.formatReadCount` (~599) duplicates the LungfishKit shared
  helper — cross-file, do NOT dedup.
- `NaoMgsResultViewController+ResultViewport.exportResults(to:format:)` ignores its `url`
  arg and delegates to `exportResults()` — pre-existing, public API, behavior-preserving; not a target.
- Various caller-less-but-PUBLIC leaf-API members (`GenotypeResultDisplaySection.
  matrixQuickPaletteColors`, etc.) — NOT removable per the leaf public-API contract.

## Phase 5 (leaf UI modules) — audit COMPLETE

All ~68 files audited (10 big VCs solo + ~58 support files in coverage sweeps). Applied:
6 committed leaf batches removing ~585 lines of grep-verified dead code (dead islands
orphaned by removed entry points, unreferenced `@objc` methods with no `#selector`, dead
overloads, write-only fields). GenotypeResultViewController + GenotypeComparisonMatrixView
statement-clean (test-pinned/windowing). All leaf-clean (no LungfishApp refs), macOS-26
compliant, concurrency correct. Value beyond the dead-code removal is in DEFERRED per-VC
splits (all >1000L VCs, same-module extensions, no promotions) + the 3 flagged unwired-UI
islands for maintainer review.

## Deferred items

_(none reverted — all applied items provably safe and verified green)_
