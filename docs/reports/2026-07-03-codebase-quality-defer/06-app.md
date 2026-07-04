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

APPLIED (Pass A batch 1 — pending build+commit):
- `Views/Viewer/AnnotationTableDrawerView+Genotypes.swift`: remove dead file-private
  `genotypeLogger` (line 18) — grep-verified zero reads in module + Tests/.
- `Views/Viewer/FASTQDatasetViewController.swift`: remove dead private `saveExpansionState()`
  (~347-354) — grep-verified zero callers in module + Tests/. NOTE: this is the WRITE half of
  an expansion-state persistence pair; the READ half (`loadExpansionState` at ~341) still runs,
  so state is loaded-but-never-saved (pre-existing latent no-op persistence). Removing the
  unused writer is behavior-preserving. Flagged below for maintainer.

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

_(one line per committed batch: commit hash + summary)_

## Deferred items

_(none yet — populated per batch as uncertain changes are reverted)_

### Deferred file splits (each its own reviewed pass)

_(catalog of >1000-line files: seam files + private→internal promotion lists + @objc/protocol
methods that must stay reachable)_

### Flagged (pre-existing rule violations / unwired-UI islands — NOT fixed in this pass)

_(macOS-26 API violations, forbidden MainActor hops, unwired-UI dead islands for maintainer)_
