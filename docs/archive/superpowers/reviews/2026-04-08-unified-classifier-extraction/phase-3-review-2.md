# Phase 3 — Adversarial Review #2 (Independent)

**Date:** 2026-04-09
**Commits reviewed:** 6ea1246, b861a9d, 6b3b106
**Reviewer:** independent subagent (clean context, did not read review-1 until after)
**Charter:** Independent post-simplification adversarial review.

## Summary

Phase 3 lands a coherent `--by-classifier` strategy that delegates to `ClassifierReadResolver`, plus the `--exclude-unmapped` extension on `--by-region`. Both authorized deviations (Option C `--by-db` rename and `--read-format`) are correctly applied: I independently verified `GlobalOptions.outputFormat` does declare `--format` (`Sources/LungfishCLI/Options/GlobalOptions.swift:13-17`), and I independently grep'd the codebase for old `--by-db` flag callers — every `--taxid`/`--sample`/`--accession` hit outside `ExtractReadsCommand.swift` belongs to a *different* `ParsableCommand` (`BlastCommand.VerifySubcommand`, `CondaExtractCommand.ExtractSubcommand`), so the rename is watertight.

I ran the test suite and confirmed: `ExtractReadsByClassifierCLITests` reports 29 tests, 0 failures (matches the simplification commit's claim). Full `LungfishCLITests` reports 363 tests, 0 failures. `swift build --build-tests` completes cleanly with no new warnings.

The simplification pass (commit 6b3b106) addresses the critical equals-form walker bug correctly and uniformly across all three flags. I traced edge cases (empty value, multiple equals signs, dangling final flag, walker forward-progress) and found no infinite-loop or off-by-one risks. The pre-flight `classifierResult` check is implemented with deliberately relaxed semantics that match the resolver's NVD sentinel-file pattern; my one concern is that it's almost *too* relaxed (see Significant #1).

## Critical issues

None. The simplification pass closed the equals-form walker bug correctly.

## Significant issues

- [ ] **Pre-flight `classifierResult` check is too forgiving for non-NVD typos.** `ExtractReadsCommand.swift:548-553`. The check passes if `fm.fileExists(atPath: resultPathStr) || parentExists`. For NVD's sentinel-file pattern this is correct, but for `esviritu`/`taxtriage`/`naomgs` (where the user is supposed to pass an actual file) a typo like `--result /etc/passw` (instead of `/etc/passwd`) would still pass the pre-flight because `/etc` exists. The user would then get a confusing lower-level error from the resolver rather than the friendly `Classifier result not found:` message the check is supposed to provide. Fix: branch on `tool.usesBAMDispatch` *and* on whether the tool's expected layout is file-shaped or directory-scanning. Or, simpler: always check the path itself first; only fall through to parent-dir check for `nvd` (the only tool with the sentinel-file pattern). The relaxation should be opt-in per tool, not blanket.

- [ ] **Walker silently accepts `--sample=` with empty value.** `ExtractReadsCommand.swift:661-666`. The `split(_:)` helper returns `("--sample", "")` for the token `--sample=`. The empty string is non-nil, so `if let value` succeeds and a selector is created with `sampleId: ""`. ArgumentParser likely rejects this at parse time (so this path is unreachable in practice), but the walker doesn't validate. Add `value.isEmpty` rejection or assert that the value is non-empty for `--sample`. Defensive but worth tightening so the walker has a single source of truth.

- [ ] **`runByClassifier` does not surface a friendly error when `tool` decode succeeds but the resolver fails on a malformed result file.** `ExtractReadsCommand.swift:582-593`. The `try await resolver.resolveAndExtract(...)` call lets any thrown error bubble straight up to `run()` and out to the caller. The other three strategies do similar (no try/catch around the service call), so this isn't a regression — but Phase 3 is the layer that promised "friendly CLI errors" via `formatter.error(...)`, and the post-resolver path doesn't deliver that for any failure that occurs inside the resolver. Minor; consistent with the rest of the file. Pre-existing pattern.

## Minor issues

- [ ] **Inconsistent closure capture pattern across the four strategies.** `runByClassifier` (line 581) does `let quiet = globalOptions.quiet` and captures the local `quiet` constant in the `@Sendable` progress closure — this is the safer pattern. `runByBAMRegion` (line 455-458), `runByReadID` (line 415-419), and `runByDatabase` (line 509-513) all capture `self.globalOptions.quiet` directly. They compile because `ExtractReadsSubcommand` is a struct of `Sendable` fields and is implicitly `Sendable`. But the inconsistency means: if a future change makes `ExtractReadsSubcommand` non-Sendable (e.g. adding a class-typed field), `runByClassifier` will keep compiling while the other three break. The simplification pass left this mismatch in place (legitimately — its charter forbade touching Phase 1/2 code paths), but it should be a tracked follow-up for Phase 5/6 polish.

- [ ] **`testRun_byClassifier_nonexistentResult_failsWithReadableMessage` accepts a non-`ExitCode` error softly.** `Tests/LungfishCLITests/ExtractReadsByClassifierCLITests.swift:497-507`. The catch block prefers `error as? ExitCode == .failure` but falls through to `XCTAssertFalse("\(error)".isEmpty)`, which is true for almost any error. This is intentional (commented as future-proofing) but means a regression that swaps `ExitCode.failure` for some other thrown type would still pass the test. Tighten by inspecting `error.localizedDescription` or fail explicitly if the error is not an `ExitCode`. The pre-existing assertion that the output file does NOT exist is the real signal, so this is mostly cosmetic.

- [ ] **`makeExtractionOptions()` is `internal` (default access) on a non-public struct.** `ExtractReadsCommand.swift:628-634`. It's exposed to the test target via `@testable import LungfishCLI`. The doc comment says "Exposed (non-private) so tests can assert ..." which is accurate but doesn't note that this widens the default access from `private` to `internal`. The "test seam" pattern is fine — but mark it explicitly with `// MARK: - Test-visible` or place it under the existing `// MARK: - Test hooks` section so future readers don't think it's a public surface contract. It's a 5-line wrapper that doesn't need to be on the production API surface at all.

- [ ] **`buildClassifierSelectors` is `internal` and reachable from outside the file via `@testable import`.** Same access-level concern as above. The plan's Step 7 explicitly warned about the trap of calling it with `nil` rawArgs from a test (would read xctest's argv). The fix was to use the flat arrays in `validate()`. The helper is correctly NOT called from `validate()` (verified at lines 254-255). Production code only calls it from `runByClassifier` with the `effectiveArgs` `#if DEBUG` switch. **No production-side trap remains.** But the helper's `internal` access leaves the door open for a future test that omits the explicit `rawArgs:` argument and accidentally reads xctest's argv. Adding a precondition like `precondition(rawArgs != nil || !ProcessInfo.processInfo.arguments.first!.contains("xctest"), "...")` would be over-engineering, but at least a doc comment warning future test writers would help.

## Test gaps

- **No directory-shaped `--result` test.** Both end-to-end tests pass `fake-nvd.sqlite` (a sentinel filename inside a real directory). The resolver's `resolveBAMURL` `hasDirectoryPath` branch is untested by Phase 3. Disposition correctly defers this to Phase 7 fixture work.

- **No test for `--by-classifier --tool kraken2` end-to-end.** Even a skip-if-fixture-missing scaffold would help. Disposition defers to Phase 7.

- **No round-trip test that the GUI command-string generator can parse its own output.** This is out of scope for Phase 3 (generator lands in Phase 4) but is the load-bearing reason the equals-form walker fix matters.

- **No negative test for `--include-unmapped-mates` actually changing samtools behavior at the resolver level.** The new `testMakeExtractionOptions_includeUnmappedMates_flowsThrough` proves the *option* flows through, but not that the resolver consumes it. Cross-target test concern; defer to Phase 5 round-trip.

- **No test that `outputDir` creation fails gracefully** (e.g. `--output /nonexistent-root/foo.fastq` where the user can't `mkdir -p` `/nonexistent-root`). `run()` line 289 calls `try fm.createDirectory(withIntermediateDirectories: true)` which will throw out of `run()` directly. Pre-existing pattern across all four strategies.

- **Walker is untested with `--sample=` (empty value)** — see Significant #2 above.

## Positive observations

- **Walker fix is correct under all the edge cases I probed.** I traced: equals-form (`--sample=A`), space-form (`--sample A`), mixed-form within one argv, multi-equals (`--sample==A`), dangling-final-flag (`--sample` at end of argv), and `default`-fall-through. In every case, `i` advances by at least 1 per iteration (forward progress guaranteed), and the only case that doesn't `continue` after the switch — the inner `if let value` failing — falls through to `i += 1` at the loop bottom. **No infinite-loop risk.** No off-by-one.

- **`#if DEBUG testingRawArgs` hook is correctly compiled out of Release.** Both the field declaration (`ExtractReadsCommand.swift:187-197`) and the read site in `runByClassifier` (`559-563`) are `#if DEBUG`-gated. A Release build sets `effectiveArgs = nil` and the helper falls through to `CommandLine.arguments.dropFirst()`. There is **no production code path** that reads `testingRawArgs` unconditionally. I confirmed this by reading the file end-to-end. The doc comment warning that the test target depends on Debug builds is the right level of disclosure.

- **`validate()` correctly uses the flat parsed arrays** (`classifierAccessionsRaw.isEmpty`, `classifierTaxonsRaw.isEmpty`) and does NOT call `buildClassifierSelectors`. The inline comment at lines 249-253 explains exactly why: a default-args call to the helper inside `validate()` would read xctest's argv during tests and false-negative. This is the correct fix to the gotcha called out in plan Step 7.

- **`samtoolsExcludeFlags` test assertion is correct.** `testMakeExtractionOptions_defaults_areFastqAndNoMates` asserts `samtoolsExcludeFlags == 0x404` (default), and `testMakeExtractionOptions_includeUnmappedMates_flowsThrough` asserts `0x400`. I verified `Sources/LungfishWorkflow/Extraction/ExtractionDestination.swift:115-117` returns `0x404` by default and `0x400` with the flag set. Tests are not testing tautologies — they're pinning the actual behavior.

- **`testParse_byDb_oldFlagNames_areRejected` is correctly tightened.** It passes `--db-accession NC_000913` alongside `--taxid 562`, satisfying the `validate()` "at least one tax-id or accession" requirement so the parser reaches its unknown-option check on `--taxid`. The assertion pattern-matches on `"unknown" || "unexpected"` in the error message. A regressed rename (where `--taxid` parses successfully because the old `@Option` is still present) would NOT throw the unknown diagnostic and the test would correctly fail. This is genuinely tighter than the pre-simplification version.

- **Test fixture path correction is documented inline** (`Tests/LungfishCLITests/ExtractReadsByClassifierCLITests.swift:550-552` uses `test.paired_end.sorted.bam` not `test.sorted.bam`). Right place, right level of detail.

- **`BAMRegionMatcher.readBAMReferences` is used to discover the reference name at runtime** (lines 573-577, 613-617) instead of hard-coding `MN908947.3`. Future-proofs against fixture BAM header changes.

- **Defensive `.clipboard, .share` branches in `runByClassifier`** (lines 604-612) emit a `formatter.error` and throw `ExitCode.failure` rather than `fatalError`. The inline comment explains they are dead code but kept defensive. Good.

- **Test count and aggregate test suite are accurate.** The simplification commit message claims 29 tests in `ExtractReadsByClassifierCLITests` (was 20 → 29 after simplification, a delta of 9 new tests). I verified by running the filter: `Executed 29 tests, with 0 failures`. The aggregate `LungfishCLITests` suite reports 363 tests, 0 failures, also matching the commit message.

- **Commit hygiene is clean.** Commit 6ea1246 = feat (production code + tests). Commit b861a9d = test (end-to-end runs only). Commit 6b3b106 = refactor (simplification, with co-located review-disposition append). Each commit is logically cohesive and bisectable.

- **MEMORY.md concurrency rules respected.** No `Task { @MainActor in }` from background context, no `DispatchQueue.main.async` access to MainActor state, no `Task.detached` awaits on @MainActor methods. The `formatReadsBytes` helper at the bottom of the file is correctly a free function (per the MEMORY.md gotcha about `[weak self]` closures + Swift 6 method resolution).

- **macOS 26 API rules respected.** Pure CLI code; no AppKit; no NSSplitView/NSImage/UserDefaults concerns.

## Forwarded from Phase 2 review-2

The four dead `ClassifierExtractionError` cases (`cancelled`, `kraken2TreeMissing`, `destinationNotWritable`, `fastaConversionFailed`) remain undeleted. The Phase 3 simplification commit message (6b3b106) explicitly defers them to Phases 4-7 with rationale. The deferral is documented and consistent with the Phase 2 review-2 disposition. **Acceptable.**

## Divergence from review-1

### Issues I found that review-1 missed

- **Significant #1: Pre-flight check is too forgiving for non-NVD typos.** Review-1 asked for a `fm.fileExists` check and the simplification pass added one. Review-1 did not notice that the check's relaxed parent-directory fallback only makes semantic sense for NVD's sentinel-file pattern, and that for esviritu/taxtriage/naomgs the relaxation lets typos slip through. This is a genuine new finding from independent probing.

- **Significant #2: Walker accepts `--sample=` with empty value.** Review-1's walker analysis stopped at "the equals form is broken" and didn't probe what happens with empty inline values. The `split(_:)` helper returns `(key, "")` for `--sample=`, and the `if let value` check passes for empty strings. ArgumentParser probably catches this at parse time, but the walker has no validation.

- **Minor #1: Closure capture inconsistency across the four strategies.** Review-1 noted the positive that `runByClassifier` uses `let quiet = ...` capture, but did not call out that `runByBAMRegion`/`runByReadID`/`runByDatabase` still capture `self.globalOptions.quiet` directly — leaving an inconsistent baseline for the next Sendable-tightening change. Worth tracking even if not blocking.

- **Minor #3: `makeExtractionOptions()` access-level note.** Review-1 asked for the helper to be added (which it was) but didn't note that `internal` widens the surface beyond `private`. Cosmetic.

### Issues review-1 found that I did not

- **Walker's silent fall-through on dangling final flag.** Review-1 flagged this as a Significant. I traced the same code path independently and concluded ArgumentParser already rejects dangling options at parse time, so the walker's silent skip is unreachable. The simplification pass marked it FIXED (by side effect) and left a comment. I agree with that disposition. Marginal disagreement on severity, not on existence.

- **Plan Task 3.3 Step 1 `testReadExtractionService_extractByBAMRegion_defaultFlagFilter_unchanged` skip.** Review-1 noted this plan-vs-implementation gap. I didn't independently verify against the plan's task list — review-1's catch is more thorough on plan-conformance.

- **`runByClassifier` cancellation not wired.** Review-1 flagged this as Significant; the disposition is WONTFIX deferred to Phase 4/5. I noted the same as a Phase 4/5 forwarded item but did not pin it as a Phase 3 issue. Severity disagreement only.

### Verdict

**Phase is ready to close** with the following caveats forwarded to subsequent phases:

1. **Significant #1 (pre-flight too forgiving for non-NVD)** is a real correctness gap that should be fixed in Phase 4 or Phase 5 once the GUI is calling the same code path. It does not block Phase 3 because: (a) the failure mode is "user gets a confusing error from the resolver instead of a friendly error from the CLI" — i.e. degraded UX, not data loss; (b) the lower-level resolver still catches the bad path and refuses to extract; (c) the existing end-to-end test (`testRun_byClassifier_nonexistentResult_failsWithReadableMessage`) does pin the friendly-error path for the *parent-doesn't-exist* case, so the most common typo is covered.

2. **Significant #2 (walker accepts empty inline value)** is reachable only via `--sample=`. ArgumentParser is the gating layer in practice. Worth a one-line `value.isEmpty` rejection in the walker as defense-in-depth, but not blocking.

3. **Minor #1 (closure-capture inconsistency)** is cosmetic and pre-existing. Forward to Phase 5/6 cleanup.

4. **All four dead `ClassifierExtractionError` cases** remain deferred to Phase 4/5/7 per the documented disposition. Phase 3 has no natural path to throw them and the deferral is correct.

5. **Test count, build status, and behavior** all verify cleanly. 29 `ExtractReadsByClassifierCLITests`, 363 `LungfishCLITests`, 0 failures, clean build.

The critical equals-form walker bug from review-1 is correctly fixed. Both authorized deviations are correctly implemented. The simplification pass introduced no regressions. Commit hygiene is clean and bisectable.

**Phase 3 gate closes. Proceed to Phase 4.**

## Gate-3 disposition (controller's resolution)

**Verdict:** Phase 3 is **closed and ready to advance to Phase 4** with the
following resolutions. No additional commits are required; both review-2
findings are forwarded to Phase 4 with explicit tracking.

### Significant #1 — Pre-flight `classifierResult` check too forgiving for non-NVD tools (DEFERRED to Phase 4)

Review-2 correctly points out that the relaxed parent-directory fallback
semantics only make sense for NVD's sentinel-file pattern. For
esviritu/taxtriage/naomgs (file-shaped result paths), a typo like
`/etc/passw` would pass the pre-flight because `/etc` exists, then produce
a confusing lower-level error from the resolver.

The correct fix is to branch the pre-flight on `tool.usesBAMDispatch` and
on whether the tool's expected layout is file-shaped (esviritu,
taxtriage, naomgs) or directory-scanning (nvd). This requires tool-level
layout metadata that does not currently exist on `ClassifierTool`.

Phase 4 owns the GUI dialog + `TaxonomyReadExtractionAction` orchestrator,
which is the natural place to define the per-tool result-layout contract
(the dialog must present the file-chooser with the right shape for each
tool). Adding the metadata to `ClassifierTool` and tightening the CLI
pre-flight to use it is a coordinated change that belongs to the same
implementer.

**Forwarded to Phase 4 review #1:** verify the per-tool result-path
layout contract is defined on `ClassifierTool` (or equivalent) and that
`ExtractReadsCommand.swift:548-553` uses it for a shape-aware pre-flight
check. Until then, the failure mode is "user gets a confusing error from
the resolver" — degraded UX, not data loss. The resolver itself still
refuses to extract.

### Significant #2 — Walker accepts `--sample=` with empty inline value (DEFERRED to Phase 4)

Reachable only via `--sample=` (or `--accession=` / `--taxon=`).
ArgumentParser itself rejects `--sample=` at parse time with an "unable
to parse value" error, so the walker's lack of a non-empty check is
unreachable in practice.

A one-line `value.isEmpty` rejection in `split(_:)` would be defense-
in-depth. The fix is trivial but not urgent because ArgumentParser is
the gating layer.

**Forwarded to Phase 4 review #1:** if the GUI command-string generator
ever emits `--sample=` (it should not, but Phase 4 adds that generator),
verify the walker is tightened to reject empty inline values. Phase 4
review #1 should grep the Phase 4 generator for `"=\("` template patterns
and confirm none produce empty strings.

### Minor #1 — Closure capture inconsistency across the four strategy methods (DEFERRED to Phase 5/6 polish)

`runByClassifier` uses the safer `let quiet = globalOptions.quiet`
pattern; `runByReadID`/`runByBAMRegion`/`runByDatabase` capture
`self.globalOptions.quiet` directly. Both compile and both work today.

Consolidation would touch Phase 1/2 code paths (the three pre-existing
strategy methods), which is out of scope for Phase 3 per the plan.
Phase 5/6 polish can harmonize the capture pattern as part of a broader
Sendable-tightening pass.

**Forwarded to Phase 5/6:** when refactoring the four `runBy*` methods
for the final `ClassifierCLIRoundTripTests` work, harmonize the closure
capture pattern across all four.

### Minor #2 — Soft fallback in nonexistent-result error test (WONTFIX)

The test at `ExtractReadsByClassifierCLITests.swift:497-507` has a
primary assertion (error is `ExitCode.failure`) and a soft fallback
(error is non-empty). Review-2 notes the fallback would pass for almost
any thrown error. This is intentional future-proofing: if a future
refactor changes the thrown error type, the test still catches the
regression via the separate assertion that the output file does NOT
exist. The soft fallback is belt-and-suspenders, not the primary signal.

**WONTFIX.** The test is cosmetically soft but functionally correct.

### Minor #3 — `makeExtractionOptions()` and `buildClassifierSelectors` `internal` access (DOCUMENTED, no change)

Both helpers are `internal` because `@testable import LungfishCLI` needs
to call them. Review-2 suggests a `// MARK: - Test hooks` section label
and/or a precondition warning against calling `buildClassifierSelectors`
with a default `rawArgs: nil` from tests.

The existing inline doc comments on both helpers already explain the
test-seam intent and the xctest-argv trap. Adding a section marker is
purely cosmetic and would touch the file layout. **No code change.**
Future readers have sufficient breadcrumbs from the existing comments.

### Test gaps — all four deferred per the original disposition

- Directory-shaped `--result` test → Phase 7 fixture work.
- Kraken2 end-to-end test → Phase 7 fixture work.
- GUI command-string round-trip → Phase 5 by design.
- `--include-unmapped-mates` resolver-level flow-through → Phase 5 round-trip.
- Walker `--sample=` empty-value test → bundled with Significant #2.
- Output-dir creation failure → pre-existing pattern, defer to Phase 5/6 polish.

None of these block Phase 3 closure. All are tracked as forwarded items
to Phase 4/5/7.

### Forwarded action items (summary)

- **Phase 4 review #1:** verify (a) the per-tool result-path shape
  contract is defined on `ClassifierTool` and used by
  `ExtractReadsCommand.swift:548-553` for tool-aware pre-flight; (b) the
  walker rejects empty inline values (`--sample=`); (c) the GUI
  command-string generator emits `--read-format` (not `--format`),
  `--db-sample`/`--db-accession`/`--db-taxid` (not `--sample` /
  `--accession` / `--taxid`), and does not produce `--foo=` empty inline
  values.
- **Phase 5/6 polish:** harmonize the closure-capture pattern across
  the four `runBy*` methods.
- **Phase 5 round-trip:** verify `--include-unmapped-mates` on the CLI
  flows all the way through to the resolver's `samtoolsExcludeFlags
  == 0x400` behavior (not just the parse surface).
- **Phase 7 fixtures:** complete the kraken2-mini fixture for the
  `testExtractViaKraken2_fixtureProducesFASTQ` integration test, and add
  a directory-shaped NVD fixture so `ClassifierReadResolver.resolveBAMURL`'s
  `hasDirectoryPath` branch is exercised.

### Gate-3 closure

All Phase 3 commits (`6ea1246`, `b861a9d`, `6b3b106`) stand unchanged.
The review files (`phase-3-review-1.md` and `phase-3-review-2.md`) will
be committed together in a separate review-closure commit before Gate 4
runs. Phase 3 proceeds to Gate 4.

**Phase 3 Gate 3: CLOSED.**
