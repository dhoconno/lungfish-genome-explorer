# Fable-only GUI Performance Refactor — Design

Date: 2026-07-02
Model constraint: implemented exclusively with Claude Fable. Items that cannot
be landed safely with Fable are recorded in an Opus-deferral file rather than
half-implemented.

## Problem

The Lungfish Genome Explorer (LGE) GUI has laggy interactions. Some lag is fixed
per-action overhead visible even on small projects (full reloads, per-keystroke
recomputation, redundant layout flushes). Some lag scales with dataset size
(non-virtualized tables/matrices, whole-array filters, synchronous file reads on
the main actor). The goal is a GUI with no perceptible lag on any operation and
that stays elegant with very large datasets.

Scope is GUI-side only: left sidebar / project tree, viewports
(sequence, alignment, assembly, taxonomy, variant), right inspector, menus, and
dialogs. Third-party scientific tool invocations (samtools, kraken2, spades,
etc.) are explicitly out of scope for performance changes.

## Prior art (reconciled, not restarted)

A June 2026 responsiveness effort already exists and this pass builds on it:

- Design spec: `docs/superpowers/specs/2026-06-09-responsiveness-sweep-design.md`
  (profile-first, `PerfSignpost` instrumentation, per-target loop).
- Inventory + ranked backlog:
  `docs/reports/2026-06-14-gui-responsiveness-inventory.md` (10 independent
  review passes, consensus risks, recommended backlog).

Landed since then (do NOT re-touch): `BatchTableView` 180 ms typing debounce,
`ProjectFilesystemRefreshCoordinator` watcher-storm coalescing, genotype matrix
rendering/selection tightening, TaxTriage selection responsiveness. Most of the
June backlog remains open; this pass executes the Fable-tractable remainder plus
a fresh audit of the current tree.

## Fresh-audit findings (current tree, 2026-07-02)

Confirmed hotspots with file:line, grouped by fix class. Line numbers are
anchors as of HEAD 5b417cfb and are re-verified before each edit.

### Per-keystroke whole-array recomputation (no debounce)

- `Sources/LungfishApp/Views/Viewer/VCFDatasetViewController.swift:259`
  `applyFilter()` filters `allVariants`, calls `classifyVariantType` per element,
  sorts, then `tableView.reloadData()` on every character. Worst offender.
- `Sources/LungfishApp/Views/Metagenomics/TaxaCollectionsDrawerView.swift:536`
  `applyFilters()` nested `taxa.contains` filter + `outlineView.reloadData()`
  per keystroke.
- `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift:355`
  `applyLocalSidebarSearch()` recursive `filterItems` + full reload per keystroke.

### Synchronous file I/O on the main actor

- `String(contentsOf:)` / `Data(contentsOf:)` on `@MainActor` in:
  `FASTQDatasetViewController.swift:1524`,
  `MultipleSequenceAlignmentViewController.swift:397`,
  `ViewerViewController+TwelveS.swift:189`,
  `Results/MHCReference/MHCReferenceBundleViewport.swift:25`,
  `Sidebar/FolderMetadataEditorSheet.swift:209`,
  `Sidebar/ProjectMetadataExportImport.swift:520`,
  `MainWindow/MainSplitViewController+ContentDisplay.swift:731`,
  `MainWindow/MainSplitViewController+ClassifierDisplay.swift:618,830,920`,
  `Inspector/InspectorViewController+MetadataImport.swift:81,286`,
  `Services/WorkflowBuilderRunService.swift:463`, and several sidebar manifest
  reads (`SidebarViewController.swift:1874..2164`,
  `SidebarViewController+MenuDelegate.swift:385`). Plus main-actor writes
  (`SidebarViewController+MenuDelegate.swift:626`,
  `FASTQDatasetViewController.swift:1513`).

### Full reloads where incremental updates apply (~114 `reloadData()` sites)

- `SidebarViewController.reloadOutlineView()` (`:548`) calls `reloadData()`
  unconditionally from 30+ call sites, despite an already-present but unused
  surgical helper `applySubtreeDiff` (`:1039`).
- `OperationsPanelController.reloadDataPreservingSelection()` (`:282`) falls back
  to full `reloadData()` even though the change stream is coalesced (150 ms).
- `NvdResultViewController` (`:352,439,480`), `VCFDatasetViewController`,
  taxonomy/result tables across leaf modules.

### Per-frame recomputation in draw / render paths

- `Set(db.allChromosomes())` rebuilt each render:
  `SequenceViewerView+Rendering.swift:732`, `SequenceViewerView.swift:1838`,
  `SequenceViewerView+Alignment.swift:124,759`.
- Synchronous DB query in an inspector render context:
  `Inspector/Sections/VariantSection.swift:126`.

### Layout thrash

- Redundant back-to-back `layoutSubtreeIfNeeded()`:
  `MainWindow/MainSplitViewController+ShellLayout.swift:102-103,243-244`,
  `Viewer/ViewerViewController+Mapping.swift:102,104`.

### Non-virtualized large surfaces (scale with dataset)

- Genotype outline/matrix stacks, EsViritu outlines, TaxTriage tables, metadata
  columns — full reloads / non-virtualized stacks per the June inventory,
  confirmed still present.

### Architectural (deepest)

- Sidebar tree building runs on the main actor; no off-main snapshot builder.
- Viewport `draw(_:)` paths schedule async data fetches inline instead of via a
  render coordinator keyed by viewport signature.

## Goals & non-goals

Goals: remove fixed per-action overhead; keep large datasets responsive via
windowing/off-main work/incremental updates; stay Swift-idiomatic; preserve the
green-bar baseline throughout; every change independently verifiable.

Non-goals: changing third-party tool invocations; altering scientific
data-creation/export or provenance behavior; unrelated refactoring not tied to a
measured or clearly-identified bottleneck.

## Approach: five phases, low-risk to high-risk, expert-gated

Single continuous pass in one worktree/branch. Changes are committed
incrementally so any single change can be dropped. **At the end of each phase,
expert agents review and the phase is iterated until reviewers are satisfied
before the next phase begins.**

Reviewer panel per phase (agent types): `swift-expert` (idiom + concurrency
correctness, esp. background→MainActor rules), `performance-engineer` (did the
change actually remove the cost; any new hot path), `code-reviewer`
(correctness, regressions, test coverage). A phase is "satisfied" when all
reviewers report no blocking findings and the green bar holds.

### Phase 1 — Behavior-preserving quick wins

No change to visible output or UX.

- Debounce the three un-debounced per-keystroke filters (VCF variant browser,
  taxa collections drawer, sidebar local search), reusing the established
  `BatchTableView` debounce pattern (180 ms). Programmatic/state-restoration
  paths remain immediate.
- Cache `Set(db.allChromosomes())` per render with invalidation on DB change.
- Move the synchronous variant DB query out of `VariantSection` render context.
- Remove redundant paired `layoutSubtreeIfNeeded()` calls.

### Phase 2 — Off-main file I/O

Move the identified synchronous `String(contentsOf:)` / `Data(contentsOf:)`
reads (and the two main-actor writes) off the main actor, committing results
back on `@MainActor` with generation guards where a stale result could apply.
One shared helper pattern; each conversion follows it. Honors the project's
background→MainActor dispatch rules exactly (no `Task { @MainActor in }` from
GCD, no bare `DispatchQueue.main.async` touching `@MainActor` state).

### Phase 3 — Incremental / diffable reloads

Convert the highest-traffic full-reload sites to surgical updates.

- Wire the sidebar delete/refresh paths through the existing `applySubtreeDiff`.
- `OperationsPanelController` → row-level insert/remove/reload deltas.
- NVD/VCF/taxonomy result tables → diffable snapshots or targeted row updates.

### Phase 4 — Large-dataset scaling (UX-altering, opt-in)

- Virtualize/window non-virtualized surfaces (genotype matrix/outline, EsViritu,
  TaxTriage) before they scale to large cohorts.
- Very large result tables default to a top-N window with an explicit "Show all"
  affordance. The exact N per table and the "very large" threshold are pinned in
  the implementation plan, not here.

These change visible behavior, so each new default gets an explicit regression
test and its existing test expectations updated deliberately.

### Phase 5 — Architectural (highest risk)

- Off-main sidebar tree snapshot builder → generation-checked `NSOutlineView`
  diff applied on the main actor.
- Render coordinator that lifts async fetch scheduling out of viewport
  `draw(_:)` paths; fetch completion invalidates only affected track/lane rects.

Fable attempts each item it is confident it can land with tests green. Any item
that cannot be safely completed with Fable is written to the deferral file with
symptom, file:line, why it exceeds a safe Fable change, and a proposed approach.

## Opus-deferral file

`docs/reports/2026-07-02-gui-perf-opus-deferrals.md`. One entry per deferred
item: symptom, location, reason it exceeds a safe Fable change, proposed
approach for a later Opus pass. Per user decision, this file holds only
genuinely-beyond-Fable items, not "conservative" deferrals.

## Testing & verification

- Behavior-preserving phases (1–3): all existing tests stay green; add
  regression tests where a fix changes a refresh/debounce/reload contract
  (mirroring the June pass's debounce regression tests).
- UX-altering phase (4): each new default (top-N, windowing) gets an explicit
  test; update existing expectations deliberately.
- Architectural phase (5): generation-guard and diff-application tests; real-app
  GUI verification via the run/verify skills for interactions not unit-testable.
- Green-bar baseline (binding): a run is GREEN iff XCTest failures are a subset
  of the known 9 environmental failures AND swift-testing failures = 0.
- SwiftPM discipline: serialize all `swift build`/`swift test` (single
  `.build/.lock`); always `--skip-update` to stay offline.

## Worktree

Single git worktree off local `main` for the whole effort
(`.claude/worktrees/fable-gui-perf-refactor`, branch
`worktree-fable-gui-perf-refactor`). Phases committed incrementally;
expert-review iteration happens on-branch between phases.

## Binding project rules honored

Plan-first (this spec); expert review per phase; phased implementation; CLI
parity considered for anything not purely UI (this pass is UI-only, so parity is
generally N/A but checked per change); OperationCenter remains the path for any
operation; GUI testing via the real app where unit tests do not apply;
background→MainActor dispatch rules; green-bar baseline.
