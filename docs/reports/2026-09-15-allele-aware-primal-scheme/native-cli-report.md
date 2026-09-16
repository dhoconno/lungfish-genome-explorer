# Allele-aware PrimalScheme CLI evaluation

**Status: evaluation in progress; GUI acceptance has not been requested.**

## Metric

Each target is the mean primer-trimmed coverage of its distinct observed aligned allele classes. Duplicate rows retain provenance but add no objective weight. A base earns credit only when an exact forward and reverse primer both bind the same observed row and the base lies between their footprints. Only concrete observed A/C/G/T bases enter the denominator; observed insertions count. The panel mean weights target MSAs equally.

The aspirational goal is >95% per target. Valid useful partial coverage is retained, including configurations that preserve some allele-supporting primer variants while dropping others.

## Historical baselines

These are binding-model coverage measurements, independently scored from stored original MSAs and actual selected BED primers. They do not claim that historical panels pass the new dimer or specificity rules. Upstream PrimalScheme3 3.3.0 used its original 180–220 bp bounds and D=0; saved LGE panels used their recorded settings. These historical comparisons are descriptive, not controlled selector ablations. The independent column measures separate target panels; combining their primers does not establish a compatible pooled scheme.

| Target | Original upstream | Saved independent LGE | Saved combined LGE |
|---|---:|---:|---:|
| KIR2DL04 | 90.5% | 93.2% | 87.9% |
| KIR3DL10 | 80.0% | 95.4% | 93.3% |
| KIR3DS | 48.7% | 85.0% | 83.3% |
| Mamu-A1 | 29.8% | 86.7% | 57.1% |
| Mamu-A2 | 35.6% | 79.1% | 67.4% |
| Mamu-A4 | 48.9% | 85.8% | 72.4% |
| Mamu-B | 14.4% | 66.1% | 31.6% |
| Mamu-DPA | 49.5% | 90.5% | 82.4% |
| Mamu-DQB | 33.8% | 72.1% | 53.0% |
| Mamu-DRB | 23.7% | 85.8% | 42.8% |
| Mamu-E | 33.1% | 85.4% | 69.6% |
| Mean across targets | 44.4% | 84.1% | 67.3% |

Baseline data and reproducibility receipts:

- [Upstream common-metric report](/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/upstream-original-common-metric-01/coverage.json) and [receipt](/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/upstream-original-common-metric-01/provenance.json).
- [Combined saved-panel report](/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/historical-combined-common-metric-02/coverage.json) and [receipt](/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/historical-combined-common-metric-02/provenance.json).
- Independent results: `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/historical-independent-common-metric-01/<target>/coverage.json`, each accompanied by its own `provenance.json`.

## Previous LGE selector control

A separate run of unchanged lge.3 (`2abc3207629aacb101f1c04a4f57348ef5b903b2`) used all original rows, normal discovery, 150–250 bp geometry, two pools, positive supplied-row product bound 2000, terminal seed 19, and the original full-span objective/0.90 target. The run completed successfully in 189.4 seconds (wait4 peak RSS 3.76 GB; OS child accounting), with fresh native validation and unchanged source/runtime/inputs. Search reached its 120-second limit after two completed starts. It selected 15 amplicons and 42 primer records.

Rescoring those primers under the common distinct-allele after-trimming metric gives **13.2% target mean**. This is a descriptive lge.3 control under its intended-sites-v1 specificity policy, not a controlled test of the new subset selector. Positive product screening makes it substantially different from historical D=0 panels.

| Target | lge.3 common-metric coverage |
|---|---:|
| KIR2DL04 | 36.6% |
| KIR3DL10 | 30.4% |
| KIR3DS | 17.7% |
| Mamu-A1 | 0.0% |
| Mamu-A2 | 11.7% |
| Mamu-A4 | 7.0% |
| Mamu-B | 0.0% |
| Mamu-DPA | 15.5% |
| Mamu-DQB | 8.0% |
| Mamu-DRB | 5.5% |
| Mamu-E | 12.7% |

[Execution receipt](/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/existing-lge3-control-01/receipt.json) and [common-metric report](/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/existing-lge3-common-metric-01/coverage.json).

## New implementation experiment

The initial combined experiment uses all 11 original alignments in the frozen snapshot’s source order; union chemistry profiles, individual variant subsets, amplicon target 200/min 150/max 250 bp, two pools, four discovery workers, distinct-observed weighting, native strict dimer −26, terminal seed 17 with one substitution and positive supplied-row product bound 2000. Strict optimization has 120 seconds; optional experimental salvage uses −28/−30/−32, 60 seconds each and cumulative per-pool caps of 8 violating physical edges and 4 incident species. Strict remains primary.

Native code is frozen at `7ca64e68690f6e4db5b91f54bfe8a4847c402a62` in an isolated worktree and virtual environment. No managed installation or original scientific bundle was modified.

Run directory: `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mhc-union-subsets-02`. Final metrics and audit results are pending; no improvement claim is made from discovery alone.

## Single-target Mamu-A1 pilot — partial results

The isolated `matrix-02` pilot uses the original six-row Mamu-A1 alignment, with the same scientific settings and search budgets as the initial combined run. The completed strict tier passes its independent native stage validation and selects 10 amplicons, with **39.1308%** mean coverage after trimming across distinct observed classes (individual classes 32.1160–43.0336%). The first two salvage tiers have the same mean coverage. The final tier and whole-bundle audit are pending.

This is below the saved independent panel’s 86.7446% common-metric coverage. The original input bytes match; the historical panel has not thereby been shown to pass the new constraints. This result is not an improvement claim or evidence about compatibility in the combined panel.

A separate code review found that construction queue refresh can reconsider consumed candidates and spend search attempts on them. The regression-tested fix is included in `matrix-03`; its effect on MHC coverage has not yet been measured. One shared deadline also permits initial seed passes to exhaust time before subset construction and repair. Final pilot counters are needed to distinguish these limits from measured constraint rejections; neither is yet established as the cause of this coverage result.

[Completed strict coverage](/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mamu-a1-union-subsets-pilot-01/stages/strict/coverage.json) and [strict validation](/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mamu-a1-union-subsets-pilot-01/stages/strict/validation.json).

## Engineering verification

The native implementation and LGE CLI integration have passed independent Astra reviews. The latest frozen native evaluation revision is `ddf45ae08c146063adb46a6d2eeb28dea657befb` in `allele-aware-primal-matrix-03`; the initial combined discovery remains frozen at the earlier `7ca64e6` revision. Scientific discovery dependencies are identical across these revisions. Subsequent changes add inspection, cache reuse, diagnostics, measured storage improvements and the reviewed construction-queue replay fix. The single-target pilot remains frozen on `matrix-02` (`c6aa554`).

- Native full suite on `matrix-03`: **718 passed**, one upstream Kaleido deprecation warning, 177.73 seconds.
- LGE focused checks after a fresh build: **87 passed** (78 XCTest and 9 Swift Testing).
- Real fresh and cached designs passed LGE publication and independent native audits.
- A cached-result bundle passed inspection, history and fresh audit after relocation while its original synthetic input, cache and prior bundles were temporarily unavailable. Originals were restored unchanged. [Relocation receipt](/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/lge-wrapper-relocation-01/provenance.json).
- Three current-binary failure-path checks retained byte-verified wrapper and native provenance.

These checks establish engineering behavior, not improved MHC coverage. GUI and managed-runtime changes remain deferred.

## Interpretation limits

- Dimer scores and exposure caps are computational screening policies, not calibrated probabilities of amplification failure or validated destructive thresholds.
- Specificity screening covers supplied MSA rows and declared seed/full-footprint uncertainty; it does not screen an unprovided genome.
- First-compatible discovery examines a bounded length prefix per row/anchor/profile. Longer alternatives require the explicit exhaustive-length option.
- Search is bounded. Unevaluated families/configurations cannot be called infeasible, and a sampled union is not a theoretical coverage ceiling.
- Exact support is conservative for primer mismatches; reports identify observed classes that remain unsupported.
