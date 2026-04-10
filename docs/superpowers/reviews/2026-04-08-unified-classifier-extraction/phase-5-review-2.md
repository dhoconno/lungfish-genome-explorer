# Phase 5 — Adversarial Review #2

**Date:** 2026-04-09
**Commits reviewed:** 72b34af, bdba3f6, af43b5a, 947c2e5, 96283ff, b206db7
**Reviewer:** independent second adversarial review (clean context, formed
opinion before reading review-1)
**Charter:** Verify Phase 5 + simplification pass close cleanly. Find bugs,
spec violations, concurrency issues, test gaps, fragile patterns, dead code,
duplication, performance issues. Verify the simplification pass did not
introduce new issues.

## Summary

Phase 5 functionally lands. All 5 classifier VCs route through
`TaxonomyReadExtractionAction.shared.present(...)`. The simplification pass
correctly extracts a shared `NSViewController` helper, hits the 40-line
budget for every classifier (independently re-verified), brings Kraken2's
chart-menu filter regression under control via the explicit-node override,
collapses the dual chart menu items, deletes the orphan provenance writer
and EsViritu callbacks, tightens visibility on every `presentUnifiedExtractionDialog`,
and adds the `ClassifierTool.expectedResultLayout` metadata that has been
bouncing forward since Phase 3. Build is clean, no `phase5:` warnings remain,
all targeted test suites pass.

**One real critical bug**: `ClassifierTool.expectedResultLayout` declares
**Kraken2 as `.file`** but Kraken2's actual on-disk shape is a directory
(`config.outputDirectory`) containing a `classification-result.json` sentinel.
`ClassificationResult.load(from:)` requires a directory parameter, not a file.
The metadata-truth will misroute any future Phase 6/7/8 consumer (CLI
pre-flight, GUI file picker) that depends on it. The metadata is currently
dormant so the bug has not yet fired in production code, but the test in
`ClassifierToolLayoutTests.testBamBackedAndKraken2_haveFileLayout` actively
locks in the wrong assumption.

Two other significant issues: a latent select-vs-clicked-row mismatch in
`TaxonomyTableView.validateMenuItem`, and the same class of issue in NVD
when `selectedRowIndexes` and `clickedRow` diverge. Both are masked in
practice by NSTableView/NSOutlineView's default right-click auto-select but
remain a fragile pattern.

## Critical issues (must fix before closing the gate)

- [ ] **`ClassifierTool.expectedResultLayout` mis-classifies Kraken2 as `.file`.**
  `Sources/LungfishWorkflow/Extraction/ClassifierToolLayout.swift:55-62`
  returns `.file` for `.kraken2`. But Kraken2's resolver path is a
  **directory**:
  - `TaxonomyViewController.resolveKraken2ResultPath` returns
    `cr.config.outputDirectory` (a directory) at
    `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift:662`.
  - `ClassifierReadResolver.extractViaKraken2` calls
    `ClassificationResult.load(from: resultPath)` at
    `Sources/LungfishWorkflow/Extraction/ClassifierReadResolver.swift:458`.
  - `ClassificationResult.load(from:)` at
    `Sources/LungfishWorkflow/Metagenomics/ClassificationResult.swift:178`
    treats its argument as a directory and reads
    `directory.appendingPathComponent("classification-result.json")` from it.
    Pre-flight check `FileManager.default.fileExists(atPath: fileURL.path)`
    fails with `sidecarNotFound(directory)` if you hand it a regular file.
  - `AppDelegate` auto-extract path at
    `Sources/LungfishApp/App/AppDelegate.swift:5309` likewise passes
    `capturedConfig.outputDirectory` (a directory).

  Kraken2 is therefore `.directorySentinel` (or, more precisely, a third
  case `.directory` — its sentinel is `classification-result.json`).
  `ClassifierToolLayoutTests.testBamBackedAndKraken2_haveFileLayout` enshrines
  the wrong assumption and the test will need to flip when the metadata is
  consumed by the CLI pre-flight (Phase 6) or the GUI file chooser (Phase 7).

  This is a **latent bug** because nothing currently consumes
  `expectedResultLayout` (`grep` returns 0 hits in `Sources/` outside the
  declaration). It will fire the moment a future phase plumbs it into the
  CLI argument parser ("expected file at `…/classification-001/`, not a
  directory") or the GUI chooser presents an `NSOpenPanel` with
  `canChooseFiles = true; canChooseDirectories = false` for Kraken2 — both
  of which the file's docstring explicitly markets as the consumers of the
  metadata.

  Fix options:
  - **Preferred:** add a third `case .directory` (parent picker, no sentinel
    enforcement) and tag Kraken2 with it. NVD stays `.directorySentinel`
    because NVD has a known sentinel filename. Kraken2's sentinel is
    architectural (`classification-result.json`) but the user-facing
    handle is the directory.
  - Or: re-tag Kraken2 as `.directorySentinel` and document that the
    sentinel is `classification-result.json`. Less precise but matches the
    existing enum cases.

  Either way the test must be split: `testKraken2_hasDirectoryLayout` (or
  `…SentinelLayout`) and `testBamBackedTools_haveFileLayout` covering only
  EsViritu/TaxTriage/NAO-MGS.

  **Note**: re-examine whether `.file` is even right for the BAM-backed
  trio. The resolver in `ClassifierReadResolver.resolveBAMURL`
  (`ClassifierReadResolver.swift:259-262`) does
  `let resultDir = resultPath.hasDirectoryPath ? resultPath : resultPath.deletingLastPathComponent()`
  and then scans siblings — i.e. the BAM-backed tools' `resultPath` is also
  effectively a sentinel that the resolver navigates from. The semantic
  difference between `.file` and `.directorySentinel` collapses across all
  five tools. The metadata's design might want a fundamental rethink before
  Phase 6/7 wires it in.

## Significant issues

- [ ] **`TaxonomyTableView.validateMenuItem` enables Extract Reads on
  `clickedNode != nil` but the handler reads `selectedRowIndexes`** —
  asymmetric gating. `Sources/LungfishApp/Views/Metagenomics/TaxonomyTableView.swift:607-609`:
  ```swift
  if menuItem.action == #selector(contextExtractReads(_:)) {
      return !outlineView.selectedRowIndexes.isEmpty || clickedNode != nil
  }
  ```
  Then `contextExtractReads` (line 613) calls `onExtractReadsRequested?()`,
  which `TaxonomyViewController` routes to `presentUnifiedExtractionDialog()`,
  which calls `buildKraken2Selectors(explicit: nil)` — and `explicit: nil`
  reads from `selectedRowIndexes`. If a user right-clicks a row that
  NSOutlineView fails to auto-select (e.g. multi-row selection where the
  right-click target is a different row), the menu item would be enabled
  via `clickedNode != nil` but the dialog would silently no-op because
  `actionable.isEmpty`. The chart-menu fix uses the explicit-node pattern
  to avoid exactly this; the table-menu validation should mirror it. Either
  remove the `|| clickedNode != nil` clause or make `contextExtractReads`
  pass the clicked node explicitly via the same `explicit:` plumbing.

- [ ] **NVD has the same selected-vs-clicked divergence.**
  `NvdResultViewController.populateContextMenu` is built per `clickedRow`
  via `menuNeedsUpdate` (line 2070), but `buildNvdSelectors` reads
  `outlineView.selectedRowIndexes` (line 1225). In practice
  NSOutlineView's default `menu(for:)` selects the right-clicked row before
  showing the menu, so `clickedRow ∈ selectedRowIndexes` for the common
  case — but this is fragile UI dependency. If a future delegate override
  changes that behavior or a multi-row selection persists across right-click
  to a different row, the dialog will operate on the **previously-selected**
  rows instead of the row whose menu the user just opened. The fix is the
  same as for Kraken2: hoist clicked-row resolution into the helper or
  pass an explicit list.

- [ ] **`buildKraken2Selectors`'s nodes-then-filter ordering may suppress
  legitimate selections silently.**
  `TaxonomyViewController.swift:651-657`:
  ```swift
  let nodes: [TaxonNode] = explicit ?? taxonomyTableView.outlineView.selectedRowIndexes.compactMap {
      taxonomyTableView.outlineView.item(atRow: $0) as? TaxonNode
  }
  let actionable = nodes.filter { isActionableTaxonNode($0) }
  guard !actionable.isEmpty else { return [] }
  ```
  When the user multi-selects 3 rows (2 of which are non-actionable, e.g.
  intermediate ranks above the resolver's threshold), the helper silently
  drops the non-actionable rows and only extracts the actionable ones. No
  warning, no message — and no test asserts this. If the user expects "all
  3 rows", they'll get a partial extract with no indication. Consider
  surfacing a count-mismatch in the dialog header, or at least adding a
  test that locks in the silent-drop semantics so future readers don't
  regress it.

## Minor issues

- [ ] **Kraken2 dual `taxonomyTableView.onExtractReadsRequested` assignment in
  `configure(result:)` and `configureFromDatabase(_:)`.** Lines 355-357 and
  443-445. Identical 3-line closures duplicated for the two configuration
  paths. Review-1 marked this WONTFIX as a "net wash" because extracting it
  would cost more lines than it saves under the line-count rules. I agree
  with the WONTFIX disposition, but flag that the duplication makes Kraken2
  fragile if someone updates one site without the other. A 1-line comment
  pointing the two assignments at each other (`// Kept in sync with line 443`)
  would be a cheap defense.

- [ ] **`ClassifierExtractionDialogPresenting.swift`'s extension is unscoped
  on NSViewController.** It adds `presentClassifierExtractionDialog` to
  every `NSViewController` in the binary. Other VCs (FASTQ viewers, FASTA
  viewers) get a method they shouldn't be calling. The extension should
  either be `internal` to a protocol that the 5 classifier VCs conform to,
  or scoped via `where Self: ClassifierExtractionPresenting`. Low priority —
  the method requires a `ClassifierTool` argument so misuse is unlikely —
  but it pollutes auto-complete on every NSViewController in the project.

- [ ] **The shared helper silently no-ops when `view.window` is nil.**
  `ClassifierExtractionDialogPresenting.swift:48`. The doc comment justifies
  this as "avoids presenting an orphan sheet" — defensible — but it also
  means the AppDelegate auto-extract path (`AppDelegate.swift:5306`) loses
  one of its guards if it ever bypasses the explicit `view.window` check.
  Currently AppDelegate constructs the `Context` and calls
  `TaxonomyReadExtractionAction.shared.present(context: ctx, hostWindow: window)`
  directly (not through the helper), so the helper's silent-no-op behavior
  is OK in the current code path. Worth noting that if the auto-extract is
  ever refactored to call through the shared helper, the `view.window`
  guard becomes the only failure mode and there's no error log.

- [ ] **The `view` property access in `presentClassifierExtractionDialog`
  triggers `loadView()` if the VC has not yet been added to a window.**
  Calling `view.window` for an unloaded VC will load the view (a UIKit/AppKit
  side effect), which then returns nil for `.window` because no window is
  attached. Worst case: the helper loads the view, returns nothing, and
  the user is left wondering why nothing happened. Not actually a bug
  because the 5 VCs are always loaded before menu interaction is possible,
  but the silent-load is a fragile invariant.

- [ ] **EsViritu's `selectedSampleIDs().first` ignores non-first samples in
  batch mode.** Line 1187 in `EsVirituResultViewController.swift`. Documented
  as deviation #1 and accepted; I confirmed the table-view API does not
  expose per-row sample ids. Phase 6 invariant I3 will be vacuously true
  for EsViritu and TaxTriage. Recommend a test marker (`// PHASE-6-VACUOUS:
  EsViritu/TaxTriage cannot satisfy I3 until table API supports per-row
  sample ids`) so future readers know why the assertion is skipped.

- [ ] **`buildNaoMgsSelectors` fold logic.** Line 1546-1550. The bucket
  pattern uses a struct-literal initializer and re-assignment to update the
  dictionary, which works but is more verbose than necessary. Could be
  written using `bySample[row.sample, default: ...]` once with named-tuple
  destructuring. Cosmetic only.

## Test gaps

- **No test verifies Kraken2's `expectedResultLayout` matches the actual
  resolver behavior** — i.e. there's no integration test that
  (a) constructs a `ClassificationResult` on disk, (b) calls
  `expectedResultLayout`, (c) validates that the chosen layout actually
  works with `ClassificationResult.load(from:)`. Such a test would have
  caught the critical bug above.

- **No test exercises the chart-menu explicit-node override under filter
  state.** The fix exists and the wiring is plumbed, but `ClassifierToolLayoutTests`,
  `TaxonomyViewControllerTests`, etc. don't actually exercise
  `presentUnifiedExtractionDialog(explicitNodes:)` against a filtered table
  state. Phase 6's I8 invariant test should cover this.

- **No test verifies the `view.window` silent-no-op contract in the shared
  helper.** A unit test could construct an unwindow'd VC, call the helper
  with non-empty selectors, and assert that
  `TaxonomyReadExtractionAction.shared.present` was NOT called. Currently the
  silent-no-op semantics live only in the docstring.

- **No test asserts the `actionable` filter in `buildKraken2Selectors`
  silently drops non-actionable rows.** A two-row selection (1 actionable,
  1 non-actionable) should produce 1 selector with 1 taxId, and the test
  should lock in this behavior so a future "show error if actionable count
  != selection count" change is intentional rather than accidental.

- **`TaxonomyTableView.validateMenuItem`'s asymmetry between `selectedRowIndexes`
  and `clickedNode` is uncovered.** A test that
  (a) selects row 5, (b) clicks row 7 to populate `clickedRow` without
  selecting it, (c) calls `validateMenuItem` should expose whether the
  Extract Reads item is correctly gated against the actual extraction path.

## Positive observations

- **Build is clean.** Zero `phase5:` warnings, zero new compiler warnings.
- **All target test suites pass:**
  - `ClassifierExtractionDialogTests`: 24/24
  - `TaxonomyViewControllerTests`: 20/20
  - `ClassifierToolLayoutTests`: 3/3
- **Concurrency is clean.** All menu handlers, action-bar closures, and
  the AppDelegate auto-extract path stay on `@MainActor`. No
  `Task { @MainActor in }` from GCD context, no `DispatchQueue.main.async`
  without `MainActor.assumeIsolated`, no `Task.detached` awaiting
  `@MainActor` methods. The `ViewerViewController+Taxonomy` deletion
  removed a 120-line `Task.detached` jungle and replaced it with synchronous
  `present(...)` calls — net concurrency simplification.
- **macOS 26 compliant.** No `runModal()`, no `lockFocus()`/`unlockFocus()`,
  no `wantsLayer = true`, no `UserDefaults.synchronize()`, no
  `NSSplitViewController` constraint overrides.
- **Shared helper extraction is well-scoped.** The `NSViewController` extension
  collapses the per-VC boilerplate from ~15 lines to ~5 (verified
  independently in all 5 VCs). The window-guard + empty-selectors-guard
  hoist correctly mirrors the per-VC checks and the docstring is precise.
- **Chart-menu filter fix is correct.** The explicit-node override path
  bypasses `selectedRowIndexes` entirely and routes the right-clicked node
  directly into the selector builder. Both `showContextMenu` and
  `showContextMenuItems` install a single "Extract Reads…" item with the
  node attached as `representedObject`, and `contextExtractReads(_:)`
  unpacks it before calling `presentUnifiedExtractionDialog(explicitNodes: [node])`.
- **NVD `sampleContig` hoist is sound.** The computed property on
  `NvdOutlineItem` correctly maps `.contig` and `.childHit` to the
  `(sampleId, qseqid)` tuple and returns `nil` for `.taxonGroup`. The
  helper testably encapsulates the pattern match and shrinks
  `buildNvdSelectors` to 11 lines.
- **Orphan deletions verified clean.**
  `grep -rn "writeTaxonomyExtractionProvenance" Sources/ Tests/` → 0 hits.
  `grep -rn "onExtractAssemblyReadsRequested" Sources/` → 0 hits.
  `\.onExtractReads\b` and `\.onExtractAssemblyReads\b` → 0 hits.
- **Visibility tightening verified.** All 5 `presentUnifiedExtractionDialog`
  methods are `private`. Confirmed via `grep -n "presentUnifiedExtractionDialog"`
  on each VC.
- **Helper usage verified across all 5 VCs.**
  `grep -rn "presentClassifierExtractionDialog\b" Sources/` → 6 hits (1
  declaration + 5 callers).
- **AppDelegate auto-extract path is correctly constructed.** Line 5305-5318
  guards on `goal == .extract && taxonomyViewController != nil &&
  dominantSpecies != nil && view.window != nil`, constructs a
  `ClassifierRowSelector` with the correct `[topSpecies.taxId]`, builds the
  context, and calls `present(...)` directly (not via the shared helper,
  which is fine — it's an entirely different call site).

## Line counts per classifier (independent re-count)

Counted using review-1's methodology: helpers = `build*Selectors` +
`presentUnifiedExtractionDialog` (+ Kraken2's `resolveKraken2ResultPath`);
wiring = action-bar closures + table-view callback closures + `@objc`
context-menu handlers + (NVD) menu install block in `populateContextMenu`
+ (Kraken2) chart `contextExtractReads` handler. Empty lines and
`// MARK: -` separators excluded.

| Classifier | Helpers       | Wiring        | Total | vs 40 |
|------------|--------------:|--------------:|------:|------:|
| EsViritu   | 16            | 12            |    28 | OK    |
| TaxTriage  | 21            |  9            |    30 | OK    |
| NAO-MGS    | 26            |  6            |    32 | OK    |
| NVD        | 22            | 15            |    37 | OK    |
| Kraken2    | 26            | 14            |    40 | OK (at target) |

**Counts match implementer's reported numbers.** All 5 at or under the
40-line target. Kraken2 sits exactly at 40 — with the
WONTFIX duplication of the `onExtractReadsRequested` assignment in
`configureFromDatabase` accounting for 3 of the 14 wiring lines. Removing
that duplication via a private helper would land Kraken2 at 37.

## Concurrency audit

- No `Task { @MainActor in }` from GCD background context.
- No bare `DispatchQueue.main.async` accessing `@MainActor` state without
  `MainActor.assumeIsolated`.
- No `Task.detached` awaiting `@MainActor` methods.
- No `alert.runModal()` introduced. `showTaxonomyExtractionErrorAlert` and
  `showBlastVerificationErrorAlert` use `beginSheetModal` (lines 519, 533 in
  `ViewerViewController+Taxonomy.swift`).
- Shared helper is `@MainActor`-annotated; all 5 callers are `@MainActor`-isolated
  VCs invoking from `@objc` menu handlers and action-bar closures.

**No concurrency violations.**

## macOS 26 audit

- No deprecated `lockFocus`/`unlockFocus` introduced.
- No `wantsLayer = true` introduced.
- No `UserDefaults.synchronize()` introduced.
- No `NSSplitViewController` constraint overrides on existing or new code.
- All alerts use `beginSheetModal`.
- No deprecated `constrainMinCoordinate`/`constrainMaxCoordinate`/`canCollapseSubview`
  overrides.

## Verification of simplification-pass deltas

| Concern | Outcome |
|---------|---------|
| Shared helper compiles & all 5 VCs use it | YES (6 grep hits, 5 callers + decl) |
| `buildKraken2Selectors(explicit:)` overrides selection state | YES, chart handler passes `[node]` directly |
| `ClassifierTool.expectedResultLayout` semantics | **NO** — Kraken2 mis-classified as `.file`, see Critical |
| Orphan deletions clean | YES (`writeTaxonomyExtractionProvenance`, `onExtractReads`, `onExtractAssemblyReads` all gone) |
| Line counts hit claimed budgets | YES (28/30/32/37/40 — matches) |
| NVD `sampleContig` hoist sound | YES (computed property on enum, correct switch) |
| Dual `configure`/`configureFromDatabase` Kraken2 closure | Still present (WONTFIX, accepted) |
| ViralDetectionTableView `validateMenuItem` | Now handles `contextExtractReads` (line 678) |
| Dual chart-menu items collapsed | YES (single "Extract Reads…" in both `showContextMenu` and `showContextMenuItems`) |
| `presentUnifiedExtractionDialog` private on all 5 VCs | YES |
| `swift test --filter ClassifierToolLayoutTests` | 3/3 pass |
| `swift test --filter TaxonomyViewControllerTests` | 20/20 pass |
| `swift test --filter ClassifierExtractionDialogTests` | 24/24 pass |
| Build clean | YES, 0 `phase5:` warnings |

## Verdict

**NOT ready, additional fix required** before closing the Phase 5 gate:

1. **Fix `ClassifierTool.expectedResultLayout` Kraken2 mis-classification.**
   Either re-tag `.kraken2` as `.directorySentinel` (or add a `.directory`
   case), update `ClassifierToolLayoutTests.testBamBackedAndKraken2_haveFileLayout`
   to split Kraken2 out, and re-run the suite. The metadata is dormant but
   it's the only critical bug in this phase and the test enshrines wrong
   semantics. Fixing it now is a 5-minute change; deferring it means Phase
   6/7/8 will discover it the hard way.

The other significant issues (asymmetric `validateMenuItem` gating in
TaxonomyTableView; selected-vs-clicked divergence in NVD; silent
non-actionable drop in Kraken2 selector build) are real but defensible as
known fragile patterns to defend in Phase 6 invariant tests. They don't
block this gate as long as the critical bug above is fixed.

After fixing the Kraken2 layout mis-classification, Phase 5 closes.

---

## Divergence from review-1

Issues I found that review-1 missed:

- **Kraken2 `expectedResultLayout` is `.file` but should be `.directory`/`.directorySentinel`.**
  Review-1 marked the metadata as "[FIXED] #2 `ClassifierTool.expectedResultLayout`
  metadata landed" without verifying that the per-tool tagging actually
  matches the resolver's on-disk expectations. The simplification pass landed
  the enum and tagged Kraken2 with `.file`, but Kraken2's resolver loads
  from a directory, not a file, and the AppDelegate / VC both pass directory
  URLs. This is the most consequential bug in the phase and is dormant
  only because no consumer of the metadata exists yet.
- **`TaxonomyTableView.validateMenuItem`'s asymmetric gating** between
  `selectedRowIndexes` and `clickedNode`. Review-1 didn't probe the
  asymmetry between menu validation reads and selector-builder reads.
- **NVD's `clickedRow`-vs-`selectedRowIndexes` divergence** in
  `populateContextMenu` vs `buildNvdSelectors`. Review-1 noted the dynamic
  menu pattern as a positive observation but did not trace it through to
  the selector builder.
- **Silent-drop of non-actionable rows in `buildKraken2Selectors`.** The
  `actionable` filter discards selected rows without surface, and there's
  no test locking in the semantics.
- **Shared helper extension is unscoped on `NSViewController`** —
  pollutes auto-complete on every VC in the binary. Review-1 marked the
  helper as a positive observation but did not flag the namespace concern.
- **`view.window` access loads the VC via `loadView()` side effect** if
  the helper is called on an unloaded VC. Practical impact is nil but the
  invariant is fragile.

Issues review-1 found that I did not (or downgraded):

- **Dual sunburst chart-menu items "Extract Sequences for X / and Children"**
  pre-simplification: this was fixed in `b206db7`, so I encountered it as
  a single "Extract Reads…" item and verified the collapse, rather than
  finding it as a bug.
- **Pre-simplification Kraken2 line budget at 58 lines.** I only counted
  the post-simplification state and verified 40. Review-1 caught the
  pre-simplification over-budget condition.
- **`presentUnifiedExtractionDialog` was `internal` instead of `private` on all
  5 VCs.** This was tightened in the simplification pass. I verified the
  fixed state.
- **`writeTaxonomyExtractionProvenance` orphaned.** Same — fixed in
  simplification, I verified the deletion was clean.
- **EsViritu `onExtractReads` / `onExtractAssemblyReads` orphaned.** Same.

Verdict:

- **NOT ready to close the gate.** One concrete fix required:
  - `Sources/LungfishWorkflow/Extraction/ClassifierToolLayout.swift:55-62`:
    Move `.kraken2` out of the `.file` group. Either add a `.directory`
    case or re-tag as `.directorySentinel`.
  - `Tests/LungfishWorkflowTests/Extraction/ClassifierToolLayoutTests.swift:18-27`:
    Split `testBamBackedAndKraken2_haveFileLayout` into
    `testBamBackedTools_haveFileLayout` (`[.esviritu, .taxtriage, .naomgs]`)
    and `testKraken2_hasDirectoryLayout`.
  - Re-run `swift test --filter ClassifierToolLayoutTests` to confirm 3/3.

  No other blocker. After this single change, Phase 5 closes and Phase 6
  can begin.

---

## Gate-3 fix disposition (controller's resolution)

Controller: Phase 5 Gate 3 fix pass. Applied the critical Kraken2 layout
fix plus one cheap Significant follow-up; the other Significant/Minor
items are deferred per explicit scope. Commit: see `fix(phase-5): Kraken2
result-layout metadata + table-menu validation tightening`.

### Critical

- **Kraken2 `expectedResultLayout` mis-classified as `.file`** — **FIXED**.
  Re-tagged `.kraken2` as `.directorySentinel` in
  `Sources/LungfishWorkflow/Extraction/ClassifierToolLayout.swift`. Rewrote
  the `.directorySentinel` doc comment to explain that the case covers BOTH
  "scan-for-siblings" (NVD, no fixed sentinel filename) AND "fixed sentinel
  filename" (Kraken2, `classification-result.json`). Added per-case inline
  doc comments on the switch arms naming each tool's concrete layout. Test
  `testBamBackedAndKraken2_haveFileLayout` split into
  `testBamBackedTools_haveFileLayout` (EsViritu, TaxTriage, NAO-MGS) and
  `testKraken2_hasDirectorySentinelLayout`, so the test file now has 4
  explicit cases plus `testAllCases_haveDeclaredLayout`. Option B (re-tag)
  chosen over Option A (new `.directory` case) because `.directorySentinel`
  already semantically covers "directory the resolver navigates from";
  adding a third case would split the enum with no consumer benefit, and
  both NVD and Kraken2 present the same "pick a directory" affordance to
  the user.

### Significant

- **`TaxonomyTableView.validateMenuItem` asymmetric gating** — **FIXED**.
  Dropped the `|| clickedNode != nil` clause at
  `Sources/LungfishApp/Views/Metagenomics/TaxonomyTableView.swift:607-609`.
  Added a 7-line explanatory comment that the gate must mirror the handler's
  read source (`selectedRowIndexes`) and that NSOutlineView's default
  right-click auto-select guarantees `clickedNode ∈ selectedRowIndexes`
  whenever the menu is shown.

- **NVD clicked-vs-selected divergence** — **DEFERRED to Phase 6/7**.
  Works in practice because NSOutlineView's default `menu(for:)` auto-selects
  the clicked row before showing the menu. The explicit-row plumbing is a
  nice-to-have hardening pass, not a correctness fix for the current state
  of the code. Phase 6 invariant I8 should cover it.

- **`buildKraken2Selectors` silently drops non-actionable rows** —
  **DEFERRED to Phase 6/7**. UX improvement rather than a bug. The
  silent-drop semantics are documented in review-2 and can be addressed
  either by a dialog-header count mismatch or a dedicated test that locks
  in the semantics, neither of which blocks Gate 3.

### Minor

- **Kraken2 dual `onExtractReadsRequested` assignment in `configure` +
  `configureFromDatabase`** — **WONTFIX**. Review-1 previously marked this
  as WONTFIX because extracting the closure would cost more lines than it
  saves. Adding a 1-line sync comment was considered in review-2 as "cheap
  defense" but the two call sites live in the same file ~90 lines apart
  and any future edit will be caught by standard code review; the comment
  adds noise for negligible benefit.

- **`ClassifierExtractionDialogPresenting.swift` extension is unscoped on
  `NSViewController`** — **DEFERRED to Phase 6 polish**. Scoping the
  extension (either via a marker protocol or `where Self:
  ClassifierExtractionPresenting`) would touch the shared helper file the
  simplification pass just landed. Low-risk but out of the Gate 3 fix
  scope, which is explicitly bounded to the Kraken2 layout critical +
  one-line `TaxonomyTableView` tightening.

- **`view.window` nil silent no-op** — **WONTFIX (documented design
  intent)**. The helper's docstring already justifies the silent-no-op as
  "avoids presenting an orphan sheet". The AppDelegate auto-extract path
  does not call through the helper, so the concern about the helper
  becoming the only failure mode is theoretical.

- **`view.loadView()` side effect** — **WONTFIX**. Practical impact is
  nil: the 5 classifier VCs are always loaded before menu interaction
  becomes possible. Review-2 agreed the invariant is fragile but not
  actually broken.

- **EsViritu `selectedSampleIDs().first` ignores non-first samples** —
  **DEFERRED to Phase 6 (vacuous I3 marker)**. Documented as Phase 5
  deviation #1 and accepted. The table-view API does not expose per-row
  sample ids; Phase 6 invariant I3 will be vacuously true for EsViritu
  and TaxTriage until the API is extended.

- **`buildNaoMgsSelectors` fold cosmetic refactor** — **WONTFIX (cosmetic
  only)**. The current struct-literal + re-assignment pattern works and is
  no less readable than the `bySample[row.sample, default: ...]` variant.

### Test gaps

All test-gap items deferred to Phase 6/7:

- Kraken2 `expectedResultLayout` integration test against an actual
  `ClassificationResult` on disk — **DEFERRED to Phase 6**. The layout
  metadata's contract is now correct; end-to-end verification against the
  resolver belongs to the phase that wires the metadata into the CLI
  pre-flight.
- Chart-menu explicit-node override under filter state — **DEFERRED to
  Phase 6 invariant I8**.
- `view.window` silent-no-op unit test — **DEFERRED to Phase 6** (low
  priority, docstring-level contract).
- `actionable` filter silent-drop lock-in test — **DEFERRED to Phase 6/7**
  (see Significant #3 above).
- `TaxonomyTableView.validateMenuItem` asymmetry test — **WONTFIX** now
  that the asymmetry is removed in Fix 3 above.

### Gate checks run

- `swift build --build-tests`: clean.
- `swift test --filter ClassifierToolLayoutTests`: 4 tests (up from 3),
  0 failures.
- `swift test --filter ClassifierExtractionDialogTests`: 24 tests, 0
  failures (Phase 4 contract holds).
- `swift test --filter ExtractReadsByClassifierCLITests`: 29 tests, 0
  failures (Phase 3 contract holds).
- `swift test --filter TaxonomyViewControllerTests`: 20 tests, 0 failures.

**Gate 3 closes.** Phase 5 is ready for Gate 4 (full-suite regression) and
Phase 6 start.
