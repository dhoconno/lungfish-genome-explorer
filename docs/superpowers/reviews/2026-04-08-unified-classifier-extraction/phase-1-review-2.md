# Phase 1 — Adversarial Review #2 (Independent)

**Date:** 2026-04-09
**Commits reviewed:** b29425a, 7c1253b, 1acf003, 5768b82, 0aad2c6, 9b2780e
**Reviewer:** fresh subagent, no prior conversation state
**Charter:** Independent adversarial review, then compare divergence with review-1.

## Summary

Phase 1 compiles cleanly and all 15 new tests pass. The value types (`ClassifierTool`,
`ClassifierRowSelector`, `ExtractionDestination`, `ExtractionOutcome`, `CopyFormat`,
`ExtractionOptions`) are small, well-documented, and conform to the types in the design spec.
The `flagFilter: Int = 0x400` parameter is threaded through both hard-coded `-F 1024` sites in
`ReadExtractionService.extractByBAMRegion`, and every pre-existing caller uses labeled arguments
so the insertion is backwards-compatible. The two SwiftUI extraction sheets are deleted and each
of the five surviving call sites is a one-line discard-stub.

There is one **significant unaddressed issue** that neither the plan text nor the simplification
pass surfaced: the Kraken2 "extract" goal auto-invokes `TaxonomyViewController.presentExtractionSheet`
from AppDelegate's pipeline-completion callback, and that path is no longer a
user-interaction-only surface — it is a programmatically-driven regression for any user who runs
Kraken2 with `goal == .extract` while Phases 1 through 4 are landed. The spec/plan asserts
"they only fire on user interaction" but misses the AppDelegate site.

Two smaller observations: `ClassifierRowSelector.isEmpty` ignores `sampleId`, which is the
correct semantic but should be pinned by a test; and `FlagFilterParameterTests` still builds a
throwaway actor instance to bind the method reference, which is fine but the reason should be
comment-documented in-line for readers who wonder why the test allocates.

Phase 1 is **functionally green and ready to close** provided the AppDelegate silent-regression is
acknowledged and either tracked as a known Phase-1-through-4 behavioral gap or repaired with a
Phase 1.5 follow-up alert. Everything else is cosmetic or deferred to later phases.

## Critical issues (must fix before moving on)

None. Phase 1 has no compile breaks, no test regressions, no spec violations in the value types,
and no macOS 26 concurrency violations.

## Significant issues (should fix, or explicitly acknowledge)

### 1. AppDelegate auto-extract flow silently no-ops

`Sources/LungfishApp/App/AppDelegate.swift:5301-5306`:

```
if capturedConfig.goal == .extract,
   let taxonomyVC = viewerController.taxonomyViewController {
    if let topSpecies = result.tree.dominantSpecies {
        taxonomyVC.presentExtractionSheet(for: topSpecies, includeChildren: true)
    }
}
```

This runs **automatically** at the end of a Kraken2 classification run when the user
selected `ClassificationConfig.Goal.extract`. It is *not* "only fired on user interaction" —
it is an automated consequence of the classify-then-extract workflow. After 5768b82
`presentExtractionSheet(for:includeChildren:)` in `TaxonomyViewController` is now a no-op
that discards both arguments and returns, so a user who picks the "extract" goal will see
classification complete, the taxonomy browser appear, and *nothing* happen where the
extraction dialog used to appear. There is no alert, no log line, no error — silent failure.

The risk is bounded (`goal == .extract` is not the default — `classify` is), but it *is*
exactly the "silent regression" class the gate architecture was built to prevent.

**Suggested resolution:** either

1. Add a tracking note in the plan that during Phases 1 through 4 the `.extract` goal
   degrades to "classify only" (zero-line change; just updates the audit trail), or
2. Land a one-paragraph toast/alert in the stub body that says
   "Extraction UI is being rewritten — use the context menu on the taxonomy table once the
   classification loads" so the user is never silently blocked, or
3. In Phase 5's commit, add a regression test that exercises this pathway end-to-end (it is
   not in the Phase 5 test list in the plan as written).

Option 1 is the cheapest and fits the "Phase 1 adds no behavior" charter.

### 2. `ClassifierRowSelector.isEmpty` semantics unchecked when only `sampleId` is set

The implementation is:

```swift
public var isEmpty: Bool {
    accessions.isEmpty && taxIds.isEmpty
}
```

A selector `ClassifierRowSelector(sampleId: "S1", accessions: [], taxIds: [])` reports
`isEmpty == true`. This is probably the intended semantic ("no extraction targets — skip"),
but it is asymmetric with a spec reading where `sampleId` alone might mean "all reads from
that sample" (e.g. the user picked a whole sample row in the batch table). The spec is
silent, but `extractViaBAM` in the Phase 2 design fetches the BAM for the sample and runs
`samtools view` *with* the regions — if there are no regions, the CLI/GUI contract of "cannot
extract all reads for a sample" would need to be explicit.

**Suggested resolution:** add a test today that pins the current semantic
(`isEmpty == true` when only `sampleId` is set) so Phase 2's resolver cannot drift. One line
of code, three-line test:

```swift
func testSelector_isEmpty_whenOnlySampleIdIsSet() {
    let sel = ClassifierRowSelector(sampleId: "S1", accessions: [], taxIds: [])
    XCTAssertTrue(sel.isEmpty)  // sampleId without targets is treated as empty
}
```

This is cheap insurance for a semantic the reviewer had to infer from code.

### 3. `testClassifierTool_usesBAMDispatch_forNonKraken2Tools` does not cover all 5 tools' `displayName`

`ClassifierRowSelectorTests` exercises `allCases`, `rawValue`, and `usesBAMDispatch`, but
`displayName` — which is user-facing text — has no test. A silent rename from `"NAO-MGS"` to
`"Nao-Mgs"` or dropping a hyphen would not be caught. Trivial to add:

```swift
func testClassifierTool_displayNames() {
    XCTAssertEqual(ClassifierTool.esviritu.displayName, "EsViritu")
    XCTAssertEqual(ClassifierTool.taxtriage.displayName, "TaxTriage")
    XCTAssertEqual(ClassifierTool.kraken2.displayName, "Kraken2")
    XCTAssertEqual(ClassifierTool.naomgs.displayName, "NAO-MGS")
    XCTAssertEqual(ClassifierTool.nvd.displayName, "NVD")
}
```

## Minor issues (nice to have)

### (a) `ExtractionDestination` is `Sendable` but not `Hashable`

`ExtractionDestination`'s `.bundle` case carries `ExtractionMetadata`, which is `Codable` but
not `Hashable`, so the enum cannot synthesize `Hashable`. This is fine today (no one
hashes destinations), but a reader might wonder why `ExtractionOptions` and
`ClassifierRowSelector` *are* `Hashable` while `ExtractionDestination` is not. A one-line
doc comment on the enum stating "not Hashable because `ExtractionMetadata` is not Hashable"
would answer the question up front.

### (b) `ExtractionOutcome.clipboard` drops the extracted string payload

The spec says: *"the actual string is returned in the out-parameter payload."* The current
`.clipboard(byteCount: Int, readCount: Int)` has no string field, only a count. Phase 2 will
have to either add a String to this case or thread the string through a separate return path.
Not an error — the enum is a Phase 1 scaffold — but worth a `// TODO[phase2]` comment now so
the drift is tracked.

### (c) `FlagFilterParameterTests` instance allocation not explained inline

The test comment (lines 21–27) explains *why* the allocation happens in a paragraph above the
function, but the actual line

```swift
let method: ...
    = ReadExtractionService().extractByBAMRegion
```

has no inline comment, and a grep-oriented reader could miss the rationale. A trailing
`// throwaway instance, see doc-comment` would cost nothing.

### (d) `_ = items; _ = source; _ = suggestedName` suppression is noisy

Strict-concurrency builds are the reason, but three discards on one line look like dead code
to future readers. Swift supports the cleaner `_ items: [String], _ source: String,
_ suggestedName: String` parameter-label form *if* the method signature is internal-only.
For the four private `presentExtractionSheet` methods this would work; for the two public
ones (`EsVirituResultViewController` internal, `TaxonomyViewController` public) it would
break ABI. Skip for public — the discards are deliberate. For private stubs, the anonymous-
parameter form is shorter:

```swift
private func presentExtractionSheet(items _: [String], source _: String, suggestedName _: String) {
    #warning("phase5: old extraction sheet removed; new dialog wired up in Phase 5")
}
```

Micro-aesthetic. Safe to ignore.

### (e) Enum raw values are all-lowercase tokens but the spec has them lowercase-only once

Spec line 51 says `case esviritu, taxtriage, kraken2, naomgs, nvd`, and the code matches.
No issue. Just noting the spec is tight enough that the implementer could not drift.

### (f) No test round-trips `Codable`

`ClassifierTool` and `CopyFormat` both declare `Codable`, but no test encodes and decodes
them. Swift's automatic conformance is reliable for `String`-raw-valued enums, so the risk
is tiny, but pinning the raw-value contract through JSON would catch any future reorder /
rename. Three lines, zero cost.

### (g) `ExtractionDestination` `case clipboard(format: CopyFormat, cap: Int)` allows invalid states

`ExtractionDestination.clipboard(format: .fasta, cap: -1)` compiles. The `cap` is used as a
loop bound in the eventual resolver, and a negative cap would either skip all output or
trap. Phase 2's resolver can clamp, but a pre-condition on the case (via a factory method
that clamps to `max(0, cap)`) would be safer. Deferred to Phase 2 — the value type today has
no construction validation anywhere, and adding it mid-Phase-1 is out of scope.

## Test gaps

In addition to the suggestions in Significant items 2 and 3 and Minor (f):

- **`ExtractionDestination`'s `.share(tempDirectory:)` case is never pattern-matched in a test.**
  The test file exercises `.file` and `.bundle` in `testDestination_fileCase_isDistinctFromBundle`,
  but not `.share` or `.clipboard`. A four-line test ensuring pattern-match coverage on all four
  cases would pin the case shape against accidental reorder.

- **No test verifies the `flagFilter` parameter threads to BOTH hardcoded sites.** The only
  test is a compile-time signature pin. If the implementer had updated line 264 (`dedupViewResult`)
  and forgotten line 288 (`viewArgs.append`), the Phase 1 tests would pass silently. Phase 2's
  resolver tests will cover this, but a Phase 1 integration test with a fake
  `NativeToolRunner` that captures argument vectors and asserts `-F` appears with the expected
  string is the strongest regression guard. Given the project's integration-test tradition is
  "real samtools" not "mock", the mock infra would be new — defer to Phase 2, agreed.

- **No test verifies `FlagFilterParameterTests` fails if the `flagFilter` parameter is
  removed.** The test *should* fail at compile time (that's the whole point), but the way
  Swift handles missing defaults for function-typed assignments can sometimes allow a "zero
  parameter position" rewrite to type-check if the reviewer doesn't watch carefully. Not a
  real concern — Swift's type checker is tight here — but a comment like
  `// If the parameter is removed, the right-hand side is (Config, Progress?) and the
  three-tuple LHS won't match.` would make the contract more explicit.

## Positive observations

1. **Commit discipline is exemplary.** Six commits, each atomic: value-type enum,
   destinations + options, `flagFilter` parameter, deletion + stubs, simplification, and
   the sha-resolution addendum. `git bisect` works.

2. **All 5 `#warning` strings are byte-identical.** Verified via the counting grep above.
   Phase 5 can do a single `sed -i '' '/phase5: old extraction sheet removed/d'` to sweep them.

3. **`ClassifierTool.usesBAMDispatch` is a clean binary split.** 4 true, 1 false, no
   ambiguity. This matches the spec's architecture section exactly. Kraken2 is correctly
   isolated because Kraken2's extraction backend is `TaxonomyExtractionPipeline`, which reads
   `classified.fastq` + `kraken2_output.txt`, not a BAM.

4. **`ExtractionOptions.samtoolsExcludeFlags` correctly implements the inverse-semantic
   knob.** `includeUnmappedMates == true` → exclude duplicates only (`0x400`);
   `includeUnmappedMates == false` → exclude duplicates AND unmapped (`0x404`). The
   15-line doc comment (lines 103–112) makes the "inverted feel" legible on first read.

5. **Every pre-existing `extractByBAMRegion` caller uses labeled arguments.** Verified by
   grep across `Sources/` and `Tests/`: 10 call sites total (`CLI ExtractReadsCommand`,
   `ViewerViewController+EsViritu`, 8 in `ReadExtractionServiceTests`), all labeled.
   Inserting `flagFilter` between `config:` and `progress:` is fully backwards-compatible.

6. **The `.bgz` infinite-loop gotcha from MEMORY.md is not touched.** Phase 1 changes no
   reader code, no stream code, no rendering code, and no `DispatchQueue.main.async` or
   `Task.detached` patterns. The blast radius is surgically small.

7. **Concurrency rules obeyed.** No `Task { @MainActor in }` from GCD, no
   `DispatchQueue.main.async` bare main-actor access, no `runModal`, no `lockFocus`,
   no `wantsLayer = true`, no `UserDefaults.synchronize()`. The only concurrency-adjacent
   change is adding `flagFilter: Int` which is value-typed and `Sendable`-safe.

8. **Dead-code scrub is thorough.** After simplification pass commit 0aad2c6, five stale
   `///` doc-comment references to `ClassifierExtractionSheet`/`TaxonomyExtractionSheet`
   are removed and one orphan comment in `EsVirituResultViewController.swift` is deleted.
   Zero references remain in `Sources/`.

9. **`ExtractionMetadata` reuse is correct.** The test file uses the pre-existing
   `ExtractionMetadata` from `Sources/LungfishWorkflow/Extraction/ExtractionConfig.swift:260`
   with the public initializer `ExtractionMetadata(sourceDescription:toolName:)` that
   defaults `extractionDate` and `parameters`. No duplication, no new type introduced.

10. **The test-compile-pin pattern for `flagFilter` is the correct Swift-6 idiom.** Actors
    do not allow the unapplied-method-reference curried form that classes do, so binding
    against a throwaway instance is the minimum-impact workaround. The post-simplification
    doc comment (FlagFilterParameterTests.swift lines 21–27) explains the constraint cleanly.

11. **Phase 1's "no behavior" charter is honored.** Zero runtime behavior change for any
    existing user of `extractByBAMRegion` (default `flagFilter` stays `0x400`). The only
    user-visible change is the five stubbed classifier VC methods becoming no-ops — which is
    a regression the plan deliberately accepted for the five-phase refactor.

12. **Build + test: 15 tests, all green, runs in under 10 ms.** Zero linker cost, zero CI
    time cost.

## Verdict

Phase 1 is **structurally sound and functionally correct.** The value types match the spec,
the `flagFilter` parameter is threaded correctly, and the deletion of the old sheets is clean.
The one meaningful finding — the AppDelegate silent regression on the Kraken2 `goal == .extract`
path — is a known consequence of the "stub for five phases" strategy but was not explicitly
acknowledged in the plan. The spec's "they only fire on user interaction" line is inaccurate
for that AppDelegate call site.

**Recommendation:** Close the Phase 1 gate *after* adding a one-line acknowledgement of the
`goal == .extract` degradation in either the plan or the disposition file. Everything else in
this review is a minor nit or a test-gap deferred to a later phase.

## Divergence from review-1

Note on methodology: during a `git show 0aad2c6` to read the simplification-pass diff, the
review-1 file was included in the diff (it was newly added in that commit). I had already
formed the "AppDelegate silent regression" finding before reading review-1 — it came from an
earlier grep for `presentExtractionSheet` call sites across `Sources/` — so the divergence
comparison is preserved.

**Issues I found that review-1 missed:**

- **AppDelegate.swift:5301 auto-extract silent regression.** Review-1 explicitly states
  "the 5 stubbed VCs' `presentExtractionSheet` methods are reachable and non-crashing. Phase 1
  asserts 'they compile' but not 'they're called without crashing.' Given they're one-line
  stubs that discard arguments and return, the risk of regression is zero; I would not add a
  test here." This misses that `AppDelegate.swift:5305` invokes
  `taxonomyVC.presentExtractionSheet(for: topSpecies, includeChildren: true)` **automatically**
  when the user's classification `goal == .extract`. That is not user-interaction; it is a
  programmatic post-classification step, and it silently no-ops during phases 1 through 4.
  Review-1 reasoned "zero risk" from the premise that the stubs are only menu-triggered, which
  is correct for 4 of the 5 stub sites but wrong for `TaxonomyViewController`.

- **`ClassifierRowSelector.isEmpty` semantics when only `sampleId` is set** is not pinned by
  any test and the asymmetry is not noted anywhere. Review-1 flagged Codable/Hashable round-trip
  test gaps but did not flag this specific semantic ambiguity.

- **`displayName` has no test.** Review-1 does not mention `displayName` at all; it is
  user-facing text with no regression guard.

- **`ExtractionOutcome.clipboard` drops the spec's string payload.** Review-1 does not call
  out this spec-vs-code discrepancy. It is deferred to Phase 2 but worth a TODO now.

**Issues review-1 found that I did not:**

- **Stale doc-comment references to deleted types** (5 files). These were *already resolved*
  by the simplification pass commit 0aad2c6, so by the time I read the code they were gone.
  Review-1 caught them when they existed. No drift.

- **Orphan comment in `EsVirituResultViewController.swift`** about "extraction closure above."
  Also resolved in 0aad2c6. Not in the tree I reviewed.

- **Test name overstates verification scope** (`testExtractByBAMRegion_hasFlagFilterParameter_withDefault0x400`).
  Resolved in 0aad2c6 by rename to
  `testExtractByBAMRegion_hasFlagFilterIntParameterInSecondPosition`. Not in the tree I
  reviewed.

- **Test count off-by-one in plan prose** (plan predicted 7, actual 8). Review-1 caught this
  as a plan-prose nit; I confirmed the same ratio but did not flag the plan prose.

- **Inconsistent `ExtractionDestination` parameter labeling** (mix of labeled and positional).
  Fair observation; I classified this as minor style and the spec itself is mixed, so I
  did not raise it as a separate item.

- **Minor concern about `async` declaration on a test that doesn't suspend.** Also resolved
  in 0aad2c6 by dropping `async`. Not in the tree I reviewed.

**Verdict:**

- **Phase 1 is ready to close** *provided* the AppDelegate `goal == .extract` silent-regression
  is acknowledged in either the plan body or the disposition file. Adding a one-line note that
  "during Phases 1 through 4, Kraken2 with goal == .extract degrades to classify-only
  behavior; the auto-extract dialog is restored in Phase 5" is sufficient. If the team prefers
  a code-side guard, a two-line toast in `TaxonomyViewController.presentExtractionSheet` body
  saying "Extraction UI is being rewritten — use the context menu" would eliminate the silent-
  failure risk entirely.

- The remaining items (`ClassifierRowSelector.isEmpty` semantic test, `displayName` test,
  `ExtractionOutcome.clipboard` TODO, the Codable round-trip, the four-case
  `ExtractionDestination` match test) are test-gap follow-ups that could either be added
  now (~15 lines) or deferred to Phase 2. All are low-risk.

- Everything else from review-1 has been cleanly addressed by commit 0aad2c6. No new issues
  introduced by the simplification pass. `#warning` stub count is still 5. Tests still 15
  green. Build still clean.

**Not ready if the AppDelegate regression is considered a blocker.** Ready with one-line
acknowledgement if it is not.

## Gate-3 disposition (controller's resolution)

**Verdict:** Phase 1 is **closed and ready to advance to Phase 2** with the
following resolutions, all landed in commit `4b0914a`:

### Significant issue 1 — AppDelegate auto-extract silent regression — ACKNOWLEDGED

The `AppDelegate.swift:5301-5307` programmatic call to
`taxonomyVC.presentExtractionSheet(for: topSpecies, includeChildren: true)`
will silently no-op for users who run Kraken2 with `goal == .extract` during
Phases 1 through 4. This is accepted as a known temporary behavioural gap for
the following reasons:

1. The Kraken2 `goal == .extract` flow is opt-in; the default is `classify`.
2. The plan's stub strategy was deliberately accepted at Phase 1 design time.
3. Adding a code-side toast would introduce behaviour to a phase that is
   explicitly behaviour-free, raising the risk of an Adversarial Review #1
   finding in a later phase that we then have to undo.

**Forwarded to Phase 5:** Phase 5's adversarial review #1 must explicitly
verify that the new `TaxonomyReadExtractionAction.shared.present(...)` flow
restores this auto-extract path. The plan at line 5497 already calls for
deleting any `AppDelegate.swift` caller of the old method, so Phase 5 has two
options: either (a) replace `taxonomyVC.presentExtractionSheet(for:includeChildren:)`
with a call to `TaxonomyReadExtractionAction.shared.present(...)`, or (b)
delete the whole AppDelegate block if the new context-menu flow is the only
intended entry point. Either way, Phase 5's review #1 must explicitly
confirm that running Kraken2 with `goal == .extract` produces a visible
extraction surface for the user. If neither happens, the auto-extract feature
is silently lost from the GUI.

### Significant issue 2 — `ClassifierRowSelector.isEmpty` only-sampleId semantic — FIXED

Added `testSelector_isEmpty_whenOnlySampleIdIsSet` in
`Tests/LungfishWorkflowTests/Extraction/ClassifierRowSelectorTests.swift`
that pins the current asymmetric semantic (`isEmpty == true` when `sampleId`
is set but `accessions` and `taxIds` are both empty). The test's doc comment
explains that this means "skip" rather than "all reads from this sample" and
that any future change requires a deliberate spec update.

### Significant issue 3 — `ClassifierTool.displayName` has no test — FIXED

Added `testClassifierTool_displayNames` to the same file pinning all five
display strings. A silent rename of any user-facing label is now caught at
test time.

### Minor issues — DEFERRED OR WONTFIX

- **(a)** `ExtractionDestination` non-Hashable doc — deferred to Phase 2 (the
  reason will become more concrete once the resolver actually consumes the type).
- **(b)** `ExtractionOutcome.clipboard` missing string payload — deferred to
  Phase 2 where the dialog will populate it. Worth a TODO at the time.
- **(c)** Inline comment on `ReadExtractionService()` allocation in
  `FlagFilterParameterTests.swift` — wontfix; the existing paragraph above
  the function (lines 21–27 after simplification) explains it adequately.
- **(d)** `_ = items; _ = source; _ = suggestedName` discard noisiness — wontfix;
  changing the parameter form would require a Phase 5 reversal.
- **(e)** Spec/raw-value note — no action required (already correct).
- **(f)** Codable round-trip tests — wontfix; auto-synthesized conformances
  for String-raw-valued enums add no signal.
- **(g)** `ExtractionDestination.clipboard(cap: -1)` no validation — deferred
  to Phase 2's resolver, which can clamp.

### Test gaps — DEFERRED

- `.share` and `.clipboard` pattern-match tests — deferred to Phase 2 where
  the resolver will exercise these paths.
- `flagFilter` integration test against both hardcoded sites — deferred to
  Phase 2's resolver tests (review #2 itself agrees this is a Phase 2 gate).
- "FlagFilterParameterTests fails if parameter is removed" comment — wontfix;
  the test name and doc comment are honest enough.

### New test count

`ClassifierRowSelectorTests` grows from 8 to 10. Total Phase 1 test count:
17 (10 + 6 + 1). Build clean. Floor unchanged.

## Gate 4 — build + test gate

Run at commit `4b0914a` (review #2 closure + 2 new selector tests).

- **Build:** `swift build --build-tests` — clean. Only pre-existing
  swift-protobuf / grpc-swift plugin warnings and the unhandled-resource
  Assets.xcassets warning, all unrelated to this work.
- **swift-testing:** 189 tests in 36 suites — all passing.
- **XCTest:** 6294 tests, 25 skipped, 8 assertion errors across 5 unique
  failing test methods. New total = 6277 baseline + 17 Phase 1 tests = 6294 ✓
- **Floor compared to Phase 0 baseline (README):**
    - `FASTQProjectSimulationTests.testSimulatedProjectVirtualOperationsCreateConsistentChildBundles` — same (3 assertion errors)
    - `NativeToolRunnerTests.testValidateToolsInstallation` — same (2 assertion errors, missing deacon)
    - `TaxonNodeRegressionTests.testEquatable` — same (1 error)
    - `TaxonNodeRegressionTests.testHashable` — same (1 error)
    - `DatabaseServiceIntegrationTests.testSRASearch` — flaky NCBI test (1 error). Per the Phase 0 README, NCBI/SRA network tests are NOT counted as the floor — they flicker red across runs based on external service state.

No new regressions caused by Phase 1 work. Gate 4 PASSES.

## Phase 1 close — summary for the audit trail

- 6 implementation commits (`b29425a`, `7c1253b`, `1acf003`, `5768b82`, `0aad2c6`, `9b2780e`).
- 1 review-#1 + simplification round (commit `0aad2c6`).
- 1 review-#2 + selector regression tests (commit `4b0914a`).
- Net new tests: 17 (10 ClassifierRowSelector + 6 ExtractionDestination + 1 FlagFilter).
- Net new source: 2 files (ClassifierRowSelector.swift, ExtractionDestination.swift).
- Net deletions: 2 files (TaxonomyExtractionSheet.swift, ClassifierExtractionSheet.swift).
- 5 stub bodies in 5 view controllers, each emitting `#warning("phase5: old extraction sheet removed; new dialog wired up in Phase 5")`. To be cleared in Phase 5.
- Known temporary behavioural gap: Kraken2 with `goal == .extract` silently no-ops the auto-extract dialog during Phases 1–4 (AppDelegate.swift:5301-5307). Forwarded to Phase 5 review #1.

**Phase 1 is closed. Phase 2 may begin.**
