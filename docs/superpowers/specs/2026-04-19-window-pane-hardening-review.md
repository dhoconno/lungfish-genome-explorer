# Main Window And Pane Hardening Review

## Purpose

This document consolidates five independent red-team reviews of Lungfish pane sizing and resizing behavior across:

- the main shell (`sidebar | viewer | inspector`)
- raw two-pane viewer layouts
- stacked list/detail viewer layouts
- pane-hosted miniBAM and scroll/detail regions
- bottom drawers and future multi-pane viewers

The goal is not to prescribe another round of one-off fixes. The goal is to define a durable implementation program that hardens the interface for all current and future viewers.

## Review Scope

Primary code paths reviewed:

- `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/MainWindow/MainWindowController.swift`
- `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Layout/SplitShellWidthCoordinator.swift`
- `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Layout/TwoPaneTrackedSplitCoordinator.swift`
- `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Layout/SplitPaneSizing.swift`
- `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Layout/SplitPaneFillContainerView.swift`
- `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Layout/ScrollViewSplitPaneContainerView.swift`
- current viewer adopters in `EsViritu`, `NVD`, `NAO-MGS`, `TaxTriage`, and `Taxonomy`
- adjacent split users including `FASTQDatasetViewController`, `WorkflowBuilderViewController`, and `HelpWindowController`

## Executive Summary

The current system has made progress toward shared layout infrastructure, but it is still too low-level and too fragmented.

The most important conclusions are:

1. The new Kraken2 crash is a shell-level reentrancy bug, not a Kraken2-specific viewer bug. The shell is mutating divider position from inside `splitViewDidResizeSubviews`, causing recursive AppKit resize notifications.
2. The shared split framework currently shares divider mechanics, not full layout ownership. Visibility, collapse/recovery, content resizing, and drawer behavior are still controller-specific.
3. Layout semantics are inconsistent across tools. The same labels (`Detail | List`, `List | Detail`, `List Over Detail`) do not produce the same emphasis or recovery behavior.
4. Testing is strongest at the symptom layer and weakest at the shared-layout engine layer. That is why regressions keep moving between tools instead of being trapped centrally.

## Critical Issues

### P0: Shell Reentrancy And Crash Risk

The main shell currently observes a resize and immediately calls `splitView.setPosition(...)` from `splitViewDidResizeSubviews`. That is an AppKit reentrancy hazard and is the direct cause of the reported crash during Kraken2 resize.

Implication:

- shell resize callbacks must become observational only
- reconciliation must be deferred out of the active AppKit drag/layout cycle

### P1: Inconsistent Shared Sizing Math

`SplitPaneSizing` and `TwoPaneTrackedSplitCoordinator` do not fully agree on the same geometry model. Divider validation accounts for divider thickness while clamping does not.

Implication:

- the framework can accept a divider position that its own validation later treats as invalid
- drag snapback and post-layout reclamping will continue until sizing, validation, collapse, and restore all use one geometry contract

### P1: No Single Owner For Pane State

Pane width, visibility, last expanded size, recommendation/default size, and persistence are currently spread across:

- split view callbacks
- controller-local flags
- global layout preferences
- ad hoc `UserDefaults`
- `NSSplitView` autosave
- selection-driven viewer logic

Implication:

- AppKit host code and viewer logic are both trying to own the same state
- behavior varies by tool and by pane

### P1: Shared Framework Stops Too Low In The Stack

The current shared layer owns:

- divider clamping
- tracked divider positions
- initial validation
- basic pane swaps

It does not own:

- pane visibility/collapse/recovery
- header/content/placeholder composition
- scroll/document fitting behavior
- embedded miniBAM/detail resizing
- drawer insertion/resizing/persistence

Implication:

- every viewer that needs hidden panes, placeholder panes, or bottom drawers forks the model

## Systemic Problems

### 1. Split Families Are Still Disconnected

There are at least four pane-layout families in the app:

- main shell via `NSSplitViewController`
- raw two-pane metagenomics viewers
- nested raw split views in `FASTQDatasetViewController`
- other shells such as `WorkflowBuilderViewController` and `HelpWindowController`

These should not all invent their own recovery and persistence behavior.

### 2. Tool-Specific Geometry Still Leaks Through

Examples:

- `TaxonomyViewController` still uses bespoke split logic
- `TaxTriageResultViewController` still owns custom hidden-pane and resize behavior
- `NVD` and `NAO-MGS` still manually fit detail content
- `EsVirituDetailPane` still owns tool-specific embedded viewport sizing behavior

### 3. UX Contract Is Not Unified

Current user-visible inconsistencies include:

- left and right shell panes do not recover symmetrically
- layout switching is overly tied to the inspector
- default pane emphasis differs by tool
- content-state changes can trigger layout-state changes
- toolbar toggles do not consistently communicate current pane state

## Recommended Target Architecture

The right end state is a layered pane framework.

### Layer 1: Workspace Shell Layout

Introduce a shell-level model for outer panels:

- `sidebar`
- `content`
- `inspector`

Recommended responsibilities:

- min/ideal/max extents
- collapse permissions
- last expanded width
- persistence keys
- explicit user width tracking
- programmatic shell layout transactions

Suggested shape:

- `WorkspaceShellSpec`
- `ShellPanelSpec`
- `ShellLayoutState`
- `ShellLayoutHostController`

### Layer 2: Viewer Layout Model

Introduce a declarative viewer layout spec rather than hardcoding each viewer as “one controller with local divider math.”

Recommended responsibilities:

- pane roles such as `primary`, `secondary`, `detail`, `list`, `overview`
- supported layout modes
- default mode and default emphasis
- per-mode min extents
- optional/hidden-pane behavior
- per-viewer persistence namespace

Suggested shape:

- `ViewerLayoutSpec`
- `LayoutNode`
- `PaneSpec`
- `ViewerLayoutMode`
- `ViewerLayoutHostController`

This layer should own:

- orientation swaps
- divider restore
- deferred validation
- hidden-pane collapse/recovery

### Layer 3: Pane Host Contract

Promote pane hosting to a semantic abstraction instead of a collection of geometry helpers.

Recommended responsibilities:

- header ownership
- content ownership
- placeholder/empty state ownership
- scroll-fitting behavior
- embedded viewport fitting behavior
- one clear geometry authority per pane

Suggested shape:

- `PaneHost`
- `ScrollPaneHost`
- `HeaderContentPaneHost`
- `ViewportPaneHost`

Current container classes can survive as internal implementation details, but viewers should stop composing them ad hoc.

### Layer 4: Drawer Host Contract

Bottom drawers and side drawers should be first-class layout objects.

Recommended responsibilities:

- edge
- min/ideal extent
- push vs overlay behavior
- persistence
- resize handle semantics
- coexistence rules with sibling panes

Suggested shape:

- `DrawerSpec`
- `DrawerHostController`
- `DrawerState`

## Declarative vs Imperative Split

### Declarative

These should be declared by shell/viewer code:

- pane inventory
- pane roles
- allowed layout modes
- min/ideal/max extents
- collapse permissions
- drawer inventory
- persistence IDs

### Imperative

These should remain inside the AppKit host layer:

- `NSSplitView` and `NSSplitViewController` bridging
- rebuild/swap operations
- animation and transition orchestration
- divider drag plumbing
- deferred reconciliation after AppKit layout
- low-level geometry clamping

The principle is:

- feature/viewer code declares desired layout policy
- AppKit host code performs the mechanics once

## Implementation Recommendations

### Recommendation 1: Make Resize Callbacks Observational Only

Immediately stop all synchronous divider mutation from:

- `splitViewDidResizeSubviews`
- `resizeSubviewsWithOldSize`
- `viewDidLayout`

Allowed behavior inside these callbacks:

- observe committed geometry
- record state
- schedule deferred reconciliation

Disallowed behavior inside these callbacks:

- calling `setPosition(...)`
- changing collapse state
- rewriting frames to “fix” an in-progress drag

### Recommendation 2: Unify The Geometry Contract

Create one shared sizing engine that owns:

- divider-thickness-aware clamping
- collapse extents
- minimum extents
- default extents
- restore extents
- validation rules

`SplitPaneSizing` should become the single source of truth for all of the above.

### Recommendation 3: Choose One Persistence Authority

Do not mix:

- `NSSplitView` autosave
- ad hoc `UserDefaults`
- local controller flags
- tracked requested divider positions

Recommended direction:

- disable split autosave where a custom layout-state store exists
- persist pane and drawer state through one shared `LayoutStateStore`

### Recommendation 4: Standardize Pane Semantics

Make layout labels mean the same thing everywhere:

- `Detail | List`: detail leads and is dominant
- `List | Detail`: list leads, but detail remains the main work surface unless a viewer explicitly opts out
- `List Over Detail`: list/header occupies a stable top slice; detail remains the dominant pane

Viewer-specific exceptions should be rare and explicit.

### Recommendation 5: Treat Content-State Changes As Content Swaps

Changing sample, organism, contig, or selection should generally:

- replace pane content
- show a placeholder
- update a header

It should not implicitly:

- collapse a pane
- restore a default split
- rebalance a user-owned divider

### Recommendation 6: Give All Outer Panes Symmetric Recovery

Sidebar and inspector should share the same contract:

- stateful toolbar toggle
- menu toggle
- shortcut
- last expanded width restoration
- no special-case behavior for one side only

### Recommendation 7: Finish Migration Before More Local Fixes

Do not keep applying framework-only fixes while major viewers still bypass the framework.

Priority adopters:

1. `MainSplitViewController`
2. `TaxonomyViewController`
3. `TaxTriageResultViewController`
4. nested split users such as `FASTQDatasetViewController`
5. remaining shell-style windows

## Proposed Phased Program

### Phase 0: Stabilize The Shell

Objective:

- stop the current crash class immediately

Actions:

- remove synchronous sidebar restoration from shell resize callbacks
- introduce shell transaction state
- commit user width from observed post-layout widths, not proposed divider positions

### Phase 1: Harden Shared Geometry

Objective:

- make sizing, validation, collapse, and restore use one math model

Actions:

- fold divider thickness into `SplitPaneSizing`
- add direct unit coverage for clamp/restore/validation behavior
- eliminate duplicated local min-extent math where possible

### Phase 2: Introduce Shared State Models

Objective:

- make pane state declarative and persistent

Actions:

- add `LayoutStateStore`
- add stable pane and drawer IDs
- replace local layout state and scattered defaults with shared state objects

### Phase 3: Ship `ViewerLayoutHostController` V1

Objective:

- make raw two-pane viewers stop owning divider state

Actions:

- evolve `TwoPaneTrackedSplitCoordinator` into a viewer host layer
- migrate `EsViritu`, `NVD`, and `NAO-MGS`
- then migrate `Taxonomy`

### Phase 4: Ship `PaneHost` And `DrawerHost`

Objective:

- remove viewer-specific geometry patches

Actions:

- promote scroll/detail fitting into pane hosts
- move drawer resize/persistence into one host
- migrate viewer annotation, BLAST drawers, taxonomy collections, and FASTQ drawers

### Phase 5: Add Optional/Hidden Pane Semantics

Objective:

- support `TaxTriage`-style overview/detail behavior without forking the framework

Actions:

- add first-class optional pane state
- restore last user extent when a hidden pane returns
- migrate `TaxTriage`

### Phase 6: Align Future Viewers To The Shared Model

Objective:

- make mapping, assembly, alignment, BAM, and multi-reference viewers consumers of the same layout foundation

Actions:

- require future viewer implementations to declare `ViewerLayoutSpec`
- prohibit new controller-local divider state machines

## Testing Strategy

### Framework-Level Unit Coverage

Add direct tests for:

- `SplitPaneSizing`
- `SplitShellWidthCoordinator`
- `TwoPaneTrackedSplitCoordinator`
- future `LayoutStateStore`

### Integration Coverage By Viewer Family

Use offscreen `NSWindow` harnesses to cover:

- shell sidebar/inspector restore behavior
- raw split viewer drag persistence
- hidden-pane collapse/recovery
- layout-mode swaps
- content resizing after divider movement
- drawer resize/persistence

### Reentrancy And Recursion Guards

Add split-view spies that track:

- nested `setPosition(...)` depth
- delegate reentry depth
- unexpected repeated resize notifications during one logical transaction

The framework must assert bounded depth, not just visually plausible final geometry.

## Acceptance Criteria

The pane system is hardened when all of the following are true:

1. A user drag survives window resize, content change, pane reopen, and layout-mode change.
2. No viewer mutates divider position synchronously from inside AppKit resize callbacks.
3. Left sidebar and right inspector have symmetric recovery behavior.
4. `Detail | List`, `List | Detail`, and `List Over Detail` feel the same across tools.
5. Hidden panes reopen at the last user-set size, not an arbitrary default.
6. Pane-hosted miniBAM and detail regions resize through shared pane-host logic, not tool-specific math.
7. Bottom drawers use one shared resize and persistence contract.
8. Future viewers can declare layout structure without inventing new divider state machines.

## Recommended Near-Term Decision

The next implementation cycle should not start with another per-tool bug fix. It should start with a shell-and-viewer layout stabilization tranche:

1. fix shell recursion and transaction ownership
2. unify geometry math
3. define shared layout state and host abstractions
4. migrate the remaining outlier viewers onto the shared host

That is the shortest path to stop repeating the same class of pane bugs under different viewer names.
