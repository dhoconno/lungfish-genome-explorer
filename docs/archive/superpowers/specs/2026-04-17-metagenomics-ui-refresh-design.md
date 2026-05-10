# Metagenomics UI Refresh and First-Run State Fixes

**Date:** 2026-04-17
**Branch:** `codex/metagenomics-ui-refresh`
**Scope:** Implement items `#1`, `#2`, `#3`, `#5`, and `#6`; explicitly defer item `#4`.

---

## Scope Summary

This pass addresses five small-but-related issues in the metagenomics UI without taking on the open-ended Kraken2 BLAST refresh bug:

1. Remove overly restrictive drag limits from resizable panes and drawers while preserving a reliable way to drag back.
2. Refresh first-run required-tool status in place after installation succeeds, including the welcome/setup surfaces.
3. Refresh open classification dialogs in place after database download/install succeeds so users do not need to cancel and reopen.
4. Add a third metagenomics layout mode with the list on top and the detail pane below it, while keeping the bottom drawer as the bottom-most region.
5. Fix EsViritu batch unique-read aggregation so `Unique Reads` cannot exceed `Total Reads` because assembly-level counts were copied into per-contig state.

Item `#4` from the original request, “BLAST verify results with Kraken2 did not change even when BLAST completed,” is deferred to a separate focused investigation. The current code path does route completion into `showBlastResults(...)`, but the exact failure mode has not yet been isolated and should not be bundled into this otherwise-contained pass.

---

## Goals

- Let drawers and split panes expand to nearly the full window in both axes.
- Preserve a visible recovery path so users are never stranded with an undraggable zero-size pane.
- Make tool and database readiness updates propagate immediately to already-open windows and sheets.
- Extend the metagenomics layout preference from a boolean left/right toggle to a three-mode preference.
- Keep the change localized to the existing controller/view structure instead of introducing a larger metagenomics container refactor.
- Fix the confirmed EsViritu counting bug without changing unrelated batch view behavior.

## Non-Goals

- Refactoring all metagenomics result controllers into one shared container.
- Redesigning the BLAST drawer UI beyond making it resizable and compatible with the new stacked layout.
- Resolving the Kraken2 BLAST completion/result refresh bug (`#4`) in this batch.
- Reworking managed-storage installation paths beyond the notification/refresh path needed for immediate status updates.

---

## Current Problems

### 1. Drag limits are hard-coded and inconsistent

Several resizable drawers cap themselves well below full-window height:

- `ViewerViewController+AnnotationDrawer.swift` caps the annotation drawer at `70%` of the viewer height.
- `ViewerViewController+FASTQDrawer.swift` caps the FASTQ metadata drawer at `70%`.
- `TaxonomyViewController+Collections.swift` caps the taxonomy bottom drawer at `50%`.

Other BLAST result drawers are not actually resizable at all:

- `EsVirituResultViewController.swift`
- `NvdResultViewController.swift`
- `NaoMgsResultViewController.swift`

Each of those currently creates a fixed-height BLAST drawer (`220pt`) instead of a drag-managed region.

Horizontal classifier pane layouts are also constrained by `NSSplitViewDelegate` min/max divider methods, which prevents users from stretching one side nearly full width.

### 2. First-run install state goes stale

The current wizard/setup views load readiness state once and then stop:

- `ClassificationWizardSheet` only reloads installed databases from `.task`.
- `TaxTriageWizardSheet` only checks prerequisites and DB state from `.onAppear`.
- `EsVirituWizardSheet` only checks DB state from `.onAppear`.

Plugin/tool/database installers refresh their own local views, but they do not publish a cross-view “managed resources changed” signal, so already-open windows remain stale until reopened.

### 3. Layout preference is only a boolean

Current classifier result views only understand one saved preference:

- `metagenomicsTableOnLeft: Bool`

Controllers swap two split subviews based on that bool, which supports only:

- `Detail | List`
- `List | Detail`

There is no way to express:

- `List`
- `Detail`
- `Bottom Drawer`

as a vertical stack, which is the new requested mode.

### 4. EsViritu batch unique-read counts are inflated

`EsVirituResultViewController.applyBatchSampleFilter()` builds:

- assembly-level unique counts
- sample+assembly unique counts
- sample+contig unique counts

The bug is that it seeds each contig with the full assembly-level unique-read count. `ViralDetectionTableView` then recomputes assembly totals by summing child contig counts, which can multiply the assembly total by the number of contigs/segments. That produces impossible output such as `Unique Reads > Total Reads`.

---

## Proposed Design

### A. Shared Metagenomics Layout Preference

Replace the current boolean preference with a small string-backed enum:

```swift
enum MetagenomicsPanelLayout: String {
    case detailLeading
    case listLeading
    case stacked
}
```

### Persistence

- Add a new `UserDefaults` key for the enum-backed value.
- Preserve backward compatibility:
  - if the enum key is absent, infer the mode from `metagenomicsTableOnLeft`
  - `false` maps to `.detailLeading`
  - `true` maps to `.listLeading`
- Keep the old bool readable during migration, but stop treating it as the source of truth once the enum key is written.

### Notification

Reuse the existing layout-change notification path (`.metagenomicsLayoutSwapRequested`) rather than introducing a second parallel notification. Its meaning changes from “flip left/right” to “layout preference changed; reread the stored mode.” No payload is required; observers should always reread the enum-backed preference from `UserDefaults`.

### Inspector UI

Update the inspector’s “Panel Layout” control from a two-choice radio group to three explicit options:

- `Detail | List`
- `List | Detail`
- `List Over Detail`

The new stacked label should describe the top/bottom arrangement clearly enough that the user does not have to infer it from the icon alone.

### B. Controller Layout Behavior

Apply the same three modes to the metagenomics result controllers that already support left/right preference changes:

- `TaxonomyViewController`
- `EsVirituResultViewController`
- `TaxTriageResultViewController`
- `NaoMgsResultViewController`
- `NvdResultViewController`

### Side-by-side modes

For `.detailLeading` and `.listLeading`, keep the current split-view model:

- one primary `NSSplitView`
- detail and list panes as the two arranged subviews
- pane order chosen by the saved mode

### Stacked mode

For `.stacked`:

- the primary content split becomes top/bottom rather than left/right
- the list/table sits in the top pane
- the detail pane sits below it
- where a bottom drawer already exists, it remains below the primary content area as the bottom-most region

This means the new layout is:

1. list
2. detail
3. bottom drawer

No extra nested drawer abstraction is introduced in this pass. Existing bottom drawer behavior remains the bottom-most region where present, which minimizes churn and keeps the implementation local to existing controllers. Views without a bottom drawer simply become a two-region `list over detail` split.

### Default proportions

Each layout mode should reapply a sane default divider position when the mode changes:

- side-by-side modes should preserve the existing general width ratio
- stacked mode should default to a usable split where the list is visible but the detail pane remains the primary focus

If a stored divider position cannot be applied to the current window size, fall back to the mode’s default.

---

### C. Resizable Drawers and Splits

### Design rule

Drawers and panes may expand to nearly the full available dimension, but they must always leave a visible restore strip for the sibling region.

Instead of percentage caps like `0.5` or `0.7`, use a minimum-visible-sibling rule:

- vertical drawers:
  - `maxDrawerHeight = containerHeight - minimumVisibleHostHeight`
- horizontal or vertical split panes:
  - max position leaves `minimumVisibleSiblingWidth` or `minimumVisibleSiblingHeight`

This creates “almost full screen” behavior without allowing a dead-end zero-size pane.

### Recovery rule

Users must always be able to restore without closing the view or relaunching:

- dragging back is always possible because the sibling pane never reaches zero visible size
- toggling drawer closed/open restores the default size if the current size is invalid
- changing layout mode reapplies that mode’s default proportions

### Affected implementations

Update the drag/max-coordinate logic in:

- `ViewerViewController+AnnotationDrawer.swift`
- `ViewerViewController+FASTQDrawer.swift`
- `TaxonomyViewController+Collections.swift`
- the split-view delegate implementations in the classifier result controllers

For BLAST drawers that are currently fixed-height in:

- `EsVirituResultViewController.swift`
- `NvdResultViewController.swift`
- `NaoMgsResultViewController.swift`

replace the fixed `220pt` anchor behavior with the same drag-managed bottom-drawer pattern already used elsewhere, rather than merely increasing the fixed height.

---

### D. Managed Resource Refresh Signal

### New cross-view notification

Add one app-wide notification for managed-resource state changes, covering:

- required tool pack installs/reinstalls/removals
- managed database downloads/installs/removals
- database storage location changes

The notification is intentionally broad because the affected views only need to know “re-read your current readiness state.”

### Producers

Post the notification after successful changes in:

- `PluginManagerViewModel.installPack(...)`
- `PluginManagerViewModel.removePack(...)`
- `PluginManagerViewModel.downloadDatabase(...)`
- database removal flows in `PluginManagerViewModel`
- database storage location changes

If there are setup/welcome controller flows that install tools outside the plugin manager path, they should also post the same notification once the install completes successfully.

### Consumers

Existing views should subscribe and rerun their current checks instead of adopting a new state model:

- `ClassificationWizardSheet`
  - rerun `loadDatabases()`
- `TaxTriageWizardSheet`
  - rerun the current prerequisite/database readiness logic
- `EsVirituWizardSheet`
  - rerun `checkDatabaseStatus()`
- any first-launch setup surface that displays required tool readiness
  - rerun pack status / readiness checks when the notification arrives

This keeps the implementation localized and preserves current logic paths while fixing the stale-state problem.

### Error handling

The refresh signal does not replace error handling:

- failed installs should still surface their error state
- successful installs should immediately trigger the green/ready state in open surfaces

No “optimistic ready” state should be shown before the install actually completes.

---

### E. EsViritu Unique-Read Fix

### Root cause

Batch assembly rows already have an assembly-level unique-read total. The current code incorrectly copies that assembly total into each contig’s per-contig entry. Later aggregation then sums those duplicated values across all child contigs, inflating the assembly total.

### Fix

In `EsVirituResultViewController.applyBatchSampleFilter()`:

- keep:
  - `uniqueByAssembly`
  - `uniqueBySampleAssembly`
- stop pre-populating:
  - `uniqueBySampleContig`
  from assembly-level unique-read values

Only populate per-contig unique-read state when the app has an actual contig-specific value.

### UI behavior for missing contig counts

If a contig-level unique-read value is not known yet:

- assembly rows still show assembly-level totals
- contig rows should remain unknown/blank/placeholder rather than displaying the parent assembly total

That preserves correctness and avoids presenting fabricated precision.

---

## Implementation Boundaries

This change should stay inside the current controller/view model structure. The implementation may add small shared helpers for:

- layout preference parsing/storage
- shared divider constraints/default sizing
- managed-resource change notifications

It should not attempt to:

- unify all classifier result controllers under one base class
- redesign BLAST drawer content
- refactor managed-install path resolution or storage architecture

---

## Testing and Validation

### Manual validation

- Drag each affected bottom drawer to near-full height and confirm it can be dragged back.
- Drag each affected split to near-full width/height and confirm the sibling pane remains recoverable.
- Toggle among all three layout modes in each touched classifier result view.
- In stacked mode, verify the ordering is list on top, detail in the middle, bottom drawer at the bottom.
- Install a required tool pack from a first-run/setup surface and confirm readiness changes in place without reopening.
- Download a classification database while the relevant wizard/dialog is open and confirm it becomes selectable immediately.
- Verify EsViritu batch results do not show `Unique Reads > Total Reads` due to duplicated assembly totals.

### Automated verification

Prefer targeted tests around:

- layout preference migration/defaulting
- any shared notification helper
- EsViritu unique-read aggregation logic if there is a practical seam to test it without UI-heavy setup

If UI automation coverage is impractical for the drawer interactions, document the manual checks performed.

---

## Open Questions Resolved For This Spec

- `#4` is out of scope for this pass.
- The new top/bottom mode uses the existing bottom drawer as-is rather than adding a second nested drawer concept.
- “Nearly full screen” means “full span minus a minimum visible sibling strip,” not true full collapse to zero.
- Open dialogs should refresh from completion notifications rather than polling or introducing a new shared observable store.
