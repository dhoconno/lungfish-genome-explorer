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

Columns: files total / audited / applied-count / clean-count / deferred-count. This ledger is
the original Phase 6 audit snapshot; 2026-07-04 hardening additions are listed below it.
`audited` MUST equal `total` for every row before the module-boundary green-bar.
`applied + clean + deferred` for a row equals `audited` (a file can be in only one bucket;
a file with an applied edit AND a deferred split counts under applied, noted separately).

| Directory | total | audited | applied | clean | deferred |
|---|---|---|---|---|---|
| Views/Viewer | 75 | 75 | 4 | 71 | 0 |
| Views/Inspector | 38 | 38 | 0 | 38 | 0 |
| Views/Metagenomics | 32 | 32 | 0 | 32 | 0 |
| Views/MainWindow | 14 | 14 | 1 | 13 | 0 |
| Views/BAM | 12 | 12 | 0 | 12 | 0 |
| Views/Sidebar | 11 | 11 | 0 | 11 | 0 |
| Views/Results | 9 | 9 | 0 | 9 | 0 |
| Views/DatabaseBrowser | 9 | 9 | 1 | 8 | 0 |
| Views/WorkflowBuilder | 8 | 8 | 0 | 8 | 0 |
| Views/Settings | 8 | 8 | 0 | 8 | 0 |
| Views/FASTQ | 7 | 7 | 0 | 7 | 0 |
| Views/ImportCenter | 6 | 6 | 0 | 6 | 0 |
| Views/Shared | 5 | 5 | 0 | 5 | 0 |
| Views/Assembly | 5 | 5 | 0 | 5 | 0 |
| Views/WorkflowOperations | 4 | 4 | 2 | 2 | 0 |
| Views/Mapping | 4 | 4 | 0 | 4 | 0 |
| Views/WorkflowLibrary | 3 | 3 | 0 | 3 | 0 |
| Views/PluginManager | 3 | 3 | 0 | 3 | 0 |
| Views/Phylogenetics | 3 | 3 | 0 | 3 | 0 |
| Views/Operations | 3 | 3 | 0 | 3 | 0 |
| Views/Layout | 3 | 3 | 0 | 3 | 0 |
| Views/Components | 2 | 2 | 0 | 2 | 0 |
| Views/Welcome | 1 | 1 | 0 | 1 | 0 |
| Views/TranslationTool | 1 | 1 | 0 | 1 | 0 |
| Views/Sequence | 1 | 1 | 0 | 1 | 0 |
| Views/Help | 1 | 1 | 0 | 1 | 0 |
| Views/Extraction | 1 | 1 | 0 | 1 | 0 |
| Views/AI | 1 | 1 | 0 | 1 | 0 |
| Services | 86 | 86 | 0 | 86 | 0 |
| App | 42 | 42 | 1 | 41 | 0 |
| StateManagement | 6 | 6 | 0 | 6 | 0 |
| ViewModels | 4 | 4 | 0 | 4 | 0 |
| Support | 1 | 1 | 0 | 1 | 0 |
| **TOTAL** | **409** | **409** | **9** | **400** | **0** |

### Per-file APPLIED / DEFERRED notes
(CLEAN files are summarized per-directory as "N files clean"; only APPLIED and DEFERRED get a
per-file line here.)

APPLIED (Pass A batch 1 — committed 08317789, scoped-green 3152/0 + 159/0):
- `Views/Viewer/AnnotationTableDrawerView+Genotypes.swift`: remove dead file-private
  `genotypeLogger` (line 18) — grep-verified zero reads in module + Tests/.
- `Views/Viewer/FASTQDatasetViewController.swift`: original pass removed dead
  `saveExpansionState()`. The 2026-07-04 hardening pass removed the remaining inert accordion
  load/state path and simplified the operation sidebar to fixed operation rows.

APPLIED (Pass A batch 2 — committed 93b6b0c3):
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
- FASTQMetadataSection.swift formerly used `if !customKeys.isEmpty || true {` to force the
  Custom Fields section visible. The hardening pass made that behavior explicit with an
  unconditional `DisclosureGroup`, removing the deceptive always-true condition without changing
  the visible UI.
- InspectorViewController+MetadataImport `assemblyContextRows`/`assemblyArtifactRows`: an
  auditor briefly considered these dead but self-corrected — they are reached via the public
  updateAssemblyDocument() API path. Kept.
- WorkflowBuilder `colorForCategory` "duplicate" (WorkflowNodePalette:343 vs WorkflowNodeView:483):
  byte-identical bodies but in DIFFERENT types, each with its own private callsite (296 / 358).
  Cross-type helpers are NOT intra-type-dedup-able; merging would introduce a shared helper =
  structural coupling change, not behavior-preserving. Kept both (auditor flagged low-confidence).

APPLIED (Pass B batch 3 — committed a6f7e84a):
- `Views/DatabaseBrowser/DatabaseSearchDialogState.swift`: remove dead `convenience
  init(selectedDestination:automationBackend:)` (~74-79) — grep-verified ZERO callers of the
  `selectedDestination:` label in Sources + Tests (all sites use the designated
  `init(initialDestination:)`, the positional form, or the no-arg default; both inits have
  identical defaults). Internal type, app-internal, no cross-module/out-of-tree consumer.

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
- `93b6b0c3` — batch 2: 4 items (dead @State pair, duplicate doc-comment, dead
  calculateZoomPercent, dead performReverseComplement island) across WorkflowOperationsDialog,
  MainSplitViewController+FASTQImport, EnhancedCoordinateRulerView, SequenceViewerView+Interaction.
  Scoped-green (3152/0 + 159/0). Pass A (71 big files) audit COMPLETE.
- `a6f7e84a` — batch 3: 1 item (dead `convenience init(selectedDestination:)` in
  DatabaseSearchDialogState). Scoped-green (3152/0 + 159/0). Pass B (all ~338 smaller files,
  directory-by-directory) audit COMPLETE — coverage ledger totals 409/409 audited.

## Deferred items

No reverted batch edits beyond the explicit flagged items below. Deferred work is mostly optional
file splitting and maintainer-owned behavior decisions.

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

### Flagged (pre-existing rule violations / unwired-UI islands)

- RESOLVED: `FASTQDatasetViewController` no longer carries loaded-but-never-saved accordion
  state for the operation sidebar.
- RESOLVED: `FASTQMetadataSection` no longer uses an always-true conditional to show Custom
  Fields; unconditional visibility is now represented directly.
- `FASTQMetadataDrawerView` — dead pair: `public func tableViewSelectionDidChange(_:)` (no-op
  break-only body) + its only reader `isSuppressingDelegateCallbacks` (never written). Left in
  place (public protocol-shaped surface); a maintainer pass could remove both.
- No macOS-26 API violations (lockFocus/wantsLayer/runModal/synchronize/NSSplitViewController
  delegate methods) and no forbidden GCD->MainActor `Task { @MainActor` hops found in any Pass A
  big file (the many `Task { @MainActor in }` are same-actor tasks on already-@MainActor types —
  legitimate, NOT the forbidden hop).
- NON-ISSUE (an auditor mislabeled these as violations — they are the CORRECT pattern, left as-is):
  `DispatchQueue.main.async { MainActor.assumeIsolated { ... } }` in SidebarViewController+MenuDelegate
  (~637/839/1032), AssemblyConfigurationViewModel (~603), FASTQIngestionService, and several
  SequenceViewerView+* files. This IS the prescribed background->MainActor hop; do NOT "modernize"
  it to `Task { @MainActor }` (that would be the forbidden hop and a concurrency-timing change).
- DEFERRED dedup (SequenceViewerView+Interaction): `annotationAtPoint` vs `annotationRectAtPoint`
  share coordinate-calculation logic, but merging is a geometry refactor -> DEFER (drawing math).
- RESOLVED: `Services/ONTImportOperationCoordinator.swift` progress callbacks now dispatch to
  the main queue and use `MainActor.assumeIsolated` instead of the forbidden progress-callback
  `Task { @MainActor ... }` hop. All OTHER `Task { @MainActor }` in App remain legitimate
  same-actor tasks on already-@MainActor types.
- NON-ISSUE (auditors flagged as violations, verified legitimate — NOT touched):
  `AssemblyConfigurationViewController.swift:74` (type is `@MainActor`, line 39) and
  `WorkflowLibraryViewModel.swift:270` (type is `@MainActor @Observable`, and it uses a proper
  generation counter) both write `Task { @MainActor in ... }` on an ALREADY-@MainActor type =
  legitimate same-actor tasks, NOT the forbidden GCD/detached hop. Left as-is.

## Phase 6 (LungfishApp) — audit COMPLETE

409/409 files audited (100% coverage — see the reconciled ledger above; `find Sources/LungfishApp
-name '*.swift'` = 409, every directory row audited == total). Two passes:
- PASS A: all 71 files >=800 lines, solo audits, largest-first.
- PASS B: all ~338 remaining files, directory-by-directory coverage sweeps (Services 86, App 42,
  Views/Viewer 75, Views/Inspector 38, Views/Metagenomics 32, and every other directory).

Original Phase 6 applied scope: 3 committed batches, **9 provably-safe items** (all
grep-verified zero-caller + compiler-verified dead + scoped-green), ~55 source lines net
removed. The 2026-07-04 hardening additions are listed alongside those batches:
- batch 1 (`08317789`): dead `genotypeLogger`; dead `saveExpansionState`; dead
  `twelveSReferenceFASTAURL` + `defaultONTGenotypingAnalysisName`; 2 identical-branch IIFE
  collapses (AppDelegate+Classification batchRoot).
- 2026-07-04 hardening pass: removed remaining FASTQ operation sidebar accordion state, made
  Custom Fields visibility explicit, and fixed the ONT import progress callback hop.
- batch 2 (`93b6b0c3`): dead `@State` pair (WorkflowOperationsDialog); duplicate doc comment
  (MainSplitViewController+FASTQImport); dead `calculateZoomPercent` (EnhancedCoordinateRulerView);
  dead `performReverseComplement` island (SequenceViewerView+Interaction).
- batch 3 (`a6f7e84a`): dead `convenience init(selectedDestination:)` (DatabaseSearchDialogState).

The App module is ALREADY statement-level clean — the same pattern every prior phase found. The
large remaining value is in DEFERRED file SPLITS (catalogued above; each its own reviewed pass).

VERIFY-EVERY-CLAIM caught several auditor misfires (recorded under REJECTED above) that were NOT
behavior-preserving and were correctly NOT applied: `= nil` parameter-default removals (remove a
default = API break); cross-type "duplicate" methods (`isGap`, `colorForCategory` — different
types, removing breaks `Self.` resolution); stale UI state and callback-hop candidates were
handled in the later hardening pass once behavior-change scope was explicitly broadened. This is
the reason each apply is grep-verified before an
implementer runs.

Module-boundary green-bar: recorded in results.md (full suite --skip ONT + ONT in isolation).

### Known-flaky test observed at the App boundary (environmental, NOT a regression)
`ViralReconWorkflowExecutionServiceTests.testConcreteRunnerCancelTerminatesProcessTree` spawns a
process tree and waits for a temp `ready` sentinel file to appear, then reads `root.pid`. Under
heavy concurrent machine load (many audit agents + back-to-back full-suite runs) it flaked ONCE
with "Timed out waiting for .../ready" + a missing `root.pid`. It passes in all other runs (the 3
scoped batch runs, a clean full-suite run, and re-run IN ISOLATION = 1.96s). It touches NO code
changed in Phase 6 (ViralReconWorkflowExecutionService + ViralReconWizardSheet were both audited
CLEAN and untouched). Load-sensitive subprocess-timing flake, not a regression. A future hardening
could increase the `ready`-sentinel timeout or reduce its reliance on wall-clock under load.
