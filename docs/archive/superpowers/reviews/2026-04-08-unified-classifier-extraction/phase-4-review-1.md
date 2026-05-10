# Phase 4 — Adversarial Review #1

**Date:** 2026-04-09
**Commits reviewed:** 813655c, 1f0a9f5, 1ab14f3, ba07481
**Reviewer:** general-purpose subagent
**Charter:** Independent adversarial review before simplification pass.

## Summary

Phase 4 lands a working dialog + orchestrator. Build is clean, all 19 new tests
pass, and the 8 authorized deviations are implemented as described — the
`--read-format` flag, ISO8601 disambiguator, refactored error alert, `Context:
Sendable`, and `handleSuccess` slimming all verify cleanly. **However** the
bundle-clobber disambiguator has a same-second-collision hole the tests do not
catch; Phase 3 forwarded item A (`ClassifierTool.expectedResultLayout`) was
dropped entirely; `ClassifierExtractionError.cancelled` is newly wired in
`resolveDestination .file` but the inflight-extract cancel path still bubbles
Swift's `CancellationError`; the `.share` success branch silently no-ops when
`sheetWindow?.contentView` is nil; and there is a dead `estimatingUnmappedDelta`
property plus a UX regression where failed operations pass no `errorMessage:`
to `OperationCenter.fail`. Forwarded items B, C, D verified clean.

## Critical issues (must fix before moving on)

- [ ] **Same-second bundle clobber still possible.** `TaxonomyReadExtractionAction.swift:400-406` appends `ISO8601DateFormatter.shortStamp(Date())` with second-level resolution (`yyyyMMdd'T'HHmmss`). Two back-to-back Create-Bundle clicks inside the same wall-clock second produce identical suffixes, reach `ClassifierReadResolver.resolveAndExtract → ReadExtractionService.createBundle` at `ReadExtractionService.swift:552-558`, and the second invocation clobbers the first via `fm.removeItem(at: destURL) + fm.moveItem`. The brief explicitly flagged this as "the single most load-bearing change in Phase 4." No test calls `shortStamp` twice to prove collision safety. **Fix**: either raise resolution (millis or UUID suffix), or check for existing bundle directory at `resolveDestination .bundle` and bail/retry. A cheap fix is to append a 4-char random suffix alongside the timestamp.

- [ ] **Dropped Phase 3 forwarded item A: `ClassifierTool.expectedResultLayout`.** Phase 3 review-2 Gate-3 disposition forwarded this to Phase 4 review #1 (see `ExtractReadsCommand.swift:548-553` comment "So we accept the path if EITHER the path itself exists OR its parent directory does"). Phase 4 did **not** add a `ClassifierTool.expectedResultLayout` metadata property. A grep for `expectedResultLayout|resultLayout|ResultLayout` across `Sources/` returns zero hits. The CLI pre-flight remains "too forgiving for non-NVD typos" and the GUI file chooser has no metadata to drive an NVD-specific sentinel-file path. **Fix**: either punt this explicitly to Phase 5/6 with a named deferral in `phase-4-review-1.md`, or add the metadata now as a 20-line addition on `ClassifierTool`.

## Significant issues (should fix)

- [ ] **`ClassifierExtractionError.cancelled` still dead on the extraction path.** `resolveDestination .file` at `TaxonomyReadExtractionAction.swift:421-423` throws `.cancelled` when the user dismisses the save panel — good, that wires up one of the four dead cases. But the detached-task `catch is CancellationError` at `TaxonomyReadExtractionAction.swift:329` still catches Swift's native `CancellationError`, not `ClassifierExtractionError.cancelled`. So if the task.cancel() path is taken (user clicks the Operation Panel cancel), the orchestrator writes `model.errorMessage = "Cancelled"` but never throws or stores the library error type. The library's `.cancelled` case in the extraction flow remains unused. This is a minor design smell; not a functional bug.

- [ ] **`.share` success branch silently fails when `sheetWindow?.contentView == nil`.** `TaxonomyReadExtractionAction.swift:473-479` presents the share picker inside `if let contentView = sheetWindow?.contentView { ... }`, and then unconditionally dismisses the sheet. If the content view is nil at the moment of success (e.g. the sheet window got deallocated), the share picker is skipped AND the sheet is dismissed, leaving the user with no feedback — they clicked Share, the operation completed, and nothing visible happens. **Fix**: either fall back to an alert ("Extraction complete; shared file at: …") in the else branch, or anchor the picker to `hostWindow.contentView` as a fallback.

- [ ] **UX regression: `OperationCenter.fail` called without `errorMessage:`.** `TaxonomyReadExtractionAction.swift:346` calls `OperationCenter.shared.fail(id: opID, detail: errorDesc)` with only 2 arguments. Per `DownloadCenter.swift:351` the `errorMessage:` parameter is "user-facing error summary (shown prominently in red)." Leaving it nil means the failure shows up in the Operations Panel detail text but NOT in the prominent red error display. All other callers (`CLIImportRunner.swift:255, 294`, `FASTQIngestionService.swift:256`, etc.) pass `errorMessage: msg` explicitly. **Fix**: `OperationCenter.shared.fail(id: opID, detail: errorDesc, errorMessage: errorDesc)`.

- [ ] **Re-entrancy: `present()` is not guarded against double-clicks.** `TaxonomyReadExtractionAction.swift:159-199` creates a fresh `sheetWindow`/`model` on every call and invokes `hostWindow.beginSheet(sheetWindow)` without checking `hostWindow.attachedSheet`. AppKit only supports one sheet per window at a time — the second `beginSheet` may queue or silently fail. **Fix**: early-return if `hostWindow.attachedSheet != nil`, or disable the menu item that triggers `present()` while a sheet is active.

- [ ] **Initial estimate not cancelled on dialog dismiss.** `runInitialEstimate` at `TaxonomyReadExtractionAction.swift:203-246` spawns a `Task.detached` that issues two `samtools view -c` invocations for BAM tools. If the user hits Cancel while the estimate is still running, the detached task keeps running (no handle is stored) and wastes subprocess resources. Not a correctness bug, but 10-sample selections mean 20 samtools spawns to discard. **Fix**: store the estimate task handle and `.cancel()` it from the `onCancel` closure.

## Minor issues (nice to have)

- [ ] **Dead property: `estimatingUnmappedDelta`.** `ClassifierExtractionDialog.swift:75` declares `var estimatingUnmappedDelta: Bool = false`. Nothing sets it. Nothing reads it. Delete.

- [ ] **Sharing panel dangle comment.** `TaxonomyReadExtractionAction.swift:476-479` acknowledges "the picker may dangle briefly" — if that's the accepted trade-off, suppress the log output so tests and reviewers aren't tempted to re-litigate.

- [ ] **`contextCopy = context` assignment is redundant.** `TaxonomyReadExtractionAction.swift:297` captures `context` (already Sendable) as `let contextCopy = context` immediately before the Task.detached. Since `Context: Sendable` is live (deviation #7), the direct capture of `context` would work. The extra variable adds no safety and is residue from the pre-Sendable version.

- [ ] **`NSPanel` style mask is `[.titled]` only.** `TaxonomyReadExtractionAction.swift:172` — the brief asks whether this should be `.titled | .closable | .resizable`. For a sheet it's fine (closable/resizable are irrelevant for modal sheets), but the bare `.titled` mask means the sheet has no close button — the user must use the dialog's Cancel button or Escape. Matches the plan; intentional.

- [ ] **`model.destination` gated by raw Button clicks in the radio list.** `ClassifierExtractionDialog.swift:206-216` implements the radio picker as a manual `Button` + `Image(systemName:)` pattern instead of a real `Picker(selection:)`. Works, but SwiftUI accessibility (VoiceOver) won't recognize it as a radio group. Consider switching to `Picker(...).pickerStyle(.radioGroup).disabled(model.clipboardDisabledDueToCap ? .clipboard : nil)` — though the per-row disable state is awkward in SwiftUI Picker and may justify the manual approach.

## Test gaps

- **No same-second collision test for the bundle disambiguator.** Two calls to `shortStamp(Date())` inside a single test frame WILL produce identical strings (second-resolution). The tests cover format + pinned-UTC but never exercise collision. Add a test that calls `shortStamp(Date())` twice in quick succession and asserts the caller's responsibility to handle collision explicitly — or, better, add a test that calls `resolveDestination(.bundle)` twice and asserts the second resolution produces a different path than the first.

- **User-rename-to-collision branch untested.** If the user customizes the name and that customized name happens to equal `context.suggestedName`, the disambiguator fires. The code comment at `TaxonomyReadExtractionAction.swift:399-404` says "If the user customized the name, trust them — no suffix," but the implementation uses a bare `model.name == context.suggestedName` comparison. If the user renames to something and then renames back to the suggested value, the suffix DOES fire. That's inconsistent with the comment's intent. No test exercises this edge case.

- **`DialogDestination → ExtractionDestination` translation untested.** The private `resolveDestination` method isn't accessible from tests (it uses the live `savePanelPresenter`, which is internal). The tests cover the view model and the CLI reconstruction but not the actual translation. Recommend: make `resolveDestination` `internal` (not `private`) and add a test that passes a mock `SavePanelPresenting` and asserts the returned `ExtractionDestination` case for each `DialogDestination`.

- **`buildCLIString` with `sampleId: nil` single-sample case not tested.** The Kraken2 test at line 160 covers `sampleId: nil` (and so exercises the "no `--sample` arg" branch), but that test's assertions only check `--tool kraken2` and `--taxon`. Add an explicit assertion: `XCTAssertFalse(cli.contains(" --sample "))`.

- **`buildCLIString` with both accessions AND taxIds (mixed selection) not tested.** Not a realistic input today (BAM tools use accessions, Kraken2 uses taxIds), but the builder doesn't enforce this — a future bug in selector construction would ship undetected.

- **`estimatedUnmappedDelta` computation not unit-tested.** The view model has a `estimatedUnmappedDelta` property and the view renders it conditionally on line 183, but no test sets `estimatedUnmappedDelta = 5` and asserts anything about the view or computed state.

- **`estimatedUnmappedDelta` vs toggle state not explicit.** The view shows the delta label regardless of whether `includeUnmappedMates` is toggled on — it's always visible when `delta != 0`. That's the design ("compute once, display always"), but the tests don't pin this behavior. A future refactor could gate on the toggle and no test would fail.

- **No test for the failure-path alert presenter.** `presentErrorAlert` is `@MainActor` and uses `alertPresenter`. A test with a mock `AlertPresenting` could drive an error path through `runInitialEstimate` (via a mock resolver that throws) and assert the mock alert presenter was called. Currently there's zero coverage of `presentErrorAlert` or the 4 test-seam protocols.

## Positive observations

- **Build clean, 19 tests pass, zero new Sendable warnings** against strict concurrency. `swift build --build-tests` and `swift test --filter ClassifierExtractionDialogTests` both succeed in ~5s.
- **Pinned UTC timestamp test is well-constructed.** `testShortStamp_pinnedUTCDate` uses `DateComponents` with explicit UTC timezone to avoid locale-dependent flakiness.
- **`Context: Sendable` makes the `Task.detached` capture clean.** Deviation #7 is the right call — `Sendable` conformance lets us pass the struct directly instead of spreading fields across captures.
- **The `presentErrorAlert` helper extraction is correct.** Deviation #3 genuinely avoids the MEMORY.md anti-pattern (see concurrency audit below).
- **`handleSuccess` parameter slimming (deviation #8) is correct.** The `@MainActor` protocol existentials `PasteboardWriting` and `SharingServicePresenting` aren't `Sendable`, so they can't be captured by the `Task.detached` closure. Using `self.pasteboard` / `self.sharingServicePresenter` from inside `MainActor.assumeIsolated` is the right pattern.
- **Test uses `@testable import LungfishApp` + `@MainActor` on the XCTestCase.** Correct for a `@MainActor`-isolated view model and internal test seams.
- **CLI reconstruction is comprehensive** — covers `--by-classifier`, `--tool`, `--sample`, `--accession`, `--taxon`, `--read-format`, `--include-unmapped-mates`, `--bundle`, `--bundle-name`, and GUI-only annotations for clipboard/share.

## Verification of the 8 authorized deviations

### 1. `--read-format` (not `--format`)

**Verified.** `TaxonomyReadExtractionAction.swift:520-521` emits `args.append("--read-format"); args.append(options.format.rawValue)`. `testBuildCLIString_formatFasta_flaggedAsReadFormat` explicitly asserts `cli.contains("--read-format fasta")` AND `!cli.contains(" --format ")` (sanity check against the colliding bare flag). Forwarded item C is closed. Note: the plan's original test at line 4705 was named `testBuildCLIString_formatFasta_flagged` and asserted the wrong flag `--format fasta` — the implementer correctly renamed and fixed the assertion.

### 2. Bundle clobber ISO8601 timestamp

**Partially verified. Has a HOLE under same-second collision** (see Critical issue #1). The helper is implemented correctly at `TaxonomyReadExtractionAction.swift:90-102` (15-char `yyyyMMdd'T'HHmmss` in UTC). It's applied in `resolveDestination` at lines 400-406 only when `model.name == context.suggestedName`. The CLI round-trip preserves the disambiguated name (`buildCLIString` uses the `displayName` from the `.bundle` case, which is the already-disambiguated value). The format is filename-safe (no `/`, `:`, etc.) — confirmed by the test. **But**: second-level resolution will collide on rapid retries; the user-rename-to-collision branch is ambiguous and untested.

### 3. Error-path alert presentation refactor

**Verified correct.** `presentErrorAlert(_:on:)` is a `@MainActor`-isolated helper at line 374. It's called from line 355 via `Task { [weak self] in await self?.presentErrorAlert(errorDesc, on: hostWindow) }` — structurally outside the `MainActor.assumeIsolated` block (line 345-350). The bare `Task { }` from inside `DispatchQueue.main.async` on the MAIN queue is acceptable per MEMORY.md: "GCD main queue IS reliably drained (mach port source in `kCFRunLoopCommonModes`)". The implicit actor isolation of the Task body comes from the `await self?.presentErrorAlert(...)` call, which hops to the main actor via the `@MainActor` method's isolation. The anti-pattern that MEMORY.md forbids is spawning `Task { @MainActor in }` from GCD **background** queues — the main queue is fine. Verified safe.

### 4. `runInitialEstimate` pattern kept as-is

**Verified.** `TaxonomyReadExtractionAction.swift:203-246` uses the `Task.detached` → `DispatchQueue.main.async { MainActor.assumeIsolated { ... } }` pattern exactly as MEMORY.md prescribes. Captures `[weak model]`, no `self.` access, and the resolver is created from a captured `resolverFactory` closure (no `self` capture). Correct.

### 5. `OperationCenter.fail` signature

**Verified compiles.** `DownloadCenter.swift:353` declares `fail(id:detail:errorMessage:errorDetail:)` with the latter two having defaults. The 2-arg call at `TaxonomyReadExtractionAction.swift:332` and `:346` compiles. **But** — see Significant issue #4 — leaving `errorMessage:` at default `nil` means the Operations Panel won't show the prominent red error summary. The signature compiles but the semantic is a minor regression against other callers.

### 6. `reloadFromFilesystem` exists on `AppDelegate`

**Verified.** `grep reloadFromFilesystem` confirms `AppDelegate.swift:408` calls `sidebarController.reloadFromFilesystem()` and many other sites do the same. The exact call chain in Phase 4 (`TaxonomyReadExtractionAction.swift:457-459`) is `let sidebar = appDelegate.mainWindowController?.mainSplitViewController?.sidebarController; sidebar.reloadFromFilesystem()`. The method is declared public on `SidebarViewController` at line 723 of `SidebarViewController.swift`. Clean.

### 7. `Context: Sendable`

**Verified.** `TaxonomyReadExtractionAction.swift:122` declares `public struct Context: Sendable`. All fields are Sendable: `ClassifierTool` is `Sendable` (per `ClassifierRowSelector.swift:22`), `URL` is trivially Sendable, `[ClassifierRowSelector]` is Sendable (per line 79), and `String` is trivially Sendable. Build-clean with strict concurrency.

### 8. `handleSuccess` parameter slimming

**Verified.** `handleSuccess` at line 439 has 5 parameters (`outcome, opID, context, hostWindow, sheetWindow`) and uses `self.pasteboard` / `self.sharingServicePresenter` directly at lines 465 and 474. Functionally identical to passing them as parameters. The reason cited (protocol existentials aren't Sendable, so they can't cross the `Task.detached` boundary) is correct — the build would fail otherwise.

## Verification of Phase 3/2 forwarded items

### A. `ClassifierTool` result-path layout metadata

**Absent.** Grep for `expectedResultLayout|resultLayout|ResultLayout` returns zero hits in `Sources/`. Phase 4 dropped this forwarded item entirely. See Critical issue #2. Either add the metadata now, or explicitly defer it to a later phase with a `review-2` sign-off.

### B. Walker rejects empty inline values

**Clean.** `buildCLIString` at `TaxonomyReadExtractionAction.swift:498-540` never emits empty inline values (`--foo=` or `--foo ""`). All appends are either literal flag names or non-empty string values derived from `selector.sampleId` (unwrapped), `selector.accessions` (filtered via `for`), `selector.taxIds` (stringified integers), `options.format.rawValue`, `url.path`, `name`. The bundle disambiguator ensures `name` is non-empty (though no guard on `model.name` being empty — see below). There is one edge case: if the user clears `model.name` and then the primary button is pressed, `buildCLIString` would emit `--bundle-name ""`. But the primary button is disabled via `.disabled(model.destination.showsNameField && model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)` at line 268 — the UI prevents it. Clean at the UI level.

### C. GUI command-string correct flag names

**Clean.** Covered by deviation #1 verification above.

### D. Bundle-clobber disambiguation

**Applied, with HOLE.** Covered by deviation #2 verification above. Critical issue #1 documents the same-second gap.

### E. Dead `ClassifierExtractionError.cancelled`

**Partially wired up.** `resolveDestination .file` at `TaxonomyReadExtractionAction.swift:421-423` throws `.cancelled` on save-panel dismissal, which is a legitimate wire-up of one dead case. The task-cancel path at line 329 still catches Swift's native `CancellationError` rather than `ClassifierExtractionError.cancelled`. Three dead cases remain: `bamNotFound`, `kraken2OutputMissing`, `kraken2TreeMissing` (these should be thrown by the resolver, not the orchestrator — forwarded to Phase 5/6).

## Concurrency audit

Phase 4 has 5 background-to-MainActor dispatch sites. MEMORY.md rules:

1. **NEVER** `Task { @MainActor in }` from GCD background queues (cooperative executor not reliably drained in AppKit).
2. **NEVER** bare `DispatchQueue.main.async` access `@MainActor` state — must wrap in `MainActor.assumeIsolated`.
3. **NEVER** `await` `@MainActor` from `Task.detached` (same reason as #1).
4. GCD main queue IS reliably drained — main-queue callbacks are safe as `MainActor.assumeIsolated` sites.

**Site 1: `runInitialEstimate` success path** (lines 230-235) — `Task.detached { ... DispatchQueue.main.async { MainActor.assumeIsolated { model?.estimatedReadCount = base } } }`. **Correct** per rule 4. Captures `[weak model]`. Clean.

**Site 2: `runInitialEstimate` failure path** (lines 238-243) — identical pattern. **Correct**.

**Site 3: Extraction progress callback** (lines 307-316) — the `progress:` closure passed to the resolver runs on the resolver's actor executor (not main). `DispatchQueue.main.async { [weak model] in MainActor.assumeIsolated { ... model?.progressFraction = fraction } }`. **Correct** per rule 4. Captures `[weak model]` which is important because the resolver may outlive the dialog.

**Site 4: Extraction success dispatch** (lines 318-328) — `Task.detached { ... DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.handleSuccess(...) } } }`. **Correct** per rule 4. `handleSuccess` is `@MainActor`-private and the call is on the main queue inside `assumeIsolated`. No `await`, so rule 3 doesn't apply.

**Site 5: Extraction failure dispatch** (lines 344-358) — the subject of deviation #3. The structure is:
```
DispatchQueue.main.async { [weak self, weak model] in
    MainActor.assumeIsolated {  // [1] state mutation only
        ...
        model?.errorMessage = errorDesc
    }
    Task { [weak self] in       // [2] spawned on main queue, lexically OUTSIDE assumeIsolated
        await self?.presentErrorAlert(errorDesc, on: hostWindow)
    }
}
```
The `Task { }` on line 355 is lexically OUTSIDE the `assumeIsolated` block but still inside the `DispatchQueue.main.async` closure. The `DispatchQueue.main.async` closure is `@Sendable` with no actor isolation, so the `Task { }` does not inherit main-actor isolation from lexical context. However:
- The Task body calls `await self?.presentErrorAlert(...)` — `presentErrorAlert` is `@MainActor`-isolated, so the `await` hops to the main actor via the function's isolation.
- Per MEMORY.md's rule 4, spawning a Task from the MAIN queue is acceptable (the cooperative executor will be drained because the main run loop drains it).
- The Task is NOT `Task { @MainActor in }` — it's a bare `Task { }` that resolves its actor from the first `await`. That avoids the anti-pattern directly.

**Verdict: site 5 is correct.** The implementer's refactor of deviation #3 genuinely avoids the MEMORY.md anti-pattern. The plan's original nesting (`Task { @MainActor in }` inside `assumeIsolated`) would have spawned an explicitly main-actor task from a non-isolated closure — still on the main queue, but lexically confusing. The refactor is a strict improvement.

**One lingering concern at site 5**: the `[weak self]` is captured TWICE — once in the outer `DispatchQueue.main.async { [weak self, weak model] in` and again in the inner `Task { [weak self] in`. The inner capture is redundant (the outer closure already holds `self` weakly). Not a bug but worth a cleanup in the simplification pass.

**One additional concurrency issue, not a bug but a sloppiness**: `startExtraction` spawns `Task { @MainActor [weak self] in ... }` at line 269. This is called from the dialog's `onPrimary` closure, which is a SwiftUI button action (MainActor). So the Task inherits MainActor context — not a cross-isolation spawn. The `@MainActor` annotation is redundant but harmless.

## Suggested commit message for the simplification pass

`refactor(phase-4-simplification): close bundle-clobber same-second gap + drop dead estimatingUnmappedDelta`

(Scope: collision-safe disambiguator, remove dead property, pass `errorMessage:` to `OperationCenter.fail`, early-return `present()` when host already has a sheet, wire `task.cancel()` from dialog cancel into `runInitialEstimate`. Defer Critical issue #2 to Phase 5 with explicit sign-off.)

## Simplification pass — disposition

Commit: `(pending)` on branch `feature/batch-aggregated-classifier-views`.
Build: `swift build --build-tests` clean.
Tests: `ClassifierExtractionDialogTests` 19 → 23 passing; `LungfishAppTests` no new regressions (3 failures in `FASTQProjectSimulationTests` are pre-existing on `ba07481`, confirmed via `git stash`); `LungfishCLITests` 363/363 passing.

### Critical issues

- **Critical #1 — Same-second bundle clobber. FIXED.** `ISO8601DateFormatter.shortStamp` now appends a 4-character random base36 disambiguator after the timestamp, producing 20-char strings like `20260409T144521-k7q2`. Collision probability across two rapid calls is ~6e-7 (36^4 ≈ 1.7M combinations), so two back-to-back Create-Bundle clicks within the same wall-clock second cannot silently clobber each other. Updated `testShortStamp_producesFilenameSafeFormat` to assert length 20 and to split/validate both the timestamp and random halves independently. Updated `testShortStamp_pinnedUTCDate` to assert the stamp starts with the pinned prefix `20260409T144521-` and has a valid 4-char base36 suffix (rather than full-equality, which the random suffix breaks). Added `testShortStamp_twoRapidCalls_produceDifferentStrings` which runs 8 paired calls and asserts at least one pair differs (a broken implementation would collide every time; the loop guards against the ~6e-7 fluke pair collision).

- **Critical #2 — Dropped Phase 3 forwarded item A (`ClassifierTool.expectedResultLayout`). DEFERRED to Phase 5 review #1.** Rationale: per the simplification-pass charter, Phase 1/2/3 code is off-limits. Adding the metadata requires touching either `ClassifierRowSelector.swift` (Phase 1, where `ClassifierTool` lives) or adding a shim extension in a new file plus tightening `ExtractReadsCommand.swift` pre-flight (Phase 3, off-limits). The user-visible consequence of deferral today is "degraded error message when a non-NVD user typos a path" — not data loss, not a wrong result, just a less-specific error. Phase 5 is the natural home for this work: it wires each classifier VC into the orchestrator, which is where the per-tool result-path shape contract first becomes load-bearing. Forward the item explicitly to Phase 5 review #1 with the reviewer instructed to verify `ClassifierTool.expectedResultLayout` exists and is consumed by the CLI pre-flight. No second deferral without an explicit adversarial sign-off.

### Significant issues

- **Significant #1 — `ClassifierExtractionError.cancelled` still dead on task-cancel path. DEFERRED to Phase 5/6.** Rationale: the `catch is CancellationError` branch writes `model.errorMessage = "Cancelled"` and calls `OperationCenter.fail` — UX is correct. Throwing `ClassifierExtractionError.cancelled` from the resolver's cancellation handler (instead of letting the Swift runtime's `CancellationError` bubble) would add no user-visible behavior change and is a cross-cutting concern that belongs at the resolver seam, not the orchestrator. Three other dead cases (`bamNotFound`, `kraken2OutputMissing`, `kraken2TreeMissing`) are similarly resolver-scoped and already forwarded to Phase 5/6 by review-1.

- **Significant #2 — `.share` silent failure when `sheetWindow?.contentView == nil`. FIXED.** The success branch now computes `let anchor: NSView? = sheetWindow?.contentView ?? hostWindow.contentView` and presents the sharing service picker against whichever view is available. In the extraordinarily rare case where neither is available, we log a warning via the existing `logger.warning` — the user's click is still accounted for in the log, not silently no-op'd. Replaced the "may dangle briefly" apology comment with a concise rationale comment referencing this review.

- **Significant #3 — `OperationCenter.fail` called without `errorMessage:`. FIXED.** Both call sites in `startExtraction` now pass the same string for both `detail:` and `errorMessage:`. This matches the pattern used by every other caller in the codebase (`CLIImportRunner.swift`, `FASTQIngestionService.swift`, etc.) and ensures the Operations Panel shows the prominent red error summary, not just the detail text.

- **Significant #4 — `present()` re-entrancy guard. FIXED.** Added an early return at the top of `present(context:hostWindow:)`: if `hostWindow.attachedSheet != nil`, log an info message and return. This matches AppKit's "one sheet per window" constraint and prevents double-click from creating orphaned extraction dialogs. A menu-item disable would be preferable (preventing the click in the first place) but is a separate concern — the menu lives in a Phase 5-owned controller.

- **Significant #5 — `runInitialEstimate` not cancellable. FIXED.** Introduced a `@MainActor final class TaskBox { var task: Task<Void, Never>? }` helper at the bottom of the file, created an instance in `present()`, passed it into the dialog's `onCancel` closure (weak-captured), and changed `runInitialEstimate` to return `@discardableResult -> Task<Void, Never>` so its handle can be stored. When the user dismisses the dialog via Cancel, the detached estimate task (which issues up to 2N `samtools view -c` spawns for BAM tools) is now cancelled. The `Task.detached` closure gained a `catch is CancellationError` branch that drops silently — the cancellation is expected and not an error state.

### Minor issues

- **Minor #1 — Dead `estimatingUnmappedDelta` property. FIXED.** Deleted the `var estimatingUnmappedDelta: Bool = false` line from `ClassifierExtractionDialogViewModel`. A grep confirms no references remained.

- **Minor #2 — Sharing dangle comment cleanup. FIXED.** Covered by the Significant #2 rewrite above — the "may dangle briefly" apology comment is gone, replaced with a rationale comment explaining the anchor fallback and citing this review.

- **Minor #3 — `contextCopy = context` redundant. FIXED.** Deleted the `let contextCopy = context` line in `startExtraction` and the equivalent line in `runInitialEstimate`. Both Task.detached closures now capture `context` directly, which is safe because `Context: Sendable` (deviation #7). Added a brief inline comment explaining the direct capture.

- **Minor #4 — `NSPanel` style mask is `[.titled]` only. WONTFIX (intentional).** Matches the plan. Sheets don't need `.closable` or `.resizable`; the dialog's own Cancel button and Escape key dismiss it. The reviewer flagged this as intentional in the original review body and the simplification pass agrees.

- **Minor #5 — Manual Button radio picker vs `Picker(.radioGroup)`. WONTFIX (intentional), comment added.** SwiftUI `Picker(selection:).pickerStyle(.radioGroup)` has no per-tag disable binding, and the clipboard row must be disabled when the selection exceeds `clipboardReadCap`. The manual Button+Image pattern is the pragmatic way to get per-row disable state. Added a comment block above the ForEach explaining the trade-off and citing this review, so future maintainers don't re-litigate.

### Test gaps

- **Same-second collision test. ADDED.** `testShortStamp_twoRapidCalls_produceDifferentStrings`. See Critical #1 above.

- **User-rename-to-collision branch. ADDED.** `testResolveDestination_bundle_withDefaultName_appendsTimestamp` and `testResolveDestination_bundle_withCustomName_doesNotAppendTimestamp`. Both exercise the `.bundle` branch of `resolveDestination` via a new `#if DEBUG` test-only wrapper `resolveDestinationForTesting(model:context:)` that takes a throwaway `NSWindow` (not used for `.bundle`). The wrapper is narrow — it only exposes the private `resolveDestination` method, not any orchestration state — and is feature-gated behind `#if DEBUG`.

- **`resolveDestination` translation (DialogDestination → ExtractionDestination). PARTIALLY ADDED.** The two `testResolveDestination_bundle_*` tests cover the `.bundle` branch end-to-end, which is the branch with the bundle-clobber defense logic that matters. The `.file`, `.clipboard`, and `.share` branches require mocking `SavePanelPresenting` / `FileManager.createDirectory`; deferred to Phase 6/7 along with the failure-path alert presenter mock.

- **`buildCLIString` `sampleId: nil` branch. ADDED** as an extra assertion inside `testBuildCLIString_kraken2_includesTaxon`: `XCTAssertFalse(cli.contains(" --sample "))`.

- **`buildCLIString` mixed accessions+taxIds. ADDED.** `testBuildCLIString_mixedAccessionsAndTaxons_emitsAll` pins the builder's behavior when a selector carries both kinds of identifiers — all three flag groups must be emitted regardless of tool kind.

- **`estimatedUnmappedDelta` computation. DEFERRED to Phase 6/7.** The view model's `estimatedUnmappedDelta` integer is set by the orchestrator's `runInitialEstimate`, not computed by the view model directly. Testing it requires a mock `ClassifierReadResolver` via `resolverFactory`, which is a larger integration-style change. The brief's test budget for Phase 4 was view-model tests, not mock-based orchestrator tests.

- **Failure-path alert presenter (mock `AlertPresenting`). DEFERRED to Phase 6/7.** Same rationale as above — requires a mock to drive the error path and is integration-style rather than view-model-style.

### Positive observations carried forward

All 8 deviations from the plan (Phase 4 plan lines 3657–4756) remain verified. The concurrency audit of the 5 background-to-MainActor dispatch sites is unchanged — the simplification pass only added behavior inside the existing `MainActor.assumeIsolated` blocks, did not introduce any new `Task { @MainActor in }` spawns, and the new `TaskBox` helper is strictly `@MainActor`-isolated (no cross-isolation captures). The refactored `runInitialEstimate` still uses the prescribed `Task.detached → DispatchQueue.main.async → MainActor.assumeIsolated` pattern from MEMORY.md.

### Gate summary

| Gate | Result |
| --- | --- |
| `swift build --build-tests` | Clean (19.18s) |
| `swift test --filter ClassifierExtractionDialogTests` | 23/23 passing (was 19/19) |
| `swift test --filter LungfishAppTests` | 1530 executed, 3 failures — all in `FASTQProjectSimulationTests`, confirmed pre-existing on `ba07481` via `git stash` |
| `swift test --filter LungfishCLITests` | 363/363 passing |
