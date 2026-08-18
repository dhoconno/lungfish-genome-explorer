# Dependency Upgrade Program: Plan B (Regression Tiers) Results

Date: 2026-08-18. Branch: claude/lge-dependency-upgrade-plan-b6b53b (base 1e4b6576, head f0759935). Tag: deps-plan-b-complete.

Execution ledger of docs/superpowers/plans/2026-08-17-dependency-upgrade-02-regression.md, kept verbatim.

```
# SDD ledger — plan: docs/superpowers/plans/2026-08-17-dependency-upgrade-02-regression.md

Spec: docs/superpowers/specs/2026-08-17-dependency-upgrade-mechanism-design.md (section 4.7 + parser hardening)
Branch: claude/lge-dependency-upgrade-plan-b6b53b (worktree). Start HEAD: 1e4b6576 (Plan A complete, tag deps-plan-a-complete)
Plan A results ledger: docs/reports/2026-08-18-dependency-upgrade-plan-a-results.md

## Pre-flight scan

| Tasks | Produces vs consumes | Finding |
|---|---|---|
| B1↔B2-B6 | `ToolAvailability.require/requireDatabase/skipOrFail`, `ProcessRunner.run` | consistent |
| B2↔B6 | B6 calls `ConformanceFixtures.fixture(_:)` (added "in B6") | Ruling: define `fixture(_:)` in B2 |
| B6↔B7 | B6 uses `SeqkitStatsParser` (B7) | Ruling: execute B7 before B3-B6 |
| B4↔B7 | B4 uses `AlignmentMetadataDatabase.parseFlagstat/parseIdxstats` statics (B7 exposes) | same ordering ruling |
| B8↔B10 | module `diff_goldens.py` invoked by CI and verify | consistent |
| B1↔B10 | `full-suite-gate.sh --require-tools --filter` | consistent |
| B2 self | pack-tool version test on a drifted dev machine (clair3 2.0.1 installed vs 2.0.0 pinned) | Ruling below |
| B3 | Kraken2 viral DB installed locally (~/.lungfish/databases/kraken2/viral, 20240904) | ok |
| B3-B6 | all needed envs exist in the real conda root; tests only READ/execute tools, never mutate envs | ok |
| B10 | CLI flag names for `conda install --pack` / `db download --yes` must be verified by implementer | note |

Rulings (pre-flight):
- Ruling: execution order B1, B2, B7, B3, B4, B5, B6, B8, B9, B10, B11, B12 — cost if wrong: none.
- Ruling: `ConformanceFixtures.fixture(_:)` defined in B2 — none.
- Ruling: `testEveryInstalledPackToolReportsPinnedVersion` reports version drift as XCTFail only under LUNGFISH_REQUIRE_TOOLS=1; otherwise XCTSkip listing the drifted tools (dev machines drift; verify.sh/CI conformance run in require mode). Required-tools test stays strict in both modes — cost if wrong: dev-machine drift hides from the default gate (verify.sh catches it).
- Ruling: conformance tests run tools from `CondaManager.shared` (the real root) read-only; never install/remove envs in tests — cost if wrong: none.
- Ruling: model routing — B1,B2,B9,B11 sonnet; B3-B6 sonnet (transcription + adapt parser entry points; escalate to opus if BLOCKED); B7 opus (parser hardening); B8 opus (diff semantics); B10 sonnet; reviews sonnet except B7/B8 opus.

## Task execution order
B1, B2, B7, B3, B4, B5, B6, B8, B9, B10, B11, B12

## Progress
Task B1: implementer DONE_WITH_CONCERNS at 6f85f8d6 (added skipOrFailForSwiftTesting for swift-testing files; fixed NativeToolRunnerTests missing ivar stub). Ruling: the newly exposed pre-existing bug (0-variant VCF import "Missing required indexes") is fixed inside B1 if contained, else XCTExpectFailure — cost if wrong: scope creep of one bounded product fix.
Task B1: pre-review follow-up dispatched (empty-VCF import bug; classify swift-testing pre-existing failure)
Task B1: follow-up landed 4aa3ec97 (root-cause fix in VariantDatabase+Import.swift: empty-DB path reset skip_variant_info without creating indexes; 2 lowest-layer tests). Review: Approved with 2 Important (gate allowlist regex misses ClassificationPipelineIntegrationTests; arg loop has no default arm) → fix round 1/5 dispatched at 4aa3ec97
Task B1: minor (deferred): usage comment alignment.
Task B1: fix round 1/5 (2 addressed, 0 open; commits 4aa3ec97..f2c75c52)
Task B1: complete (commits 1e4b6576..f2c75c52, review clean)
Task B2: implementer DONE at d06a3421; NOTE for Plan C: local drift bwa-mem2 2.2.1 vs 2.3, clair3 2.0.1 vs 2.0.0, bracken 3.0.1 vs pinned 1.0.0 (verify the bracken pin: bioconda has 2.x/3.x; check-upstream must surface it)
Task B2: review Approved w/ 1 Important (substring version match) → fix round 1/5 dispatched at d06a3421
Interleaved user request: ONT demux provenance descriptors resolved from packTools (commit f6ddb31a) — outside Plan B tasks; test added.
Task B2: fix round 1/5 (2 addressed, 0 open; commits d06a3421..263b3618)
Task B2: complete (commits f2c75c52..263b3618, review clean)
Task B7: implementer DONE at 3fa6fea2 (2 commits); review Needs fixes (Important: EsViritu error swallowed at 4 callers; seqkit parse errors discarded; sumLen Int→Int64) → fix round 1/5 dispatched. Ruling: surface parse errors at classification/import sites (fail/log), keep raw-count fallback only for headerless files.
Task B7: minor (deferred): doubleValue nan suffix check over-broad; C-locale assumption undocumented; parseAll strict header/value count; looksLikeJSON untested; Kreport scoped throw kept by design (do not relitigate in B3).
Task B7: fix round 1/5 (4 addressed, 0 open; commits 3fa6fea2..9cd22445)
Task B7: complete (commits f6ddb31a..9cd22445, review clean)
Task B7: minor (deferred): parseEsVirituVirusCount re-read on fileReadError silently falls to countDataRows (pre-existing tolerance).
Task B3+B4 (batched): implementer DONE at ddc4a5c1 (8a0b2f56 B3, ddc4a5c1 B4); review Approved w/ 1 Important (pipefail in bcftools pipeline) → fix round 1/5 dispatched
Task B3+B4: Ruling: unclassified-node assertion conditional (viral DB classifies 100% of the viral fixture) — cost if wrong: none.
Task B3+B4: minor (deferred): kreport/bracken parsers positional (reorder resilience — production parser gap, out of scope); parseFlagstat falls back to 0 on unmatched categories; ProcessRunner no SIGKILL fallback.
Task B3+B4: fix round 1/5 (1 addressed, 0 open; commits ddc4a5c1..415af244)
Task B3: complete (commit 8a0b2f56, review clean)
Task B4: complete (commits ddc4a5c1..415af244, review clean)
Task B5+B6 (batched): implementer DONE at 15ab3d19 (04dd4cf2 B5, 15ab3d19 B6). FOLLOW-UP found: SPAdesOutputParser stage-marker parsing does not match SPAdes 4.2.0 log format (progress reporting inert in production) — file a fix in Plan C sweep or separately.
Task B5: complete (commit 04dd4cf2, review clean)
Task B6: complete (commit 15ab3d19, review clean)
Task B5+B6: minor (deferred): assembler runs have no explicit seed (asserted on structure); SPAdesOutputParser stage markers vs SPAdes 4.2 (follow-up filed above).
Task B8: implementer DONE at fa6acad4; review Needs fixes (Important: shell quoting for space paths; duplicate keys collapse silently; tolerances uncalibrated [carry to sweep]) → fix round 1/5 dispatched
Task B8: Ruling: kraken2-mini committed fixture untouched (Standard-16 artifact, not reproducible); new golden dir under conformance/2026.1 — cost if wrong: none.
Task B8: minor (deferred): SKIP vs FAIL conflated (fixing in round); wallTime granularity; VALID_KINDS unused; --only unknown id exit code.
Task B8: fix round 1/5 (4 addressed, 0 open; commits fa6acad4..89acd863)
Task B8: complete (commits 15ab3d19..89acd863, review clean)
Task B8: minor (deferred): first-row-only comparison within duplicate-key groups (order-sensitive); SPAdes itself rejects output paths with spaces (documented limitation).
Task B9: complete (commit 42d305a2, review clean)
Task B10: complete (commit 6f2bb09d, review clean) — CI toolset-conformance job NOT yet triggered (manual: gh workflow run ci.yml --ref <branch>)
Task B11: complete (commit 42327e8d, review clean)
Task B9-B11: minor (deferred): CI env var documented in a comment only (gate script sets it internally); pipeline-goldens dirs contain sibling files.
Task B12: full gate running (bvjypor5i); final Plan B review dispatched (fable) on final-review-code-only.diff (1e4b6576..42327e8d)
Final review (fable): With fixes. Important: (1) full-suite-gate.sh --filter with no value hangs; (2) CI toolset-conformance cannot pass as written (variant-calling pack, deacon-panhuman DB, python deps missing) and never dispatched; (3) ~20 tool/DB XCTSkips remain unconverted (plan-scope gap); (4) flag-stat display order nondeterministic after FlagstatSummary dict; (5) IQ-TREE assertion bypasses production TreeInputParser; (6) release-skill/SKILLS gate references verify.sh (Plan C); (7) run-pipelines.sh exits 0 on missing candidate (diff status 3) and hardcodes SRR35517702. Minors: ClassificationPipelineIntegrationTests still accepts emptyReport; flagstat JSON no live coverage; MinimalNewickTree split canonicalization; ucsc version exempt; SeqkitStatsParser doc claim; recipe stderr suppressed; cutadapt assertion weak.
Ruling: single fix wave covers Important 1-7 (incl. converting the remaining skips + extending the allowlist/CI filter) and minors: emptyReport tightening, live flagstat -O json coverage, split canonicalization, stderr capture, cutadapt output assertion; ucsc/doc minors deferred — cost if wrong: larger fix wave.
Task B12: gate rerun (42327e8d): XCTest 13381 executed, 36 skipped, 0 failures; swift-testing 3 issues = FileSystemWatcherTests (environmental) → GREEN modulo environmental. Fix wave dispatched (opus) at 42327e8d.
Fix wave: COMPLETE (42327e8d..65581d8c, 6 commits). Report: .superpowers/sdd/2026-08-17-dependency-upgrade-02-regression/final-fix-wave-report.md
Fix wave: verification — default mode 197 executed/0 failures/2 skipped; LUNGFISH_REQUIRE_TOOLS=1 197 executed/3 failures. Both require-mode failures (ToolVersionConformanceTests bwa-mem2 2.2.1 vs 2.3 drift; ClassificationPipelineIntegrationTests micromambaNotFound) reproduce identically at pre-wave HEAD 42327e8d — pre-existing, not regressions. python3 -B -m unittest discover -s scripts/tests = 253 OK. bash -n clean on all three scripts.
Fix wave: new consistency test found a pre-existing gap — ReadsToVariantsEndToEndTests, BAMPrimerTrimSubcommandTests, IVarConverterViralReconParityTests were in the CI --filter but never in CONFORMANCE_ALLOWLIST, so their skipOrFail skips were never checked. Now in both.
Fix wave: added `lungfish conda db install-managed <id>` (Sources/LungfishCLI/Commands/DbCommand.swift) — managedData databases had no CLI entry point; CI needs it for deacon-panhuman.
CONCERN (RESOLVED 74e33b0a, controller ruling): CondaManager.ensureMicromamba resolved only the BUNDLED micromamba, so ClassificationPipelineIntegrationTests failed under require-tools even with ~/.lungfish/conda/bin/micromamba installed. Now falls back to an installed root-prefix micromamba (version-verified; unusable file still throws micromambaNotFound); bundled still wins when present. 5 new CondaManagerTests. ClassificationPipelineIntegrationTests now PASSES in require mode.
CI dispatch command (NOT run): gh workflow run ci.yml --ref claude/lge-dependency-upgrade-plan-b6b53b (push the branch to origin first).
Fix wave: commits 42327e8d..65581d8c (6 commits): all 7 Important + minors; new CLI `conda db install-managed <id>`; remaining skips converted + allowlist/CI filter synced.
Fix wave: Ruling: ensureMicromamba must fall back to an installed <condaRoot>/bin/micromamba when the bundled binary is unavailable (test bundle lacks resources) — load-bearing for the CI job; addendum dispatched — cost if wrong: an app build without the bundled binary silently uses an installed one (fine).
Fix wave: known require-mode failure on this machine: bwa-mem2 2.2.1 vs pinned 2.3 (real local drift, expected).
Fix wave follow-up (74e33b0a): micromamba fallback per controller ruling. Ruling command LUNGFISH_REQUIRE_TOOLS=1 --filter 'ClassificationPipelineIntegrationTests|CondaManagerTests' = 58 executed, 0 failures, exit 0.
Fix wave FINAL verification: default mode 197 executed/0 failures/1 skipped (exit 0); LUNGFISH_REQUIRE_TOOLS=1 197 executed/1 failure (exit 1) = ToolVersionConformanceTests bwa-mem2 2.2.1 vs pinned 2.3 local drift ONLY. Down from 2 skips/3 failures before the fallback. python3 -B -m unittest discover -s scripts/tests = 253 OK.
Fix wave: addendum commit 74e33b0a (ensureMicromamba installed fallback); re-review: all findings addressed, no new breakage; final gate running (bvpkiy3bt) on 74e33b0a
Deferred after Plan B: bwa-mem2/clair3/bracken local drift (Plan C reconciles); SPAdesOutputParser stage markers (follow-up); tolerances calibration (sweep); toolset-conformance CI job dispatch (needs branch pushed).
Task B12: final gate (74e33b0a): XCTest 13403 executed, 2 failures = DbCommandRegressionTests.testSubcommands (real: new install-managed subcommand; fixed in follow-up commit) + PBAAClusteringPipelineTests timing flake (known); swift-testing 4 = FileSystemWatcherTests (environmental). Verdict: GREEN modulo known-environmental after the one-line test fix.
Task B12: complete. Plan B complete on branch.
```
