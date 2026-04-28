# State Management Hardening Design

**Goal:** Make window resizing, async UI updates, navigation, selection, and workflow/dialog state coherent across the app so visible data and biological actions always match the active user context.

**Status:** Approved by the user on 2026-04-28. Expert review inputs came from software architecture, QA/QC, UI/UX, and biological end-user perspectives.

## Problem

Several UI paths can keep stale state after the user resizes a window, changes sidebar selection, switches alignment settings, sorts or filters result tables, changes wizard inputs, or operates multiple project windows. The highest-risk cases are not cosmetic. A stale read/depth/consensus fetch, metagenomics detail update, table selection, or workflow/import response can make the app display or act on biological evidence from a previous sample, result, taxon, contig, read group, database query, or workflow.

## Design Principles

- The active content identity is the source of truth for every async UI commit.
- A stale async response must be ignored, not adapted into the current view.
- Window-owned UI state must not route through global app state when an owning window/controller exists.
- Table selection must be preserved by stable row identity, not by displayed row index.
- Resize paths must update visible geometry immediately and must not persist transient window-resize dimensions as user divider choices.
- Unit/controller tests cover deterministic state logic; XCUI tests cover real AppKit responder, split-view, sheet, and multi-window behavior.
- Biological actions such as extraction, BLAST, bundle creation, consensus export, and workflow/import writes must be disabled or rebound when their backing selection becomes stale.

## Worktree Architecture

### `codex/state-foundations`

This branch introduces shared, testable primitives under `Sources/LungfishApp/StateManagement/` and fixes the current SwiftPM discovery blocker.

It owns:

- `AsyncRequestGate`: generation/token helper for "last valid identity wins" async commits.
- `ContentSelectionIdentity`: canonical UI content identity using standardized URLs plus optional domain fields.
- `WindowStateScope`: value used to tag window-owned notifications and async commits.
- `AsyncValidationSession`: reusable session model for SwiftUI sheet validation/search/readiness tasks.
- `SelectionIdentityStore`: selection-by-ID helper for tables that sort, filter, or reload.
- Tests for each primitive.
- `Package.swift` integration-test dependency correction.

### `codex/main-window-state`

This branch owns the shell and global navigation choke point. It must be based on `codex/state-foundations`.

It owns:

- `MainSplitViewController.swift`
- `SidebarViewController.swift`
- `InspectorViewController.swift`
- `Views/Layout/*`
- Tests for shell resize, sidebar navigation, inspector/window notification scoping, and stale main-result loads.

### `codex/viewer-fetch-state`

This branch owns viewer fetch invalidation and resize redraw. It must be based on `codex/state-foundations`.

It owns:

- `ViewerViewController.swift`
- `SequenceViewerView.swift`
- viewer-owned helpers and tests.

### `codex/database-workflow-import-state`

This branch owns search, workflow, import, and wizard readiness state. It must be based on `codex/state-foundations`.

It owns:

- `Views/DatabaseBrowser/*`
- `Views/Workflow/*`
- `Views/ImportCenter/*`
- `NaoMgsImportSheet.swift`
- `NvdImportSheet.swift`
- metagenomics wizard sheet files whose readiness comes from async child state.

### `codex/metagenomics-selection-state`

This branch owns result table identity and metagenomics/assembly selection coherence. It must be based on `codex/state-foundations`.

It owns:

- `BatchTableView.swift`
- metagenomics result controllers
- assembly/reference result table selection adapters where stable identity is missing.

### `codex/state-integration-tests`

This branch is created after domain branches are merged into an integration branch.

It owns:

- broad SwiftPM regression tests
- XCUI app-shell flows for resize, multi-window isolation, dialog reset, and viewer/inspector/sidebar coherence.

## Acceptance Criteria

### Resize and Layout

- Shrinking and enlarging the main window updates sidebar, viewer, inspector, and embedded result panes immediately.
- Sidebar and inspector widths clamp to min/max while preserving viewer usability.
- Ordinary window resize never overwrites persisted user divider widths.
- Explicit divider drag still persists user widths.
- Vertical and stacked split views use the same clamp/preserve semantics.

### Async State

- Every async UI commit checks the current request token and content/window identity before mutating UI state.
- Slow response A cannot overwrite faster response B after the user changes selection, query, path, workflow, tool, window, or alignment settings.
- Cancel/reopen paths leave no stale spinner, ready state, pending task handle, or stale result.

### Navigation and Window Scoping

- Sidebar, viewer, and inspector resolve to the same active content after user and programmatic navigation.
- Context-menu Open routes through the same explicit display path as selection.
- Window-owned notifications include scope; observers ignore notifications from other windows.
- Existing legacy notifications remain tolerated during migration until all producers have scope.

### Viewer Biology

- Changing MAPQ, duplicate, secondary, supplementary, read group, visible alignment track, or consensus settings invalidates read, depth, consensus, tooltip, selection, and export backing data.
- In-flight old read/depth/consensus fetches cannot repopulate caches after settings change.
- Geometry changes invalidate the visible viewer immediately, while expensive fetches remain coalesced.

### Table Selection

- Sort/filter/reload preserves selection by stable biological identity when the row remains visible.
- Selection clears when the row is filtered out or removed.
- Detail panes and actions never target a row that is not currently selected under the active filter.
- Duplicate taxa, accessions, organisms, read IDs, and contig names across samples/runs remain distinguishable by full identity.

### Dialogs and Workflows

- Readiness text and primary button enabled state agree.
- Async child readiness affects only the currently selected runner/tool.
- Search/schema/import validation responses apply only to the active query/path/workflow/tool.
- Fresh sheet presentations start with fresh state except for deliberate user preferences.

## Verification Strategy

- Run targeted SwiftPM tests for each branch before integration.
- Run `swift test --filter LungfishAppTests` after app-test changes are integrated.
- Run `swift test list` after fixing the integration-test dependency blocker.
- Run XCUI scripts only after controller/unit regressions pass, because XCUI should verify the real shell rather than debug deterministic logic.

## Decisions Delegated To Experts

The user has approved autonomous expert decision-making for spec and implementation details unless a decision changes product behavior or biological interpretation. Engineering, QA/QC, UI/UX, and biological acceptance criteria in this document are the operating contract for those decisions.
