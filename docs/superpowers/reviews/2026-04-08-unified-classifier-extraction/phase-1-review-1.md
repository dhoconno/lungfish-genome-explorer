# Phase 1 — Adversarial Review #1

**Date:** 2026-04-09
**Commits reviewed:** b29425a, 7c1253b, 1acf003, 5768b82
**Reviewer:** general-purpose subagent
**Charter:** Independent adversarial review before simplification pass.

## Summary

Phase 1 is in good shape overall. The value types are well-scoped and documented, the `flagFilter` parameter is threaded correctly through both samtools invocations, the deleted sheets are cleanly excised, and the build is green with 15 new Phase 1 tests passing (8 + 6 + 1) and the 18 `ReadExtractionServiceTests` regression tests still green. There are no concurrency bugs, no macOS 26 API violations, and no orphaned helper methods left in the five stubbed VCs. The `FlagFilterParameterTests` deviation is a sound compile-time fix, but it leaks a misleading name: the test only pins parameter count, position, and type — it does not actually verify the default is `0x400`. The bigger issues are cosmetic: five stale doc-comment cross-references to deleted types (`ClassifierExtractionSheet`, `TaxonomyExtractionSheet`) that will break DocC links, plus one dangling orphan comment in `EsVirituResultViewController.swift` that refers to an "extraction closure above" that no longer exists.

## Critical issues (must fix before moving on)

None. Phase 1 is structurally sound: nothing is broken, nothing silently regresses, and the 1400+ pre-existing tests remain green.

## Significant issues (should fix)

- [ ] **`FlagFilterParameterTests` name overstates what it verifies.** `Tests/LungfishWorkflowTests/Extraction/FlagFilterParameterTests.swift:20` is named `testExtractByBAMRegion_hasFlagFilterParameter_withDefault0x400`, and the doc comment on line 10 claims it "compile-check[s] ... with a default of 0x400". It does not. Taking a method reference erases default values — you always have to supply all parameters at the call site for a function-typed value. If someone changes the default to `0x500`, this test still passes. The test genuinely pins the parameter's existence, position (between `config` and `progress`), and type (`Int`), but not the default. Rename to `testExtractByBAMRegion_hasFlagFilterIntParameterInSecondPosition` and/or soften the doc comment, OR add a second test that uses a fake `NativeToolRunner` and asserts the `-F` argument is `"1024"` when `extractByBAMRegion(config:progress:)` is called without supplying `flagFilter`. Given there is no fake/mock `NativeToolRunner` infrastructure in the test targets yet and Phase 2 will build real integration tests, the pragmatic fix is the rename + doc tweak.

- [ ] **Stale doc-comment references to deleted symbols.** Five files still reference the deleted `ClassifierExtractionSheet` / `TaxonomyExtractionSheet` in `///` doc comments using DocC double-backtick symbol links (e.g. `` /// Presents a ``ClassifierExtractionSheet`` for the given selected items. ``). DocC will emit "unresolved symbol reference" warnings on these:
  - `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift:1549`
  - `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift:2675`
  - `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift:1223`
  - `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift:1223`
  - `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift:86` (class-header doc, not the method; reference is to `TaxonomyExtractionSheet`, and also to `TaxonomyExtractionPipeline` which still exists)

  Either delete the stale sentence from each doc comment or replace with a phase5 placeholder (e.g. "TODO[phase5]: update doc comment when `TaxonomyReadExtractionAction` wires this up"). Per the plan, the whole method is deleted in Phase 5 anyway, so simply deleting the stale sentence now is cheapest.

- [ ] **Dangling orphan comment in EsViritu VC.** `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift:1234-1235`:
  ```
  // BAM extraction pipeline now handled by ReadExtractionService.extractByBAMRegion()
  // called inline in the presentExtractionSheet onExtract callback above.
  ```
  The "onExtract callback above" no longer exists — it was deleted in commit 5768b82. Delete these two comment lines.

## Minor issues (nice to have)

- [ ] **`ClassifierRowSelectorTests` test count 8, plan predicted 7.** Not a real discrepancy — the plan's code listing at lines 189–246 already contained all 8 test methods (`testClassifierTool_allCasesCovered`, `_rawValuesAreStableAndLowercase`, `_usesBAMDispatch_forNonKraken2Tools`, `testSelector_initializesFields`, `_isEmpty_whenNoAccessionsOrTaxIds`, `_isNotEmpty_withAccessions`, `_isNotEmpty_withTaxIds`, `_nilSampleId_meansSingleSampleFixture`). The implementer followed the plan verbatim. The plan's Step 4 comment "PASS, 7 tests" is a prediction miscount. No change needed beyond noting it.

- [ ] **`FlagFilterParameterTests.testExtractByBAMRegion_hasFlagFilterParameter_withDefault0x400` is declared `async` but never `await`s anything.** `Tests/LungfishWorkflowTests/Extraction/FlagFilterParameterTests.swift:20`. XCTest tolerates async test methods even when no suspension point is reached, but it's a smell. Consider dropping `async`, or adding a genuine await. Micro.

- [ ] **Minor wastefulness: `ReadExtractionService().extractByBAMRegion`** allocates a throwaway actor instance just to take a bound-method reference. The allocation is harmless (test runs in microseconds) but is semantically wrong: the test is about the type, not the instance. If Swift allowed the unapplied form for actors this would be `ReadExtractionService.extractByBAMRegion` with an explicit curried signature. Since it doesn't, the current form is the minimum-impact workaround. Document why in a one-line comment for readers who wonder.

- [ ] **`ExtractionDestination` cases `.bundle` and `.share` have inconsistent parameter labeling.** `.bundle(projectRoot:displayName:metadata:)` uses labels, but `.file(URL)`, `.clipboard(format:cap:)`, `.share(tempDirectory:)` mix raw positional and labeled. Not wrong, but inconsistent. If the simplification pass touches this file, consider adding labels everywhere (e.g. `.file(url: URL)`). The spec ExtractionDestination (spec lines 62-68) uses this mixed style, so leaving as-is is defensible.

## Test gaps

Things a reasonable engineer would cover that the Phase 1 test suite does not:

- **No test that `ClassifierTool` round-trips through `Codable`** — the enum is declared `Codable` in `ClassifierRowSelector.swift:22` but nothing verifies an encode/decode cycle. Low-risk because Swift's automatic conformance is reliable for `String`-raw-valued enums, but is a structural contract worth pinning.
- **No test that `ClassifierRowSelector` is `Hashable` in practice** — it conforms to `Hashable` at line 79 but no test exercises `Set<ClassifierRowSelector>` or dictionary keying. Low-risk.
- **No test that `ExtractionOptions` is `Hashable`** — same concern.
- **No test that `ExtractionMetadata` survives being placed inside `ExtractionDestination.bundle`** — `ExtractionMetadata` is `Sendable, Codable` but NOT `Hashable`. Because `ExtractionDestination` is declared only `Sendable` and not `Hashable`, this works fine, but a future refactor that adds `Hashable` to `ExtractionDestination` will be blocked silently by metadata. Worth a FIXME comment near the case.
- **No test that `flagFilter` is actually threaded to BOTH hardcoded sites** — the test only pins the parameter on the public API. If the implementer had forgotten to replace the `"1024"` at line 287 but updated the one at line 261, the Phase 1 tests would not catch it. A reasonable test would use a captured-argument fake `NativeToolRunner` and invoke both code paths (one with `config.deduplicateReads == true` and one fallback-dedup path). This is, however, an appropriate Phase 2 gate, not Phase 1.
- **No test that the 5 stubbed VCs' `presentExtractionSheet` methods are reachable and non-crashing.** Phase 1 asserts "they compile" but not "they're called without crashing." Given they're one-line stubs that discard arguments and return, the risk of regression is zero; I would not add a test here.

## Positive observations

- **Clean commit discipline.** Four commits, each doing exactly one thing: b29425a (value types + enum), 7c1253b (destinations + options), 1acf003 (flagFilter), 5768b82 (deletion + stubs). Easy to review and easy to bisect.
- **All 5 `#warning` strings are byte-identical** (`"phase5: old extraction sheet removed; new dialog wired up in Phase 5"`) — verified via grep. The audit trail is intact.
- **`ClassifierTool.usesBAMDispatch` is correct per spec** — 4 true, 1 false, Kraken2 isolated. The spec's architecture section confirms the binary split (spec lines 127–149). Raw values match spec line 51.
- **`ExtractionOptions.samtoolsExcludeFlags` inversion is correct and well-documented.** The field name `includeUnmappedMates` reads like "add flags", but `samtoolsExcludeFlags` is a subtract mask. `false` → exclude unmapped (`0x404`); `true` → keep unmapped (`0x400`). The doc comment on `samtoolsExcludeFlags` (lines 104–112) explains the semantics cleanly and cites `MarkdupService.countReads`. Not inverse-of-expected once you read the comment, which is the relevant bar.
- **`ExtractionMetadata` is the pre-existing `LungfishWorkflow` type from `Sources/LungfishWorkflow/Extraction/ExtractionConfig.swift:260-290`**. The test instantiates it with `ExtractionMetadata(sourceDescription: "s", toolName: "t")`, using the default `extractionDate: Date()` and empty parameters — this matches the public initializer on line 281. No duplication, no new type.
- **No other hard-coded `"1024"` or `-F 1024` remains in `ReadExtractionService.swift` source.** Only comments at lines 254 and 285 reference `1024` (prose description of what the code does). The two actual argument-array positions at lines 264 and 288 both use `String(flagFilter)`. Verified via targeted grep.
- **No orphaned `Task.detached` captures from deleted method bodies.** The only `Task.detached` references in `Sources/LungfishApp/Views/Metagenomics/` after 5768b82 are: `NaoMgsResultViewController.swift:1037` (inside `loadMiniBAMsAsync`, unrelated), `MapReadsWizardSheet.swift:420` (unrelated), and a `/// comment` at `EsVirituResultViewController.swift:741`. The 3+ deleted Task.detached blocks were cleanly excised.
- **Concurrency rules obeyed.** The Phase 1 changes introduce no new actor boundary crossings, no `Task { @MainActor in }` from GCD, no `DispatchQueue.main.async` without `MainActor.assumeIsolated`, no `.runModal()`, no `lockFocus()`, no `wantsLayer = true`. The only concurrency-adjacent addition is the `flagFilter: Int` parameter, which is value-typed and Sendable-safe. `ReadExtractionService` remains `public actor`; the new call sites will interact via existing `await` surfaces in later phases.
- **SwiftUI imports in the 5 VCs are still valid.** Each modified VC still has at least one `NSHostingController(rootView:)` or `struct _: View` that justifies the `import SwiftUI`. No unused imports introduced.
- **The stub parameter-discard pattern `_ = items; _ = source; _ = suggestedName`** correctly silences unused-parameter warnings under strict concurrency builds. Documented in the plan and applied consistently.
- **Build time is cheap.** The four Phase 1 test files add 15 tests that execute in <10ms combined. Zero linker pressure.

## Suggested commit message for the simplification pass

`simplify(phase1): scrub stale doc-comment refs to deleted sheets; rename FlagFilter test to reflect what it actually checks`

The simplification pass should focus on:
1. Deleting the 5 stale `ClassifierExtractionSheet` / `TaxonomyExtractionSheet` doc-comment references.
2. Deleting the dangling `// BAM extraction pipeline now handled by...onExtract callback above` comment in `EsVirituResultViewController.swift:1234-1235`.
3. Either renaming `testExtractByBAMRegion_hasFlagFilterParameter_withDefault0x400` to honestly describe what it pins, or replacing it with a fake-tool-runner test that actually verifies the default.
4. Optionally dropping the unused `async` on the FlagFilter test function and adding a one-line comment explaining the `ReadExtractionService()` allocation.

## Simplification pass — disposition

Commit: `0aad2c6` on top of `5768b82`.

### Significant issues

- **[1] `FlagFilterParameterTests` name overstates what it verifies** — **FIXED**
  Renamed `testExtractByBAMRegion_hasFlagFilterParameter_withDefault0x400` → `testExtractByBAMRegion_hasFlagFilterIntParameterInSecondPosition`. Doc comment rewritten to explicitly state that the test pins parameter count, position, and type (`Int`), NOT the default value. Added a sentence explaining that the default-argument contract is deferred to Phase 2's resolver tests.
- **[2] Stale doc-comment references to deleted symbols (5 sites)** — **FIXED**
  - `NaoMgsResultViewController.swift:1549` — deleted the `/// Presents a ``ClassifierExtractionSheet`` …` line.
  - `TaxTriageResultViewController.swift:2675` — same.
  - `EsVirituResultViewController.swift:1223` — deleted the stale first line of the doc but preserved the "Internal visibility …" sentence so the `func`-level comment still explains why it's `internal`.
  - `NvdResultViewController.swift:1223` — same pattern as NaoMgs/TaxTriage.
  - `TaxonomyViewController.swift:86` — rewrote the `## Extraction` paragraph to drop `TaxonomyExtractionSheet` while keeping the live `TaxonomyExtractionPipeline` reference.
- **[3] Dangling orphan comment in EsViritu VC** — **FIXED**
  Deleted the two comment lines at `EsVirituResultViewController.swift:1234-1235` that referenced an "onExtract callback above" that no longer exists.

### Minor issues

- **(a) `ExtractionDestination` cases inconsistent parameter labeling** — **WONTFIX**
  The spec (lines 62–68) uses this mixed style intentionally. Review-1 itself says "leaving as-is is defensible". The rename would touch every call site in Phases 2–8 and is not worth the churn.
- **(b) Unused `async` on FlagFilter test** — **FIXED**
  Dropped `async` from the renamed test.
- **(c) `ReadExtractionService()` throwaway allocation** — **FIXED**
  Added a note in the test doc comment explaining that the allocation is a workaround for the fact that actors do not expose the unapplied curried form `(Self) -> (Args) async throws -> Result`, and that the test cares about the type not the instance.
- **(d) `ClassifierRowSelectorTests` test count 8 vs plan's predicted 7** — **WONTFIX**
  Plan prediction was a miscount; actual code matches the plan code-block verbatim. Nothing to fix.

### Test gaps

- **Codable round-trip tests for `ClassifierTool`** — **WONTFIX**
  Auto-synthesized `Codable` conformance on a `String`-raw-valued enum is reliable. Manual round-trip tests add no signal.
- **`Hashable` behavior tests for `ClassifierRowSelector` / `ExtractionOptions`** — **WONTFIX**
  Auto-synthesized conformance on value types with `Hashable` fields. Manual set/dictionary tests add no signal.
- **`ExtractionMetadata` inside `ExtractionDestination.bundle` survival** — **WONTFIX**
  `ExtractionDestination` is `Sendable` only, not `Hashable`. No future-refactor tripwire is currently needed; a FIXME in the source would add noise. If Phase 8 adds `Hashable` to `ExtractionDestination`, the compiler will fail immediately because `ExtractionMetadata` is not `Hashable` — that is the tripwire, and it is free.
- **`flagFilter` threaded to BOTH hardcoded sites** — **WONTFIX (deferred to Phase 2)**
  Review-1 explicitly says "this is an appropriate Phase 2 gate, not Phase 1". Phase 2 will introduce the fake-tool-runner infrastructure that makes this testable.
- **5 stubbed VCs' `presentExtractionSheet` reachability** — **WONTFIX**
  Review-1 explicitly says "the risk of regression is zero; I would not add a test here".

### Additional opportunities beyond review-1

- **Unused imports in the 5 stubbed VCs** — **verified none**
  The review claimed "SwiftUI imports still valid". Re-verified by grepping for `NSHostingController`, `SwiftUI`, `: View`: every modified VC has at least one `NSHostingController(rootView:)` call or SwiftUI comment that justifies `import SwiftUI`. No imports to remove.
- **Dead code in `Sources/LungfishWorkflow/Extraction/`** — **none found**
  Phase 1 was additive (new types) and surgical (one parameter added). Nothing in the Extraction/ directory became dead; nothing to absorb.
- **Duplicated doc comments on `ExtractionDestination.bundle` vs `ExtractionOutcome.bundle`** — **none found**
  The two cases have distinct doc comments: `ExtractionDestination.bundle` describes input parameters (projectRoot, displayName, metadata) while `ExtractionOutcome.bundle` describes the finished bundle URL. No duplication.
- **New files in module public API export lists** — **N/A**
  The package uses SPM's default auto-export (no custom `exports`); new `public` types are visible to downstream modules without listing. Nothing to update.

### Gate results

- `swift build --build-tests` — clean (only the expected 5 `#warning` phase5 stubs plus pre-existing unrelated warnings).
- `swift test --filter ClassifierRowSelectorTests` — 8 tests passed.
- `swift test --filter ExtractionDestinationTests` — 6 tests passed.
- `swift test --filter FlagFilterParameterTests` — 1 test passed.
- `#warning` count across the 5 VCs: still 5 (verified).
