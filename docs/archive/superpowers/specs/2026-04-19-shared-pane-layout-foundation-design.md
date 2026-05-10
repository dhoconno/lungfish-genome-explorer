# Shared Pane Layout Foundation Design

## Goal

Create a reusable pane-and-drawer foundation for Lungfish so repeated list/detail and detail/list/stacked layouts behave consistently across metagenomics tools, app shells, and future result viewers such as mapping, assembly, and alignment views.

## Scope

This first rollout covers:

- A shared pane sizing and divider tracking foundation in an app-wide location.
- A reusable adapter for raw two-pane `NSSplitView` layouts.
- A reusable adapter for `NSSplitViewController` shell panes.
- Initial adoption in the currently broken metagenomics result views:
  - `EsVirituResultViewController`
  - `NvdResultViewController`
  - `NaoMgsResultViewController`
  - `TaxTriageResultViewController`
- Initial adoption in one app shell:
  - `MainSplitViewController`

This rollout does not attempt a repo-wide migration of every existing split view.

## Requirements

### Shared Behavior

- Pane layouts must support:
  - leading detail / trailing list
  - leading list / trailing detail
  - stacked list over detail
- Divider positions must be clamped to minimum pane extents.
- User drag changes must persist through relayouts and deferred validation passes.
- Deferred initial layout validation must never overwrite an actual user drag.
- Embedded viewport/detail content must resize with its pane after divider movement.
- Bottom drawer sizing must use the same shared clamp rules across adopters.

### Shell Behavior

- Sidebar and inspector resizing in shell contexts must not snap back after user drag.
- Programmatic width recommendations may set sensible defaults, but must not override an explicit user resize.
- A collapsed pane must be recoverable after aggressive resizing.

### Future Applicability

- Foundation types must not be named or structured as metagenomics-only concepts.
- The system must be reusable by future mapping, assembly, alignment, and BAM-oriented views.

## Architecture

### 1. Shared Layout Primitives

Create app-wide pane layout primitives for:

- divider position clamping
- drawer extent clamping
- tracked divider positions
- pane fill containers that keep embedded content synced to pane bounds

These types live outside the `Metagenomics` namespace so they can be adopted by other viewers.

### 2. Raw Two-Pane Split Adapter

Introduce a shared helper for raw `NSSplitView` controllers that owns:

- initial divider application
- deferred initial validation
- tracked user divider restoration
- pane order swaps for horizontal vs. stacked layouts
- minimum extent logic per layout mode

Controllers provide:

- the split view
- the two pane views
- layout-specific minimum extents
- layout-specific default fraction

The helper owns the state machine so controllers stop duplicating divider math.

### 3. Split-Controller Shell Adapter

Introduce a shell-focused helper for `NSSplitViewController` panes that owns:

- persisted preferred widths
- user-resize detection
- suppression of stale auto-width recommendations after explicit drag
- collapse/restore width behavior

This first rollout applies it to `MainSplitViewController`.

### 4. Viewport Fill Behavior

Detail panes that host scrollable or embedded miniBAM content must use shared fill-container behavior so pane width changes propagate immediately to the viewport host. Raw split controllers should not each hand-roll content-width synchronization.

## Error Handling

- If a split container has zero extent during early layout, the foundation must defer instead of forcing positions.
- If available extent is smaller than the sum of pane minimums, clamp while preserving visibility of both panes when possible.
- Hidden/collapsed panes must use explicit collapse rules rather than relying on AppKit to infer zero-width behavior.

## Testing

Add regression coverage for:

- raw split views preserving a user-moved divider after deferred validation
- viewport/detail content width tracking pane width after divider movement
- shell sidebars/inspectors not snapping back after explicit drag
- collapsed pane recovery in shell and raw split contexts
- no recursive layout mutation from `viewDidLayout`

## Rollout Notes

- Migrate only the currently broken adopters in this pass.
- Keep legacy behavior in untouched screens until the shared foundation is proven.
- Favor shared helpers over broad class hierarchies so adoption remains incremental.
