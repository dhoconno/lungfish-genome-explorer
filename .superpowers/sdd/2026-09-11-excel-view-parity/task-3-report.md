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

## Review round 2 partial handoff (NEEDS_CONTEXT)

Implemented and verified:

- `/tmp/lungfish-task3-review2-scope-red.log`: behavioral RED showed unbounded 2,758-character internal filter dump, missing readable labels, and filtered-call-derived capability.
- `/tmp/lungfish-task3-review2-review-red.log`: behavioral RED using actual `GenotypeEditableWorkbookService.Change` showed native review comments capped at four lines.
- `/tmp/lungfish-task3-review2-green1.log`: 7 focused native dialog/review tests passed.
- `/tmp/lungfish-task3-review2-combined.log`: complete affected Task 3 suites passed, **157 tests / 0 failures**.
- Captured scope now uses bounded sample/locus lists and labelled min reads, min percent, percent basis, search, visibility, and locus fields; it does not expose encoded/internal keys. Workbook-level modern-vs-legacy projection capability no longer guesses from visible call source strings or missing visible baselines.
- Production `GenotypeExcelExportDialogPresenter` now owns the exact native alert used by the controller; tests inspect its actual Return/Escape equivalents, default role, and primary label.
- Review tests construct actual Task 2 `Change` values and verify H1 identity, explicit clear, exact cell/stable-cluster identity, and complete long multiline before/after comments. Labels have no line cap and a bounded wrapping width inside the outer scroll view.
- `PendingGenotypeCurrentWorkbookRoute` captures the originating controller and `OperationRouteContext` synchronously before fingerprint preparation. Production revalidates both after that await and again around canonical preparation/open. `genotypeCurrentWorkbookExternalOpener` and `genotypeExcelErrorPresenter` are the exact injected I/O seams now used by this production path.
- Review ownership is revalidated after inspection before presentation, before apply, and before scoped error presentation. Sync phase availability treats project-session write denial as read-only, not only filesystem denial.

Unresolved required production workflow coverage:

- Controller replacement/project switch/authorization loss across both async waits needs a reliable production-route fixture covering success and failure suppression.
- Inspection → actual presentation → Task 2 acceptance → immediate recompute/refresh/save, zero-change acknowledgement, cancellation, ownership loss, and actionable errors still lacks a single injected production workflow test.
- The delayed `NSSavePanel` path still lacks an injected panel/export seam proving the same frozen snapshot crosses both dialogs and cancellation has no filesystem effects.

Two attempts at a production controller-replacement test were stopped and not retained. `/tmp/lungfish-task3-review2-route-green.log` first failed at the gate assertion. `/tmp/lungfish-task3-review2-route-green2.log` then hung after build completion and was interrupted: hiding the controller emits a bundle-switch request, producing a second fingerprint waiter against the fixture's single-continuation `FingerprintLoadGate` and orphaning the original waiter. No native modal, production app, or user project was launched. This partial commit must not be treated as Task 3 completion; a fresh integration-fixture pass is required.

## Astra integration remediation after round 2

This section supersedes the preceding partial handoff for the Task 3 UI/integration slice. Scientific acceptance and final scoped review remain separate parent-owned gates.

### Production changes

- The Inspector resolves project write authority when presenting the Excel role dialog. A denied editable-open or review request surfaces an actionable write-ownership explanation; ownership loss during review publishes unavailable state before stopping.
- The role dialog's call capability now comes from `currentWorkbookHaplotypeProjectionMode()`, captured synchronously with the displayed scope. It no longer infers workbook capability from `haplotypeCalls == nil`, visible rows, or call source strings. The supported explanation explicitly retains the per-row raw-baseline restriction.
- Review captures controller, bundle, `OperationRouteContext`, and actual native-window identity before resolving the Python runtime. It revalidates before inspection, after inspection, before atomic apply, and before error presentation. The existing real service, annotation store, recompute, matrix refresh, Inspector notification, and accepted-workbook regeneration remain the implementation.
- Editable open captures the same originating identities before fingerprint loading. Both successful preparation and errors revalidate them; coordinator authorization revalidation also retains this origin. Stale fingerprint requests remove their own pending slot without deleting a newer request. Accepted-workbook regeneration shares the guarded preparation/error path and never opens Excel automatically.
- Added production-used I/O seams for fingerprint loading, runtime/service lookup, inspection, native review presentation, role/save-panel presentation, and the existing viewport exporter. Defaults use the prior real services and native panels. No alternate/test-only workflow model or workbook engine was introduced.
- Production review alerts assign Return/Escape. The existing scroll presenter is exercised with actual parsed H1/H2 edits, row/column/cell targets, explicit clear, and complete multiline before/after comments.

### Behavior evidence

- `/tmp/lungfish-task3-integration-route-red.log`: `swift test --jobs 6 --filter MappingViewportRoutingTests/testExcelOpenRouteRevalidatesOriginAcrossBothAwaits` completed with **1 test / 5 expected failures**. It opened on a window change before fingerprint completion, and opened/presented errors on project/window changes after preparation.
- `/tmp/lungfish-task3-integration-review-red.log`: delayed native role/save tests passed; real accepted-workbook regeneration exposed an unguarded `NSApp.presentError` modal. A one-second process sample (`/tmp/lungfish-task3-integration-hang.sample`) identified `routeGenotypeCurrentWorkbookRequest`'s accepted-regeneration catch. The exact synthetic xctest process was terminated; that catch now uses the scoped injected presenter. No production app or user project was opened.
- `/tmp/lungfish-task3-integration-capability-red.log`: `swift test --jobs 6 --filter 'testControllerUsesCanonicalCallCapabilityWhenManualCallsAreFilteredOut|testExcelExportDialogReflectsProjectWriteOwnershipAndDeniedOpenIsActionable'` completed with **2 tests / 5 expected failures**, proving incorrect manual-call capability, an enabled editable role without ownership, and silent denied open.
- `/tmp/lungfish-task3-integration-review-mutation-red.log`: removing only project/window comparisons from the production origin predicate caused **1 test / 16 expected failures** in the actual review workflow (stale inspection/presentation/acceptance/errors). Both comparisons were restored before subsequent runs.
- `/tmp/lungfish-task3-integration-green2.log`: `swift test --jobs 6 --filter 'MappingViewportRoutingTests/testExcel|GenotypeExcelDialogBehaviorTests'` passed **12 tests / 0 failures**. The routing tests include 20 open cases across both awaits and 20 review cases across runtime, inspection, and presentation, including ownership loss, project change, actual window removal, and same-bundle controller replacement.
- `/tmp/lungfish-task3-integration-apply-green.log`: the enhanced real-service acceptance test passed **1 test / 0 failures**, covering eight cases: mixed edits, zero changes, cancel, workbook changed after review, runtime error, inspection error, regeneration error, and initial ownership denial. It checks durable annotations and acceptance provenance, exact call/row/column/cell presentation, full multiline comments, immediate exported viewer state, full-vs-annotation-only regeneration requests, and retention of accepted annotations when regeneration fails.
- First affected-suite covering run (`/tmp/lungfish-task3-integration-covering.log`) completed **215 tests / 2 failures**, both existing bundle-switch synchronization tests. Investigation found the round-2 origin guard applied to every action and rejected the intentional background sync after hiding its controller. Origin checks are now limited to `.openEditable`/`.acceptedEditable`; ordinary registration/dirty/background-sync behavior remains intact. Both failing tests remain included.
- `/tmp/lungfish-task3-integration-covering-final.log` then passed **215 tests / 0 failures**, including both restored lifecycle tests.
- Self-review strengthened the same-bundle replacement case to issue the replacement controller's real registration request as well. `/tmp/lungfish-task3-integration-coalescing-red.log` reproduced **1 test / 2 expected failures**: coalescing transferred the old pending open intent onto the replacement controller's registration. Stale Excel intents are now discarded before action coalescing; an imminent bundle-switch save also cancels a pending open intent.
- Final affected-suite covering command: `swift test --jobs 6 --filter 'MappingViewportRoutingTests|GenotypeExcelDialogBehaviorTests|GenotypeResultDisplaySectionTests|GenotypeNumericFilterDraftTests|GenotypeResultViewportWorkbookPublicationTests|GenotypeCurrentWorkbookSyncCoordinatorTests'`; final log `/tmp/lungfish-task3-integration-covering-complete.log`: **215 tests / 0 failures**, 47.631 seconds, completed 2026-09-11 19:13:26 local tool time. This includes all 66 MappingViewportRoutingTests and the strengthened coalescing/re-registration assertions.

### Fixture scope and limits

The new request-aware pause fixture stores one continuation per request and expires each after two seconds; fixture Python creation/editing also has a five-second deadline. Native display and actual production route methods are used throughout. The open tests retain real coordinator preparation and canonical-workbook validation, injecting only update I/O and the external opener. The review tests use actual openpyxl inspection and real atomic `acceptEditableWorkbook`/annotation-store publication; the injected update runner verifies already-saved state and attests the disposable workbook to complete the coordinator path.

The delayed-save tests invoke the real configured controller and its real production `NSAlert`/`NSSavePanel` setup, then inject user responses and exporter I/O. Literal assertions check the original threshold, original filtered rows, format, destination, progress/success, both cancellation paths, and editable-open dispatch. The stub output is an I/O witness, not a scientific XLSX validation. Full CLI regeneration/export bytes and integrated cohort/scientific QA remain Task 4, using the existing Task 1/2 services and their prior immutable test evidence.

Parent separately identified active-analysis export selection, canonical current-workbook locus narrowing, and percent-denominator coupling defects in scientific acceptance. They are deliberately not changed by this UI remediation. No release, merge, branch/worktree cleanup, or original/private cohort mutation was performed. This tracked report was appended normally; no new scratch report was force-added.

Self-review and `git diff --check` passed. Task 3 integration remediation is complete for parent scoped review; the scientific acceptance defects above remain release blockers in the parent's subsequent slice.

## Round 3: remaining scope disclosure and UIUX follow-ups (BASE 3547298e6)

- Added human-readable matrix row search, matrix sample search, diagnostic-only allele restriction, and filtered-cell highlight visibility to `GenotypeExcelCapturedScope`. The independent search field is now labelled “General search” so an empty general query cannot obscure active matrix searches.
- A configured production controller test activates all four real matrix restrictions, checks its generated snapshot, and pauses both native choice/save boundaries. It verifies every restriction appears in the actual alert, later live snapshots contain changed values, and the originally displayed summary and exported snapshot remain unchanged through both delays.
- Disabled editable-radio and read-only review-required Inspector actions now explain the writable-result/project-write-ownership requirements and that filtered export remains available. The native radio exposes the explanation as visible text, accessibility help, and tooltip; the Inspector exposes visible text, help, and accessibility hint. Approved role labels/explanations remain intact. The native accessory accommodates the extra explanation's height.
- A review with no supported changes uses “Acknowledge & Refresh”; a nonempty inspected change list retains “Import Changes”. The real-service production acceptance test verifies both branches, Return/Escape, zero-change acceptance, and existing error/cancel semantics.

Behavioral RED: `/tmp/lungfish-task3-round3-scope-red.log`, **2 tests / 6 failures**, demonstrated the omitted restrictions and ambiguous general-search label. `/tmp/lungfish-task3-round3-readonly-red.log`, **3 tests / 9 failures**, demonstrated missing native/Inspector denial explanations and the incorrect zero-change button title (two failures were ViewInspector reporting the absent help/visible content, not compilation errors).

Focused GREEN command: `swift test --jobs 6 --filter 'GenotypeExcelDialogBehaviorTests|GenotypeResultDisplaySectionTests/testReadOnlyExcelReviewExplainsUnavailabilityAndKeepsFilteredExportEnabled|GenotypeResultDisplaySectionTests/testDocumentExcelSectionHasOneExportButtonAndContextualReviewAction|MappingViewportRoutingTests/testExcelReviewAcceptanceSavesRefreshesAndRegeneratesIncludingZeroChange|MappingViewportRoutingTests/testExcelExportDialogReflectsProjectWriteOwnershipAndDeniedOpenIsActionable'` — **14 tests / 0 failures**, 9.386 seconds, `/tmp/lungfish-task3-round3-focused-green.log`.

Self-review and `git diff --check` passed. No scientific percent/locus/analysis behavior changed, no production app/private cohort was opened, and the previously passing 215-test run was not repeated for these presentation-only changes. Parent scoped re-review and subsequent scientific correction remain outstanding.
