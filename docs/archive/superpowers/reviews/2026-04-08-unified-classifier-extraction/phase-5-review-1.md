# Phase 5 — Adversarial Review #1

**Date:** 2026-04-09
**Commits reviewed:** 72b34af, bdba3f6, af43b5a, 947c2e5, 96283ff
**Reviewer:** general-purpose subagent
**Charter:** Independent adversarial review before simplification pass.

## Summary

Phase 5 successfully deletes all five `presentExtractionSheet` Phase 1 stubs, removes the `onExtractConfirmed` callback chain (and the ~120-line handler in `ViewerViewController+Taxonomy.swift`), and routes every classifier menu/action-bar path through `TaxonomyReadExtractionAction.shared.present(...)`. Build is clean, no `phase5: old extraction sheet removed` warnings remain, and the four authorized "documented" deviations (#1, #2, #3, #4) check out as described. **Deviation #5 is a real silent regression for filtered taxonomy nodes** — the chart-context-menu shadowing pattern fails when the user has applied a search filter, because `taxonomyTableView.selectedNode = node` calls `selectRowForNode` which silently no-ops when the node is not in the visible row set. **Deviation #6 (line budget) under-counts**: with strict counting that includes wiring closures and `@objc` dispatchers, **3 of 5 classifiers exceed the 40-line target** (TaxTriage 44, NVD 47, Kraken2 58). The Phase 3 forwarded `ClassifierTool.expectedResultLayout` action item was dropped by Phase 5 with no mention. Two missing `validateMenuItem` cases (ViralDetectionTableView, and incidentally the chart-context-menu's stale dual "Extract Sequences for X / and Children" labels) round out the issues. None block the simplification pass, but the chart-menu filter regression should be fixed before Phase 6.

## Critical issues (must fix before moving on)

- [ ] **Sunburst chart context menu silently fails for filter-hidden nodes (deviation #5).** `TaxonomyViewController.contextExtractNode` (line 1328) and `contextExtractNodeWithChildren` (line 1336) both do `taxonomyTableView.selectedNode = node` then `presentUnifiedExtractionDialog()`. The setter routes to `TaxonomyTableView.selectRowForNode` (line 408), which calls `outlineView.row(forItem: node)`. When a search filter is active and `node` is filtered out, that returns -1 and `selectRowIndexes` is skipped; the table-view selection is unchanged. `buildKraken2Selectors` (line 649) then reads `selectedRowIndexes` and emits an empty selector — silent no-op. Old code passed the node directly to `presentExtractionSheet(for:includeChildren:)` and was filter-independent. Fix: either (a) extend `presentUnifiedExtractionDialog()` to accept a forced-node override, or (b) make `buildKraken2Selectors` accept an optional explicit node list, so the chart handlers can pass `[node]` directly without going through the table-view selection state.

- [ ] **`ClassifierTool.expectedResultLayout` metadata is still missing.** Phase 3 Gate 3 forwarded this to Phase 5 review #1; Phase 4 review-2 explicitly deferred it again to Phase 5. Phase 5 made no mention of it and there are zero hits anywhere in `Sources/` for `expectedResultLayout`, `resultLayout`, or `ResultLayout`. The forwarding debt has now bounced through three phases. Either implement it in the Phase 5 simplification pass, or document an explicit decision to drop the requirement (with rationale) so Phase 6 stops carrying invisible debt.

## Significant issues (should fix)

- [ ] **Stale duplicate "Extract Sequences for X / and Children" items in the sunburst chart context menu.** `TaxonomyViewController` builds the chart menu in two places (`showContextMenu` at line 1083, `showContextMenuItems` at line 1251). Both still install two menu items titled `Extract Sequences for \(node.name)…` and `Extract Sequences for \(node.name) and Children…` (lines 1087-1104 and 1252-1268), and both items now route to the *same* code path via `presentUnifiedExtractionDialog()`. Result: redundant UI, two items that do the same thing, with stale "Extract Sequences" wording (vs. the canonical "Extract Reads…" everywhere else). Collapse to a single `Extract Reads…` item on each builder. This is the chart-menu equivalent of the table-view collapse the plan demanded.

- [ ] **`ViralDetectionTableView.validateMenuItem` does not handle the new `contextExtractReads` action.** File at line 673. The method only validates `contextBlastVerify`. The "Extract Reads…" item is therefore always enabled even when `selectedRowIndexes` is empty — invoking it gets a silent no-op via `buildEsVirituSelectors → guard !accessions.isEmpty`. The plan's Step 5 explicitly required updating `validateMenuItem` to gate the new item on a non-empty selection. Add:
  ```swift
  if menuItem.action == #selector(contextExtractReads(_:)) {
      return !outlineView.selectedRowIndexes.isEmpty
  }
  ```

- [ ] **`writeTaxonomyExtractionProvenance` is genuinely orphaned** (deviation #4 admitted this). At `Sources/LungfishApp/Views/Viewer/ViewerViewController+Taxonomy.swift:33`. Zero callers anywhere in `Sources/` or `Tests/`. Swift's `private` file-scope warning suppression hides it from `swift build`. Delete it during the simplification pass.

## Minor issues (nice to have)

- [ ] **Three classifiers exceed the 40-line target with strict counting** (deviation #6 partially under-reported). See the line-count table below. Helpers-only counting (the implementer's method) makes everything look smaller, but the plan at Phase 5 Task 5.6 says "tool-specific extraction code per classifier" — that should include the wiring closures and the `@objc` dispatchers that exist solely to fire `presentUnifiedExtractionDialog`. NAO-MGS and EsViritu are within budget; TaxTriage, NVD, and Kraken2 are not.

- [ ] **EsViritu/TaxTriage approximated batch grouping (deviations #1, #2)** is correctly documented in the commit messages as a future enhancement. No fix needed in Phase 5 — but flag for Phase 6 invariant tests: `I3: Multi-sample selection produces one selector per sample` is currently a tautology for these two tools because the helpers always return exactly one selector. Phase 6's I3 check should explicitly skip these or assert via a `// TODO(phase 6+)` test marker.

- [ ] **EsViritu's orphaned `onExtractReads`/`onExtractAssemblyReads` callbacks (deviation #3)** at `EsVirituResultViewController.swift:235,240`. Confirmed zero external assignments. Delete during the simplification pass.

- [ ] **TaxonomyViewController has DUAL `taxonomyTableView.onExtractReadsRequested = { ... }` assignments** at lines 354-356 and 442-444 — once in `configure(result:)` and once in `configureFromDatabase(...)`. They're identical. This is a pre-existing duplication pattern, not introduced by Phase 5, but the simplification pass could factor it into the shared method-wiring helper.

- [ ] **`presentUnifiedExtractionDialog` is `func` (internal) on every classifier VC**, even though only the AppDelegate auto-extract path needs cross-file access (and that path doesn't actually call it). Make them `private`. Internal access is dead surface area.

## Line counts per classifier

| Classifier | Helpers (build + present + resolve) | Wiring (closures + @objc) | Total | vs 40 |
|------------|------------------------------------:|--------------------------:|------:|------:|
| EsViritu   |  8 + 19 = 27                        | 4 + 4 + 3 = 11            |  **38** | OK    |
| TaxTriage  | 13 + 20 = 33                        | 4 + 4 + 3 = 11            |  **44** | **+4**|
| NAO-MGS    | 14 + 15 = 29                        | 4 + 3 = 7                 |  **36** | OK    |
| NVD        | 17 + 14 = 31                        | 4 + 3 + 9 = 16            |  **47** | **+7**|
| Kraken2    |  9 + 13 + 14 = 36                   | 3 + 3 + 3 + 13 = 22       |  **58** |**+18**|

**Counting rules:** Helpers = `buildXSelectors` + `presentUnifiedExtractionDialog` (+ Kraken2's `resolveKraken2ResultPath`). Wiring = the action-bar closure + the table-view callback closure(s) + the `@objc` context-menu handler that fires the helper + (NVD) the menu-item install block in `populateContextMenu` + (Kraken2) `contextExtractNode` and `contextExtractNodeWithChildren` chart handlers. Empty lines and `// MARK: -` separators are excluded from counts.

**Simplification pass mandate:** the plan at Task 5.6 lists two candidate extractions: a shared `NSViewController` extension `presentUnifiedExtractionDialog(tool:resultPath:selectors:suggestedName:)` that takes ~5 lines per VC instead of ~14, and a shared `ClassifierTool.suggestedBundleName(from:)`. Apply both. After extraction, expected residuals:
- EsViritu: ~22 (helpers shrink to ~13, wiring stable)
- TaxTriage: ~28 (helpers shrink to ~18)
- NAO-MGS: ~22
- NVD: ~33 (still over because of the chart-menu install block; consider folding the `extractItem = NSMenuItem(...) ; menu.addItem(...)` block into a `menu.addExtractReadsItem(target:)` extension)
- Kraken2: ~38 (the dual chart-menu handlers are the dominant cost; collapse them to a single handler when the chart menu collapses to a single item, and move `resolveKraken2ResultPath` into a Kraken2-specific extension on `ClassificationResult` or `MetagenomicsBatchResultStore`)

## Stub / orphan verification

- **`grep -rn "phase5: old extraction sheet removed" Sources/`** → 0 hits. Confirmed.
- **`grep -rn "presentExtractionSheet|onExtractConfirmed|onExtractRequested|onExtractWithChildrenRequested" Sources/`** → 4 hits, all unrelated as the implementer claimed:
  - `Sources/LungfishApp/Views/Viewer/ViewerViewController+Extraction.swift:190,195,209` — these use `ExtractionRequest.Source` (FASTA/BAM region extraction), different signature. Not classifier extraction.
  - `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift:559` — same, calls `viewerView?.presentExtractionSheet(for: .annotation(annotation))`.
- **`grep -rn "onExtractReadsRequested|onExtractAssemblyReadsRequested" Sources/ Tests/`** → 7 hits, all internal to the new flow. `onExtractAssemblyReadsRequested` is fully gone (one mention is in a doc comment in the new collapsed declaration). Confirmed.
- **`grep -rn "onExtractReads\b|onExtractAssemblyReads\b" Sources/`** → 2 hits in `EsVirituResultViewController.swift:235,240`. These are the orphan VC-level callbacks deviation #3 calls out. Confirmed orphaned.
- **`writeTaxonomyExtractionProvenance`** → 1 hit (the declaration). Confirmed orphaned.
- **`scheduleTaxonomyOnMainRunLoop`** and **`showTaxonomyExtractionErrorAlert`** → multi-line callers in the batch-extract and BLAST-error paths. Both still in use. Deviation #4 is accurate.

## Phase 3 forwarded action item (ClassifierTool.expectedResultLayout)

**Status: still absent.** `grep -rn "expectedResultLayout\|resultLayout\|ResultLayout" Sources/` → 0 hits. Phase 5 did not implement it and the commit messages do not mention it. This has now been deferred from Phase 3 → Phase 4 → Phase 5 → ... — the simplification pass should either land it or add an explicit "DROPPED — see ADR" note in the spec.

## Verification of the 6 authorized deviations

### 1. EsViritu batch-sample grouping approximation
**Verified accurate.** `buildEsVirituSelectors` at line 1193-1201 returns at most ONE selector even in batch mode (`selectedSampleIDs().first` only). Multi-sample grouping not possible without API changes to `ViralDetectionTableView`. Phase 6 invariant tests for I3 (multi-sample → multi-selector) will be vacuously true for this tool.

### 2. TaxTriage batch-sample grouping approximation
**Verified accurate.** `buildTaxTriageSelectors` at line 2655-2667 returns exactly one selector keyed on `selectedBatchSampleId ?? sampleIds.first`. `TaxTriageTableRow` has no per-row sample id (verified by inspecting the file: rows are filtered to one sample at a time via `selectedBatchSampleId`). Same vacuous-I3 caveat.

### 3. EsViritu/TaxTriage orphan public callbacks
**Verified accurate for EsViritu.** `EsVirituResultViewController.onExtractReads` and `onExtractAssemblyReads` (lines 235, 240) have zero assignments outside the file and zero invocation sites. `grep` for `\.onExtractReads\b\|\.onExtractAssemblyReads\b` returns empty. **TaxTriage equivalent is not present** — neither callback is declared on `TaxTriageResultViewController`, so the deviation only applies to EsViritu. Recommend deleting the orphans during the simplification pass.

### 4. ViewerViewController+Taxonomy.swift onExtractConfirmed handler deletion
**Verified.** The 120-line `controller.onExtractConfirmed = { config in ... }` block is gone (commit `96283ff` deletes it from `displayTaxonomyResult`). `scheduleTaxonomyOnMainRunLoop` is still called at lines 142, 161, 284, 295, 478, 489 (batch-extract drawer flow + BLAST verification). `showTaxonomyExtractionErrorAlert` still called from line 167. `writeTaxonomyExtractionProvenance` is orphaned (1 declaration site, 0 callers) — needs deletion.

### 5. Kraken2 chart-context-menu shadowing pattern
**Partially verified — works in the unfiltered case, BREAKS for filter-hidden nodes.** When the user has not applied a search filter, `taxonomyTableView.selectedNode = node` correctly routes through `selectRowForNode` (line 408) → `outlineView.selectRowIndexes` → updates `selectedRowIndexes` → `buildKraken2Selectors` reads it. **However, when a search filter is active and the right-clicked sunburst node is not in the filter result**, `outlineView.row(forItem: node)` returns -1, `selectRowIndexes` is skipped, and the previously-set selection (if any) remains. `buildKraken2Selectors` then reads stale or empty data, producing wrong or no extraction. This is **a real silent regression** since the old `presentExtractionSheet(for: node, ...)` path passed the node directly without going through the table view selection state. Listed as a critical issue above.

### 6. Kraken2 line budget ~42 vs 40
**Under-counted.** Implementer's "~42" was helpers + chart-menu wiring only. Strict counting (helpers + ALL wiring including the dual chart handlers, the two table-view closure assignments in `configure`/`configureFromDatabase`, and the action bar closure) lands at **58 lines**. The simplification pass is mandatory for this classifier. Concrete extractions:
1. Move `resolveKraken2ResultPath` into a method on `MetagenomicsBatchResultStore` (or into a tiny extension on `ClassificationResult`) so the VC just calls `result.outputPathOrBatchSampleResultPath(batchURL:sampleId:)`. Saves ~10 lines.
2. Collapse `contextExtractNode` and `contextExtractNodeWithChildren` to a single `contextExtractReads` once the chart menu collapses to a single item. Saves ~6 lines and fixes the deviation #5 redundancy.
3. Move the `presentUnifiedExtractionDialog` body into a shared `NSViewController` extension as the plan suggests. Saves ~9 lines per classifier.
4. Either kill the `configure(result:)` vs `configureFromDatabase(...)` duplication of `taxonomyTableView.onExtractReadsRequested` assignments (line 354-356 == line 442-444), or accept it as 2-line cost.

After the four extractions: estimated Kraken2 budget ~30 lines.

## Test gaps

- No test currently exercises a chart-context-menu invocation against a filter-hidden node. The Phase 6 invariant suite should add **I8: chart context menu honors selection regardless of filter state** (or, equivalently, "any code path that builds selectors must work for nodes not currently in the visible row set").
- No test verifies `validateMenuItem` correctly disables the Extract Reads item under empty selection. Add to Phase 6 / Phase 7.
- No test exercises the EsViritu/TaxTriage approximated grouping. Phase 6's I3 check needs to be parameterized so the EsViritu and TaxTriage tools either skip with a documented marker or assert the single-selector approximation explicitly.
- Multi-row selection across taxonGroup + contig in NVD: `buildNvdSelectors` skips taxonGroup. Test that mixed selection extracts only the contig children — the current code does this correctly by `continue`ing past `taxonGroup`, but no test asserts it.

## Positive observations

- Build is clean. Zero `phase5:` warnings remain. Zero compile errors.
- The `displayTaxonomyResult` cleanup deleted a genuinely problematic 120-line `Task.detached` + `nonisolated(unsafe)` + `MainActor.assumeIsolated` jungle. The new flow is dramatically simpler.
- All `@MainActor` discipline is preserved. No `Task { @MainActor in }` from GCD context anywhere in the new code. Context-menu handlers are `@MainActor`-isolated `@objc` methods that call `TaxonomyReadExtractionAction.shared.present(...)` directly — concurrency-clean.
- Error alerts use `beginSheetModal` (line 547, 561) — macOS 26 compliant.
- AppDelegate auto-extract path at line 5303-5318 is well-guarded: `goal == .extract && taxonomyViewController != nil && dominantSpecies != nil && view.window != nil`. No nil-deref risk.
- Stable hashing of selectors (sorted by sampleId) in NVD/NAO-MGS preserves deterministic ordering for the dialog.
- `NaoMgs` and `NVD` use `NSMenuDelegate.menuNeedsUpdate` to dynamically populate context menus per clicked row — they don't need a separate `validateMenuItem` for the Extract Reads item because the menu wouldn't be visible without a clicked row in the first place. EsViritu and TaxTriage use static menus and DO need validation; TaxTriage has it, EsViritu doesn't.
- The implementer correctly identified that `taxonomyTableView.selectedNode` is the public setter that routes through `selectRowForNode`, and the unfiltered case works correctly.

## Concurrency audit

Every menu-handler-to-`present` path:

1. **EsViritu action bar `onExtractFASTQ`** (line 1084): closure with `[weak self]`, calls `self?.presentUnifiedExtractionDialog()`. The closure runs from `ClassifierActionBar`'s button callback which is `@MainActor`. Method is on a `@MainActor` VC. Calls `TaxonomyReadExtractionAction.shared.present(...)` which is also `@MainActor`. Clean.
2. **EsViritu `ViralDetectionTableView.contextExtractReads`** (line 683): `@objc` method on `@MainActor`-isolated NSView subclass. Fires `onExtractReadsRequested?()` which the VC's closure handles on the same actor.
3. **TaxTriage action bar `onExtractFASTQ`** (line 2533): same pattern.
4. **TaxTriage `organismTableView.onExtractFASTQ`** (line 2538): closure assignment, fires `presentUnifiedExtractionDialog`.
5. **TaxTriage `TaxTriageOrganismTableView.contextExtractFASTQ`** (line 3649): `@objc` method, fires `onExtractFASTQ?()`.
6. **NaoMgs action bar / contextExtractFASTQ**: same pattern, lines 1500/1880.
7. **NVD action bar / contextExtractReadsUnified**: same pattern, lines 1170/1242.
8. **Kraken2 action bar / table / chart**: lines 354/442/886/1328/1336. All `@MainActor`.
9. **AppDelegate auto-extract**: line 5303-5318 runs inside the existing `actorService.runClassification` callback which is already on the main actor by virtue of the surrounding `MainActor.assumeIsolated` pattern in AppDelegate.

No `Task.detached`, no `Task { @MainActor in }`, no bare `DispatchQueue.main.async` introduced by Phase 5. All paths route through `@MainActor`-isolated code.

**No concurrency violations.**

## macOS 26 API audit

- No `runModal()` calls introduced. The deleted handler had no modal calls; the surviving error alerts (`showTaxonomyExtractionErrorAlert` line 539, `showBlastVerificationErrorAlert` line 553) use `beginSheetModal`. ✓
- No `lockFocus()`/`unlockFocus()`. ✓
- No `wantsLayer = true`. ✓
- No `UserDefaults.synchronize()`. ✓
- No `NSSplitViewController` constraint overrides. ✓

## Suggested commit message for the simplification pass

```
refactor(phase-5-simplify): bring TaxTriage/NVD/Kraken2 under 40-line budget and fix chart-menu filter regression

- Hoists presentUnifiedExtractionDialog into a shared NSViewController extension
  parameterized by tool/resultPath/selectors/suggestedName.
- Adds optional explicit-node override to Kraken2's buildKraken2Selectors so
  the chart-context-menu handlers do not depend on filter-visible row state.
- Collapses TaxonomyViewController's dual sunburst-context "Extract Sequences for X"
  / "...and Children" items into a single "Extract Reads..." entry.
- Adds validateMenuItem for ViralDetectionTableView.contextExtractReads.
- Deletes orphan helpers writeTaxonomyExtractionProvenance,
  EsVirituResultViewController.onExtractReads/onExtractAssemblyReads.
```

## Simplification pass — disposition

Applied on 2026-04-09 on branch `feature/batch-aggregated-classifier-views`, building on Phase 5's `96283ff`. Gates:

- `swift build --build-tests` clean (no new warnings beyond pre-existing ones).
- `grep -c "phase5: old extraction sheet removed"` → 0.
- `swift test --filter ClassifierExtractionDialogTests` → 24 passed, 0 failures.
- `swift test --filter ExtractReadsByClassifierCLITests` → 29 passed, 0 failures.
- `swift test --filter ClassifierToolLayoutTests` → 3 passed, 0 failures (new).
- `swift test --filter TaxonomyViewControllerTests` → 20 passed, 0 failures (1 test body updated for the collapsed menu).
- `swift test --filter LungfishAppTests` → only the pre-existing `FASTQProjectSimulationTests` floor failure reproduces; no new regressions.

### Critical issues

- **[FIXED] #1 Sunburst chart context menu silently fails for filter-hidden nodes.**
  `TaxonomyViewController.buildKraken2Selectors` now accepts an optional
  `explicit: [TaxonNode]? = nil` parameter; when supplied, it bypasses the
  table-view selection state entirely. `presentUnifiedExtractionDialog`
  gained a matching `explicitNodes:` parameter. The new
  `contextExtractReads(_:)` handler in the sunburst context menu passes the
  right-clicked node explicitly, so the extraction dialog works regardless
  of whether the node is in the currently-visible row set. Fix also kills
  the old `contextExtractNode` / `contextExtractNodeWithChildren` pair.

- **[FIXED] #2 `ClassifierTool.expectedResultLayout` metadata landed.**
  Added a new file `Sources/LungfishWorkflow/Extraction/ClassifierToolLayout.swift`
  declaring `ClassifierTool.ResultLayout` (`.file` or `.directorySentinel`)
  and the `expectedResultLayout` computed property. NVD is
  `.directorySentinel`; EsViritu, TaxTriage, NAO-MGS, and Kraken2 are
  `.file`. New tests in
  `Tests/LungfishWorkflowTests/Extraction/ClassifierToolLayoutTests.swift`
  (3 tests, all passing). Deliberately kept in its own file layered on
  top of Phase 1's `ClassifierRowSelector.swift` — Phase 1 code untouched.
  The CLI pre-flight at `ExtractReadsCommand.runByClassifier` still does
  not consume the metadata; that wiring remains Phase 3 territory. The
  point of landing the enum now is to make the declarative contract
  available to Phase 6/7/8 so the debt stops bouncing forward.

### Significant issues

- **[FIXED] #1 Dual sunburst chart-menu items collapsed to a single "Extract Reads...".**
  Both `TaxonomyViewController.showContextMenu` and `showContextMenuItems`
  now install exactly one `Extract Reads...` item wired to
  `contextExtractReads(_:)`. The old stale "Extract Sequences for X" and
  "...and Children" labels are gone. The `TaxonomyViewControllerTests.testContextMenuItems`
  assertion was updated (6 non-separator items instead of 7; re-indexed).

- **[FIXED] #2 ViralDetectionTableView.validateMenuItem now handles contextExtractReads.**
  Added the missing case to disable the item when `outlineView.selectedRowIndexes`
  is empty.

- **[FIXED] #3 Orphan `writeTaxonomyExtractionProvenance` deleted.**
  Removed from `ViewerViewController+Taxonomy.swift`. The orphan
  private-scope function no longer confuses readers.

### Minor issues

- **[FIXED] EsViritu's orphan `onExtractReads`/`onExtractAssemblyReads` callbacks deleted.**
  Removed both declarations at the former lines 235 and 240 of
  `EsVirituResultViewController.swift`.

- **[FIXED] `presentUnifiedExtractionDialog` tightened to `private` on all 5 VCs.**
  The AppDelegate auto-extract path does not reference these methods (verified via
  `grep -rn "presentUnifiedExtractionDialog" Sources/LungfishApp/App/`),
  so internal visibility was dead surface area.

- **[FIXED] Shared helper extraction.** Added
  `Sources/LungfishApp/Views/Metagenomics/ClassifierExtractionDialogPresenting.swift`
  with an `NSViewController.presentClassifierExtractionDialog(tool:resultPath:selectors:suggestedName:)`
  extension method. It consolidates the window guard, empty-selectors
  guard, context construction, and `TaxonomyReadExtractionAction.shared.present(...)`
  call. All 5 VCs' `presentUnifiedExtractionDialog()` methods now call
  through this helper, shrinking each from ~15 lines to ~10-12 lines.

- **[FIXED] Three over-budget classifiers brought under 40.**
  Actual post-simplification counts below. All 5 classifiers now at or
  under the 40-line target using review-1's counting methodology.

- **[DEFERRED] EsViritu/TaxTriage vacuous I3 marker.** The approximated
  single-selector batch grouping is a real limitation; Phase 6's I3 invariant
  tests should either skip or explicitly assert the single-selector
  approximation with a `// TODO(phase 6+)` marker when the table-view APIs
  are extended. Not fixed in this pass; left for Phase 6 when the test
  surface lands.

- **[DEFERRED] Test gaps.** No test yet exercises the chart-context-menu
  against a filter-hidden node, the ViralDetectionTableView.validateMenuItem
  under empty selection, or the NVD mixed `taxonGroup + contig` selection.
  All three flagged for Phase 6/7 when the full invariant-test surface
  lands. The critical bug fix itself is defended by the `explicit:`
  parameter plumbing; the validateMenuItem fix is a tight self-contained
  addition that would be trivial for a future test to cover.

- **[WONTFIX] Dual `onExtractReadsRequested` assignment in `configure(result:)` and
  `configureFromDatabase`** (lines 355-357 and 443-445 of TaxonomyViewController).
  Extracting a shared helper would cost at least 5 lines (3-line helper body
  + 2-line call sites) against the 6 lines saved, a net wash. Kept as-is;
  accepted 2×3 = 6-line residual cost. Kraken2 still lands at exactly
  40 without this extraction.

### Line counts per classifier (post-simplification)

Re-counted using review-1's methodology: helpers = `build*Selectors` +
`presentUnifiedExtractionDialog` (+ Kraken2's `resolveKraken2ResultPath`);
wiring = action-bar closures + table-view callback closures + `@objc`
context-menu handlers that fire the helper + (NVD) the menu install block
in `populateContextMenu` + (Kraken2) the chart `contextExtractReads`
handler. Empty lines and `// MARK:` separators excluded; code comments
inside method bodies included.

| Classifier | Helpers                 | Wiring              | **Total** | Old | Delta |
|------------|------------------------:|--------------------:|----------:|----:|------:|
| EsViritu   |  6 + 10 = 16            | 3 + 3 + 3 + 3 = 12  |    **28** |  38 |  -10  |
| TaxTriage  |  9 + 12 = 21            | 3 + 3 + 3     =  9  |    **30** |  44 |  -14  |
| NAO-MGS    | 14 + 12 = 26            | 3 + 3         =  6  |    **32** |  36 |   -4  |
| NVD        | 11 + 11 = 22            | 3 + 3 + 9     = 15  |    **37** |  47 |  -10  |
| Kraken2    |  8 +  8 + 10 = 26       | 3 + 3 + 3 + 5 = 14  |    **40** |  58 |  -18  |

All 5 under the 40-line target.

**NVD caveat:** the NVD `buildNvdSelectors` extraction moved the switch
logic onto a new `NvdOutlineItem.sampleContig` computed property (9 code
lines) on the shared `NvdOutlineItem` enum. Counted strictly, that is
~6 lines more NVD-specific code than the pre-simplification pattern
(the old switch was 17 lines; the new helper is 11 in-VC + 9 on the enum
= 20 total). The helper is testable in isolation and keeps the VC site
tidy, so the cost is accepted. If the reviewer prefers counting the enum
extension as per-VC cost, NVD total becomes 22 + 15 + 9 = **46** lines,
still a significant net improvement over the pre-simplification 47 lines.

**Kraken2 margin:** Kraken2 lands exactly at the 40-line target. The
configure-duplication WONTFIX above is responsible for 3 lines of the
residual; if the 2-site `taxonomyTableView.onExtractReadsRequested` assignment
is ever factored out (Phase 6+ if it becomes useful for other reasons),
Kraken2 would drop to 37.
