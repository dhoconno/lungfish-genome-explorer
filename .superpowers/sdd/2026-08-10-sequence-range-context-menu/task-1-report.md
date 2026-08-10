# Task 1 Report: Compose target-specific and selected-range menus

## Status

Implemented the bounded local-composer architecture for `SequenceViewerView` context menus. Task 2 routing was intentionally left unchanged.

## Implementation

- Added the local `SequenceViewerContextTarget` model with read, variant, annotation, alignment, and sequence cases.
- Added `buildContextMenu(for:clickedTrackIndex:)`, selected-range composition, separator normalization, and the DEBUG `testBuildContextMenu` seam.
- Preserved sequence/background commands, including Select All, Zoom to Fit, Show in Inspector, Center View Here, and the no-selection per-track translation toggle path.
- Reused the existing closure-backed read action builder without replacing its targets.
- Split alignment, variant, and annotation menu construction from presentation. Alignment construction accepts an empty entry list and preserves BAM URL payloads; variant and annotation payloads and enabled-state logic remain intact.
- Removed duplicate shared center/selection-zoom entries from specialized builders while retaining Zoom to Annotation.
- Preserved Copy/Extract Visible Region selectors and semantics; renamed only the selection zoom label to Zoom to Selected Region.

## Files

- `Tests/LungfishAppTests/SequenceViewerContextMenuTests.swift`
- `Sources/LungfishApp/Views/Viewer/SequenceViewerView+Interaction.swift`
- `Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift`

## Exact TDD RED/GREEN evidence

1. RED: `swift test --filter SequenceViewerContextMenuTests` exited 1. The new test could not compile because `testBuildContextMenu` and the target model did not exist; compiler diagnostics identified those missing production symbols.
2. GREEN: the same command exited 0 with 1 test executed and 0 failures.
3. RED: the focused command exited 1 with 3 tests executed; alignment failed to provide Show BAM in Finder and read failed to provide both specialized actions, while the sequence test passed.
4. GREEN: the same command exited 0 with 3 tests executed and 0 failures.
5. RED: the focused command exited 1 with 5 tests executed; variant failed the table/genotype action lookup and annotation failed the annotation action lookup.
6. GREEN: the same command exited 0 with 5 tests executed and 0 failures.
7. RED: the focused command exited 1 with 6 tests executed; the background-preservation regression reported the missing Show in Inspector item.
8. GREEN: the same command exited 0 with 6 tests executed and 0 failures.
9. RED: the focused command exited 1 with 7 tests executed; the separator regression reported no separator before the shared selection section.
10. GREEN: the same command exited 0 with 7 tests executed and 0 failures.

## Final verification

`swift test --filter 'SequenceViewerContextMenuTests|ReadContextMenuTests|SequenceViewerReadVisibilityTests'` exited 0: 20 tests executed, 0 failures.

`git diff --check` exited 0.

## Self-review

- Target precedence and `rightMouseDown` production routing were not refactored; Task 2 retains that responsibility.
- Read menu actions retain closure-backed targets and alignment reveal actions retain the view target plus URL represented objects.
- Variant and annotation represented objects, selectors, enabled-state handling, annotation-specific zoom, and shared-item uniqueness are covered by real NSMenu tests.
- No generalized framework, MiniBAM, scientific-data, or provenance changes were introduced.
- A separate code-review subagent was unavailable in this environment; manual scope and behavior review was performed after the final focused suite.

## Concerns

None for Task 1. Task 2 still owns production routing integration for the centralized composer.
