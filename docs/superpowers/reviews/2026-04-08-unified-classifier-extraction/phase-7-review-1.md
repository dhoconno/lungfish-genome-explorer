# Phase 7 — Adversarial Review #1

**Date:** 2026-04-09
**Commits reviewed:** c20e4be, 9ef8314, 61bf4db
**Reviewer:** general-purpose subagent
**Charter:** Independent adversarial review before simplification pass.

## Summary

Phase 7 lands three pieces of test coverage: a multi-sample fixture helper, a
VC → orchestrator menu-wiring test with a `testingCaptureOnly` hook, and a
CLI round-trip suite that exercises `--by-classifier` across 5 flag combinations.
The work is structurally sound and the deviations all match the review prompt,
but the CLI-coverage matrix is noticeably thin and the most important regression
guard in the suite (`testCLI_bundle_lands_in_project_root`) does not actually
guard against the original EsViritu bundle-in-`.tmp/` bug. The menu-wiring test
leaves three of the five classifier tools uncovered by live I3-style tests, and
Phase 6 invariants do *not* backfill that coverage for TaxTriage / NAO-MGS / NVD
in the way the commit message claims.

## Critical issues

### C1. `testCLI_bundle_lands_in_project_root` doesn't guard against the bug it's named for

`Tests/LungfishAppTests/ClassifierCLIRoundTripTests.swift:99-136` is called out
in the plan (line 6933) as "regression guard for the EsViritu .tmp/ bug the
whole feature is motivated by", but the assertion at lines 127-135 only checks
that **at least one** `.lungfishfastq` exists **anywhere** under `projectRoot`:

```swift
let bundles = (enumerator?.compactMap { $0 as? URL } ?? [])
    .filter { $0.pathExtension == "lungfishfastq" }
XCTAssertFalse(bundles.isEmpty, ...)
```

Because `buildFixture` creates `.lungfish/` inside `projectRoot` (as the
project-root marker directory) and `resolveDestination` in the `.share` branch
writes to `projectRoot.appendingPathComponent(".lungfish/.tmp")`, a regression
that put the bundle inside `projectRoot/.lungfish/.tmp/foo.lungfishfastq` would
**still satisfy the assertion**. `FileManager.enumerator` walks the full tree,
so `.tmp/` descendants count.

**Fix**: either assert every bundle URL's path does NOT contain `"/.tmp/"` or
`"/.lungfish/"`, or assert the bundle sits directly at `projectRoot/<name>.lungfishfastq`.
The test would then actually bite the EsViritu bug if it recurred.

## Significant issues

### S1. CLI flag-matrix coverage is much thinner than the plan asks for

Plan Task 7.3 says "every flag combination in the spec's CLI section". The 5
tests cover single-file/multi-sample/bundle/`--read-format`/kraken2 `--taxon`
but **miss**:

- **`--include-unmapped-mates`** — the flag exists in
  `ExtractReadsCommand.swift:164` and is exercised by the GUI path; no CLI
  test drives the Phase 5 I4-strict-teeth fixture through the CLI with this
  flag set. The markers BAM was built specifically so this flag's value
  matters (`testI5` checks it at the resolver level, not through the CLI).
- **`--exclude-unmapped` on `--by-region`** — declared at
  `ExtractReadsCommand.swift:169` but only `--by-classifier` is tested here.
  Phase 6 does not exercise `--by-region` either.
- **TaxTriage and NAO-MGS round-trips** — only `esviritu`, `nvd`, and
  `kraken2` appear by name in the suite. `assertI7` at
  `ClassifierExtractionInvariantTests.swift:568-574` does cover them, but only
  single-sample; the CLI-specific suite should at minimum include a one-line
  smoke test per tool to catch regressions in per-tool dispatch paths.
- **Combined `--bundle --read-format fasta`** — only bundle+fastq and
  file+fasta are tested; the fasta-bundle combination is untested.
- **`--include-unmapped-mates` rejected for kraken2** — `validate()` at
  `ExtractReadsCommand.swift:267` throws on this combo. No test pins this
  rejection.

None of these are blockers on their own, but Phase 7's charter is exactly
"catches failures the invariants miss (per-flag-combo CLI behavior)" — a
5-test suite that misses 5 flag combinations undersells the phase goal.

### S2. I3 click-wiring is NOT covered for TaxTriage / NAO-MGS / NVD

The commit message on 9ef8314 claims "other three tools [...] are covered by
Phase 6 source-level I1 tests plus manual smoke testing", and the test file's
own docstring repeats this. That is only half true: Phase 6 I1 tests at
`ClassifierExtractionInvariantTests.swift:62-102` are **string-grep tests**
on the VC source files — they check that `"Extract Reads…"` and
`#selector(contextExtractFASTQ...)` appear in source, but they do not exercise
the orchestrator callback from a table-view click. I3 tests
(`testI3_clickWiring_*`) only exist for esviritu and kraken2
(`ClassifierExtractionInvariantTests.swift:136-150`).

So for TaxTriage / NAO-MGS / NVD:
- I1 verifies the menu item text exists in source (easy to fool with a comment).
- I4/I7 verify the resolver's extraction correctness.
- **Nothing** verifies that clicking the menu item reaches the orchestrator
  with a properly-built `Context`.

The review-prompt rationale ("similar wiring patterns that Phase 6 invariants
already exercise at the table-view level") isn't quite right — the three
VC-owned tables don't live in the two table view classes Phase 6 I3 covers,
so their click path is literally untested end-to-end. This is the exact gap
that would let a refactor accidentally drop a `#selector` binding and pass
every test in the suite.

**Recommendation**: either (a) add source-level click-wiring tests by
instantiating the VCs in isolation with a stub data source (the hard path,
requires mocking the app window), or (b) explicitly document that I3-live
coverage for these three tools is deliberately deferred and list the assertions
that would catch the regression instead. Silently claiming Phase 6 covers it
is misleading.

### S3. Multi-sample test has no count verification

`testCLI_multiSample_byClassifier_concatenates` at line 61 only asserts the
output is non-empty. The plan's stated goal is "multi-sample concatenation",
which means the interesting assertion is "output contains records from both
samples" or "record count is the expected 2× single-sample count". The
comment at lines 88-91 acknowledges this gap and defers to Phase 6 I7, but
**I7 is single-sample** (`assertI7` builds via `buildFixture`, not
`buildMultiSampleFixture`, and only calls `defaultSelection` for one sample).
Nothing in the whole test suite currently verifies the multi-sample 2× factor.

Cheapest fix: assert the count of `@` records (or `>` records for fasta) is
≥ `2 * singleSampleRecordCount`, OR call back into
`ClassifierExtractionFixtures.buildFixture(tool: .nvd, sampleId: "single")`
and compare output sizes.

## Minor issues

### M1. `tearDown` idempotency — good, but there's a subtle hazard

`ClassifierExtractionMenuWiringTests.swift:37-41` resets
`testingCaptureOnly = false` and the capture struct on every tearDown. XCTest
runs tearDown even on test failure (but not if `setUp` itself throws, which
this one doesn't), so the pattern is sound. **However**: if another unrelated
XCTestCase in the same test process sets `testingCaptureOnly = true` for its
own reasons and forgets to clear it in tearDown, subsequent tests in this
class will observe stale state between `setUp` and the first assertion. Not
a bug today (only one test class uses the hook), but worth a one-line
comment at the hook declaration in
`TaxonomyReadExtractionAction.swift:703-707` warning future users to always
clear it in tearDown.

### M2. `testingCaptureOnly` hook placement — correct

The hook at
`TaxonomyReadExtractionAction.swift:170-182` correctly sits BEFORE the
re-entrancy guard at line 188. Verified by reading the modified `present()`:
the `#if DEBUG if testingCaptureOnly {...return}` block is the first statement
inside the method, so a lingering attached sheet from a prior test (which
would cause the re-entrancy guard to drop the call) doesn't prevent the
capture. Matches the probe's expectation.

### M3. `buildMultiSampleFixture` — uses the markers BAM

Confirmed: lines 156-194 of `ClassifierExtractionFixtures.swift` copy
`sarscov2BAM` (which is defined at lines 53-54 as the `.markers.bam` variant)
for every sample, so the multi-sample path also exercises the I4-teeth
fixture. Good consistency with `buildFixture`.

### M4. Kraken2 skip diagnostic — inherited, not a new bug

The skip message "Kraken2 source FASTQ could not be located" originates
from `ClassifierExtractionError.kraken2SourceMissing` at
`ClassifierReadResolver.swift:810`. This is the same Phase 2 review-2
forwarded fixture-incomplete state; Phase 7 propagates it unchanged via the
`catch error {throw XCTSkip(...)}` block at
`ClassifierCLIRoundTripTests.swift:215-219`. Not a regression.

### M5. `@testable import LungfishCLI` dependency

`Package.swift:177` declares `LungfishAppTests.dependencies = ["LungfishApp", "LungfishCLI"]`.
The `Lungfish` executable (`Package.swift:182-191`) only depends on
`LungfishApp`, so pulling `LungfishCLI` into the test target does not leak
into production binaries. The `@testable import LungfishCLI` at
`ClassifierCLIRoundTripTests.swift:7` compiles against the existing dependency
added in Phase 6. No issue.

### M6. `testingRawArgs` is `#if DEBUG` — compiles in test builds

`ExtractReadsCommand.swift:193-197` wraps `testingRawArgs` in `#if DEBUG`.
SPM defaults to Debug for `swift test`, so the new round-trip tests compile
cleanly. A Release-configured test run (`swift test -c release`) would fail
to compile. Not a Phase 7 regression — this hook was added earlier — but
worth noting if anyone adds a release-mode CI job.

### M7. `testAllTools_menuLabelIsExtractReads` is duplicative of Phase 6 I1

The new test at lines 120-143 checks that both `ViralDetectionTableView`
and `TaxonomyTableView` have the "Extract Reads…" menu item. Phase 6 I1 at
`ClassifierExtractionInvariantTests.swift:40-54` already asserts the same
thing via `testingContextMenu.items.contains(...)`. The docstring at line
121-125 justifies the duplication as "fails together when the label drifts",
which is fine but leans toward the simplification-pass target. Consider
collapsing.

## Test gaps

1. No CLI test for `--include-unmapped-mates` (Significant S1).
2. No CLI test for `--exclude-unmapped` on `--by-region` (Significant S1).
3. No CLI smoke test for `taxtriage` or `naomgs` specifically (Significant S1).
4. No CLI test that pins the kraken2 + `--include-unmapped-mates` validation
   rejection (`ExtractReadsCommand.swift:267`).
5. No multi-sample record count assertion (Significant S3).
6. No test that a bundle destination lands **outside** `.lungfish/.tmp`
   (Critical C1).
7. No I3 click-wiring for TaxTriage / NAO-MGS / NVD (Significant S2).
8. `testAllTools_menuLabelIsExtractReads` is redundant with Phase 6 I1 (M7).

## Verification of the 5 deviations

1. **`--format` → `--read-format`** — verified in
   `ExtractReadsCommand.swift:157-162` (comment explains the collision with
   `GlobalOptions.outputFormat`). Used consistently in
   `testCLI_readFormat_fasta_header_convertsCorrectly` at line 161.
   **Correct.**

2. **Kraken2 XCTSkip handling** — verified: the test at
   `ClassifierCLIRoundTripTests.swift:189-220` wraps both the
   `ClassificationResult.load` call and the `cmd.run()` call in do/catch +
   XCTSkip. The skip diagnostic "Kraken2 source FASTQ could not be located"
   matches the real error message at
   `ClassifierReadResolver.swift:810`. **Correct.**

3. **`testingContextMenu` property (not method)** — verified at
   `TaxonomyTableView.swift:947` and
   `ViralDetectionTableView.swift:1320`. The menu-wiring test reads it as a
   property: `viralTable.testingContextMenu` (not `viralTable.testingContextMenu()`).
   **Correct.**

4. **`singleArgv` dead line removed** — verified: the multi-sample test at
   lines 61-95 has no orphan `let singleArgv = ...` line. **Correct.**

5. **Test renamed `testCLI_format_fasta` → `testCLI_readFormat_fasta`** —
   verified at line 140. The test name matches the actual CLI flag being
   tested. **Correct.**

All five deviations are applied as described in the review prompt.

## Concurrency audit

- `ClassifierExtractionMenuWiringTests` is `@MainActor final class`, which is
  required because it touches `NSView`, `NSWindow`, and the `@MainActor`
  singleton. Correct.
- `ClassifierCLIRoundTripTests` is **not** `@MainActor` (line 22). Every test
  is `async throws`. `ExtractReadsSubcommand.parse/validate/run` don't need
  `@MainActor`. Correct.
- No `Task.detached`, no `Task { @MainActor in }` from GCD, no bare
  `DispatchQueue.main.async` crossing `@MainActor` boundaries. The
  `testingCaptureOnly` hook sits inside the already-`@MainActor`-isolated
  `present()` method, so no actor-hopping is needed.
- `TaxonomyReadExtractionAction.TestingCapture` is not `Sendable`, which is
  fine because it's mutated only from `@MainActor` (the orchestrator is
  `@MainActor` and the tests run on the main actor).

**No concurrency violations.**

## Temp-dir cleanup audit

All five CLI tests use `defer { try? FileManager.default.removeItem(at: ...) }`
for both `projectRoot` and the output file(s) — verified at lines 31/36,
66/71, 104, 145/150, 183/201. Missing cleanup on crash is handled by the
`temporaryDirectory` prefix, which macOS purges periodically. No leaks.

The menu-wiring tests don't write to the filesystem at all — only construct
`NSView` + `NSWindow` instances that ARC handles. No cleanup needed.

## Simplification pass — disposition

All critical, significant, and minor findings have been addressed in the
Phase 7 simplification pass. Test-count changes:

- `ClassifierCLIRoundTripTests`: 5 → 8 (1 skipped for kraken2 fixture).
- `ClassifierExtractionMenuWiringTests`: 3 → 3 (deleted 1 duplicate, added 1
  VC-agnostic orchestrator round-trip).
- `ClassifierExtractionInvariantTests`: 24 → 24 (unchanged, 1 skipped).

### Critical

**C1. bundle regression guard now actually rejects `.lungfish/.tmp/` paths** —
Closed. `testCLI_bundle_lands_in_project_root` now iterates every bundle it
finds under `projectRoot` and asserts that none of the path components are
`.lungfish` or `.tmp`. The original "at least one bundle exists" assertion
is preserved to catch the opposite failure (CLI silently produces no bundle
at all). The test now actually pins the EsViritu bundle-in-`.tmp/` bug — the
whole motivation for the feature.

### Significant

**S1a. `--include-unmapped-mates` CLI coverage** — Added
`testCLI_includeUnmappedMates_keepsMates`. Runs two NVD extractions against
the markers BAM, one without `--include-unmapped-mates` and one with, and
asserts the loose-mask record count is STRICTLY greater than the strict-mask
count. The markers BAM has 3 unmapped records so the delta is guaranteed
positive; a regression that dropped the flag dispatch in the CLI path would
fail here.

**S1b. `--tool kraken2` rejects `--include-unmapped-mates`** — Added
`testCLI_kraken2_rejects_includeUnmappedMates`. The test wraps both
`parse(argv)` and `validate()` in a single `XCTAssertThrowsError` because
ArgumentParser internally runs `validate()` during `parse()` and surfaces
`ValidationError` as `CommandError.parserError.userValidationError` — the
rejection fires at the `parse` call site, not at a subsequent `validate()`
call. Asserting on the combined block is robust to ArgumentParser's internal
ordering.

**S1c. `--by-region --exclude-unmapped`** — Added
`testCLI_byRegion_excludeUnmapped_filtersOutUnmapped`. The test uncovered a
wrinkle: the CLI pipeline is `samtools view -b -F 0x404 | samtools fastq -F
0x900`, so the effective filter on the markers BAM is `0x404 | 0x900 = 0xD04`
(not the naive `0x404` one might assume from the flag name alone). The
ground-truth comparison uses `MarkdupService.countReads(... flagFilter:
0xD04 ...)` and also asserts `0xD04 < 0xD00` to prove the fixture has teeth.

**S2. VC-agnostic orchestrator coverage for all 5 tools** — Added
`testAllTools_orchestratorAcceptsAllClassifierTools` to
`ClassifierExtractionMenuWiringTests`. The test iterates over every
`ClassifierTool` case, constructs a minimal `Context`, calls `present()`,
and asserts the orchestrator captured the tool + suggestedName. This is
deliberately weaker than a VC-level click test — it only proves the
orchestrator's `present()` path accepts each tool — but it would catch a
regression where a specific tool is silently rejected by the dispatch
switch. The per-VC menu-click tests for TaxTriage/NAO-MGS/NVD remain
deferred to Phase 8 manual GUI verification because those VCs require a
live NSApplication context.

**S3. Multi-sample 2× record count verified** —
`testCLI_multiSample_byClassifier_concatenates` now counts records in the
multi-sample output and runs a parallel single-sample A-only CLI command as
a ground-truth control, then asserts
`multiRecordCount == singleRecordCount * 2`. Record counting uses
`line_count / 4` (dividing the total line count rather than prefix-matching
`@`) to avoid the quality-line-starts-with-`@` ambiguity.

### Minor

**Deleted `testAllTools_menuLabelIsExtractReads`** — Phase 6 I1 already pins
the "Extract Reads…" menu label via `testingContextMenu.items.contains(...)`
at the same two table views, so the test was a duplicate. Removed in full
from `ClassifierExtractionMenuWiringTests.swift`.

### Deferred to Phase 8 manual

- Per-VC click-wiring tests for TaxTriage, NAO-MGS, NVD. Their menus are
  built inside VCs that cannot be instantiated without full app context;
  Phase 8's manual smoke test is the right place to verify these paths.
- `M1` (tearDown idempotency warning comment on the hook declaration). The
  `testingCaptureOnly` hook is only used by `ClassifierExtractionMenuWiringTests`,
  and that class resets the hook on every `tearDown`. A future test class
  that uses the hook would be the right place to add a reminder comment.
- `M6` (Release-mode CI compile check on `#if DEBUG` hooks). Out of Phase 7
  scope; documented for follow-up if anyone adds a `swift test -c release`
  job.

## Suggested simplification-pass message

```
Phase 7 simplification pass

Critical: fix testCLI_bundle_lands_in_project_root regression guard — it
must assert bundles are NOT inside `.lungfish/.tmp/` or any `.tmp/`
descendant, not just "at least one bundle exists under projectRoot".

Significant additions requested:
1. Add CLI tests for --include-unmapped-mates (one per BAM-backed tool is
   overkill; nvd alone suffices).
2. Add a CLI smoke test each for taxtriage and naomgs via --by-classifier.
3. Add multi-sample record-count assertion (compare 2× single-sample
   output to multi-sample output).
4. Either add live I3 click-wiring tests for TaxTriage/NAO-MGS/NVD OR
   update the commit-message claim + test docstring to accurately describe
   what Phase 6 covers (source-level grep, not click wiring).
5. Pin the validation rejection of --include-unmapped-mates + --tool kraken2.

Minor cleanup:
- Drop testAllTools_menuLabelIsExtractReads (duplicates Phase 6 I1).
- Add a one-line warning comment on testingCaptureOnly reminding callers
  to always reset in tearDown.

Deviations all verified correct; concurrency and cleanup are clean.
```
