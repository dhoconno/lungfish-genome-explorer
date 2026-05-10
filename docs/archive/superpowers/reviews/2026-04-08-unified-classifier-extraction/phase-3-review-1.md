# Phase 3 — Adversarial Review #1

**Date:** 2026-04-09
**Commits reviewed:** 6ea1246, b861a9d
**Reviewer:** general-purpose subagent
**Charter:** Independent adversarial review before simplification pass.

## Summary

Phase 3 lands a workable `--by-classifier` strategy that wraps `ClassifierReadResolver`, plus the `--exclude-unmapped` extension for `--by-region`. Both authorized deviations (Option C flag rename and `--read-format`) are implemented correctly and internally consistent: the property names `sample`/`taxIds`/`accessions` on the `--by-db` side are preserved verbatim so `runByDatabase` is byte-identical to the Phase 2 baseline, and `--read-format` is correctly used by both the property declaration (line 156) and the two end-to-end tests. The main correctness gap is the raw-argv walker — it only handles space-separated flags, so `--sample=A` (equals form) silently fails grouping and nil-samples the selector. There are also several test gaps (see below), a missing pre-flight file-existence check for `--result`, and the four dead `ClassifierExtractionError` cases forwarded from Phase 2 review-2 remain dead.

## Critical issues (must fix before moving on)

- [ ] **Raw-argv walker does not handle `--foo=bar` equals-style arguments.** `ExtractReadsCommand.swift:604-639`. The `switch token` only matches the literal strings `"--sample"`, `"--accession"`, `"--taxon"`. ArgumentParser accepts both `--sample A` and `--sample=A` — if the user (or the Phase 4 GUI command-string generator, or a shell-quoted test) writes `--sample=A`, `classifierSamples` will still populate with `["A"]` (so `validate()` passes), but the walker skips the `"--sample=A"` token as `default` and produces `selectors == []`. The resolver then throws `ClassifierExtractionError.zeroReadsExtracted` from a user's well-formed command. Fix: check `token.hasPrefix("--sample=")`/`"--accession="`/`"--taxon="` and split on the first `=`, using that value instead of reading `argv[i+1]`. Add parse tests for the equals-form for all three flags. This is load-bearing because Phase 4 generates the CLI-command string programmatically and Phase 5's round-trip test will parse it back — if the Phase 4 generator ever uses the equals form, round-trip silently breaks.

## Significant issues (should fix)

- [ ] **No pre-flight existence check on `classifierResult`.** `ExtractReadsCommand.swift:508-518`. `runByReadID` (line 361), `runByBAMRegion` (line 421), and `runByDatabase` (line 461) all do `guard fm.fileExists(atPath: …) else { print formatter.error; throw ExitCode.failure }` as their first action. `runByClassifier` does not. The resolver will still fail, but with a less-readable error (and for tools like `nvd` that scan a directory, a typo'd path may resolve to a confusing `bamNotFound` instead of "result not found"). Add a symmetric check after line 518.

- [ ] **Raw-argv walker treats `i + 1 < argv.count` as a silent fall-through.** `ExtractReadsCommand.swift:608, 616, 625`. If the user passes `--sample` as the final token with no value, `i + 1 < argv.count` is false, the `if` block is skipped, and `i += 1` runs at the bottom of the loop body — effectively ignoring the dangling flag. ArgumentParser itself would reject this at parse time (a lone `--sample` missing a value throws), so the condition is dead defensive code in practice. But if ArgumentParser's behavior ever changes, or if a future edit removes the `@Option` declaration, the walker silently drops dangling values. Consider deleting the inner guard or asserting it never triggers. Not urgent but fragile.

- [ ] **`classifierResult` file vs directory semantics are untested.** The resolver's `resolveBAMURL` (`ClassifierReadResolver.swift:254-264`) has a `resultPath.hasDirectoryPath` branch — pass a file and it uses the parent, pass a directory and it uses the path itself. Neither end-to-end test exercises the directory path (both pass `fake-nvd.sqlite`, a file). A test that passes the containing directory as `--result` would pin the behavior and catch future regressions.

- [ ] **`runByClassifier` does not wire cancellation.** No `Task.handleCancel`, no SIGINT handler. The resolver's `cancelled` error case is forwarded from Phase 2 as dead code. Even a minimal "on SIGINT, call `task.cancel()` and catch `CancellationError` as `ExitCode.failure` with a readable message" would give the CLI a consistent Ctrl+C story. Current behavior: Ctrl+C leaves temp files and may orphan the samtools child process. Phase 3 likely can't fix that cleanly (the whole codebase may not have a CLI-wide signal handler pattern), but it should at least be noted as a test gap for Phase 5.

- [ ] **`testParse_byDb_oldFlagNames_areRejected` cannot distinguish rename-succeeded from rename-failed.** `ExtractReadsByClassifierCLITests.swift:264-278`. Passing `--taxid 562` with `--by-db`: if the rename succeeded, parse throws "unknown option". If the rename had FAILED (old `@Option(name: .customLong("taxid"))` still present), parse would succeed but `validate()` would throw "At least one --db-taxid or --db-accession is required" because the NEW property `taxIds` is empty. Both paths pass the bare `XCTAssertThrowsError`. Tighten the assertion by inspecting the error message OR add a positive assertion that `--taxid` produces an "unrecognized" diagnostic. (The positive `testParse_byDb_renamedFlags_validate` test DOES pin the new names, so the rename isn't totally unprotected — but the rejection test is weaker than it looks.)

## Minor issues (nice to have)

- [ ] **`testingRawArgs` escapes `#if DEBUG` only via the struct field.** `ExtractReadsCommand.swift:182-187`. The field is `#if DEBUG`-gated, but `runByClassifier`'s `#if DEBUG let effectiveArgs = testingRawArgs` block (line 524-528) is too — so release builds correctly fall through to `CommandLine.arguments`. Good. But note: both tests that set `cmd.testingRawArgs = argv` (lines 357, 401) will fail to compile in a Release build of the test target. Since xctest builds in Debug by default this is fine, but a comment in the `#if DEBUG` block noting that the test file depends on Debug builds would prevent surprise.

- [ ] **`strategyParameters["format"]`** `ExtractReadsCommand.swift:670`. Uses the key `"format"` even though the CLI flag is now `--read-format`. The metadata bundle ends up with `format: fastq` instead of `readFormat: fastq`, which is inconsistent with the flag spelling. If anything downstream consumes this metadata by key it could confuse readers. Rename to `readFormat` for consistency, OR add a comment explaining it's a semantic key independent of the CLI spelling.

- [ ] **Duplication across `runByReadID` / `runByBAMRegion` / `runByDatabase` / `runByClassifier`.** Each strategy has the same "print header → print key-value table → call service → return result" shape. Four-way duplication is tolerable, but the pattern would benefit from a small `StrategyContext` helper or a protocol. Not blocking. The simplification pass should decide whether to consolidate or leave it.

- [ ] **`classifierSamples` is declared but never read.** `ExtractReadsCommand.swift:144`. It's used for the ArgumentParser side (so the parser accepts `--sample` and doesn't error), but `validate()` uses `classifierAccessionsRaw`/`classifierTaxonsRaw` and `buildClassifierSelectors` uses the raw argv walk. The array is pure parser-appeasement. A comment at the declaration noting "declared for parse-side acceptance only; grouping is reconstructed by buildClassifierSelectors" would make this less confusing. (The comment at line 137-141 explains the dance but doesn't explicitly call out that `classifierSamples` is unused beyond the parse validator.)

- [ ] **`runByClassifier` closure captures `quiet` via local let, which is the correct pattern** (line 550) — just calling it out as a positive that the closure does NOT capture `self.globalOptions` inside the `@Sendable` progress closure. The plan's original sketch (line 3314) captured `self.globalOptions.quiet` inside the closure, which would have been a Sendable-capture problem. The implementation fixed it correctly.

## Test gaps

- **No test for the equals-style flag parsing** (`--sample=A`, `--accession=NC_001`, `--taxon=9606`). Directly related to the critical issue above.
- **No test that `--include-unmapped-mates` on a non-kraken2 tool actually flows to `ExtractionOptions.includeUnmappedMates: true`** — `testParse_byClassifier_nonKraken2_acceptsIncludeUnmappedMates` only asserts parse success, not that the flag changes `samtoolsExcludeFlags` at the resolver level. A Phase 5 round-trip test would catch this but Phase 3 does not.
- **No test for `--by-classifier --tool kraken2` end-to-end**, not even a negative one. Phase 2 review-2's known-incomplete kraken2 fixture is the reason, but Phase 3 could have added a skip-if-fixture-missing test as a scaffold so Phase 4 can wire a real one. The `includeUnmappedMates` rejection for kraken2 is parse-level only.
- **No test covering mutual exclusion of `--by-classifier` with each of `--by-id` and `--by-db` individually.** `testParse_byClassifier_multipleStrategiesFails` only tests `--by-classifier` + `--by-region`. Adding two more one-line tests would pin all three pairs.
- **No test for directory-shaped `--result`** (vs file-shaped). Both end-to-end tests pass `fake-nvd.sqlite` (file).
- **No test for error surfacing when `classifierResult` points to a nonexistent path.** The resolver will throw `bamNotFound` or similar; the CLI should translate it to a readable `formatter.error(…)` + `ExitCode.failure`. Currently, `runByClassifier` just lets the throw propagate out of `run()`, so the user sees a raw Swift error dump, not a friendly message.
- **No negative test that the clipboard/share branches in the outcome switch are genuinely unreachable.** They're defensive dead code (line 574-577), which is fine, but a comment would help the simplification pass decide whether to delete them.
- **The Phase 3 plan's Task 3.3 Step 1 explicitly calls for `testReadExtractionService_extractByBAMRegion_defaultFlagFilter_unchanged`** (plan line 3573-3582). The implementer skipped it, citing it "would add zero signal over the Phase 1 FlagFilterParameterTests." That reasoning is sound (Phase 1's `FlagFilterParameterTests` does pin the 0x400 default), but the skip should be cross-referenced in the Phase 3 plan's checklist so the gate-4 review knows it's deliberate.

## Positive observations

- The `@Sendable` progress closure in `runByClassifier` (lines 557-561) correctly captures `quiet` as a local let rather than `self.globalOptions.quiet`, avoiding the Sendable/Actor-isolation trap the plan sketch would have introduced. The plan at line 3314 wrote `self.globalOptions.quiet` inside the closure — this is a silent fix.
- The audit for the Option C rename is actually complete (within the load-bearing scope). I grep'd `Sources/` and `Tests/` for `--sample`, `--taxid`, `--accession`, and every hit outside `ExtractReadsCommand.swift` is on a DIFFERENT command (`BlastCommand.VerifySubcommand` with its own `@Option(name: .customLong("taxid"))` for blast-verify, `CondaExtractCommand`/`ExtractSubcommand` with its own `--taxid` — these are independent `ParsableCommand` types so no collision). The rename is watertight.
- The `classifierResult` local variable is captured by value into the closure (`resultPath` line 518), avoiding any actor-hop issues.
- The `run()` method's bundle-wrapping and summary-print ladder works unchanged for all four strategies because `runByClassifier` correctly translates `ExtractionOutcome` back to `ReadExtractionResult`. Byte-identical downstream code path for the three pre-existing strategies.
- The fixture BAM filename fix (`test.paired_end.sorted.bam` vs the plan's `test.sorted.bam`) is noted inline in the test (`ExtractReadsByClassifierCLITests.swift:313-315`), which is exactly the right place for that correction.
- Validation uses the flat `classifierAccessionsRaw`/`classifierTaxonsRaw` arrays (lines 244-245) instead of calling `buildClassifierSelectors` — matches the plan's Step 7 course-correction and avoids the CommandLine.arguments-in-test-context false-negative trap. The inline comment at lines 239-243 explains exactly why.
- Both end-to-end tests use `BAMRegionMatcher.readBAMReferences` to discover the reference name at runtime rather than hard-coding `MN908947.3` — future-proofs against fixture BAM header changes.

## Forwarded from Phase 2 review-2 — resolution

All four unused `ClassifierExtractionError` cases remain dead in Phase 3. The disposition from Phase 2 said "Phase 5/3 reviewers: when wiring up the GUI/CLI, verify that the four currently-unused cases are either thrown from appropriate user-facing paths or deleted from the enum." Phase 3 is the CLI surface, and none of the four is thrown from the CLI layer:

- **`cancelled`** — still dead. CLI does not wire SIGINT/Ctrl+C handling in `runByClassifier`, and the resolver does not check `Task.isCancelled` at any of its yield points. Recommend: Phase 4 (GUI orchestrator) or Phase 5 (final polish) is responsible. Phase 3 leaves it dead. **Defer to Phase 4.**
- **`kraken2TreeMissing`** — still dead. Would be thrown from the `extractViaKraken2` path if the taxonomy tree file were missing, but the actual resolver code path (`TaxonomyExtractionPipeline` wrapping) never constructs this error — it bubbles up as a lower-level `ClassificationResult.load` error. Either the resolver should translate the lower-level error or the case should be deleted. **Phase 3 cannot fix; recommend deletion or re-raise in Phase 4 kraken2 wiring.**
- **`destinationNotWritable`** — still dead. Could be thrown from the CLI by a pre-flight check on `outputURL`'s parent directory, but Phase 3's CLI pattern is "`fm.createDirectory(at: outputDir, withIntermediateDirectories: true)` with throws" (line 279) and then let the resolver fail. The case is redundant with FileManager's own errors. **Recommend deletion from the enum.**
- **`fastaConversionFailed`** — still dead. Would be thrown from the FASTQ → FASTA streaming helper if a record was malformed. The Phase 3 test `testRun_byClassifier_format_fasta_endToEnd` exercises the conversion path but only positively; there is no test that forces a malformed FASTQ through. If the helper does not actually throw this, the case is dead. **Recommend Phase 4/5 audit whether the helper throws it; delete if not.**

Phase 3 review concludes: all four remain dead, all four should be raised to Phase 4/5 for final disposition. Phase 3's CLI handler has no natural path to throw any of them.

## Verification of the two authorized deviations

### Option C — --by-db flag rename

The rename is cleanly applied. Verification:

- `Sources/LungfishCLI/Commands/ExtractReadsCommand.swift:116-125` — four `@Option` declarations use `--db-sample`, `--db-taxid`, `--db-accession`, `--max-reads`. Property names (`sample`, `taxIds`, `accessions`, `maxReads`) are unchanged, so `runByDatabase` body at lines 452-504 is character-for-character identical to Phase 2 baseline except for the closure formatting. Confirmed via `git show 3560cf6:Sources/LungfishCLI/Commands/ExtractReadsCommand.swift`.
- `ValidationError` text at line 224 now reads `"At least one --db-taxid or --db-accession is required with --by-db"`. Matches.
- `DocComment` at line 38 updated to `--db-sample S1 --db-taxid 12345`. Matches.
- `CommandConfiguration.discussion` at lines 62-65 updated to mention `--db-sample, --db-taxid, --db-accession`. Matches.
- Help strings on each `@Option` (lines 116, 119, 122) say "(for --by-db)". Matches.

Audit of old flag names:
- `Sources/` grep for `"--sample"` / `"--taxid"` / `"--accession"` literals in `@Option` declarations: zero hits in `ExtractReadsCommand.swift` for `--by-db` use. Other commands (`BlastCommand.VerifySubcommand`, `CondaExtractCommand.ExtractSubcommand`) have their own independent `--taxid`/`--accession` declarations, which live in separate `ParsableCommand` types and do not conflict with `ExtractReadsSubcommand`.
- `Tests/` grep: every `--taxid` hit (in `CLICommandTests.swift` and `DbExtractCommandTests.swift`) is for `BlastCommand.VerifySubcommand.parse(…)` or `ExtractSubcommand.parse(…)` — different commands. No external caller of `ExtractReadsSubcommand` uses `--taxid`, `--sample`, or `--accession` for the `--by-db` strategy. Audit holds.

Test coverage:
- `testParse_byDb_renamedFlags_validate` at `ExtractReadsByClassifierCLITests.swift:246-262` positively asserts that `--db-sample S1 --db-taxid 562 --db-accession NC_000913` parses and validates cleanly. PINS the new names.
- `testParse_byDb_oldFlagNames_areRejected` at line 264-278 negatively asserts that `--taxid 562` with `--by-db` throws. But as noted in significant issues, this assertion is ambiguous (it would also throw from `validate()` if the rename had failed). The positive test is the real pin; the negative test is redundant in a good-path build but at least doesn't lie.

Verdict: **Option C rename is correctly implemented.** No missed call sites. Byte-identical behavior for the `--by-db` strategy.

### --read-format vs --format

The deviation is cleanly applied. Verification:

- `Sources/LungfishCLI/Commands/ExtractReadsCommand.swift:152-157` contains an inline 5-line comment explaining the rationale (`GlobalOptions.outputFormat` already declares `--format`, two same-name `@Option`s would collide at parse time). The comment is correct: `GlobalOptions.swift:13-17` does declare `@Option(name: .customLong("format")) var outputFormat: OutputFormat = .text`. Two `--format` declarations in the same `ParsableCommand` would fail ArgumentParser's parse-time validator.
- Line 156 uses `@Option(name: .customLong("read-format"))` with default `"fastq"`.
- `validate()` at line 261 uses `--read-format` in the error text.
- Both end-to-end tests (lines 144, 215, 397) use `--read-format`.
- The FASTA end-to-end test (lines 388-390) has an inline comment explaining the deviation, which is exactly the right place to document it for Phase 4/5 readers.

Phase 4/5 implication:
- `docs/superpowers/plans/2026-04-08-unified-classifier-extraction.md` references `--format` at lines 4498, 4715, 6877, 6934 (GUI command-string generator and round-trip test). These are inside Phase 4/5 code blocks. Phase 3 cannot modify them, but those code snippets will need to emit/expect `--read-format` when Phase 4/5 lands. A note at the top of the plan's Phase 4 or Phase 5 section, or a forward reference from Phase 3's summary doc, would help — but Phase 3 is out of scope for plan edits.
- The end-to-end test's inline comment (`ExtractReadsByClassifierCLITests.swift:388-390`) is the best single source of truth for the deviation inside the code tree. Phase 4/5 reviewers will see it during their code-read.

Verdict: **The `--read-format` deviation is correctly implemented.** The only follow-up is that Phase 4/5 will need to use `--read-format` in the generated CLI-command string and the round-trip test, which is a forward dependency that Phase 3 cannot control but has clearly flagged.

## Suggested commit message for the simplification pass

`refactor(phase-3): harden equals-style arg walker + add result-path existence check`

(The raw-argv walker's `--foo=bar` gap is the single biggest simplification-pass target; secondary targets are the missing `classifierResult` fm.fileExists guard and the optional four-way strategy-method consolidation. The four dead `ClassifierExtractionError` cases are Phase 4/5 business.)

## Simplification pass — disposition

Commit: see git log for SHA (refactor(phase-3-simplification): harden equals-style arg walker + result-path guard).

### Critical

- **Raw-argv walker does not handle `--foo=bar` equals-style arguments.** **FIXED.** `buildClassifierSelectors(rawArgs:)` now factors each token into `(key, inlineValue)` via a `firstIndex(of: "=")` split. When an inline value is present the walker consumes one token; otherwise it falls back to the space-separated form and consumes two. Applies uniformly to `--sample`, `--accession`, and `--taxon`. New tests pin all three flags in the equals form plus a mixed-form test (`testParse_byClassifier_equalsForm_sampleAndAccession`, `testParse_byClassifier_equalsForm_taxon`, `testParse_byClassifier_mixedForm_spaceAndEquals`).

### Significant

- **No pre-flight existence check on `classifierResult`.** **FIXED.** `runByClassifier` now calls `fm.fileExists(atPath: resultPathStr)` before constructing the resolver. The check is slightly relaxed vs the other three strategies because the resolver semantically accepts "sentinel file whose parent directory contains the BAMs" (for nvd), so the check passes if EITHER the path itself OR its parent directory exists. The failure path prints `formatter.error("Classifier result not found: ...")` and throws `ExitCode.failure`. New test `testRun_byClassifier_nonexistentResult_failsWithReadableMessage` pins the behavior.

- **Raw-argv walker treats `i + 1 < argv.count` as a silent fall-through.** **FIXED (as a side effect).** The rewritten walker has a single unified "resolve value" block that yields `nil` for the dangling-final-flag case, and the switch's `guard let value` falls through to `i += 1` at the bottom. The behavior is the same (silent skip) but the intent is now explicit: ArgumentParser rejects dangling options at parse time so this path remains defensive dead code. Left with an inline comment explaining why rather than asserting or crashing.

- **`classifierResult` file vs directory semantics are untested.** **WONTFIX (deferred to Phase 7).** Adding a directory-shaped fixture invocation requires either reshaping the existing sarscov2 fixture copy or introducing a second layout, both of which are fixture work and Phase 2 review-2 explicitly forwarded fixture work to Phase 7. The file-shaped end-to-end tests still cover the code path; a directory-shaped end-to-end would not exercise a different CLI-layer branch (the branching is internal to `ClassifierReadResolver.resolveBAMURL`).

- **`runByClassifier` does not wire cancellation.** **WONTFIX (deferred to Phase 4/5).** The CLI codebase has no existing SIGINT/`Task.handleCancel` pattern to extend, so retrofitting one for `--by-classifier` alone would be scope creep and inconsistent with the other three strategies (which also lack cancellation). The `ClassifierExtractionError.cancelled` case remains dead; Phase 4 (GUI orchestrator, which has a natural cancel button) or Phase 5 (final polish) is responsible for the codebase-wide pattern.

- **`testParse_byDb_oldFlagNames_areRejected` cannot distinguish rename-succeeded from rename-failed.** **FIXED.** The test now passes an additional `--db-accession NC_000913` to satisfy `validate()`'s "at least one of tax-id/accession" requirement, which forces ArgumentParser to reach its unknown-option diagnostic on `--taxid` instead of short-circuiting on the validation error. The assertion then pattern-matches on `fullMessage(for: error).lowercased().contains("unknown")`, so a regressed rename (where `--taxid` silently re-parses successfully) would correctly fail the test. A detailed explanatory comment was added to document this ArgumentParser ordering quirk for future readers.

### Minor

- **`testingRawArgs` escapes `#if DEBUG` only via the struct field.** **FIXED (comment added).** An inline comment on the `#if DEBUG` block in `ExtractReadsCommand.swift` now notes that any test that assigns to `cmd.testingRawArgs` depends on the Debug build configuration.

- **`strategyParameters["format"]`.** **FIXED.** Renamed to `strategyParameters["readFormat"]` for consistency with the CLI flag (`--read-format`) and added an inline comment explaining the naming rationale. No other code reads this key.

- **Duplication across `runByReadID` / `runByBAMRegion` / `runByDatabase` / `runByClassifier`.** **WONTFIX (design intent).** Each of the four strategies has a different argument list, different error surface, and different progress-string format. A shared `StrategyContext` helper or protocol would touch Phase-1/2 code in all three existing strategies, which the simplification-pass charter explicitly forbids ("do NOT modify ClassifierReadResolver or anything in Sources/LungfishWorkflow/Extraction"). A future refactor can consolidate if it chooses; the current four-way shape is tolerable.

- **`classifierSamples` is declared but never read.** **FIXED (comment added).** A comment on the declaration now notes that `classifierSamples` exists purely for ArgumentParser parse-side acceptance and that the grouping is reconstructed by `buildClassifierSelectors(rawArgs:)`.

- **`runByClassifier` closure captures `quiet` via local let.** **NOTED AS POSITIVE; no action.** This was already a positive observation in the review; the refactor preserves it.

### Test gaps

- **Equals-style flag parsing.** **ADDRESSED.** Three new tests (`testParse_byClassifier_equalsForm_sampleAndAccession`, `testParse_byClassifier_equalsForm_taxon`, `testParse_byClassifier_mixedForm_spaceAndEquals`) cover all three flags in the equals form plus a mixed-form invocation within a single argv.

- **`--include-unmapped-mates` flow-through to `ExtractionOptions`.** **ADDRESSED.** A new non-private helper `makeExtractionOptions()` on `ExtractReadsSubcommand` exposes the `ExtractionOptions` struct to tests. Three new tests (`testMakeExtractionOptions_defaults_areFastqAndNoMates`, `testMakeExtractionOptions_includeUnmappedMates_flowsThrough`, `testMakeExtractionOptions_readFormatFasta_flowsThrough`) pin the mapping from CLI flags to the resolver-facing options, including the derived `samtoolsExcludeFlags` (0x404 by default, 0x400 with the flag set).

- **`--by-classifier --tool kraken2` end-to-end.** **WONTFIX (deferred to Phase 7).** Phase 2 review-2 already forwarded fixture work to Phase 7. Landing even a skip-if-fixture-missing scaffold would require sketching what the fixture looks like, which is out of scope for the simplification pass.

- **Individual mutual-exclusion pairs for `--by-classifier` vs `--by-id` / `--by-db`.** **ADDRESSED.** Two new tests (`testParse_byClassifier_vs_byId_mutuallyExclusive`, `testParse_byClassifier_vs_byDb_mutuallyExclusive`) cover the remaining two pairs. The pre-existing `testParse_byClassifier_multipleStrategiesFails` covers `--by-classifier + --by-region`.

- **Directory-shaped `--result` test.** **WONTFIX (deferred to Phase 7).** See significant issue #3 above.

- **Error surfacing for nonexistent `classifierResult`.** **ADDRESSED.** `testRun_byClassifier_nonexistentResult_failsWithReadableMessage` pins that runs against `/does/not/exist/...sqlite` fail with a readable error and do NOT create an output file.

- **Unreachable-branch defensive-code comment.** **ADDRESSED.** An inline comment on the `.clipboard, .share` branches in `runByClassifier`'s outcome switch now notes that they are defensive dead code (CLI always passes `.file(outputURL)`) but are kept rather than `fatalError` so a future refactor that adds a CLI-side destination doesn't silently crash end users.

- **Phase 3 plan's Task 3.3 Step 1 skipped test.** Noted in the review; the implementer's reasoning (Phase 1's `FlagFilterParameterTests` already pins the 0x400 default) is sound. No action required in the simplification pass; the cross-reference to the plan's gate-4 review is a doc-level concern, not a code concern.

### Forwarded from Phase 2 review-2 — dead `ClassifierExtractionError` cases

Phase 3 does not delete any of the four cases from the enum (per the charter). All four remain deferred:

- **`cancelled`** — WONTFIX (defer to Phase 4/5). No existing CLI SIGINT pattern to extend; the resolver does not check `Task.isCancelled`; Phase 3 has no natural path to throw this case.
- **`kraken2TreeMissing`** — WONTFIX (defer to Phase 4/5). The resolver's Kraken2 path wraps `TaxonomyExtractionPipeline` which surfaces lower-level errors directly; Phase 3 has no natural path to throw this case. Phase 4 kraken2 wiring is the right place to either translate or delete.
- **`destinationNotWritable`** — WONTFIX (defer to Phase 4/5). Phase 3's `runByClassifier` relies on `createDirectory(withIntermediateDirectories: true)` at the top of `run()` for `.file` destinations, and the resolver surfaces FileManager errors directly. The case is redundant with FileManager's own errors at the CLI layer but may have a natural home in the Phase 4 GUI destination pickers (where bundle/clipboard/share have more nuanced writability semantics).
- **`fastaConversionFailed`** — WONTFIX (defer to Phase 4/5). The FASTQ → FASTA streaming helper is exercised by `testRun_byClassifier_format_fasta_endToEnd` positively (197 reads converted successfully); Phase 3 does not have a negative path that forces a malformed FASTQ through. Phase 4/5 should audit whether the helper actually throws this and delete the case if it does not.

All four are noted as dead-code-until-Phase-4/5 rather than removed, per the charter.
