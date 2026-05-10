# Phase 6 — Adversarial Review #2

**Date:** 2026-04-09
**Commits reviewed:** 5adb411, 8fed1cf, fe9615f, dec2202, be9f0c2, 60a4774, 3aa8c62
**Reviewer:** independent second-pass adversarial review
**Charter:** Second independent review after simplification pass. Verify I4 fixture teeth empirically, confirm simplification pass did not regress, probe for issues missed by review-1.

## Summary

Phase 6 is in strong shape. The 24-test invariant suite runs in **2.488s** (50% of the 5s budget) with 1 documented skip (Kraken2 I7, Phase 7 fixture work). Empirical `samtools 1.23` counts on `test.paired_end.sorted.markers.bam` confirm the Phase 2 review-2 forwarded I4 fixture requirement: raw=203, `-F 0x404`=199, with 1 secondary, 1 supplementary, 1 duplicate, and 3 unmapped records. The simplification pass correctly tightened I7 catches to `ClassifierExtractionError.kraken2SourceMissing` and added a strict `<` teeth assertion in I5 against the markers BAM directly.

I found one minor issue review-1 missed (a temp-directory leak in `defaultSelection`), and concur with review-1 on everything it called out. **No blockers.**

## Critical issues (must fix before moving on)

None.

## Significant issues (should fix)

None. Both significant issues from review-1 (I7 catch breadth, I5 strict vs loose teeth) were resolved by the simplification pass and I verified the fixes empirically.

## Minor issues

- [ ] **Temp-directory leak in `ClassifierExtractionFixtures.defaultSelection` (Kraken2 branch).** `Tests/LungfishAppTests/TestSupport/ClassifierExtractionFixtures.swift:161` calls `buildFixture(tool: .kraken2, sampleId: sampleId)` and discards the returned `projectRoot` via `let (resultPath, _) = try buildFixture(...)`. `buildFixture` always creates a temp project root at `fm.temporaryDirectory.appendingPathComponent("clfx-kraken2-\(UUID())")` with a `.lungfish/` marker and `analyses/kraken2-result/` subdirectory before the per-tool switch (lines 82-87) — so this scaffolding is created even when the Kraken2 case only returns the mini fixture dir as `resultPath`. The discarded `projectRoot` is never deleted. Each Kraken2 invariant test invocation leaks one orphan directory into `$TMPDIR`. Small (~few KB) and harmless on CI, but worth fixing. Either (a) have `defaultSelection` return the projectRoot so the test can `defer` cleanup, or (b) have Kraken2's branch in `buildFixture` skip the `projectRoot` scaffolding entirely since it's unused. Review-1 did not catch this.

- [ ] **`testI1_*_menuItemVisible_sourceLevel` does not guard against a stale test path.** Lines 63-64, 79-80, 92-93 hand-build the VC source file path via `String(contentsOfFile:)`. A file-move refactor will throw from `String(contentsOfFile:)` and fail the test loudly (good), but there's nothing preventing the substring search from silently matching comments or doc-string examples. The test would trivially pass if someone puts `// example: #selector(contextExtractFASTQ(...))` in a doc block even if the real wiring is broken. Review-1 noted the brittleness angle (line 26). I'd add that an implementation comment carrying the same string would also fool the test — the strings are unanchored. Acceptable for Phase 6 but keep in mind.

- [ ] **I3 click-wiring tests bypass the menu dispatch chain.** `testI3_clickWiring_esviritu_firesPresent` and `testI3_clickWiring_kraken2_firesPresent` call `simulateContextMenuExtractReads()` which calls `contextExtractReads(nil)` directly, which invokes `onExtractReadsRequested?()`. This verifies only the one-line `contextExtractReads` → `onExtractReadsRequested` relay. It does NOT verify that (a) the menu item's `action:` is wired to `#selector(contextExtractReads(_:))`, (b) AppKit's validateMenuItem path isn't disabling the item for a subtle reason, or (c) the outer VC has wired `onExtractReadsRequested` to the shared presenter. The test passes trivially as long as the three-line method body exists. Review-1 did not explicitly flag this. Acceptable because I2 + I3 together cover `validateMenuItem` and the relay, but the chain is not end-to-end.

- [ ] **`private static var _testingStubKey: UInt8 = 0` in two classes uses the same local name with `&Self._testingStubKey` — correct, but fragile.** Each class has its own `_testingStubKey` as a per-class static, and `objc_setAssociatedObject` keys by the memory address of that static plus the owning object. Since `ViralDetectionTableView` and `TaxonomyTableView` are distinct classes with distinct instances, there's no collision risk. However, Swift's `private static var` semantics guarantee a stable address only within a single compilation unit; if either class is ever moved into a file that redeclares the static in a scope that crosses a module boundary, behavior could shift. Non-actionable today, but would be cleaner as a file-private `fileprivate static let _testingStubKey = UInt8(0)` with `withUnsafePointer`. Negligible risk.

- [ ] **Release-mode build couldn't fully verify DEBUG hooks compile out via `swift test`.** `swift build --build-tests -c release` fails on an unrelated pre-existing LungfishPluginTests issue (`module 'LungfishPlugin' was not compiled for testing`). I verified `swift build -c release --target LungfishApp` succeeds (230s, clean), which confirms the `#if DEBUG` hooks and the `_TestingXxxStubOutlineDataSource` fileprivate classes compile out of the release library. The full release test target cannot be built as-is, but that's not a Phase 6 regression.

## I4 fixture teeth verification (empirical, independent of review-1)

Ran my own `samtools 1.23` counts on `Tests/Fixtures/sarscov2/test.paired_end.sorted.markers.bam`:

| Flag selector            | Count | Notes |
|--------------------------|------:|-------|
| raw (no filter)          | **203** | 200 original + 3 synthetic |
| `-F 0x404`               | **199** | strict: excludes dup + unmapped |
| `-F 0x400`               | **202** | loose: excludes dup only (keeps unmapped) |
| `-f 0x100` (secondary)   |   1 | synthetic_sec_1 (flag 355) |
| `-f 0x400` (duplicate)   |   1 | synthetic_dup_1 (flag 1123) |
| `-f 0x800` (supplementary)|  1 | synthetic_sup_1 (flag 2147) |
| `-f 0x004` (unmapped)    |   3 | pre-existing unmapped mates in sarscov2 data |

Delta 203 − 199 = 4 = 1 duplicate + 3 unmapped. Delta strict vs loose (199 vs 202) = 3, matching the 3 unmapped records. The synthetic records cover the three flag categories requested by Phase 2 review-2 (secondary 0x100, duplicate 0x400, supplementary 0x800). All verified on disk with `samtools view`:

```
synthetic_dup_1 1123 MT192765.1 643
synthetic_sec_1 355  MT192765.1 643
synthetic_sup_1 2147 MT192765.1 643
```

I4 has real teeth: `assertI4` asserts both `outcome.readCount == MarkdupService.countReads(flagFilter: 0x404)` AND `outcome.readCount < rawTotal` (via a second MarkdupService call with `flagFilter: 0`). A regression that drops the 0x404 mask in the resolver (making outcome.readCount = 203) fails the `< 203` assertion immediately. A regression that drops the mask in MarkdupService (making unique = 203) fails the count-equality assertion because outcome would still be 199 from the resolver's own `samtools view -b -F 0x404` call.

## I5 strict teeth verification

I5's `testI5_allBAMBackedTools_dispatchCorrectFlag` has two layers:

1. **Loop-level `<=` defensive check** across all 4 BAM-backed tools (line 332). The implementer kept `<=` here to avoid breaking when a future fixture has zero duplicates/unmapped reads.
2. **NVD + markers BAM strict `<` teeth** at line 374-378. NVD's fixture copies the markers BAM verbatim, and `estimateReadCount` dispatches through the region filter (`MT192765.1`). Strict should produce 199, loose should produce 202. I ran the test and it passed — the resolver IS dispatching two different flag masks.

Unmapped-record check: the 3 unmapped reads (flags 89×2/133/165) all carry `RNAME=MT192765.1` (not `*`), so the region selection picks them up. If they were on `*`, the strict `<` assertion would fall through because both strict and loose would return the same count. The test authors got this right: the fixture has unmapped reads that are still assigned to the selected reference, which is what `samtools view REGION` expects for unmapped mates of mapped reads.

Ran `swift test --filter testI5_allBAMBackedTools_dispatchCorrectFlag 2>&1` — passes in 0.099s.

## I7 catch narrowing verification

Re-read `assertI7` lines 446-462 post-simplification:

```swift
do {
    _ = try await resolver.resolveAndExtract(
        tool: tool,
        ...
        destination: .file(guiOut),
        progress: nil
    )
} catch ClassifierExtractionError.kraken2SourceMissing {
    throw XCTSkip("\(tool.displayName) kraken2 source FASTQ unavailable ...")
}
```

Only `ClassifierExtractionError.kraken2SourceMissing` converts to skip. Everything else — samtools failure, IO error, any other `ClassifierExtractionError` case, `FASTQConversionError`, etc. — propagates and fails the test. The CLI path `do { } catch { throw XCTSkip }` blocks were deleted outright (lines 497-500):

```swift
var cmd = try ExtractReadsSubcommand.parse(tokens)
cmd.testingRawArgs = tokens
try cmd.validate()
try await cmd.run()
```

Any CLI parse/validate/run failure now propagates as a hard XCTFail. Verified the kraken2 test still skips correctly (line 461 XCTSkip fires at runtime).

## Per-invariant test coverage (post-simplification)

| Invariant | # tests | Coverage | Notes |
|-----------|--------:|----------|-------|
| I1 | 5 | 2 dynamic (ESViritu, Kraken2) + 3 source-level (TaxTriage, NAO-MGS, NVD) | source-level also asserts `#selector(...)` prefix |
| I2 | 2 | ESViritu + Kraken2 dynamic | other 3 tools rely on integration suites |
| I3 | 2 | ESViritu + Kraken2 dynamic | bypasses AppKit menu dispatch |
| I4 | 4 | 4 BAM tools × all destinations | count-equality + `< raw` teeth |
| I5 | 3 | 2 unit (flag bits) + 1 parameterized (4 tools + NVD markers strict) | `<=` loop + `<` NVD strict teeth |
| I6 | 3 | view-model cap + resolver reject | covered |
| I7 | 5 | 4 BAM + 1 Kraken2 (documented skip) | catch narrowed to `kraken2SourceMissing` |

**Total: 24 tests, 1 skip, 23 passing.**

## Performance budget (measured)

`Executed 24 tests, with 1 test skipped and 0 failures (0 unexpected) in 2.488 (2.490) seconds`.

- I1 (5): ~0.11s
- I2 (2): ~0.005s
- I3 (2): ~0.003s
- I4 (4, 13 runs): ~2.00s (dominant, one samtools dispatch per destination)
- I5 (3): ~0.10s
- I6 (3): ~0.026s
- I7 (5, 4 runs): ~0.21s

**2.488s is within the 5s budget (50% used).** Independent replication of review-1's 2.42s number with some variance (0.07s difference) explained by system noise.

## Build + full-suite regression check

- `swift build --build-tests`: clean. `Build complete! (0.39s)` on incremental.
- `swift build -c release --target LungfishApp`: clean. Confirms DEBUG hooks compile out.
- `swift test --filter ClassifierExtractionInvariantTests`: **24 pass, 1 skip, 0 fail in 2.49s.**
- `swift test --filter LungfishAppTests`: 1555 tests, 2 skips, **3 failures** (1 unexpected). The failing test is `FASTQProjectSimulationTests.testSimulatedProjectVirtualOperationsCreateConsistentChildBundles` at line 119-120, plus a follow-on error in `FASTQCLIMaterializer.swift:389`. **These failures are pre-existing and unrelated to Phase 6** — confirmed via `git log 1744a9f..HEAD -- Tests/LungfishAppTests/FASTQProjectSimulationTests.swift Sources/LungfishWorkflow/Extraction/FASTQCLIMaterializer.swift` returning empty. Phase 6 neither touched nor broke these files.

## Concurrency audit

- `@MainActor` on the test class — all tests inherit MainActor isolation.
- `ClassifierReadResolver` is an `actor`; structured `try await resolver.resolveAndExtract(...)` hops correctly.
- `MarkdupService.countReads` is a synchronous static function called without `await`.
- `NativeToolRunner.shared.findTool(.samtools)` at `ClassifierExtractionFixtures.swift:184` is `async throws` and correctly awaited.
- `BAMRegionMatcher.readBAMReferences(bamURL:runner:)` at `ClassifierExtractionFixtures.swift:141` is `async throws` and correctly awaited.
- No `Task.detached`, no `Task { @MainActor in }`, no bare `DispatchQueue.main.async`, no `MainActor.assumeIsolated`.
- The `objc_setAssociatedObject` calls are on `@MainActor` instance methods — no cross-actor concerns.

**Zero concurrency issues.**

## Test isolation audit

- Each test function instantiates its own `ClassifierReadResolver()` (lines 175, 317, 361, 408, 443). The actor is a local value, so there's no cross-test state.
- `buildFixture` creates unique UUIDs per call; no collisions.
- All `buildFixture` calls inside the test file pair with `defer { try? FileManager.default.removeItem(at: projectRoot) }` — verified at lines 167, 312, 357, 403, 433.
- The `share(tempDirectory: projectRoot)` destination places the share subdir inside the fixture project root, so it's cleaned up with the parent.
- Output file cleanup: `guiOut` (444) + `cliOut` (488) each have their own `defer` removal.
- DEBUG stub data sources retained via `objc_setAssociatedObject` die with the freshly-constructed table view on each test function exit — no cross-test leakage.

**One leak: `defaultSelection(for: .kraken2, ...)` discards `projectRoot` (see Minor issue 1).** This is the only isolation gap I found.

## Simplification pass verification

Reviewed commit 60a4774 (`refactor(phase-6-simplification): narrow I7 skip catches + tighten I5 strict count`). Changes:

1. **I7 GUI catch** (lines 446-462): narrowed to `catch ClassifierExtractionError.kraken2SourceMissing`. ✓
2. **I7 CLI catch blocks**: deleted; errors propagate as hard failures. ✓
3. **I5 strict NVD assertion** (lines 346-378): new `XCTAssertLessThan(nvdStrict, nvdLoose, ...)` against the markers BAM directly via NVD. ✓
4. **I5 empty-iteration guard** (lines 307-344): added `var toolsIterated = 0` counter and `XCTAssertFalse(toolsIterated == 0, ...)`. ✓
5. **I4 oracle comment** (lines 199-205): added disclaimer that count-equality shares the dispatch path and the `< rawTotal` assertion below is the teeth. ✓
6. **Source-level I1 tests**: upgraded to assert `#selector(...)` prefix rather than bare method name. ✓
7. **`sarscov2BAMIndex` URL construction**: changed to `sarscov2BAM.appendingPathExtension("bai")` (and the 4 inline sites in `buildFixture` too). ✓

**Simplification pass introduced no regressions.** Post-simplification runtime 2.488s is effectively identical to pre-simplification 2.42s (variance <3%).

## Divergence from review-1

Issues I found that review-1 missed:

- **Temp-directory leak in `ClassifierExtractionFixtures.defaultSelection` Kraken2 branch.** Reviewer-1 audited temp cleanup (lines 138-143) and verified every `buildFixture` in the test file has a matching `defer` — but missed that `defaultSelection` also calls `buildFixture` internally (line 161) and discards the projectRoot. This leaks ~1 temp directory per Kraken2 test invocation. Minor (test-only, $TMPDIR), but a real gap.
- **I3 click-wiring tests bypass the menu dispatch chain.** Review-1 treats I3 as "click wiring" but I3 actually only tests a 1-line relay from `contextExtractReads` to `onExtractReadsRequested`. It does not verify the menu item's `action:` selector, validateMenuItem path, or VC-level closure binding. Review-1 did not explicitly call this out.
- **Source-level I1 test substring matches are unanchored.** Review-1 flagged the path-brittleness (line 26) but not that the strings can match comments/doc-strings in the VC source file. This would let a commented-out example fool the test even with real wiring broken.

Issues review-1 found that I did not:

- None of substance. Review-1 caught the two significant issues (I7 catch breadth, I5 `<=` vs `<`) that drove the simplification pass; both are now fixed. Review-1 also caught the consistency issue with the `sarscov2BAMIndex` URL construction (now fixed in simplification). Review-1's per-invariant coverage table and performance breakdown match mine.

Issues we both found:

- I1 source-level smoke-test weakness (regression categories not caught).
- I4 count-equality is a weak oracle because both sides share the same dispatch path (mitigated by the `< rawTotal` teeth).

## Verdict

**Phase is ready to close.**

Justification:

1. The Phase 2 review-2 forwarded I4 fixture requirement is resolved with real teeth (empirical 203 vs 199 delta, verified independently).
2. Both review-1 significant issues were addressed in the simplification pass (commit 60a4774), verified by re-running the suite.
3. The invariant suite meets the spec's performance budget (2.488s < 5s).
4. 24 tests, 1 documented skip (Kraken2 I7, Phase 7 fixture work), 0 failures.
5. No concurrency issues, no test isolation issues beyond one cosmetic `defaultSelection` temp leak.
6. Release build verified clean for `LungfishApp` target (DEBUG hooks compile out).
7. The 3 pre-existing full-suite failures (`FASTQProjectSimulationTests`) are unrelated to Phase 6 — Phase 6 touched neither the failing test nor `FASTQCLIMaterializer.swift`.

The `defaultSelection` Kraken2 temp leak (Minor issue 1) is the only new finding. It is cosmetic, test-only, and does not warrant blocking the gate. Recommend fixing it opportunistically during Phase 7 fixture expansion since Phase 7 will rework the Kraken2 fixture anyway.

Phase 6 gate closes. Phase 7 can start.
