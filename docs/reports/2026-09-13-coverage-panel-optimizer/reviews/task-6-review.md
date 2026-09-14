# Task 6 spec and quality review

Reviewed native `39aea29d2776d0aa43615cf8931917763a602682..c3d8538` (utility code at `7b6148b6f80d70052fa2ed8aa3a44d4def3e8954`) and LGE documentation `bc535d90f7c95eaae2c624ff87927a85de692bcd..cc6d75bc0` against the Task 6 brief/preflight, final report, design contract, and final recorded evidence. Read-only; no production edits, delegates, solver installation or benchmark reruns.

**Spec verdict: CHANGES REQUESTED. Quality verdict: CHANGES REQUESTED, documentation only.** One important finding remains. No important defect was identified in the committed benchmark utility or final benchmark interpretation.

## P2 — State the supported pool and terminal-policy contract, not the benchmark configuration

Locations:

- Native `docs/designs/coverage-panel.md:95–98`, particularly line 97.
- LGE `docs/reports/2026-09-13-coverage-panel-optimizer/report.md:35–37`.

The new native usage section says coverage requires observed-only terminal-gap handling. The durable LGE report additionally says coverage supports two or more configured pools. Both statements narrow the implemented and accepted contract. `ConstraintProfile.__post_init__` accepts any positive integer pool count; native `Config` retains `TerminalGapPolicy.LEGACY` as its default; capabilities advertise both terminal policies; `test_coverage_accepts_both_discovery_backends_and_zero_caps` explicitly covers both. LGE's argument guard likewise accepts any positive pool count and does not restrict coverage to observed-only; its frontend default is observed-only. Two pools with observed-only are the recorded HLA experiment settings, not capability requirements.

A reader using the new authoritative usage/report text would incorrectly conclude a valid one-pool or legacy-terminal-policy coverage run is unsupported and could silently substitute a materially different discovery policy to follow the documentation. This conflicts with the Task 6 requirement to document exact defaults and supported constraints.

Minimal correction: state that supported coverage uses one or more pools and either `legacy` or `observed-only` terminal-gap policy; distinguish the native default (`legacy`) from the LGE default (`observed-only`); separately state that all three HLA benchmark runs used two pools and observed-only. Change documentation, not implementation or existing scientific artifacts. Verification should compare the corrected prose with the existing Config/capabilities/CLI guards and already-passing coverage tests; a new biological run is unnecessary.

## Small optional usage clarification

The local-use section first changes directory to the native fork at line 69, then presents the LGE `.build/debug/lungfish-cli` command at line 78 without changing into the sibling LGE worktree. Its relative executable/override paths assume the LGE working directory. Add an explicit `cd` or say to execute that block from the LGE worktree so the documented sequence is directly reproducible. This is not an additional important scientific finding.

## Evidence and successful correspondence

- Utility pre-review remains applicable: actual search core, explicit abstract oracle, deterministic interval/graph fixture, independent literal-union/pool/graph feasibility, known feasible alternative, work limits, overwrite refusal, and output hash inventory are present. The final prose correctly qualifies retained Python allocation baselines and cumulative RSS.
- The reported final commands are tied to the reviewed code: 143 native `tests/lge` tests, 35 focused Swift tests, CLI build/help, Ruff, compile and diff checks. These reported checks were not redundantly rerun here.
- Read the root-owned audit outputs for all three immutable bundles and its successful provenance. They match the report's 50,969/16,376 candidate counts, 24/29 assignment counts, per-target reference lengths/full/interior metrics, semantic digests, and 175 wrapper/31 native descriptors. The root verifier's exact exception is the manifest-listed LGE-derived `ordering-v1.csv`, not unrestricted extra native files. The root independently rechecked final bytes and geometry; this review does not pretend to have rerun that entire audit or the native biochemical validator.
- The 600-second wide search's native optimizer evidence confirms 251.363580 seconds, four completed starts, eight repair rounds, 9,152 intrinsic and 115,382 pair evaluations. The report correctly says its assignment vector and objective did not improve over wide120. Narrow completed in its budget. Stop/work limits are disclosed.
- Legacy comparison is expressly a different end-to-end system/profile, the C bound is conditional on the fixed full-nine catalogue/profile, coverage is not allele amplification, and the new selector remains opt-in. Negative runs and both harness failures remain disclosed.
- The 100-target result is explicitly abstract and does not claim 100-MSA biological scale. Complete human and synthetic verification evidence is retained with reproducibility provenance.
- A lightweight direct text comparison confirmed all eight `Ruling:` lines are preserved verbatim in the durable report. Plan checkboxes leave final branch review pending.

The newly requested ensemble experiment is separately pending and currently proposes only ignored diagnostics. It neither supplies an improvement claim nor changes this Task 6 review's code scope. Resolve the one P2 documentation finding before Task 6 sign-off.
