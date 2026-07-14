# Focused Reference Annotation Scope Design

## Goal

Keep the reference annotation detail scoped to every visible record during normal list browsing, but show only the currently selected record's annotations while the reference viewport is in Focus mode.

## Behavior

- In list/detail mode, the annotation drawer scope remains the set of all rows displayed after global and per-column filtering.
- Entering Focus mode publishes a singleton annotation scope containing the selected record's sequence name.
- If no displayed row is selected when Focus is requested, the first displayed row is selected before the singleton scope is published.
- If no rows are displayed, Focus mode publishes an empty scope and retains the existing empty-detail placeholder.
- Changing filters while Focus mode is active reconciles selection first, then republishes the selected row as the singleton scope. If filtering removes every row, the focused scope becomes empty.
- Leaving Focus mode restores the normal all-visible-row scope. Legacy reference tables retain their existing unfiltered `nil` scope outside Focus mode.

## Architecture

`ReferenceBundleViewportController` remains the owner of both presentation mode and row selection. Its annotation-scope publisher will derive scope from presentation mode:

1. Reconcile the selected row against `displayedRows`.
2. In Focus mode, publish either the selected row's name as a singleton set or an empty set.
3. Outside Focus mode, publish the existing visible-row scope rules.

`ViewerViewController` and `AnnotationTableDrawerView` require no new query model. They continue receiving `Set<String>?` through `setAnnotationRecordScope(_:)`, so existing cancellation, count/type refresh, and stale-generation handling remain unchanged.

## Error and Empty States

- A missing selection with visible rows is repaired by selecting the first visible row.
- Zero visible rows clear graphical detail and publish an empty annotation scope.
- A corrupt or missing record store continues to use the existing manifest-row fallback; Focus mode still scopes to its selected sequence.

## Testing

Viewport tests will verify:

- list mode publishes all visible record-store rows;
- entering Focus publishes only the selected row;
- leaving Focus restores all visible rows;
- filtering while focused selects the first remaining row and publishes it;
- zero matches publish an empty scope and clear selection;
- legacy unfiltered list mode uses `nil`, Focus uses a singleton, and leaving Focus restores `nil`.

