# Task 3 implementation report

Status: implemented and focused verification passing.

## RED / GREEN evidence

- `/tmp/lungfish-task3-numeric-red.log`: focused compile failed because `prepareNumericFiltersForExport()` did not exist (intended RED).
- `/tmp/lungfish-task3-numeric-green.log`: 2 numeric export-boundary tests passed.
- `/tmp/lungfish-task3-dialog-red.log`: focused compile failed because the Excel role/choice API did not exist (intended RED).
- `/tmp/lungfish-task3-review-ui-red.log`: focused compile failed because the contextual review callback did not exist (intended RED).
- `/tmp/lungfish-task3-review-ui-green.log`: mounted SwiftUI Inspector review/export interaction test passed, 1 test / 0 failures.
- `/tmp/lungfish-task3-final-focused.log`: numeric draft, viewport publication, current-workbook coordinator, and Task 3 Inspector/dialog tests passed, **88 tests / 0 failures**.

One intermediate broad `GenotypeResultDisplaySectionTests` run (`/tmp/lungfish-task3-ui-green2.log`) had 2 failures in pre-existing threshold-guidance text assertions unrelated to Task 3. The final task-focused command excludes those unrelated assertions and includes the complete numeric, viewport publication, and workbook coordinator suites.

## Wiring and APIs

- `GenotypeResultDisplaySectionViewModel.prepareNumericFiltersForExport()` cancels debounce, validates all dirty drafts before mutation, preserves invalid nonempty text, commits valid fields atomically, clears pending/stepper flags, and publishes once.
- Inspector has one permanent `Export to Excel…` control in the Excel section. The old Genotype Display export control is removed.
- `GenotypeExcelExportRole` contains the approved role labels/explanations and defaults to filtered view. The native AppKit dialog uses radio buttons, Return/Escape, role-specific primary titles, committed filter summary, and disables editable current.xlsx for read-only projects.
- The composition root settles numeric drafts and revalidates the active controller before `presentExcelExportDialog(expectedDisplayState:)` captures one immutable `GenotypeViewportExportSnapshot`. The same snapshot crosses the choice and save panels.
- Filtered export continues through `GenotypeViewportExportService`/`.pivotExcel`; no second workbook engine was added.
- Editable open emits `.openEditable`; App wiring builds the normal fingerprinted coordinator request and calls Task 2 `preparedEditableWorkbookURL`, then opens the canonical writable path.
- `.reviewRequired` renders contextual `Review Excel Changes…`. Review resolves the managed `openpyxl` Python, calls `GenotypeEditableWorkbookService.inspect` off-main, rechecks controller identity, displays every proposed supported change (including zero-change acknowledgement), and calls only `GenotypeAnnotationStore.applyEditableWorkbook` through `acceptEditableWorkbook`.
- Accepted imports refresh effective haplotype/matrix UI immediately, emit the new full-vs-annotation snapshot according to imported call changes, call `markEditableWorkbookAccepted`, and regenerate via `preparedEditableWorkbookURL`. Task 2 revalidation remains authoritative.

## Files changed

- `Sources/LungfishGenotypeUI/GenotypeExcelExportChoice.swift` (new)
- `Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift`
- `Sources/LungfishGenotypeUI/GenotypeResultDocumentSection.swift`
- `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- `Sources/LungfishGenotypeUI/GenotypeNotifications.swift`
- `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`
- `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift`
- focused App/UI tests.

## Self-review / concerns

- `git diff --check` passed. No original checkout, release branch, or scientific input was touched.
- No production app was launched and no user project was opened. Native mounted SwiftUI behavior was exercised; no screenshot was retained.
- Existing Audit-lens legacy exports remain for their distinct non-Inspector formats.
- The Inspector reports current status and actionable errors. A durable “latest filtered file” link was not added because filtered exports can target arbitrary external paths and no provenance-backed recent-export state seam currently exists; adding an ephemeral path to document state would risk presenting a stale or deleted file as current.

## Completion follow-up

Commit following `e4571bd99` adds the required session-scoped latest filtered-export presentation.

- `/tmp/lungfish-task3-latest-link-red.log`: intended RED; the behavior test could not compile because `GenotypeFilteredExportSessionState` did not exist.
- `/tmp/lungfish-task3-latest-link-green.log`: successful-output retention, failed/cancelled retention, missing-file disabled/actionable UI, and current threshold guidance passed, 3 tests / 0 failures.
- `/tmp/lungfish-task3-final-combined3.log`: fresh final run after removing automatic Finder reveal; complete `GenotypeResultDisplaySectionTests`, `GenotypeNumericFilterDraftTests`, `GenotypeResultViewportWorkbookPublicationTests`, and `GenotypeCurrentWorkbookSyncCoordinatorTests` passed, **138 tests / 0 failures**.

The prior latest-link concern is resolved: state is intentionally per Inspector/controller session, records only a successful filtered export, retains the previous successful URL through failure/cancel, clears with Inspector selection teardown, and checks file existence again when rendering. The same Excel section shows progress, success/failure status, an explicitly labelled “Last filtered export” Finder link, and an actionable missing-file error. It never auto-opens the filtered output.

The two threshold-guidance failures were obsolete assertions, not a Task 3 regression. Controller inspection confirmed BASE `3258df0e7` already used “Display filters do not change calls. Re-run the analysis to change calling thresholds.” The test now asserts that exact current distinction and is named accordingly; it passes within the complete class run above.

## Review round 1 fixes

- `/tmp/lungfish-task3-review1-stepper-red.log`: behavioral RED; exporting during a rapid stepper burst published `[1]` instead of the settled `[1, 2]`.
- `/tmp/lungfish-task3-review1-typed-red.log`: behavioral RED; localized status text incorrectly removed the review action.
- `/tmp/lungfish-task3-review1-presenter-red.log`: initial presenter test recorded the missing production presenter symbols; the mounted behavior then exposed and drove the document-view sizing correction.
- `/tmp/lungfish-task3-review1-green2.log`: focused GREEN, **84 tests / 0 failures**.
- `/tmp/lungfish-task3-review1-combined.log`: final affected suites (`GenotypeExcelDialogBehaviorTests`, full `GenotypeResultDisplaySectionTests`, `GenotypeNumericFilterDraftTests`, `GenotypeResultViewportWorkbookPublicationTests`, `GenotypeCurrentWorkbookSyncCoordinatorTests`, and `GenotypeViewportPivotExportTests`), **155 tests / 0 failures**.

Production changes:

- The numeric export barrier now flushes an in-flight stepper burst exactly once and cancels its deferred duplicate.
- Review presentation uses typed `requiresReview` state rather than English status parsing. It renders call H1/H2 and exact matrix row/column/cell identities, previous-to-new values (including explicit clears), in a vertically scrollable native view; zero-change acknowledgement remains enabled.
- Review inspection and acceptance require current controller identity, bundle identity, and project-session write ownership both before inspection and immediately before atomic Task 2 apply.
- Canonical editable open captures its originating controller and revalidates controller, bundle, and project write authority after async preparation. Stale errors are likewise suppressed unless that same authorized context remains current.
- The role dialog describes the full immutable captured scope (semantic samples/loci plus every sorted visibility/search/filter value, including percent denominator) and identifies legacy/manual or missing-raw-baseline calls as read-only while retaining matrix review/comment support.
- `GenotypeExcelExportDialogRoute` is the production completion seam exercised for cancel-without-effects, both roles, and exact captured-snapshot reuse. The actual AppKit radio accessory is mounted in tests. Return/Escape remain assigned on the production alert.
- Filtered progress/success/failure events now publish only when the production request is explicitly the filtered Excel workflow; legacy exports cannot replace the session's last-filtered state.

New focused production/test files are `Sources/LungfishApp/Views/Inspector/GenotypeExcelReviewPresenter.swift` and `Tests/LungfishGenotypeUITests/GenotypeExcelDialogBehaviorTests.swift`. `git diff --check` passed. No production app or user project was opened. No screenshot was retained.
