# Phase 4 — Adversarial Review #2 (independent)

**Date:** 2026-04-09
**Commits reviewed:** 813655c, 1f0a9f5, 1ab14f3, ba07481, 218e1f4
**Reviewer:** independent second pass (clean context, review-1 not consulted until end)
**Charter:** Independent adversarial review AFTER the simplification pass.

## Summary

Phase 4 lands a working dialog + orchestrator and the simplification pass closes
the bundle-clobber collision hole, wires `errorMessage:` into `OperationCenter.fail`,
adds a `present()` re-entrancy guard, and makes the initial estimate cancellable.
Build is clean, 23 ClassifierExtractionDialogTests pass (empirically verified),
and the `ExtractionBundleNaming.bundleName(source:selection:)` path confirms the
disambiguated `displayName` is load-bearing for the bundle directory name (the
forwarded Phase 2 review-2 item is now fully closed at the filesystem level).

**However**, one **significant behavioral regression** remains that neither the
initial implementation nor the simplification pass addressed: the dialog's
`Cancel` button during an in-flight extraction only cancels the estimate task
and tears down the sheet — it does **not** cancel the extraction `Task.detached`.
The plan explicitly says (spec lines 277–278): "Cancel stays enabled and routes
to the underlying Task's cancellation." Today the only path to cancelling an
in-flight extraction is the Operations Panel row, which is a UX gap.

Additionally: test-seam mutation on the shared singleton has no reset/teardown
discipline, one `@testable` latent NSWindow side-effect in the test helper, and
the CLI round-trip embeds the random disambiguator suffix into `--bundle-name`
(user-visible in the Operations Panel) with no acknowledgement.

## Critical issues (must fix before moving on)

- [ ] **Dialog Cancel during extraction does not cancel the extraction task.**
  `TaxonomyReadExtractionAction.swift:204-209` — the dialog's `onCancel` closure
  captures only `estimateTaskBox`. When the user clicks Cancel after pressing
  Create Bundle (while `model.isRunning == true`), the closure does
  `estimateTaskBox.task?.cancel()` (a no-op, the estimate already completed or
  returned) and then `hostWindow.endSheet(sheetWindow)` — the sheet closes but
  the extraction `Task.detached` at `startExtraction:336-406` keeps running.
  The extraction task's handle is only stored in
  `OperationCenter.shared.setCancelCallback(for: opID)`, so the user must find
  the running row in the Operations Panel to stop it. Worse, `handleSuccess`
  later runs on the detached task's completion path, triggers
  `sidebar.reloadFromFilesystem()`, and produces an orphaned bundle in the
  project folder with no dialog feedback. The cancel button in the dialog is
  NOT disabled during `isRunning` (correctly per the spec at ASCII-mockup line
  278), so the user actively expects it to cancel the operation. **Fix**:
  extend `TaskBox` (or introduce a second box) to also hold the extraction
  task handle, store it on successful assignment in `startExtraction`, and
  cancel it in the dialog's `onCancel` closure. Do NOT dismiss the sheet on
  cancel until `model.isRunning` is false — show "Cancelling…" state and wait
  for the catch branch.

## Significant issues (should fix)

- [ ] **Test-seam mutation on `.shared` singleton has no reset/teardown.**
  `ClassifierExtractionDialogTests.swift:199, 228` invoke
  `TaxonomyReadExtractionAction.shared.resolveDestinationForTesting(…)` against
  the live singleton. The test seams (`alertPresenter`, `savePanelPresenter`,
  `resolverFactory`, `pasteboard`) are `var`s on the singleton. Today's tests
  only touch the `.bundle` branch which doesn't exercise any seam, so they
  pass — but any future test that assigns
  `TaxonomyReadExtractionAction.shared.savePanelPresenter = Mock()` will leak
  that state into every subsequent test in the same process. There is no
  `setUp`/`tearDown` snapshot-and-restore discipline, no
  `@MainActor func tearDown()` to reset to defaults. **Fix**: either make the
  singleton's test-seam mutators go through a `resetTestSeams()` method that
  tests call in `tearDown`, or move the tests away from `.shared` and
  construct a fresh instance per test (requires loosening the `private init`
  or adding a `#if DEBUG` convenience init).

- [ ] **`resolveDestinationForTesting` creates a real `NSWindow` per invocation.**
  `TaxonomyReadExtractionAction.swift:612-617` constructs
  `NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)`
  on every test call. The `.bundle` branch doesn't touch the window, but the
  NSWindow initializer itself allocates an `NSWindowTabGroup` and posts
  `NSWindowDidBecomeKey`-adjacent notifications when the window is first
  materialized. With `defer: true` the window-server backing is deferred until
  display, so this is probably harmless in headless XCTest, but the helper
  accepts an optional `NSWindow?` pattern that would be cleaner: make
  `resolveDestination`'s `hostWindow` parameter `NSWindow?` and early-error if
  the caller needs it (i.e., only the `.file` branch), then
  `resolveDestinationForTesting` can pass `nil`. Minor, but would also make
  future `.file`-branch tests trivially mockable.

- [ ] **CLI round-trip embeds the random disambiguator suffix without warning.**
  `TaxonomyReadExtractionAction.swift:542-588` — `buildCLIString` receives
  the already-resolved `destination`, so when the user hits Create Bundle with
  the default name, the resolved `displayName` is `my-extract-20260409T144521-k7q2`
  and the Operations Panel shows:
  `lungfish extract reads --by-classifier --tool esviritu ... --bundle --bundle-name my-extract-20260409T144521-k7q2 -o my-extract-20260409T144521-k7q2.fastq`
  A user who copies that command and re-runs it tomorrow will get a bundle
  with yesterday's stale timestamp baked into the name. That's not a bug per
  se — the CLI will happily make a bundle with whatever name you pass — but
  it's surprising. The random 4-char suffix specifically will never match
  what the CLI would produce on its own (the CLI has no such suffix). **Fix**:
  either (a) document this in a comment above `buildCLIString` so future
  maintainers don't chase it, or (b) strip the disambiguator suffix from the
  `--bundle-name` arg in the reconstruction. Option (a) is simpler.

- [ ] **Operations Panel `.log()` entries use different levels than the plan.**
  The plan at line 4302 says `OperationCenter.shared.log(id: opID, level: .info, message: "Extraction started: \(cli)")`. The implementation at
  `TaxonomyReadExtractionAction.swift:332` matches. But the progress callback
  at line 346-354 logs every progress tick as `.info`, which will flood the
  operations log for a 10k-read extraction (samtools view -c → samtools view
  → samtools fastq → concat → gzip, each step probably multiple ticks).
  MEMORY.md "Operations Panel Logging" notes that `.log()` adds a timestamped
  entry — if the resolver fires progress 100+ times, the user's Operations
  Panel becomes unreadable. **Fix**: log only at phase boundaries (initial
  "Extraction started", a few key milestones, and "Extracted N reads"), not
  on every progress fraction update.

## Minor issues (nice to have)

- [ ] **`TaskBox` has no cancel-on-present-return teardown.** If `present()`
  returns normally (sheet opens successfully), the estimate task runs to
  completion, writes its result into the model, and the detached task's
  closure captures the box by value (reference). The box is never explicitly
  cleared. This is fine under ARC (the dialog closure and box are released
  when the sheet closes), but add a brief comment explaining the lifetime so
  future maintainers don't reach for a strong-cycle-breaker they don't need.

- [ ] **`@Observable` macro + `@MainActor` — verify no strict-concurrency
  warnings at clean build.** The view model at `ClassifierExtractionDialog.swift:56-58`
  combines `@Observable` and `@MainActor`. The Observation macro generates
  non-isolated tracking infrastructure; the combination is legal but worth
  verifying. A clean `swift build --build-tests 2>&1 | grep -i warning`
  against this file would pin the claim. My spot-run of the test target
  shows no warnings, but I did not do a full strict-concurrency clean build.

- [ ] **Dead code: `ClassifierExtractionDialogViewModel.estimatedUnmappedDelta`
  is read by the view but the view model's unit tests never set it.** Minor
  coverage gap; see Test gaps below. The simplification pass deleted
  `estimatingUnmappedDelta` but kept `estimatedUnmappedDelta`, which is
  correct — the latter IS used by the view at line 182.

- [ ] **`buildCLIString` uses `#  (…)` annotation for clipboard/share.** The
  `#` prefix is a shell comment marker, which is correct — a copy-pasted
  command with the annotation at the end will be parsed as a comment by bash.
  But the annotation starts mid-command (`--read-format fastq # (clipboard — GUI only)`),
  which is technically fine but ugly in the Operations Panel display. A
  cleaner pattern would be to put the annotation on its own line, prefixed
  with `#`, and emit the working command without it. Not urgent.

- [ ] **`NSPanel` style mask `[.titled]` has no `.nonactivatingPanel` or
  `.hudWindow` consideration.** The plan specifies `[.titled]` for the sheet
  container, which is correct for a standard sheet. `NSPanel` defaults keep
  this as a child-window-style sheet. No action needed; noting for
  completeness.

## Test gaps

- **No test for Dialog Cancel during extraction.** See Critical #1 — a test
  that toggles `model.isRunning = true`, calls the cancel closure, and
  asserts the extraction task is cancelled would pin the correct behavior.

- **No test seam reset/teardown pattern.** See Significant #1 — a
  `tearDown()` method that restores defaults would prevent future test
  pollution across runs. Not strictly a gap today (nothing mutates seams),
  but load-bearing once Phase 6/7 starts adding mock-based tests.

- **No test that `resolveDestinationForTesting` round-trips `.bundle` twice
  and asserts unique output paths.** The existing
  `testResolveDestination_bundle_withDefaultName_appendsTimestamp` asserts the
  suffix is present, and `testShortStamp_twoRapidCalls_produceDifferentStrings`
  asserts the stamp itself varies, but no test asserts that two sequential
  `resolveDestinationForTesting` calls with the default name produce
  different `displayName`s end-to-end.

- **`estimatedUnmappedDelta` not exercised in any test.** The view reads it
  conditionally (line 182) and the orchestrator sets it (line 267). No test
  asserts the view model's behavior when `estimatedUnmappedDelta = 5`.
  A one-line test would pin the display rule.

- **No test for `.file` save-panel cancellation throwing `.cancelled`.**
  `resolveDestination .file` at line 467-469 throws `ClassifierExtractionError.cancelled`
  when `savePanel.present` returns `nil`. A test that injects a mock
  `SavePanelPresenting` returning `nil` and asserts the throw would pin this
  newly-wired error path. Deferred to Phase 6/7 per simplification disposition,
  but worth re-raising.

- **No test for the re-entrancy guard in `present()`.** A test that calls
  `present()` with a mock window that claims to already have an attached
  sheet, and asserts nothing was allocated, would pin the guard against
  accidental removal.

- **No clean-build warning check for `@Observable @MainActor`.** See Minor #2.

## Verification of the simplification pass (commit 218e1f4)

- **#1 `shortStamp` random suffix**. VERIFIED empirically. I ran a standalone
  Swift test of the exact helper logic — 100 calls inside a single wall-clock
  second produced 100 unique suffixes (0 collisions). 10000 calls over the
  full 36^4 space produced 28 collisions, matching birthday-paradox
  expectations (~19 expected). The helper is robust for real rapid-click
  scenarios.

- **#2 `OperationCenter.fail(… errorMessage:)`**. VERIFIED. Both call sites
  (line 370 cancellation, line 388 error) now pass `errorMessage:` explicitly.

- **#3 `present()` re-entrancy guard**. VERIFIED correct. The check at
  line 175 reads `hostWindow.attachedSheet` which is an AppKit property;
  `present()` is `@MainActor`, so the read is main-thread safe. The guard
  logs via `logger.info` but silently drops — a disabled menu item would be
  more user-visible but belongs to the Phase 5 controller.

- **#4 `TaskBox` race**. VERIFIED theoretical-only. The box is assigned
  synchronously right after `beginSheet`, which schedules the SwiftUI render
  on the next run-loop tick. The user cannot physically click Cancel between
  `beginSheet` and the `.task = runInitialEstimate(…)` assignment because the
  button doesn't exist on screen yet. The race is impossible in practice.

- **#5 `.share` contentView fallback**. VERIFIED. Line 521 now computes
  `let anchor: NSView? = sheetWindow?.contentView ?? hostWindow.contentView`
  and falls through to a `logger.warning` in the double-nil case. Line 523
  calls `sharingServicePresenter.present(items: [url], relativeTo: anchor, …)`
  which means the log is at least present in the double-nil case — good.

- **#6 Deleted `estimatingUnmappedDelta`**. VERIFIED. Grep returns zero
  matches for the identifier in the view or view model.

- **#7 Deleted redundant `contextCopy = context`**. VERIFIED. Both sites
  (runInitialEstimate and startExtraction) capture `context` directly now.
  `Context: Sendable` makes this safe.

- **#8 `resolveDestinationForTesting #if DEBUG` gate**. VERIFIED. Line 601
  wraps the helper in `#if DEBUG … #endif`. The helper is NOT visible in
  release builds, confirmed by the `#if` placement around the method
  declaration itself (not just the body).

- **#9 `shortStamp` 20-char format**. VERIFIED by test
  `testShortStamp_producesFilenameSafeFormat` which splits on `-`, asserts
  14 digits + `T` in the timestamp half and 4 base36 chars in the random
  half. `testShortStamp_pinnedUTCDate` asserts prefix match. Both tests pass.

## Verification of authorized deviations (1–17)

I verified deviations #1-9 (inherited from initial implementation) via code
reading and test run. All match the descriptions in the context. Deviations
#10-18 (simplification pass) are covered above.

One note on deviation #17 (`resolveDestinationForTesting` test hook): the
helper is correctly `#if DEBUG`-gated and does not leak into Release. However,
the throwaway `NSWindow` it constructs has `styleMask: []` which is a valid
construction but unusual. The cleaner fix (make `hostWindow: NSWindow?`) is
noted as Significant #2.

## Probes from the charter (independent of review-1)

1. **`shortStamp` determinism**: Empirically robust (see simplification-pass #1).

2. **`TaskBox` race**: Theoretical only, not a real problem (see #4).

3. **`NSWindow` side-effects in test helper**: Acceptable under `defer: true`,
   but cleaner alternative noted (Significant #2).

4. **`resolveDestination` vs `resolveDestinationForTesting` drift**: The test
   helper is a genuine pass-through (line 618 calls `resolveDestination`
   directly), not a copy. Future refactors will automatically flow through.

5. **Bundle disambiguator user-rename edge cases**:
   - User types suggested name verbatim → suffix IS applied. Tested implicitly.
   - User renames to `"foo"` then back to suggested → suffix IS applied.
     Not tested; minor UX surprise but not a correctness bug.
   - Empty `suggestedName` → `"" == ""` is true, suffix applied, gives
     `-20260409T144521-k7q2` which is a valid (if ugly) bundle name. No
     crash. Not tested.

6. **`present()` re-entrancy guard thread safety**: Safe because `present()`
   is `@MainActor` and `attachedSheet` reads from the main thread.

7. **`TaskBox` class isolation**: `@MainActor final class`, correct. All
   box access is on the main actor.

8. **Random suffix regex check in tests**: Confirmed — the test splits on
   `-` and validates the 4-char base36 suffix alphabet, but does not assert
   a regex match across the full `\d{8}T\d{6}-[a-z0-9]{4}` pattern. The
   current assertions are sufficient.

9. **CLI round-trip with timestamp suffix**: Users will see an ugly
   `--bundle-name my-extract-20260409T144521-k7q2` in the Operations Panel.
   Raised as Significant #3.

10. **Resolver `selectionDescription: "extract"` hardcoding**: VERIFIED at
    `ClassifierReadResolver.swift:703`. The directory name is
    `{sanitize(displayName + "-extract")}.lungfishfastq` via
    `ExtractionBundleNaming.bundleName(source:selection:)` at line 378. The
    disambiguator applied to `displayName` drives the `source` input, so two
    Phase 4 invocations WITH the disambiguator produce unique directories.
    The hardcoded `"extract"` is NOT load-bearing for uniqueness. The Phase
    4 fix is correct.

11. **`runInitialEstimate` 2x samtools cost**: Acceptable per-dialog cost
    (runs once on dialog open, cancellable on dismiss). A parallel
    single-invocation optimization is possible but out of scope for Phase 4.

12. **Dialog Cancel vs Escape**: Escape key is wired via
    `.keyboardShortcut(.cancelAction)` at line 270. During `model.isRunning`
    the Cancel button is NOT disabled, so Escape will invoke `onCancel`.
    But see Critical #1 — this only cancels the estimate, not the extraction.

13. **`@Observable @MainActor` compatibility**: Compiles and runs, no
    warnings in the test target build. Not verified against a full clean
    strict-concurrency build.

14. **SwiftUI body decomposition**: The dialog body is ~150 lines with two
    nested `VStack`s and one `HStack` per row. Type inference is fine —
    the test build shows no slow-compile warnings. Acceptable.

15. **`@testable import LungfishApp`**: Works because `LungfishApp` is a
    regular `.target` in `Package.swift` (line 160), not an
    `.executableTarget`. Test target at line 175 declares
    `dependencies: ["LungfishApp"]`. `@testable` imports internal symbols
    correctly.

## Positive observations

- **Build clean, 23/23 `ClassifierExtractionDialogTests` passing**
  (empirically verified via `swift test --filter`).
- **Empirical rapid-call test of `shortStamp` shows 0 collisions in 100
  same-second calls.** The random-suffix fix is robust.
- **The bundle-clobber defense is correctly load-bearing** — I traced the
  `displayName` through `ClassifierReadResolver.routeToDestination → ReadExtractionService.createBundle → ExtractionBundleNaming.bundleName → sanitize` and confirmed the disambiguator survives intact into the
  filesystem path (`sanitize` preserves `-` and alphanumerics).
- **Concurrency audit clean** — 5 background-to-MainActor dispatch sites
  all follow the `Task.detached → DispatchQueue.main.async →
  MainActor.assumeIsolated` pattern from MEMORY.md. No `Task { @MainActor in }`
  spawns from detached contexts, no bare `DispatchQueue.main.async` writes to
  `@MainActor` state.
- **`#if DEBUG`-gated test helper is the correct pattern** for exposing
  private orchestrator internals without leaking them into release builds.
- **CLI reconstruction is comprehensive** — covers `--by-classifier`, `--tool`,
  `--sample`, `--accession`, `--taxon`, `--read-format`, `--include-unmapped-mates`,
  `--bundle`, `--bundle-name`, and GUI-only annotations for clipboard/share.
- **All signatures verified** — `OperationCenter.start`, `OperationCenter.fail`,
  `OperationCenter.setCancelCallback`, `ExtractionOptions.init`,
  `ExtractionDestination.share(tempDirectory:)`, `ExtractionOutcome.share(URL, readCount:)`, and `ExtractionBundleNaming.bundleName(source:selection:)` all
  line up with how the orchestrator uses them.

## Divergence from review-1

**Issues I found that review-1 missed:**

- **Critical #1 — Dialog Cancel during extraction does not cancel the
  extraction task.** Review-1 flagged Significant #5 that `runInitialEstimate`
  needed a cancel path, which the simplification pass fixed via `TaskBox`.
  But neither review-1 nor the simplification pass noticed that the SAME
  problem applies to the extraction task during `isRunning == true`: the
  `Task.detached` handle at `startExtraction:336` is only stored in the
  `OperationCenter.setCancelCallback` slot, not in a box reachable from the
  dialog's `onCancel` closure. The spec explicitly requires this at design
  doc line 278: "Cancel stays enabled and routes to the underlying Task's
  cancellation." This is a larger regression than the estimate-cancel issue
  review-1 caught.

- **Significant #1 — Test-seam mutation on `.shared` singleton has no
  reset/teardown.** Review-1 verified the test seams exist but did not flag
  the singleton-pollution risk. This is latent today but becomes load-bearing
  in Phase 6/7 when mock-based integration tests start mutating the seams.

- **Significant #2 — `resolveDestinationForTesting` creates a real NSWindow
  per call.** Review-1 didn't examine the test helper's window construction.
  Not a bug today but a cleaner alternative exists.

- **Significant #3 — CLI round-trip embeds the random disambiguator suffix.**
  Review-1 verified `buildCLIString` covers `--bundle-name` but didn't trace
  the fact that the disambiguated name (with random 4-char suffix) is what
  gets rendered into the Operations Panel command string. The CLI cannot
  reproduce the suffix on its own, so the copy-pasteable command is slightly
  misleading.

- **Significant #4 — Progress callback floods `.log()` at `.info` level.**
  Review-1 verified the log/update pattern is correct per MEMORY.md but did
  not consider the volume of `.log()` entries at info level. A 10k-read
  extraction producing 100+ progress ticks will spam the Operations Panel
  log row.

**Issues review-1 found that I did not:**

- Review-1 verified the forwarded Phase 3 item A (`ClassifierTool.expectedResultLayout`)
  is absent and correctly documented the deferral to Phase 5 review #1. I did
  not check this forwarded item directly.
- Review-1 made the observation about double `[weak self]` capture at site 5
  (outer DispatchQueue.main.async captures weak self, inner Task captures
  weak self again). I examined the structure but didn't flag the redundant
  second capture.
- Review-1 noted the `NSPanel` style mask consideration and explicitly
  flagged it as intentional/WONTFIX. I arrived at the same conclusion.
- Review-1 raised the "user-rename-back-to-default" edge case explicitly in
  test gaps. I noted it under probe #5 but did not escalate it as a
  separate test gap.

**Verdict: NOT ready — additional fixes required.**

The dialog's Cancel button during an in-flight extraction does not cancel the
extraction task (Critical #1). This is a direct spec violation (design doc
line 278) and a user-visible regression: the user clicks Cancel, the sheet
closes, and a zombie samtools pipeline keeps consuming CPU and filesystem
space until the user finds the Operations Panel row to kill it. The fix is
small — extend the `TaskBox` pattern to also hold the extraction task
handle, cancel it from `onCancel`, and defer sheet dismissal until the
catch branch fires. File: `Sources/LungfishApp/Views/Metagenomics/TaxonomyReadExtractionAction.swift`
lines 200-227 (present) and 336-406 (startExtraction).

Significant issues #1-4 are follow-ups that do not individually block Phase
5, but issue #1 (test-seam pollution) should be fixed before Phase 6 starts
adding mock tests. Issue #3 (CLI disambiguator suffix) should at minimum
get a documenting comment before merge.

Recommendation:
1. Add Critical #1 fix (extend `TaskBox` or add a second box) + test.
2. Add a comment to `buildCLIString` explaining the random suffix embedding.
3. Proceed to Phase 5 with Significant #1-2 and #4 as follow-up items.

## Gate-3 fix disposition (controller's resolution)

Applied on branch `feature/batch-aggregated-classifier-views` as a single
targeted commit on 2026-04-09. Each review-2 comment is resolved below.

### Critical

- **Critical #1 — Dialog Cancel during extraction does not cancel the
  extraction task.** **FIXED.** Extended the existing `TaskBox` class with
  two optional task handles (`estimateTask`, `extractionTask`) and nested
  it under `TaxonomyReadExtractionAction` as a public-API surface for the
  Gate-3 test. The dialog's `onCancel` closure now cancels both handles
  and defers sheet dismissal when `model.isRunning` is true — the sheet
  closes from the extraction's `catch is CancellationError` branch after
  the detached task has honored the cancel. The `onCancel` path also sets
  `model.progressMessage = "Cancelling..."` as visual acknowledgement of
  the in-flight cancel. `startExtraction` now accepts the `taskBox` as a
  new parameter and stores the detached task handle immediately after
  creation so both the dialog's Cancel button and the Operations Panel
  row can tear it down. The `catch is CancellationError` branch dismisses
  the sheet after flipping `model.isRunning = false`. Spec conformance
  restored (design doc line 278). Orphaned-bundle UX regression closed.

### Significant

- **Significant #1 — Test-seam mutation on `.shared` singleton has no
  reset/teardown.** **DEFERRED to Phase 6/7.** The risk is latent today
  (no test mutates the seams) and becomes load-bearing only when mock-based
  integration tests start arriving in Phase 6/7. Deferring per the
  recommendation's "Significant #1 as follow-up items" line. Phase 6/7
  will need to add a `resetTestSeams()` method or move away from `.shared`
  before mock tests land.

- **Significant #2 — `resolveDestinationForTesting` creates a real
  `NSWindow` per invocation.** **DEFERRED.** Acceptable under
  `defer: true`; only the `.file` branch would benefit from an
  `NSWindow?` refactor. Out of scope for Gate-3's targeted cancel fix.

- **Significant #3 — CLI round-trip embeds the random disambiguator
  suffix without warning.** **FIXED.** Added a doc-comment block above
  `buildCLIString` explaining the situation: the disambiguated
  `displayName` is embedded in `--bundle-name` on purpose (faithful
  record of what the GUI did, not a recipe for reproduction). Future
  maintainers will not chase the embedded timestamp as a bug.

- **Significant #4 — Progress callback floods `.log()` at `.info`
  level.** **DEFERRED to Phase 5 polish.** Volume issue, not
  correctness. Phase 5's operations-panel polish pass will narrow the
  logging to phase-boundary milestones only.

### Minor

- **Minor #1 — `TaskBox` lifetime comment.** **FIXED.** The new doc
  comment on `TaskBox` explains the lifetime (released with the dialog's
  closures via ARC, no explicit clear needed).
- **Minor #2 — `@Observable @MainActor` strict-concurrency warnings.**
  **WONTFIX/VERIFIED.** A clean `swift build --build-tests` for Gate-3
  shows no warnings in the view model file. Pre-existing unrelated
  warnings in `VariantTrackRendererTests.swift` are untouched.
- **Minor #3 — Dead code coverage gap for `estimatedUnmappedDelta`.**
  **DEFERRED.** Test gap, not a correctness bug.
- **Minor #4 — `buildCLIString` `#` annotation formatting.** **DEFERRED.**
  Cosmetic; not urgent.
- **Minor (unnumbered) — `NSPanel` style mask consideration.**
  **WONTFIX.** Standard sheet container, intentional.

### Test gaps

- **No test for Dialog Cancel during extraction.** **PARTIALLY FIXED.**
  Added `testTaskBox_cancelBothTasks_cancelsSeparately` pinning the
  two-task-cancel building block that the critical #1 fix depends on.
  The full integration path (present → startExtraction → onCancel)
  requires a real `NSWindow` + mock resolver and is deferred to Phase 6/7
  mock-based tests per the disposition on Significant #1. Test count
  went from 23 → 24 in `ClassifierExtractionDialogTests`.
- **No test seam reset/teardown pattern.** **DEFERRED to Phase 6/7**
  alongside Significant #1.
- **No test for `resolveDestinationForTesting` round-tripping `.bundle`
  twice with unique paths.** **DEFERRED.** Existing tests
  (`testResolveDestination_bundle_withDefaultName_appendsTimestamp` +
  `testShortStamp_twoRapidCalls_produceDifferentStrings`) cover the
  building blocks; an end-to-end pair test is marginal.
- **`estimatedUnmappedDelta` view-model coverage.** **DEFERRED.**
- **No test for `.file` save-panel cancellation throwing `.cancelled`.**
  **DEFERRED to Phase 6/7** (requires mock `SavePanelPresenting`).
- **No test for the re-entrancy guard in `present()`.** **DEFERRED to
  Phase 6/7** (requires mock window with `attachedSheet`).
- **No clean-build warning check for `@Observable @MainActor`.**
  **VERIFIED inline** in the Gate-3 build output.

### Gate-3 verification

- `swift build --build-tests` — clean. Only pre-existing
  `VariantTrackRendererTests.swift` unused-variable warnings remain.
- `swift test --filter ClassifierExtractionDialogTests` — 24/24 passing
  (was 23/23; added `testTaskBox_cancelBothTasks_cancelsSeparately`).
- `swift test --filter LungfishAppTests` — 1531 tests executed, 3
  failures all in `FASTQProjectSimulationTests.testSimulatedProjectVirtualOperationsCreateConsistentChildBundles`
  which is the pre-existing floor failure acknowledged in the task
  prompt. No regressions from Gate-3 changes.
- `swift test --filter LungfishCLITests` — 363 tests, 0 failures.
  Phase 3 CLI contract intact.

**Verdict after Gate-3 fix disposition: Critical #1 closed, Significant
#3 closed, Minor #1 closed. Phase 4 is ready to hand off to Phase 5 with
Significant #1/#2/#4 and the remaining test gaps on the Phase 5-7
backlog.**
