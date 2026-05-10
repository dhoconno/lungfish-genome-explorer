# Phase 7 — Adversarial Review #2

**Date:** 2026-04-09
**Commits reviewed:** c20e4be, 9ef8314, 61bf4db, 7606639 (post-simplification)
**Reviewer:** independent second-pass adversarial agent
**Charter:** Verify the simplification pass did not regress behavior, and
find any issues review-1 missed.

## Summary

The Phase 7 simplification pass (7606639) addresses every critical and
significant finding from review-1 materially. The bundle regression guard is
now genuinely load-bearing, the CLI flag matrix is expanded with three new
tests (include-unmapped-mates, kraken2 rejection, by-region exclude-unmapped),
the multi-sample test now has teeth via a 2× control run, and a VC-agnostic
orchestrator-all-tools probe covers the three VC-level-untestable tools with
a narrow but real guarantee. I empirically verified the math behind the
`0xD04` ground truth, the delta-count assertions, the `FileManager.enumerator`
descent into hidden directories, and the XCTest pass result (8 ran, 1 Kraken2
skipped as expected). One minor Package.swift hygiene note and one minor
assertion-coverage weakness in `testAllTools_orchestratorAcceptsAllClassifierTools`
are the only remaining observations; neither is a blocker. **Verdict: ready
to close.**

## Critical issues

None.

## Significant issues

None. Review-1's C1/S1a/S1b/S1c/S2/S3 items are all resolved by 7606639.

## Minor issues

### m1. `@testable import LungfishIO` relies on transitive resolution

`ClassifierCLIRoundTripTests.swift:8` adds `@testable import LungfishIO` for
the `MarkdupService.countReads` ground-truth helper. `Package.swift:175-179`
declares `LungfishAppTests.dependencies = ["LungfishApp", "LungfishCLI"]` —
`LungfishIO` is not listed, but it is pulled in transitively via `LungfishApp`.
The build is green (`swift build --target LungfishAppTests` succeeds, verified),
and `@testable` works on transitive dependencies when the target is actually
compiled into the dependency graph. This is a minor hygiene issue, not a
blocker — adding `"LungfishIO"` to the explicit dependency list would make
the relationship intentional and survive any future refactor that narrows
`LungfishApp`'s public surface.

### m2. `testAllTools_orchestratorAcceptsAllClassifierTools` does not assert `resultPath` preservation

The loop in `ClassifierExtractionMenuWiringTests.swift:140-185` constructs a
per-tool `resultPath` (`/tmp/unit-test-<tool>.sqlite`) but only asserts on
`captured?.tool` and `captured?.suggestedName`. If a future regression
mis-routed `resultPath` through `present()` (dropping or overwriting the
field), this test would not catch it. Adding one more assertion
(`XCTAssertEqual(captured?.resultPath.path, "/tmp/unit-test-\(tool.rawValue).sqlite")`)
inside the loop would close that gap for ~1 line of code. Not a blocker
since `Context` is a plain struct with copy semantics and the orchestrator
does not rewrite `resultPath`, but review-1 did not flag this either.

### m3. Test class-level tearDown idempotency on the shared singleton

Both `ClassifierExtractionMenuWiringTests` and `ClassifierExtractionDialogTests`
touch `TaxonomyReadExtractionAction.shared`. The dialog tests only use
`resolveDestinationForTesting` and do NOT set `testingCaptureOnly`, so there
is no interaction today. Review-1's M1 already flagged the latent risk for
future test classes that might use the hook; I confirm the concern and note
that a single-line warning on the hook declaration in
`TaxonomyReadExtractionAction.swift:703-707` would future-proof it. Not a
blocker.

## Empirical verifications

### Bundle regression guard — `FileManager.enumerator` DOES descend into `.lungfish/.tmp/`

I wrote a stand-alone Swift snippet creating
`tmp/.lungfish/.tmp/bundle.lungfishfastq` and enumerating with
`FileManager.default.enumerator(at:)`. The enumerator returned the hidden
bundle URL. So the guard at `ClassifierCLIRoundTripTests.swift:167-177`
WOULD fire on the exact regression it claims to guard. The
`.filter { $0.pathExtension == "lungfishfastq" }` + `components.contains(".lungfish")`
pair is not dead weight — confirmed.

Important caveat: the Phase 7 test writes via the **CLI** path using NVD, not
the GUI EsViritu path that had the original bug. The CLI path uses
`outputURL.deletingLastPathComponent()` as `outputDir` and passes it to
`ReadExtractionService.createBundle`. So this guard pins CLI-level bundle
destination correctness; the GUI EsViritu bug is separately covered by
Phase 6 invariant I4 which exercises `.bundle` destination via
`resolveDestinationForTesting`. The two layers together guard both sides.
The commit-message framing of the Phase 7 test as "the regression guard for
the whole feature" is slightly grandiose but substantively correct.

### `0xD04` ground truth — verified via direct samtools invocation

```
samtools view -c -F 0xD04 <markers.bam> = 197
samtools view -c -F 0xD00 <markers.bam> = 200
samtools view -c -F 0x404 <markers.bam> = 199
samtools view -c -F 0x900 <markers.bam> = 201
samtools view -c <markers.bam>          = 203
```

And `samtools fastq --help` confirms the default is `-F 0x900`. The CLI
`--by-region` pipeline is `view -b -F 0x404 | fastq -F 0x900` (because
`convertBAMToFASTQSingleFile` passes `flagFilter: 0x900` at
`ReadExtractionService.swift:624`), so the effective filter composition is
`0x404 | 0x900 = 0xD04`. The test's ground truth is correct. Strict expected
= 197; loose expected = 200; delta = 3 (strictly greater than zero, so the
test has teeth).

### `testCLI_byRegion_excludeUnmapped_filtersOutUnmapped` teeth check

Assertion: `actual == strictExpected` (197) AND `strictExpected < looseExpected`
(197 < 200). If the implementation inverted `--exclude-unmapped` so that
passing it produced `-F 0x400` (the loose mask), the `actual` would be 200
and the equality assertion would fail. If someone dropped `--exclude-unmapped`
plumbing entirely (always `-F 0x400`), same failure. The test bites both
regressions.

### `testCLI_includeUnmappedMates` teeth

Strict pipeline (by-classifier path): `view -b -F 0x404 | fastq -F 0x404` →
effective mask `0x404`, count = 199. Loose: `view -b -F 0x400 | fastq -F 0x400`
→ effective mask `0x400`, count = 202. Delta = 3. Assertion
`XCTAssertGreaterThan(looseCount, strictCount)` is strict (not `>=`), so any
regression that made the flag a no-op (strict == loose) would fail. Test has
teeth. Test run output confirms: strict=199, loose=202. Matches the predicted
counts exactly.

### `line_count / 4` off-by-one check

`countFASTQRecords` at `ClassifierCLIRoundTripTests.swift:449-459` splits on
`\n` with `omittingEmptySubsequences: false`, then subtracts 1 if the last
element is empty (trailing newline). For a well-formed FASTQ file ending in
`\n` with N records: `split` yields `4N + 1` elements, last is empty, decrement
to `4N`, `/4 = N`. For a file without trailing newline: `split` yields `4N`
elements, no decrement, `/4 = N`. Both correct. I verified the test output's
multi-sample count = 398 matches `2 × 199 = 398` exactly, so no off-by-one
in practice. Empty file: `[""]` → 1 → 0 → 0. Correct.

### `samtools fastq` default `-F 0x900` confirmed

From `samtools fastq --help`:
```
-F, --excl[ude]-flags INT
             only include reads with none of the FLAGs in INT present [0x900]
```

Review-1's C1 reasoning and the simplification-pass comment on
`testCLI_byRegion_excludeUnmapped` are correct.

### `testingCapture` state pollution in
`testAllTools_orchestratorAcceptsAllClassifierTools`

The loop resets `testingCapture = .init()` at the top of each iteration
(line 142). Each assertion reads
`TaxonomyReadExtractionAction.shared.testingCapture.presentCount == 1` and
captures `lastContext`. No accumulation across iterations. Confirmed clean.

### Kraken2 XCTSkip honesty

Test run skip message: "Kraken2 extraction failed on incomplete fixture:
Kraken2 source FASTQ could not be located. The source file may have been
moved or deleted." This traces to
`ClassifierReadResolver.swift:586 throw ClassifierExtractionError.kraken2SourceMissing`
(resolveKraken2SourceFiles walks the kraken2-mini fixture, can't find any of
the 3 possible locations, throws). This is a genuine fixture-incompleteness
state, not a masked bug. A real Phase 5 regression in
`ClassifierReadResolver.runKraken2Dispatch` (kraken2 code path entirely broken)
would throw a different error type / manifest differently. Skip is honest.

### Deleted `testAllTools_menuLabelIsExtractReads` — Phase 6 I1 equivalence

`ClassifierExtractionInvariantTests.swift:32` defines
`private static let extractReadsTitle = "Extract Reads\u{2026}"` and
`testI1_esviritu_menuItemVisible` / `testI1_kraken2_menuItemVisible` at lines
36-54 assert this exact title exists in the context menus of both
`ViralDetectionTableView` and `TaxonomyTableView`. The deleted test
(previously at `ClassifierExtractionMenuWiringTests.swift` per the plan)
covered the same two table views with the same assertion. Coverage is
preserved; deletion is correct.

### Build + test run

```
swift build --target LungfishAppTests         → OK (4.47s)
swift test --filter ClassifierExtractionMenuWiringTests   → 3 passed
swift test --filter ClassifierCLIRoundTripTests           → 7 passed, 1 skipped (kraken2)
```

All Phase 7 tests green on my machine.

## Verification of simplification-pass actions (items 6-12 from the prompt)

| # | Action | Verified | Evidence |
|---|---|---|---|
| 6 | bundle regression guard rejects `.lungfish/.tmp/` paths | YES | lines 167-177 iterate every bundle URL and assert neither `.lungfish` nor `.tmp` in path components |
| 7 | `testCLI_includeUnmappedMates_keepsMates` added | YES | lines 279-331, strict/loose assertion |
| 8 | `testCLI_kraken2_rejects_includeUnmappedMates` added | YES | lines 346-363, `XCTAssertThrowsError` wraps parse+validate |
| 9 | `testCLI_byRegion_excludeUnmapped_filtersOutUnmapped` with 0xD04 ground truth | YES | lines 381-439, uses `MarkdupService.countReads` with 0xD04 and 0xD00 |
| 10 | `testAllTools_orchestratorAcceptsAllClassifierTools` | YES | `ClassifierExtractionMenuWiringTests.swift:131-185`, iterates all 5 tools |
| 11 | multi-sample uses `line_count / 4` + single-A control | YES | lines 93-119, counts records in both outputs, asserts multi=2×single |
| 12 | deleted `testAllTools_menuLabelIsExtractReads` | YES | Phase 6 I1 covers EsViritu and Kraken2 tables with identical assertion |

## Concurrency audit

- `ClassifierExtractionMenuWiringTests` is `@MainActor final class` — correct
  for `NSView` / `NSWindow` / singleton access.
- `ClassifierCLIRoundTripTests` is non-main-actor with `async throws` tests —
  correct, because `ExtractReadsSubcommand.run()` is not `@MainActor` isolated.
- `testingCaptureOnly` mutation sits inside `present()` which is `@MainActor`
  by class isolation, so no actor-hop.
- No `Task.detached`, no `Task { @MainActor }`, no GCD main-queue dispatch
  across actors. Clean against MEMORY.md's background-to-MainActor guidance.
- The test's loop in `testAllTools_orchestratorAcceptsAllClassifierTools`
  mutates `TaxonomyReadExtractionAction.shared.testingCapture` from
  `@MainActor` context, and the class itself is `@MainActor`, so the
  singleton access is serialized.

No concurrency violations.

## Temp-dir cleanup audit

All 8 CLI tests use `defer { try? FileManager.default.removeItem(at: ...) }`
for both `projectRoot` and the output file(s). The `testCLI_byRegion_*`
test creates an output directory and removes it via `defer` at line 395.
The menu-wiring tests don't touch the filesystem. No leaks.

## Test-gap status (review-1's 8 gaps)

1. `--include-unmapped-mates` CLI — **closed** (testCLI_includeUnmappedMates_keepsMates)
2. `--exclude-unmapped` on `--by-region` — **closed** (testCLI_byRegion_excludeUnmapped_filtersOutUnmapped)
3. CLI smoke test for taxtriage/naomgs — **partially closed** by
   `testAllTools_orchestratorAcceptsAllClassifierTools` at the
   orchestrator level; dedicated per-tool CLI smoke tests are still missing
   (deferred — see below)
4. `--include-unmapped-mates` + `--tool kraken2` rejection — **closed**
   (testCLI_kraken2_rejects_includeUnmappedMates)
5. Multi-sample record count — **closed** (2× invariant verified)
6. Bundle outside `.lungfish/.tmp` — **closed** (regression guard has teeth)
7. I3 click-wiring for TaxTriage/NAO-MGS/NVD — **documented deferral to
   Phase 8 manual** in test docstring at lines 120-130
8. `testAllTools_menuLabelIsExtractReads` duplication — **closed** (deleted)

Gap #3 is the only remaining thin spot, but
`testAllTools_orchestratorAcceptsAllClassifierTools` (new in 7606639) offers
narrow compensating coverage at the orchestrator level, and Phase 6 I4/I7
cover the resolver-level dispatch. A dedicated per-tool CLI round trip for
TaxTriage and NAO-MGS would be additive, not load-bearing.

## Divergence from review-1

**Issues I found that review-1 missed:**
- **m1**: `@testable import LungfishIO` relies on transitive dependency
  resolution (`LungfishAppTests.dependencies` doesn't list `LungfishIO`
  explicitly). Not a blocker — build is green — but a minor Package.swift
  hygiene note.
- **m2**: `testAllTools_orchestratorAcceptsAllClassifierTools` asserts on
  `tool` and `suggestedName` but NOT on `resultPath`, leaving a small gap
  where a future regression mis-routing `resultPath` through the dispatch
  would pass the test. One-line fix possible.

**Issues review-1 found that I did not:**
- Review-1's Significant S2 (I3 click-wiring missing for
  TaxTriage/NAO-MGS/NVD) — I independently agree that
  `testAllTools_orchestratorAcceptsAllClassifierTools` is weaker than a live
  click test, but I view the documented Phase 8 manual deferral in the
  test's own docstring as an acceptable disposition given the practical cost
  of instantiating those VCs in a unit-test harness.
- Review-1's M6 (Release-mode CI compile check on `#if DEBUG`) — I did not
  re-probe this because it's out of Phase 7 scope.
- Review-1 provided a more thorough verification of the 5 original deviations
  (`--format` → `--read-format`, Kraken2 XCTSkip, `testingContextMenu`
  property, `singleArgv` line removal, test rename); I spot-checked the
  rename and the Kraken2 skip but did not re-probe all five.

**Verdict:**
- **Phase is ready to close.** All critical findings from review-1 are
  addressed materially. The simplification pass (7606639) is well-targeted,
  the new tests have mathematically correct teeth (empirically verified via
  direct samtools invocation), the bundle regression guard genuinely rejects
  `.lungfish/.tmp/` paths (verified via standalone FileManager probe), and
  the Kraken2 XCTSkip is honest. The two minor notes (m1, m2) are
  nice-to-have polish, not gate-blockers. I recommend closing Gate 3 and
  proceeding to Gate 4 (build+test gate) / Phase 8.
