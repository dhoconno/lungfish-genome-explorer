# Phase 2 — Adversarial Review #1

**Date:** 2026-04-09
**Commits reviewed:** f759923, 3b51b7d, e9b70ec, 82c8dd8, 2b5b4e7, c83c225, f0df170
**Reviewer:** general-purpose subagent
**Charter:** Independent adversarial review before simplification pass.

## Summary

Phase 2 lands a working `ClassifierReadResolver` actor with the right surface area — unified entry point, sensible per-tool BAM resolution, shared destination routing, and a Kraken2 wrapper around the existing pipeline. The 2b5b4e7 fix from `-0` to the 4-file split is a real catch and makes the code correct for paired-end data, though it duplicates ~75 lines from `ReadExtractionService` that should arguably live in one place. The four documented deviations are all justified and correct. The most serious finding below is a **latent spec-invariant violation**: `estimateBAMReadCount` uses `samtools view -c` (which includes secondary/supplementary alignments) while `extractViaBAM` pipes through `samtools fastq` (which by default excludes `0x900`), so the I4 count-sequence invariant is structurally broken on BAMs containing secondary or supplementary alignments — the sarscov2 fixture masks this because it has zero. Several smaller issues (dead parameters in `routeToDestination`, hardcoded `pairedEnd: false`, unchecked sample-label collision, stdout-fallback write-encoding bug) are worth fixing before moving on but are not blockers.

## Critical issues (must fix before moving on)

- [ ] **Estimate / extract read-count divergence on secondary/supplementary alignments.** `ClassifierReadResolver.swift:182` builds `["view", "-c", "-F", String(options.samtoolsExcludeFlags), …]`. Default exclude flags are `0x404` — secondary (`0x100`) and supplementary (`0x800`) are **not** excluded. `extractViaBAM` at `ClassifierReadResolver.swift:360` filters the same BAM with `view -b -F 0x404`, then pipes through `convertBAMToFASTQ` which calls `samtools fastq` with **no explicit `-F`** (line 601–612). `samtools fastq`'s default is `-F 0x900` (verified via `samtools fastq` help). The result:
  - `estimateBAMReadCount` counts alignments including secondary + supplementary.
  - `extractViaBAM` produces FASTQ records with secondary + supplementary **dropped** at the `fastq` stage.
  - `MarkdupService.countReads` (`Sources/LungfishIO/Services/MarkdupService.swift:172`) also uses `view -c -F 0x404`, so the "Unique Reads" column in the UI matches the estimate but **not** the extracted file.

  This directly violates spec invariant I4 ("count == Unique Reads column") on any BAM with secondary or supplementary alignments. The sarscov2 fixture has `samtools view -c -f 0x900 test.paired_end.sorted.bam == 0`, so every test in the phase passes trivially — the gap only shows up on real metagenomics BAMs (common with minimap2's `--secondary=yes`).

  **Fix:** either (a) pass `-F 0x904` to `view -c` in `estimateBAMReadCount` so the estimate matches `samtools fastq`'s default, and update `MarkdupService.countReads` callers that want the "Unique Reads" column to the same flag set; or (b) pass `-F <options.samtoolsExcludeFlags>` to `samtools fastq` inside `convertBAMToFASTQ` (e.g. add `"-F", "0x404"` — making the extract path match the estimate but diverge from samtools' fastq defaults and potentially break unpaired singleton handling). Option (a) is the safer change because it aligns the estimate, the Unique Reads column, and the extracted file count. Phase 6's I4 suite must specifically exercise a BAM with secondary/supplementary alignments to catch this — not just sarscov2.

## Significant issues (should fix)

- [ ] **Dead parameters in `routeToDestination`.** Lines 746 and 744 accept `tool: ClassifierTool` and `tempDir: URL` respectively, but neither is referenced inside any of the four `case` arms. Both call sites (lines 416–423 and 514–521) pass real values that are thrown away. If these are forward-looking hooks (e.g. for per-tool bundle naming), they need a comment saying so; otherwise they should be deleted. Today they add noise and make call-site refactors harder.

- [ ] **`convertBAMToFASTQ` stdout-fallback write encoding.** `ClassifierReadResolver.swift:662` writes `stdoutResult.stdout` via `.write(to:atomically:encoding:)`. `stdout` is already a `String` produced by decoding the process output; writing it with `.utf8` encoding is correct byte-by-byte only for ASCII input. FASTQ quality scores are ASCII, so this happens to be safe, but the equivalent in `ReadExtractionService.convertBAMToFASTQSingleFile:667` has the exact same pattern and exact same latent concern. Worth a comment documenting the ASCII-only assumption. More importantly: `NativeToolRunner.run` captures `stdout` as a decoded Swift `String`, which means very large process outputs go through a lossy UTF-8 decode round-trip. For the rare BAMs that hit the stdout fallback, this is a correctness and a memory-pressure hazard (the entire FASTQ buffered in RAM as a Swift `String`). Deferred-fix acceptable for this phase, but flag it.

- [ ] **`convertBAMToFASTQ` logic duplication.** `ClassifierReadResolver.swift:587–664` is a near-line-for-line copy of `ReadExtractionService.swift:602–669` (`convertBAMToFASTQSingleFile`). The only substantive differences are:
  - `sidecarPrefix` uses the caller's `outputFASTQ.deletingPathExtension().lastPathComponent` rather than a fixed `reads_` prefix, enabling multiple calls to share one `tempDir`.
  - Timeout is 3600 vs 7200 (why?).
  - Error uses `ClassifierExtractionError.samtoolsFailed` rather than `ExtractionError.samtoolsFailed`.
  - No `logger.warning` on the stdout-fallback branch.

  The simplification pass should collapse this into one implementation. The cleanest option: change `ReadExtractionService.convertBAMToFASTQSingleFile` from `private` to `internal` and accept a `sidecarPrefix: String` and a custom timeout, then have the resolver call it. That eliminates ~75 lines of near-copied code and keeps the stdout-fallback pitfall in one place. Note also the timeout divergence — 3600s (resolver) vs 7200s (service) should be unified; this could matter for very large BAMs.

- [ ] **Kraken2 test permanently skipped.** `testExtractViaKraken2_fixtureProducesFASTQ` (line 503) uses an `isDirectory` filter to find `classification-*` directories. But `Tests/Fixtures/kraken2-mini/SRR35517702/` contains only `classification-result.json` and `classification.kreport` (both files, no directory). The filter is a correctness fix — without it the test would crash `ClassificationResult.load` on a file-not-directory. Good fix. But the test **always skips** today, which means `extractViaKraken2` has **zero end-to-end coverage**. Phase 7 fixture work must create a proper `classification-<date>/` subdirectory in the kraken2-mini fixture with a kreport, classified output, and source FASTQ, or this test remains cosmetic.

- [ ] **No cancellation cleanup in `extractViaKraken2`.** `extractViaBAM` calls `try Task.checkCancellation()` inside the per-sample loop (line 346). `extractViaKraken2` never checks cancellation between phases (load → resolve sources → build config → pipeline.extract → concatenate → count → convert → route). The `TaxonomyExtractionPipeline.extract` presumably checks internally, but the resolver's own wrapper steps do not. A cancellation during concatenation or FASTA conversion will run to completion. For a small Kraken2 fixture this is fine; for a large extraction it's a UX bug. Add `try Task.checkCancellation()` calls around the concatenate/count/convertFASTQToFASTA calls.

- [ ] **`estimateKraken2ReadCount` silently returns 0 on load failure.** `ClassifierReadResolver.swift:208–213` — the `do/catch` swallows any `ClassificationResult.load` error and returns 0. The comment says "best-effort estimate; don't fail the pre-flight" which is reasonable for a GUI hint, but a zero estimate pre-flight followed by a non-zero extraction is confusing and the user may be misled. At minimum, log the error via the module logger so it shows up in diagnostics. Better: distinguish "no taxa selected" (0, expected) from "couldn't load" (nil → GUI shows "—").

## Minor issues (nice to have)

- [ ] **Hardcoded `pairedEnd: false` in `.bundle` routing.** `ClassifierReadResolver.swift:769` constructs `ExtractionResult(…, pairedEnd: false)` unconditionally. I traced this through and confirmed `ReadExtractionService.createBundle` (line 526–593) never reads `result.pairedEnd` — it only uses `result.fastqURLs`. So the hardcoded value has zero effect on persisted bundle metadata. BUT: `ExtractReadsCommand.swift:228` reads `result.pairedEnd` for CLI display. That isn't in Phase 2's hot path (the CLI goes through `ExtractionPipeline`, not the resolver), so today nothing breaks. If a future phase plumbs the CLI through the resolver and keeps using `ExtractionResult`, the CLI will print "Paired-end: no" for every extraction. Worth a one-line TODO on line 769 or a guard at the point where the resolver wraps an `ExtractionResult`.

- [ ] **Shared-tempDir sample-label collision risk.** `convertBAMToFASTQ` at line 595 builds sidecar names from `outputFASTQ.deletingPathExtension().lastPathComponent`. In `extractViaBAM`, the per-sample output is `"\(sampleLabel).fastq"` where `sampleLabel = sampleId ?? "sample"`. If a caller passes selectors mixing `sampleId: nil` and `sampleId: "sample"` (both would produce `sampleLabel = "sample"`), the second iteration overwrites the first iteration's sidecars AND the `sample.fastq` itself, then re-appends it to `perSampleFASTQs`. The result: sample A's reads are lost and sample B's reads appear twice in the final output. No caller today does this, but `groupBySample` would need to detect the collision to be safe. Cheapest fix: use the `index` (loop counter) in the stem — `"\(index)_\(sampleLabel).fastq"` — so stems are unique regardless of input.

- [ ] **Generic share file names.** `routeToDestination` `.share` case at line 796 uses `finalFile.lastPathComponent`, which is always `"concatenated.fastq"` (line 397) or `"concatenated.fasta"` (line 410) for BAM-backed tools, and `"kraken2-concat.fastq"` / `"kraken2-concat.fasta"` for Kraken2. The user sees all shared files named "concatenated" regardless of which tool or sample they came from. For a UX-polish pass: name the final file after the tool + sample list (e.g. `esviritu_S1_S2.fastq`) so share-sheet recipients get a meaningful filename.

- [ ] **`convertFASTQToFASTA` silently tolerates malformed input.** If a FASTQ ends mid-record (e.g. 3 lines of a final record), the `while let` loop terminates at EOF and the last `mod % 4 != 0` lines are silently dropped without error. `countFASTQRecords` using `lineCount / 4` has the same tolerance. For our controlled samtools → concatenate → wc-divide-by-4 pipeline the inputs are always well-formed, but if a future caller feeds an externally-produced FASTQ this could mask corruption. A defensive fix: after conversion, verify `lineIndex % 4 == 0` and throw `fastaConversionFailed` if not. Optional.

- [ ] **`LineReader` uses legacy synchronous `readData(ofLength:)`.** This is fine for fileprivate helper, but worth noting that `concatenateFiles` and `countFASTQRecords` use the same pattern. On large FASTQs we're doing synchronous reads in a non-actor-isolated context inside actor methods. The reads happen on the actor's executor, which effectively serializes them with all other resolver work. Not a correctness bug, but worth being aware of for the perf pass.

- [ ] **`estimateBAMReadCount` 600s timeout vs `extractViaBAM` 3600s.** Why are these different? `samtools view -c` on the same BAM is usually faster than `view -b` + `fastq`, so 600s may be fine, but the asymmetry is unexplained and brittle if a single BAM is huge. Document or unify.

- [ ] **`#if DEBUG testingResolveBAMURL` hook.** This is a fine pattern for exposing private actor methods to tests, and I verified it compiles and behaves correctly. Worth a one-line comment above the `#if DEBUG` explaining why (so future cleanup passes don't delete it).

## Test gaps

- **Zero end-to-end coverage for `extractViaKraken2`.** As noted, `testExtractViaKraken2_fixtureProducesFASTQ` always skips on the current fixture. The Kraken2 path has never run against real data in this phase.
- **No test for the `includeUnmappedMates: true` flag path.** `ExtractionOptions` exposes this, but every test uses the default `false`. The 0x400 vs 0x404 behavior is the whole reason this struct exists and is untested.
- **No test exercising the `fasta` output format.** `convertFASTQToFASTA` runs only if `options.format == .fasta`, which no test sets. The conversion is ~40 lines of hand-rolled byte munging — untested hand-rolled byte code is a classic regression surface.
- **No multi-sample count correctness test.** `testExtractViaBAM_multiSample_concatenatesOutputs` asserts only `outcome.readCount > 0`. A test that extracts sample A alone, then sample B alone, then A+B together, and asserts `count(A+B) == count(A) + count(B)` would catch any concatenation bug or the stem-collision risk above.
- **No test that verifies the FASTQ records in the output are actually unique** (no duplicates from repeated reads of the same sidecar). The stem-collision bug is invisible to the current tests.
- **No test for `estimateBAMReadCount` against a real BAM.** Only the empty-selection fast path has coverage. The actual samtools invocation is untested.
- **No single-sample `nil` sampleId test for `resolveBAMURL`.** The enumerator branch at lines 270–273 is dead code as far as the test suite is concerned.
- **No test for `kraken2SourceMissing` or `bamNotFound` beyond happy-path negation.** `resolveKraken2SourceFASTQs` has three fallback branches; only the third (error) is implicitly untested because there's no successful Kraken2 test at all.
- **No test confirms that `resolveProjectRoot` handles the filesystem root edge case** (symlinks, `/` itself, `~`). Probably fine but not exercised.
- **No test confirms that the `defer { try? fm.removeItem(at: tempDir) }` actually runs on error paths.** A throws test that catches and inspects `tempDir.fileExists` would.

## Positive observations

- The 2b5b4e7 commit message is excellent — it clearly explains the defect, cites the `ReadExtractionService` doc comment verbatim, and notes the deferred deduplication work. This is how post-mortem deviation-from-plan notes should look.
- The actor boundaries are correct throughout. `ClassifierReadResolver` as an actor, `NativeToolRunner` as an actor, `TaxonomyExtractionPipeline` as an actor — all `await`-called with `try await` at the right points. No sign of the `Task.detached` / `@MainActor` dispatch bugs called out in MEMORY.md. The `c83c225` propagation of `async` through `routeToDestination` was done correctly at both call sites (lines 416 and 514), as the reviewer asked me to verify.
- The `resolveBAMURL` per-tool switch is clean, centralizes knowledge that was previously scattered, and has good unit coverage (one happy-path test per tool plus a missing-BAM negative).
- The `#if DEBUG testingResolveBAMURL` hook is a pragmatic way to test private actor methods without relaxing visibility in production builds.
- The `routeToDestination` clipboard cap check throws **before** reading the file into memory (line 781–787), which is the right order — a 1GB clipboard cap should never materialize 1GB in RAM. Good defensive ordering.
- No macOS 26 API violations: no `lockFocus()`, no `wantsLayer = true`, no `runModal`, no `Task { @MainActor in }` from GCD queues. Pure Foundation + NativeToolRunner.
- `groupBySample` preserves insertion order (`order: [String?]` array), which means the concatenated FASTQ has deterministic ordering for a given input selection — helpful for the Phase 6 CLI/GUI round-trip equivalence tests.
- `ClassifierExtractionError` is thoughtfully separated from the lower-level `ExtractionError`, with readable `LocalizedError` strings that hint at user actions ("try adjusting the flag filter"). Good UX-oriented error design.
- The implementation plan's four documented deviations are all justified and the commit messages explain each one. This is an unusually clean-phase execution.

## Suggested commit message for the simplification pass

`refactor(workflow): dedupe convertBAMToFASTQ between resolver and service; drop dead routeToDestination params; align samtools fastq -F mask with estimate`

Specifically the simplification pass should:
1. Extract the 4-file-split BAM→FASTQ logic into a shared helper (make `ReadExtractionService.convertBAMToFASTQSingleFile` internal + parameterize the sidecar prefix + unify the 3600/7200s timeout, or lift it to a top-level function in `Extraction/`).
2. Delete the unused `tool` and `tempDir` parameters from `routeToDestination`.
3. Fix the count-sequence invariant (critical) — pass `-F 0x904` to `samtools view -c` so it matches `samtools fastq`'s `-F 0x900` default, OR pass `-F 0x404` explicitly to `samtools fastq` so it matches the estimate. Write an invariant test using a BAM that contains secondary alignments to lock this in.
4. Add cancellation checks to `extractViaKraken2`.
5. (Optional) unique-per-iteration sample stems in `extractViaBAM` to kill the nil-vs-"sample" collision.

## Simplification pass — disposition

Commit: `b7556bd` on top of `f0df170`.

### Critical issues

- **[1] Estimate / extract read-count divergence on secondary/supplementary alignments** — **FIXED**
  Extracted the 4-file-split BAM→FASTQ logic into a shared free function `convertBAMToSingleFASTQ(inputBAM:outputFASTQ:tempDir:sidecarPrefix:flagFilter:timeout:toolRunner:)` in a new file `Sources/LungfishWorkflow/Extraction/BAMToFASTQConverter.swift`. The helper now passes `-F <flagFilter>` to BOTH samtools fastq invocations (the 4-file split AND the stdout fallback), so the `-F` mask applied to `samtools view -c` (estimate), `samtools view -b` (extract), and `samtools fastq` (split) is always identical. In `ClassifierReadResolver.extractViaBAM` the flag filter is taken from `options.samtoolsExcludeFlags` (default `0x404`, matching `MarkdupService.countReads`). The resolver catches `BAMToFASTQConversionError.samtoolsFailed` and re-throws `ClassifierExtractionError.samtoolsFailed(sampleId:stderr:)` so the error domain stays consistent.

  `ReadExtractionService.convertBAMToFASTQSingleFile` was also refactored to delegate to the shared helper, but it passes `flagFilter: 0x900` to preserve the HISTORICAL behavior of that code path (`samtools fastq`'s built-in default). The service's existing callers apply their own `view -b -F <flagFilter>` upstream; changing the service's fastq step to use `0x404` would change behavior for the CLI/UI code paths that still consume `ReadExtractionService` directly. The resolver is the place the count-alignment fix landed because it is the place the spec invariant I4 applies.

  **HAND-OFF TO PHASE 6 REVIEW #1**: Phase 6 must verify its I4 invariant fixtures include at least one BAM containing secondary (`0x100`) and/or supplementary (`0x800`) alignments. The sarscov2 fixture has ZERO such records, so every test in this simplification pass (including the three new tests added below) passes trivially. Without a fixture that actually exercises the secondary/supplementary path, the Critical fix is unverified in CI. See `docs/superpowers/plans/2026-04-08-unified-classifier-extraction.md` Phase 6 section.

### Significant issues

- **[2] Dead parameters in `routeToDestination`** — **FIXED**
  Dropped both `tool: ClassifierTool` and `tempDir: URL` from the `routeToDestination` signature. Updated both call sites (`extractViaBAM` final return and `extractViaKraken2` final return) to no longer pass the dead arguments. No forward-looking hooks were retained; if Phase 5+ needs `tool` for per-tool bundle naming it can be threaded back then.

- **[3] `convertBAMToFASTQ` logic duplication** — **FIXED**
  Extracted the shared free function in `Sources/LungfishWorkflow/Extraction/BAMToFASTQConverter.swift`. Both `ClassifierReadResolver.extractViaBAM` and `ReadExtractionService.convertBAMToFASTQSingleFile` now call `convertBAMToSingleFASTQ(...)` with appropriate parameters. The resolver's private `convertBAMToFASTQ` method was deleted entirely (~78 lines removed from ClassifierReadResolver.swift). The service's private method shrank from ~68 lines to ~30 lines (delegation wrapper). Total code reduction: ~75 lines of duplicated logic collapsed to ~100 lines of shared helper + ~40 lines of delegation call sites. The free function is `internal` to `LungfishWorkflow` module and takes `NativeToolRunner` as a parameter — it does NOT introduce an actor-hop, because it runs in the calling actor's isolation domain and only awaits `runner.run(...)` which was already an actor-hop in the old code. Both timeouts unified (see item [m]).

- **[4] Kraken2 test permanently skipped** — **WONTFIX (hand-off to Phase 7)**
  `testExtractViaKraken2_fixtureProducesFASTQ` still XCTSkips today because `Tests/Fixtures/kraken2-mini/SRR35517702/` does not contain a `classification-<date>/` subdirectory. The test's isDirectory filter is the correct fix for now (prevents a `ClassificationResult.load` crash on file-not-directory). Phase 7 fixture work must add a proper classification subdirectory (kreport + classified output + source FASTQ) or create a new fixture, and Phase 7's test additions must include a non-skipping Kraken2 end-to-end test that exercises the resolver against real data. Synthesizing a kraken2 fixture inside this simplification pass would be scope creep.

- **[5] No cancellation cleanup in `extractViaKraken2`** — **FIXED**
  Added `try Task.checkCancellation()` checkpoints after each non-trivial phase of `extractViaKraken2`: after `resolveKraken2SourceFASTQs`, after `pipeline.extract`, after `concatenateFiles`, after `countFASTQRecords`, and (conditionally) after `convertFASTQToFASTA`. The existing `defer { try? FileManager.default.removeItem(at: cleanTempDir) }` handles cleanup on cancellation.

- **[6] `estimateKraken2ReadCount` silently returns 0 on load failure** — **FIXED**
  Added a `logger.warning(...)` call inside the `catch` block so the swallowed `ClassificationResult.load` error is surfaced in diagnostics. The return type is still `Int` (unchanged API surface) so callers still get a zero-valued best-effort estimate.

### Minor issues

- **(a) Hardcoded `pairedEnd: false` in `.bundle` routing** — **FIXED** (TODO added)
  Added a multi-line `// TODO[phase3+]:` comment above the `ExtractionResult(...)` literal explaining that the resolver doesn't currently know whether the upstream extraction was paired-end, that `createBundle` doesn't read the field today so there's no immediate effect, and that any future caller reading `ExtractionResult.pairedEnd` (e.g. `ExtractReadsCommand.swift:228`) would see a stale `false`. Deferred the real fix to when the CLI and GUI converge on a single extraction path.

- **(b) Shared-tempDir sample-label collision risk** — **FIXED**
  Per-sample stems in `extractViaBAM` now use an index-prefixed form: `let stem = "\(index)_\(sampleLabel)"`. The `perSampleBAM`, `perSampleFASTQ`, and sidecar file paths all derive from `stem`, so `nil` + `"sample"` + duplicate labels can never overwrite each other. The human-friendly `sampleLabel` is still used for progress messages and error reporting.

- **(c) Generic share file names** — **WONTFIX**
  Deferred to a UX-polish pass. The current behavior is defensible; there is no call site today that depends on meaningful share filenames.

- **(d) `convertFASTQToFASTA` silently tolerates malformed input** — **WONTFIX**
  The internal pipeline (samtools → concatenate → convertFASTQToFASTA) always produces well-formed input. No external caller feeds arbitrary FASTQ to the resolver's private converter. Defensive validation is deferred until a future caller adds that risk.

- **(e) `LineReader` uses legacy synchronous `readData(ofLength:)`** — **WONTFIX**
  Fileprivate helper; performance is acceptable for the pipeline's output-size distribution. Addressing this would require async FileHandle I/O which is a separate refactor.

- **(f) `estimateBAMReadCount` 600s timeout vs `extractViaBAM` 3600s** — **FIXED**
  Unified to `3600` for both. A pre-flight estimate should never impose a tighter timeout than the operation it previews; added a comment explaining why.

- **(g) `#if DEBUG testingResolveBAMURL` hook comment** — **FIXED**
  Added a multi-line comment block above the `#if DEBUG` explaining that `resolveBAMURL` is a private internal-dispatch helper (not public contract), why tests need access to each tool's BAM layout, and that the wrapper is compiled out of release builds.

- **(h) `convertBAMToFASTQ` stdout-fallback write encoding** — **WONTFIX (documented)**
  The ASCII-only FASTQ-quality-score assumption is now documented in the shared `BAMToFASTQConverter.swift` doc comment, alongside an acknowledgement that the UTF-8 decode round-trip is a latent memory-pressure concern shared with every `NativeToolRunner.run` caller that buffers large stdout as `String`. Tracking as a separate cross-cutting refactor.

- **(i) `ClassifierRowSelectorTests` test count 8 vs plan's predicted 7** — **WONTFIX**
  Inherited from Phase 1 review disposition; not applicable to Phase 2.

### Test additions

- **[test-1] Fasta-output format test** — **ADDED**
  `testExtractViaBAM_fastaFormat_producesValidFASTA` exercises `ExtractionOptions(format: .fasta)` against the sarscov2 fixture. Parses the output, verifies header/sequence alternation (`>` prefix), verifies record count matches `outcome.readCount`, and enforces even line count. Catches bugs in `convertFASTQToFASTA` hand-rolled byte munging. Passes.

- **[test-2] `includeUnmappedMates: true` flag path test** — **ADDED**
  `testExtractViaBAM_includeUnmappedMates_succeeds` runs `ExtractionOptions(includeUnmappedMates: true)` against sarscov2 and asserts non-zero reads. The fixture has no unmapped mates, so this primarily pins the API surface and verifies the `0x400` flag path doesn't error out. Passes.

- **[test-3] Multi-sample count equivalence test** — **ADDED**
  `testExtractViaBAM_multiSample_countEquivalence` extracts sample A alone, sample B alone, and A+B together (three full `resolveAndExtract` calls), then asserts `count(A+B) == count(A) + count(B)`. This catches both concatenation bugs AND the stem-collision bug from minor issue (b) — if two sidecars collided, one sample's reads would be lost or double-counted and the equation would fail. Passes after the stem-index fix in (b).

### Test gaps deferred to later phases

- **Kraken2 end-to-end coverage** — deferred to Phase 7 (needs a real kraken2-mini fixture).
- **`estimateBAMReadCount` against real BAMs** — deferred to Phase 6 invariant suite.
- **Single-sample `nil` sampleId `resolveBAMURL` branch** — dead code in tests today; exercised implicitly in the resolver's single-sample callers.
- **`kraken2SourceMissing`, `bamNotFound` beyond happy-path negation** — deferred to Phase 7 classifier-by-classifier test coverage.
- **`resolveProjectRoot` filesystem root edge cases** — existing tests cover the common paths; `/` / symlinks / `~` are all handled by the `while current.path != "/"` + `parent == current` early-exit logic.
- **`defer { try? fm.removeItem(at: tempDir) }` cleanup on error paths** — not instrumented; would require mocking `NativeToolRunner` which is a separate infrastructure effort.
- **`convertBAMToSingleFASTQ` secondary/supplementary regression test** — deferred to Phase 6 with an explicit note that the fixture must contain secondary/supplementary records or the Critical fix is unverified.

### Additional opportunities beyond the review

- **Dead code paths** — verified none. After deleting `convertBAMToFASTQ`, all remaining private helpers (`groupBySample`, `resolveBAMURL`, `resolveKraken2SourceFASTQs`, `concatenateFiles`, `countFASTQRecords`, `convertFASTQToFASTA`) are called from at least one site. The test hook `testingResolveBAMURL` is gated on `#if DEBUG`.
- **`let _ =` discards** — verified none. Grepped for `let _ =` in `ClassifierReadResolver.swift`, zero matches.
- **Strict-concurrency warnings in modified files** — verified none. Filtered `swift build --build-tests` warnings to the three modified files (`ClassifierReadResolver.swift`, `BAMToFASTQConverter.swift`, `ReadExtractionService.swift`); all clean. Pre-existing warnings in unrelated files (`NextflowRunner.swift`, `ViewerViewController+Taxonomy.swift`) are not touched by this pass.
- **Sidecar-naming collision risk after prefix change** — verified none. The new stems are `"\(index)_\(sampleLabel)"`; the sidecar helper in `BAMToFASTQConverter.swift` derives all four sidecar names from `sidecarPrefix`, so `<0_A>_other.fastq`, `<0_A>_r1.fastq`, etc. are unique per sample iteration. Concurrent resolvers using the SAME `tempDir` would still collide, but each resolver creates its own `ProjectTempDirectory` per extraction (UUID-suffixed).
- **`ClassifierReadResolver.swift` size** — shrank from 923 lines to 857 lines (-66 lines, -7%). `ReadExtractionService.swift` shrank from ~740 lines to 667 lines. Net new code is 145 lines in `BAMToFASTQConverter.swift`, so the line-count footprint is slightly larger (+6 lines overall) but the duplication is eliminated and the Critical correctness fix is in place.

### Gate results

- `swift build --build-tests 2>&1 | tail -20` — clean. Pre-existing unrelated warnings only.
- `swift test --filter ClassifierReadResolverTests 2>&1 | tail -10` — **20 tests**, 19 passed, 1 skipped (kraken2 fixture). Up from 17 in Phase 2 head (+3 new tests).
- `swift test --filter ReadExtractionServiceTests 2>&1 | tail -10` — **18 tests**, all passing. The delegation refactor did not regress any existing service behavior.
- `swift test --filter ExtractionDestinationTests 2>&1 | tail -10` — **6 tests**, all passing.
- Full `swift test` not run (per charter: Phase 2 Gate 4 will run that).
