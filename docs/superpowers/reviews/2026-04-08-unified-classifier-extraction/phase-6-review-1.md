# Phase 6 — Adversarial Review #1

**Date:** 2026-04-09
**Commits reviewed:** 5adb411, 8fed1cf, fe9615f, dec2202, be9f0c2
**Reviewer:** general-purpose subagent
**Charter:** Independent adversarial review before simplification pass.

## Summary

Phase 6 closes the 7-invariant regression guard convincingly. The Phase 2 review-2 forwarded item — I4 fixture teeth — is resolved: `Tests/Fixtures/sarscov2/test.paired_end.sorted.markers.bam` now contains 203 raw reads, 199 after `-F 0x404`, with at least 1 secondary, 1 supplementary, 1 duplicate, and 3 unmapped records. The `assertI4` helper asserts both `outcome.readCount == MarkdupService.countReads(flagFilter: 0x404)` AND `outcome.readCount < raw_total`, so any regression that drops the flag mask between the resolver and MarkdupService produces a hard failure. 24 tests, 1 skip (Kraken2 I7, genuinely fixture-bound), 0 failures, measured runtime **2.42s** — well under the 5s budget. Two significant issues remain (overly broad I7 catch, weak I5 assertion), plus several minor items. No critical blockers.

## Critical issues (must fix before moving on)

None.

## Significant issues (should fix)

- [ ] **I7 `catch` is too broad and silently masks resolver regressions.** `ClassifierExtractionInvariantTests.swift:388-399` wraps the entire `resolveAndExtract` call in `do { ... } catch { throw XCTSkip(...) }`. For Kraken2 today that catches `kraken2SourceMissing` and produces a genuine skip, but for EsViritu/TaxTriage/NAO-MGS/NVD any real resolver regression (samtools failure, destination-not-writable, FASTA conversion bug, etc.) is also converted to XCTSkip. The test would silently turn green on a broken resolver. Narrow the catch to `catch ClassifierExtractionError.kraken2SourceMissing` so only that specific error produces a skip. Lines 432-448 have the same too-broad-catch pattern on CLI parse/validate/run (three separate `do { } catch { throw XCTSkip }` blocks). These should either propagate (let the assertion fail) or scope to a specific expected error type.

- [ ] **I5 `testI5_allBAMBackedTools_dispatchCorrectFlag` uses `<=` where `<` has teeth.** `ClassifierExtractionInvariantTests.swift:313-317` asserts `countStrict <= countLoose`. On the markers BAM with 1 duplicate record + 3 unmapped mates, strict (0x404) should be 199 and loose (0x400) should be 202 — strictly less. A `strict < loose` assertion would catch a regression that folds the two flag paths to the same mask. As written, a regression that makes both modes return identical counts would pass the `<=` check.

## Minor issues

- [ ] **Source-level I1 tests (lines 62-99) only verify the string `"Extract Reads…"` and the selector name exist somewhere in the VC source.** They would not catch: a menu item created but never `menu.addItem()`-attached; a selector wired to the wrong title; an action body that has been emptied; an `#if false` block disabling the whole menu section. The comment at lines 56-61 acknowledges this and relies on I3 integration coverage in other suites. Acceptable for Phase 6, but the weakness should be tracked — if no dynamic coverage lands by Phase 7, upgrade these to full VC instantiation.

- [ ] **Test source refers to `#file`-style paths via string concatenation** at lines 63-64 (`"\(ClassifierExtractionFixtures.repositoryRoot.path)/Sources/...swift"`). A file-move refactor would break these silently since they're loaded via `String(contentsOfFile:)`. A missing file throws and fails the test, but a typo in the hand-written path would quietly pass (because the string search literally runs on nothing and XCTAssertTrue would fail). Acceptable but brittle.

- [ ] **The `MarkdupService.countReads` ground-truth call in `assertI4` (lines 179-184) duplicates the samtools dispatch path that the resolver uses.** If `ClassifierReadResolver.extractViaBAM` switched from MarkdupService.countReads to a different oracle (e.g., counting FASTQ lines), the test would still pass trivially for the count-match assertion. The `< raw_total` teeth assertion mitigates this, but the count-equality assertion does not independently verify the resolver against an *external* oracle — both sides call the same `samtools view -c -F 0x404`. That's not a bug but the review should note it.

- [ ] **`ClassifierExtractionFixtures.sarscov2BAMIndex` at line 58** constructs the index URL via `URL(fileURLWithPath: sarscov2BAM.path + ".bai")` instead of `sarscov2BAM.appendingPathExtension("bai")`. Works, but inconsistent with the rest of the codebase.

- [ ] **`testI5_allBAMBackedTools_dispatchCorrectFlag` iterates `ClassifierTool.allCases.where { usesBAMDispatch }`** but doesn't assert the case list is non-empty, so a refactor that flips all tools off BAM dispatch would silently pass the test with zero iterations. Add `XCTAssertFalse(iterated.isEmpty)`.

## I4 fixture teeth verification (Phase 2 review-2 forwarded item)

Empirical samtools 1.23 counts on `Tests/Fixtures/sarscov2/test.paired_end.sorted.markers.bam`:

| Flag selector | Count |
|---|---|
| raw (no filter)              | **203** |
| `-F 0x404` (not dup+unmapped)| **199** |
| `-f 0x100` (secondary)       |   1 |
| `-f 0x800` (supplementary)   |   1 |
| `-f 0x400` (duplicate)       |   1 |
| `-f 0x4`   (unmapped)        |   3 |

Delta 203 − 199 = 4 = 1 duplicate + 3 unmapped (the `0x404` mask excludes both). Secondary + supplementary records (1 each) are **preserved** in the 0x404 count, which matches the spec's intent. The implementer's claim (203/199, ≥1 secondary, ≥1 supplementary, ≥1 duplicate) is correct.

**Verdict: I4 has real teeth.** `assertI4` (lines 154-224) issues two assertions: (1) `outcome.readCount == MarkdupService.countReads(flagFilter: 0x404)` using the same markers BAM, and (2) `outcome.readCount < rawTotal` via a second MarkdupService call with `flagFilter: 0` (203 vs 199 on the markers BAM). Assertion (2) is the hard teeth the implementer promised — if a future refactor drops the flag mask in the resolver, 203 will equal 203 and the `< raw` assertion will fail. Running the suite produces CLI-side "Wrote 199 reads" log output for all 4 BAM-backed tools, confirming the resolver actually emits 199 records from the 203-record markers BAM end-to-end.

## Per-invariant test coverage

| Invariant | # methods | Tools covered | Status |
|-----------|----------:|---------------|--------|
| I1 | 5 | EsViritu (dynamic), Kraken2 (dynamic), TaxTriage (source-level), NAO-MGS (source-level), NVD (source-level) | covered — TaxTriage/NAO-MGS/NVD weaker |
| I2 | 2 | EsViritu (dynamic), Kraken2 (dynamic) | partial — other 3 tools rely on I3 coverage in separate suites |
| I3 | 2 | EsViritu (dynamic), Kraken2 (dynamic) | partial — other 3 tools rely on integration tests |
| I4 | 4 | EsViritu (4 destinations), TaxTriage (3 dest), NAO-MGS (2 dest), NVD (2 dest) | fully covered for BAM-backed tools |
| I5 | 3 | ExtractionOptions unit (2 methods) + all 4 BAM-backed tools parameterized | covered |
| I6 | 3 | clipboardDisabledAboveCap + clipboardEnabledAtCap + resolverRejectsOverCap (NVD fixture) | covered |
| I7 | 5 | EsViritu, TaxTriage, NAO-MGS, NVD (all pass); Kraken2 (genuine skip) | 4/5 covered |

Total: 24 tests, 1 skip.

## Performance budget

Measured: `Executed 24 tests, with 1 test skipped and 0 failures (0 unexpected) in 2.420 (2.422) seconds`. Breakdown:

| Suite segment | Time |
|---|---:|
| I1 (5 tests)            | ~0.10s |
| I2 (2 tests)            | ~0.005s |
| I3 (2 tests)            | ~0.004s |
| I4 (4 tests, 13 runs)   | 1.98s (dominant) |
| I5 (3 tests)            | 0.083s |
| I6 (3 tests)            | 0.024s |
| I7 (5 tests, 4 runs)    | 0.23s |

**Verdict: 2.42s, well under the 5s target (52% budget used).** The dominant cost is I4 because each of the 13 destination runs invokes samtools externally (estimate + view + FASTQ write) ~150ms each. This will not regress under load — the markers BAM is only 19 KB.

## Verification of the 8 deviations

### 1. Fixture BAM filename
`Tests/Fixtures/sarscov2/test.paired_end.sorted.markers.bam` (19490 bytes) + `.bai` (128 bytes) present and reachable via `ClassifierExtractionFixtures.sarscov2BAM`. Original `test.paired_end.sorted.bam` (19725 bytes) retained for other test suites. OK.

### 2. Kraken2 fixture path
`ClassifierExtractionFixtures.buildFixture(tool: .kraken2, ...)` points at `Tests/Fixtures/kraken2-mini/SRR35517702` directly (line 126) and returns the directory URL as `resultPath`. This matches the flat layout. OK.

### 3. DEBUG hooks via `objc_setAssociatedObject`
Reviewed both `ViralDetectionTableView.swift` (lines +1315-1372 in the diff) and `TaxonomyTableView.swift` (lines +942-999). The pattern:

- Creates a fresh `_TestingXxxStubOutlineDataSource` for each `setTestingSelection` call.
- Retains via `objc_setAssociatedObject(self, &_testingStubKey, stub, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)`.
- Installs as `outlineView.dataSource = stub` and calls `reloadData()` + `selectRowIndexes(...)`.
- Each test instantiates a fresh `ViralDetectionTableView`/`TaxonomyTableView`, so the associated object dies with the view — no cross-test leak.
- `_testingStubKey` is a `private static var UInt8` — per-class key, correctly used as an address sentinel.
- All DEBUG code wrapped in `#if DEBUG` / `#endif`.
- The fileprivate stub structs (`_TestingTaxonomyStubOutlineDataSource`, `_TestingViralStubOutlineDataSource`) are also wrapped in `#if DEBUG`.

**Sound.** No cross-test leakage. Correct retention semantics. Compiles out of Release.

### 4. `testingContextMenu` property
`public var testingContextMenu: NSMenu? { outlineView.menu }` (inside `#if DEBUG`). The VC-level `buildContextMenu()` is called once in init and `outlineView.menu` is set there, so this read-only accessor is sufficient. The tests use it successfully. OK.

### 5. Source-level I1 smoke tests
Reviewed at lines 62-99. Does a plain-text search on the VC source for:
- `"Extract Reads\u{2026}"` string literal
- The action selector name (`contextExtractFASTQ` for TaxTriage/NAO-MGS, `contextExtractReadsUnified` for NVD).

**Regressions caught:** menu title rename, selector rename, deletion of action function, deletion of menu item's title literal.

**Regressions NOT caught:** menu item created but not added to menu via `addItem()`; selector wired to wrong title; action body emptied to no-op; `#if false` block around the whole menu construction; the menu item attached to a menu that is never installed on the outline view.

This is weaker than instantiating the VC. Acceptable for Phase 6 given the VC instantiation cost and the existence of integration-level dynamic coverage elsewhere. Documented tradeoff in lines 56-61. Track for upgrade if integration coverage thins.

### 6. CLI prefix drop count (2 not 3)
The `tokenizeCLIString` helper (lines 465-493) honors single-quoted segments. `OperationCenter.buildCLICommand` shell-escapes `"extract reads"` into `'extract reads'` (one quoted token). Tokenizer produces `["lungfish", "extract reads", "--by-classifier", ...]` — 2 prefix tokens. `dropFirst(2)` leaves `--by-classifier ...` which `ExtractReadsSubcommand.parse(...)` accepts directly. Verified empirically: all 4 BAM-backed I7 tests pass with "Wrote 199 reads" CLI log lines.

### 7. `#file` → `#filePath`
`ClassifierExtractionFixtures.repositoryRoot` at line 40 uses `#filePath`. `assertI4` and `assertI7` use `file: StaticString = #filePath` for failure location passing. Consistent with Swift 6 diagnostics. OK.

### 8. `Package.swift` LungfishCLI dependency
Diff at line 177: `dependencies: ["LungfishApp", "LungfishCLI"]`. `LungfishCLI` depends on `LungfishCore/LungfishIO/LungfishWorkflow` only — **not on LungfishApp** — so no circular dependency. LungfishCLITests already has a separate test target. The addition is minimal and does not break other targets. OK.

## Concurrency audit

- Test class declared `@MainActor` at line 27. All tests inherit MainActor isolation.
- `ClassifierReadResolver` is an `actor` (line 45 in ClassifierReadResolver.swift), so `try await resolver.resolveAndExtract(...)` is a structured actor hop from MainActor — correct.
- `MarkdupService.countReads` is synchronous `static func`, called without `await`. OK.
- `NativeToolRunner.shared.findTool(.samtools)` at fixture line 184 is `async throws`, awaited correctly.
- No `Task.detached`, no `Task { @MainActor in }` from background, no `DispatchQueue.main.async`. Clean.
- The `fastqRecordsSorted(at:)` and `tokenizeCLIString(_:)` static helpers are pure synchronous — no isolation concerns.

No concurrency issues.

## Test isolation audit

**Temp directory cleanup:**
- `buildFixture` creates `fm.temporaryDirectory.appendingPathComponent("clfx-\(tool)-\(UUID())")`.
- Every caller pairs it with `defer { try? FileManager.default.removeItem(at: projectRoot) }` — verified at lines 164, 293, 343, 373.
- For `testI5_allBAMBackedTools_dispatchCorrectFlag`, the `defer` is inside the `for` body, so it runs at end of each loop iteration. Correct.
- The `share(tempDirectory: projectRoot)` case puts the share subdir inside the fixture project root, so it's cleaned up with the parent. OK.

**Resolver instance scoping:** Each test instantiates its own `ClassifierReadResolver()`. Since the resolver is an actor (not a singleton), there's no cross-test state.

**Test hook leakage:** The `objc_setAssociatedObject`-backed stub is associated with a freshly-constructed `ViralDetectionTableView`/`TaxonomyTableView` per test. The associated object's lifetime is bounded by the view's lifetime (which is itself bounded by the test function scope). No leakage across tests.

**Output file cleanup:** I7 uses `guiOut` and `cliOut` temp paths outside the projectRoot, each with their own `defer { try? FileManager.default.removeItem(...) }` block (lines 387, 426). Consistent.

No isolation concerns.

## Suggested commit message for the simplification pass

```
refactor(phase-6): narrow I7 catch scope + strengthen I5 strict/loose assertion
```

Specifically:
1. Change `assertI7` lines 388-399 catch to `catch ClassifierExtractionError.kraken2SourceMissing` (reuse for just Kraken2; other errors propagate).
2. Change `assertI7` lines 432-448 CLI parse/validate/run catches to `throw` (no skip — real regressions should fail).
3. Change `testI5_allBAMBackedTools_dispatchCorrectFlag` line 313-317 from `XCTAssertLessThanOrEqual` to `XCTAssertLessThan` (strict teeth on the markers BAM).
4. Add `XCTAssertFalse(toolsIterated.isEmpty)` at the end of the I5 loop.
5. Optional: narrow the fixture index URL to `sarscov2BAM.appendingPathExtension("bai")`.

Time estimate: 10 minutes. No fixture changes required.

## Simplification pass — disposition

Date: 2026-04-09. Branch: `feature/batch-aggregated-classifier-views`. All changes landed in a single commit (see SHA at the bottom of this section).

### Significant issues

- **[FIXED] I7 `catch` too broad (lines 388-399 + 432-448).** `assertI7` now narrows the GUI-path catch to `catch ClassifierExtractionError.kraken2SourceMissing` only — the documented Phase 7 fixture-incomplete signal. Any other resolver error (samtools failure, destination-not-writable, FASTA conversion, etc.) propagates as a test failure. The three CLI parse/validate/run do/catch/XCTSkip blocks were deleted outright; CLI failures are real regressions and must fail the test. The selection build `do { } catch` was also removed — `defaultSelection` already throws XCTSkip internally when fixtures are missing, so a simple `try` both propagates skips and fails on unexpected errors.

- **[FIXED] I5 strict vs loose uses `<=` where `<` has teeth (lines 313-317).** The per-tool loop keeps `XCTAssertLessThanOrEqual` defensively (handles a hypothetical future fixture with no duplicates/unmapped reads), but `testI5_allBAMBackedTools_dispatchCorrectFlag` now ADDS a strict teeth assertion using NVD directly against the markers BAM: `XCTAssertLessThan(nvdStrict, nvdLoose, ...)`. On the markers BAM, 199 (strict, 0x404) must be strictly less than 202 (loose, 0x400) because the 3 unmapped records distinguish the two flag masks. A regression folding both flag paths to the same mask is now caught.

### Minor issues

- **[FIXED] Source-level I1 tests weak.** Upgraded `testI1_taxtriage/naomgs/nvd_menuItemVisible_sourceLevel` to assert `source.contains("#selector(contextExtractFASTQ")` (or `contextExtractReadsUnified` for NVD) instead of just the bare selector name. The `#selector(` prefix enforces that the method is actually *wired* via `#selector(...)` somewhere in the file — so a regression that deletes the `NSMenuItem(action: #selector(...))` line while leaving an `@objc private func contextExtractFASTQ` orphaned would now fail the test. Not as strong as full VC instantiation, but a free improvement over the original bare-name check.

- **[WONTFIX] String-concatenated `#filePath` paths (lines 63-64).** Acknowledged as brittle but acceptable. Changing these to computed properties on `ClassifierExtractionFixtures` is pure cosmetics and would add maintenance without catching more regressions.

- **[FIXED] I4 count-equality shares dispatch path.** Added a load-bearing comment above the `XCTAssertEqual(outcome.readCount, unique, ...)` in `assertI4` noting that the count-equality is a weak oracle on its own (both sides call `samtools view -c -F 0x404`) and the teeth is in the `< rawTotal` assertion below. Future readers now know where the teeth live.

- **[FIXED] `sarscov2BAMIndex` URL construction inconsistent (line 58).** Changed to `sarscov2BAM.appendingPathExtension("bai")`. Also applied the same pattern to the four inline `URL(fileURLWithPath: bam.path + ".bai")` sites inside `buildFixture` for consistency.

- **[FIXED] I5 empty-iteration guard missing.** Added `var toolsIterated = 0` counter and `XCTAssertFalse(toolsIterated == 0, ...)` after the `for tool in ClassifierTool.allCases where tool.usesBAMDispatch` loop. A refactor that flips all 4 tools off BAM dispatch would now fail the test instead of silently iterating zero times.

### Gate results post-simplification

- `swift build --build-tests`: clean (10.78s).
- `swift test --filter ClassifierExtractionInvariantTests`: **24 tests, 1 skipped, 0 failures in 2.482s** (Kraken2 I7 still correctly skipped via the narrowed `kraken2SourceMissing` path).
- `swift test --filter ClassifierExtractionDialogTests`: **24 tests, 0 failures in 0.072s**.

### Commit

Simplification pass landed as a single commit on `feature/batch-aggregated-classifier-views`. SHA is appended to this section once the commit lands.
