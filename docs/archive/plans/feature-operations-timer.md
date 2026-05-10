# Feature: Operations Panel Elapsed Timer

## Status: Ready for Implementation

## Investigation Summary

### Current State of the Model (`OperationCenter.Item`)

The `OperationCenter.Item` struct in `Sources/LungfishApp/Services/DownloadCenter.swift` already has the timestamps needed:

- `startedAt: Date` -- set in `init()` via `Date()` default, recorded when `start()` is called.
- `finishedAt: Date?` -- set to `Date()` in `complete(id:detail:)`, `complete(id:detail:bundleURLs:)`, and `fail(id:detail:)`.

**No model changes are needed.** The elapsed time for a running operation is `Date().timeIntervalSince(item.startedAt)`. The final elapsed time for a finished operation is `item.finishedAt!.timeIntervalSince(item.startedAt)`.

### Current State of the UI (`OperationsPanelViewController`)

The panel is in `Sources/LungfishApp/Views/Operations/OperationsPanelController.swift`. It is a pure AppKit `NSPanel` with an `NSTableView` using manual cell construction (no SwiftUI). Key details:

- **Four columns**: Type (80px), Operation/title+detail (200px), Progress (120px), Action/cancel (60px fixed).
- **Data source**: `items: [OperationCenter.Item]` mirrored from `OperationCenter.shared.$items` via Combine `sink`.
- **Cell construction**: `reuseOrCreate(identifier:in:)` returns `NSTableCellView` with subviews created lazily on first use, identified by `tag` values.
- **Refresh trigger**: `OperationCenter.shared.$items` publisher fires on any item mutation (progress update, state change, add, remove). The table reloads fully via `tableView.reloadData()`.
- **Row height**: Fixed 36pt.

### Existing Elapsed Time Precedent in the Codebase

`WorkflowExecutionView` (in `Sources/LungfishApp/Views/Workflow/WorkflowExecutionView.swift`) already implements an elapsed time display with exactly the pattern we need:

- A `Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true)` fires every second.
- It calls `updateElapsedTime()` which formats `hh:mm:ss` via `String(format: "%02d:%02d:%02d", hours, minutes, seconds)`.
- The label uses `NSFont.monospacedDigitSystemFont` so digits do not jitter as they change.
- Timer is started on run, stopped on completion.

The `DocumentSection` SwiftUI view also has a `formatDuration` helper for static (completed) durations: `"42s"` / `"3m12s"`.

---

## Implementation Plan

### 1. Add an "Elapsed" Column to the Table (AppKit)

Insert a new column between Progress and Action.

| Column    | ID         | Width | Min | Max  | Content                        |
|-----------|------------|-------|-----|------|--------------------------------|
| Type      | `type`     | 80    | 60  | --   | Operation type badge           |
| Operation | `title`    | 200   | 100 | --   | Title + detail (two-line)      |
| Progress  | `progress` | 120   | 80  | --   | Bar or status text             |
| **Elapsed** | **`elapsed`** | **70** | **50** | **90** | **Elapsed time text** |
| Action    | `action`   | 60    | 60  | 60   | Cancel button                  |

The column header title should be "Elapsed". The cell contains a single `NSTextField` using `monospacedDigitSystemFont(ofSize: 11, weight: .regular)` and `.secondaryLabelColor`.

### 2. Cell Rendering Logic

In `tableView(_:viewFor:row:)`, add a new `case "elapsed":` branch:

```
For running items:
    Compute elapsed = Date().timeIntervalSince(item.startedAt)
    Format and display (see formatting rules below)
    Text color: .secondaryLabelColor

For completed items:
    Compute elapsed = item.finishedAt!.timeIntervalSince(item.startedAt)
    Format and display
    Text color: .tertiaryLabelColor (dimmed, operation is done)

For failed items:
    Same as completed (show how long it ran before failure)
    Text color: .tertiaryLabelColor
```

### 3. Timer Mechanism for Live Updates

The table currently only reloads when `OperationCenter.$items` publishes, which happens on progress updates but not on a fixed cadence. For elapsed time to tick visibly, we need a periodic refresh of the elapsed column while any operation is running.

**Recommended approach: A single 1-second `Timer` owned by the view controller.**

- **Start condition**: When `items` changes and at least one item has `state == .running`.
- **Stop condition**: When no items have `state == .running`.
- **Tick action**: Reload only the elapsed column cells, not the entire table. Use `tableView.reloadData(forRowIndexes:columnIndexes:)` targeting the elapsed column index and rows where `state == .running`. This avoids disrupting progress bar animations or cancel button states.
- **Storage**: `private nonisolated(unsafe) var elapsedRefreshTimer: Timer?` (same pattern as `WorkflowExecutionView.elapsedTimer`).
- **Scheduling**: `Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true)`. No need for `RunLoop.common` modes since this panel is a standalone utility window without scroll-tracking interference.
- **MainActor dispatch**: The timer callback should use `DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { ... } }` per the project's established pattern for GCD-to-MainActor dispatch (see MEMORY.md). However, since `Timer.scheduledTimer` already fires on the main run loop and the view controller is `@MainActor`, a simpler `Task { @MainActor in }` wrapper (matching the existing WorkflowExecutionView pattern) is acceptable here because the panel's run loop is reliably drained.

**Why not other approaches:**
- `CADisplayLink`: 60fps is overkill for a once-per-second text update. Wastes energy.
- `Timer.publish` (Combine): Would require another Combine subscriber. The existing codebase uses `Timer.scheduledTimer` for this exact pattern. Consistency wins.
- Relying on `$items` publisher alone: Progress updates come at irregular intervals (some operations update every 100ms, others every 5s). We need guaranteed 1s ticks for the elapsed column.

### 4. Time Formatting Rules

Use a single free function (module-level, not instance method -- per project convention for `@Sendable` closure compatibility):

```
formatElapsedTime(_ interval: TimeInterval) -> String
```

**Formatting tiers:**

| Duration Range   | Format     | Example    |
|------------------|------------|------------|
| < 1 second       | `"<1s"`    | `<1s`      |
| 1s -- 59s        | `"Ns"`     | `42s`      |
| 1m -- 59m 59s    | `"Nm Nns"` | `3m 12s`   |
| >= 1 hour        | `"Nh Nm"`  | `1h 23m`   |

Rationale:
- The compact format (`3m 12s`) is consistent with the existing `formatDuration` in `DocumentSection` and the `estimatedRemainingText` in `AppDelegate`.
- `hh:mm:ss` format (as in `WorkflowExecutionView`) is appropriate for a dedicated large label but too wide for a 70px table column.
- Sub-second operations show `<1s` rather than `0s` to indicate the operation did run.
- At the hour+ tier, seconds are dropped because they add noise and the column is narrow.

### 5. Lifecycle: What Happens When an Operation Completes

1. `OperationCenter` sets `finishedAt = Date()` and `state = .completed` (or `.failed`).
2. The `$items` Combine subscriber fires, which calls `tableView.reloadData()`.
3. The elapsed column cell for that row now computes from `finishedAt - startedAt` (a fixed value) and renders in `.tertiaryLabelColor`.
4. If no more running items remain, the 1-second timer is invalidated and set to `nil`.
5. The final elapsed time is frozen and remains visible until the user clears completed items.

### 6. Edge Cases

| Edge Case | Handling |
|-----------|----------|
| Operation completes in <1s | Display `<1s` (not `0s` or blank) |
| Operation runs for hours | Format as `Nh Nm` (e.g. `2h 15m`); no overflow risk since `TimeInterval` is `Double` |
| Multiple concurrent operations | Each row independently computes from its own `startedAt`; timer refreshes all running rows |
| Panel opened after operation started | `startedAt` is on the model, not the view. Elapsed time is correct immediately. |
| Panel closed while operations run | Timer should be invalidated in `viewWillDisappear` / `deinit`. Reopening the panel recreates the timer if needed. |
| `finishedAt` is nil on a completed item | Defensive: fall back to `Date().timeIntervalSince(startedAt)`. This should not happen given current code, but guard against it. |
| Timer leaks on dealloc | `deinit` must invalidate the timer. Use `nonisolated(unsafe)` storage (same as existing timers in the codebase). |
| Clock jumps (NTP adjustment, sleep/wake) | `Date()` is wall-clock time. A large NTP jump could produce a negative or inflated interval. Clamp to `max(0, elapsed)`. For sleep/wake, the elapsed time correctly reflects wall-clock duration, which is the user's expectation. |

### 7. Panel Width Adjustment

The new column adds approximately 70px. Adjust the default panel width from 500 to 560 in `OperationsPanelController.init()`:
- `contentRect: NSRect(x: 0, y: 0, width: 560, height: 400)`
- `panel.minSize = NSSize(width: 460, height: 250)` (was 400)

### 8. Files to Modify

| File | Change |
|------|--------|
| `Sources/LungfishApp/Views/Operations/OperationsPanelController.swift` | Add elapsed column, timer, formatting function, column rendering |
| `Sources/LungfishApp/Services/DownloadCenter.swift` | No changes needed |

### 9. Testing Considerations

- **Unit test for `formatElapsedTime`**: Test all four tiers plus negative input and very large values.
- **Manual verification**: Start a download, open the panel, confirm the timer ticks once per second. Complete/fail the operation, confirm the time freezes and dims.
- **Memory**: Open the panel, close it, re-open it. Confirm no timer leaks via Instruments Allocations.
- **Performance**: With 20 items in the table, the per-second reload of one column (approximately 20 cells) is negligible.

### 10. Implementation Order

1. Add the `formatElapsedTime` free function at the bottom of the file.
2. Add the elapsed `NSTableColumn` in `setupTableView()`.
3. Add the `case "elapsed":` branch in `tableView(_:viewFor:row:)`.
4. Add the 1-second timer with start/stop logic keyed to running item presence.
5. Adjust panel dimensions.
6. Test manually.
7. Add unit test for the formatting function (consider extracting it to a testable location if needed).
