# LungfishApp — Deferred Items (Phase 6)

Module: `Sources/LungfishApp/**` (409 files, ~188K LOC). LARGEST module (composition roots).
Protocol: audit -> apply (behavior-preserving only) -> build + scoped tests
(`--filter LungfishAppTests`) -> independent adversarial review -> revert-on-uncertainty ->
commit. Full module-boundary green-bar at the App boundary.

App-specific binding invariants (never violate / flag):
- **Composition roots STAY in App** (do NOT extract into leaves): `ViewerViewController`,
  `MainSplitViewController`, `InspectorViewController`, `SidebarViewController`, the IQ-TREE
  inference dialog cluster, the Taxonomy hub (CzId + Mapping stay too — Mapping's
  `ReferenceBundleViewportController` embeds `ViewerViewController`). App importing leaves is
  fine (App->leaf OK); a leaf/kernel referencing an App type is the forbidden cycle.
- **Generation-counter patterns** on async fetches reject stale results
  (`ViewerViewController.{fetchAnnotations,fetchSequence,fetchVariants}Async`) — do NOT
  refactor away the generation guards.
- macOS 26 API rules (AppKit-heavy): NO `NSSplitViewController` delegate methods, `lockFocus`,
  `wantsLayer`, `runModal`, `synchronize`. Flag existing; never introduce.
- Background->MainActor dispatch rules; distinguish legitimate same-actor `Task { @MainActor }`
  from the forbidden GCD/notification-context hop. NEVER write literal `Task {` then `@MainActor`.
- OperationCenter update()+log() pairing where App code drives ops; materialization
  (`materializeInputFilesIfNeeded` in AppDelegate); never save alignment as SAM.
- Virtual-FASTQ materialization semantics (preview vs full reconstruction) untouched.

Big files (audit solo, largest first): AnnotationTableDrawerView (5224) + its extensions,
ViewerViewController (3762 — composition root, keep in App), DatabaseBrowserViewController
(3565), MultipleSequenceAlignmentViewController (3521), FASTQDatasetViewController (3032),
AppDelegate+ImportCenter (2843), SidebarViewController (2697 — composition root),
ReadStyleSection (2482), FASTQMetadataDrawerView (2115), FASTQOperationDialogState (2088),
SequenceViewerView (2069), ReadTrackRenderer (1973), WorkflowOperationDialogState (1928),
AppDelegate+Classification (1879), TaxonomyViewController (1783), OperationPreviewView (1764).
Then directory clusters (Views/Viewer, Views/Inspector, Views/Sidebar, Views/DatabaseBrowser,
Views/FASTQ, Views/Metagenomics, App/, Services/, etc.).

If tokens/time run short: complete whole batches, defer the untouched remainder EXPLICITLY
here (never leave a half-applied batch).

## Coverage ledger (the anti-selectivity proof — every one of 409 files accounted for)

Columns: files total / audited / applied-count / clean-count / deferred-count.
`audited` MUST equal `total` for every row before the module-boundary green-bar.
`applied + clean + deferred` for a row equals `audited` (a file can be in only one bucket;
a file with an applied edit AND a deferred split counts under applied, noted separately).

| Directory | total | audited | applied | clean | deferred |
|---|---|---|---|---|---|
| Views/Viewer | 75 | 0 | 0 | 0 | 0 |
| Views/Inspector | 38 | 0 | 0 | 0 | 0 |
| Views/Metagenomics | 32 | 0 | 0 | 0 | 0 |
| Views/MainWindow | 14 | 0 | 0 | 0 | 0 |
| Views/BAM | 12 | 0 | 0 | 0 | 0 |
| Views/Sidebar | 11 | 0 | 0 | 0 | 0 |
| Views/Results | 9 | 0 | 0 | 0 | 0 |
| Views/DatabaseBrowser | 9 | 0 | 0 | 0 | 0 |
| Views/WorkflowBuilder | 8 | 0 | 0 | 0 | 0 |
| Views/Settings | 8 | 0 | 0 | 0 | 0 |
| Views/FASTQ | 7 | 0 | 0 | 0 | 0 |
| Views/ImportCenter | 6 | 0 | 0 | 0 | 0 |
| Views/Shared | 5 | 0 | 0 | 0 | 0 |
| Views/Assembly | 5 | 0 | 0 | 0 | 0 |
| Views/WorkflowOperations | 4 | 0 | 0 | 0 | 0 |
| Views/Mapping | 4 | 0 | 0 | 0 | 0 |
| Views/WorkflowLibrary | 3 | 0 | 0 | 0 | 0 |
| Views/PluginManager | 3 | 0 | 0 | 0 | 0 |
| Views/Phylogenetics | 3 | 0 | 0 | 0 | 0 |
| Views/Operations | 3 | 0 | 0 | 0 | 0 |
| Views/Layout | 3 | 0 | 0 | 0 | 0 |
| Views/Components | 2 | 0 | 0 | 0 | 0 |
| Views/Welcome | 1 | 0 | 0 | 0 | 0 |
| Views/TranslationTool | 1 | 0 | 0 | 0 | 0 |
| Views/Sequence | 1 | 0 | 0 | 0 | 0 |
| Views/Help | 1 | 0 | 0 | 0 | 0 |
| Views/Extraction | 1 | 0 | 0 | 0 | 0 |
| Views/AI | 1 | 0 | 0 | 0 | 0 |
| Services | 86 | 0 | 0 | 0 | 0 |
| App | 42 | 0 | 0 | 0 | 0 |
| StateManagement | 6 | 0 | 0 | 0 | 0 |
| ViewModels | 4 | 0 | 0 | 0 | 0 |
| Support | 1 | 0 | 0 | 0 | 0 |
| **TOTAL** | **409** | **0** | 0 | 0 | 0 |

### Per-file APPLIED / DEFERRED notes
(CLEAN files are summarized per-directory as "N files clean"; only APPLIED and DEFERRED get a
per-file line here.)

APPLIED (Pass A batch 1 — committed 08317789, scoped-green 3152/0 + 159/0):
- `Views/Viewer/AnnotationTableDrawerView+Genotypes.swift`: remove dead file-private
  `genotypeLogger` (line 18) — grep-verified zero reads in module + Tests/.
- `Views/Viewer/FASTQDatasetViewController.swift`: remove dead private `saveExpansionState()`
  (~347-354) — grep-verified zero callers in module + Tests/. NOTE: this is the WRITE half of
  an expansion-state persistence pair; the READ half (`loadExpansionState` at ~341) still runs,
  so state is loaded-but-never-saved (pre-existing latent no-op persistence). Removing the
  unused writer is behavior-preserving. Flagged below for maintainer.

APPLIED (Pass A batch 2 — pending build+commit):
- `Views/WorkflowOperations/WorkflowOperationsDialog.swift`: remove dead `@State private var
  showingReferencePanel`/`showingOutputPanel` (lines 55-56) — grep-verified zero reads incl.
  `$`-bindings in module + Tests/ (sibling showingTwelveSReferenceBuilder stays).
- `Views/MainWindow/MainSplitViewController+FASTQImport.swift`: remove one of two byte-identical
  `///` doc-comment lines above showDuplicateFileDialog (~471-472). Cosmetic, behavior-preserving.
- `Views/Viewer/EnhancedCoordinateRulerView.swift`: remove dead private `calculateZoomPercent()`
  (~782-790) — grep-verified zero callers in module + Tests/ (drawing/geometry math around it left
  untouched).
- `Views/Viewer/SequenceViewerView+Interaction.swift`: remove dead `performReverseComplement()`
  (~1251-1267) — orphaned island. Its stale doc comment claims "Called by the Sequence > Reverse
  Complement menu item", but the LIVE menu path is #selector(SequenceMenuActions.reverseComplement)
  -> AppDelegate+SequenceMenu.reverseComplement -> viewerView.runSelectedSequenceFASTAOperation(
  toolID: .reverseComplement). The method is non-@objc (cannot be a menu action target) with zero
  callers anywhere; the shared helper `reverseComplementString` has 4 other live callers -> no
  cascade. Verified dead.

REJECTED candidates (audited, proven NOT safe — recorded so a future pass does not re-propose):
- MSA `MultipleSequenceAlignmentViewController.swift` "duplicate `isGap` at ~3131": NOT a
  duplicate. Line 1917 is on `MultipleSequenceAlignmentViewController`; line 3131 is on the
  private class `MSAAlignmentMatrixView` (opened ~2726). The `Self.isGap` calls at ~3067/3101
  are inside `MSAAlignmentMatrixView`, so they resolve to 3131. Removing 3131 breaks compile.
  File is CLEAN.
- All `= nil` parameter-default removals proposed by an auditor (FASTQDatasetViewController,
  AppDelegate+ImportCenter, ~13 sites): a parameter `foo: T? = nil` has a DEFAULT VALUE;
  removing `= nil` forces every caller to pass the arg = API/behavior/compile change. NOT
  behavior-preserving. Rejected wholesale.

DEFERRED:
- `Views/Viewer/FASTQMetadataDrawerView.swift`: no-op `public func
  tableViewSelectionDidChange(_:)` (~1312-1321) — body is pure `break`s, behaviorally a no-op
  delegate stub. Removal is behavior-equivalent but it is PUBLIC protocol-shaped surface with
  near-zero cleanup value; deferred rather than touch public surface. `isSuppressingDelegate
  Callbacks` (line 119) is its only reader and is never written -> both are effectively dead;
  a maintainer pass could remove the pair.

## Applied batches (commit log)

- `08317789` — batch 1: 6 provably-safe items (4 dead members + 2 identical-branch IIFE
  collapses) across AnnotationTableDrawerView+Genotypes, FASTQDatasetViewController,
  WorkflowOperationDialogState, AppDelegate+Classification. Scoped-green.

## Deferred items

_(none yet — populated per batch as uncertain changes are reverted)_

### Deferred file splits (each its own reviewed pass)

All same-module `extension` moves (private does NOT cross files in Swift, so any cross-file
helper needs a `private`->`internal` promotion; @objc/#selector/NSTableViewDelegate/NSMenuDelegate
conformance methods must remain reachable from the type that declares the conformance). Splits
are DEFERRED by design — each is a large relocation warranting its own reviewed+green commit.

Pass A big files (catalogued from the solo audits):
- `AnnotationTableDrawerView.swift` (5224) — already partly split (+Filtering/+Columns/+TableView/
  +Genotypes/+Bookmarks/+Export). Further seams: +UI (setup/layout), +Notifications (the @objc
  handleVariantSelected/handleViewportVariantsUpdated/handleViewerCoordinatesChanged/
  handleSampleDisplayStateChanged/variantColorThemeDidChange must stay #selector-reachable),
  +MenuHandling (context-menu @objc actions). Promote core state (displayedAnnotations, activeTab,
  delegate, tableView, searchIndex, isLoading) to internal.
- `ViewerViewController.swift` (3762, COMPOSITION ROOT) — already well-decomposed via 18
  ViewerViewController+*.swift. Further extraction would promote private helpers to internal
  (widens surface); low value. Generation-counter guards stay. Statement-clean.
- `DatabaseBrowserViewController.swift` (3565) — CLEAN; split by concern (SRA search / Pathoplexus
  metadata / result-table / provenance). Private request-identity structs stay same-module.
- `MultipleSequenceAlignmentViewController.swift` (3521) — CLEAN. Safest seam: move the
  #if DEBUG testing extension (~2025-...) to +Testing.swift (all internal/testing-scoped, no
  promotions). The trailing private NSView subclasses (MSAAlignment* Corner/Gutter/ColumnHeader/
  Overview/Overlay/Matrix, ~2292-3418) could move to +Views.swift (each carries its own isGap
  etc.). @objc #selector methods (~565-1395) stay reachable.
- `FASTQDatasetViewController.swift` (3032) — split UI-configuration (+UIConfiguration) from
  API/panes; @objc methods reachable. Materialization-adjacent nothing here.
- `SidebarViewController.swift` (2697, COMPOSITION ROOT) — CLEAN; already split (+OutlineDataSource/
  +OutlineDelegate/+MenuDelegate). @objc at ~379/469/689 are #selector-pinned.
- `ReadStyleSection.swift` (2482) — CLEAN; SwiftUI views already well-sectioned; low-value split.
- `FASTQMetadataDrawerView.swift` (2115), `FASTQOperationDialogState.swift` (2088),
  `SequenceViewerView.swift` (2069, +6 extension files already), `ReadTrackRenderer.swift` (1973,
  drawing — leave whole), `WorkflowOperationDialogState.swift` (1928), `OperationPreviewView.swift`
  (1764), `TaxonomyViewController.swift` (1783, +Blast/+Collections already) — all statement-clean;
  splits are optional file-size hygiene, deferred.
- `AppDelegate+*.swift` cluster (ImportCenter 2843 / Classification 1879 / ToolsMenu 1590 /
  MenuActions 879 / SequenceMenu 845) — already concern-split extensions on AppDelegate; @objc
  menu actions are NSMenu-dispatched, keep reachable. Materialization in +ImportCenter untouchable.

### Flagged (pre-existing rule violations / unwired-UI islands — NOT fixed in this pass)

- `FASTQDatasetViewController` — latent no-op persistence: `loadExpansionState` reads
  `expandedCategories` from UserDefaults at init, but the writer (`saveExpansionState`, now
  removed as dead) was never called, so expansion state was loaded-but-never-persisted. Removing
  the dead writer is behavior-preserving; WIRING a save call would be a behavior CHANGE (out of
  scope). Maintainer decision: either wire persistence or drop the load too.
- `FASTQMetadataDrawerView` — dead pair: `public func tableViewSelectionDidChange(_:)` (no-op
  break-only body) + its only reader `isSuppressingDelegateCallbacks` (never written). Left in
  place (public protocol-shaped surface); a maintainer pass could remove both.
- No macOS-26 API violations (lockFocus/wantsLayer/runModal/synchronize/NSSplitViewController
  delegate methods) and no forbidden GCD->MainActor `Task { @MainActor` hops found in any Pass A
  big file audited so far (the many `Task { @MainActor in }` are same-actor tasks on already
  @MainActor types — legitimate, NOT the forbidden hop).
