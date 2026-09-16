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

## Single-target Mamu-A1 pilot

The isolated `matrix-02` pilot uses the original six-row Mamu-A1 alignment, with the same scientific settings and search budgets as the initial combined run. The completed strict tier passes its independent native stage validation and selects 10 amplicons, with **39.1308%** mean coverage after trimming across distinct observed classes (individual classes 32.1160–43.0336%). All three salvage tiers have the same mean coverage. Native execution and a fresh whole-bundle audit both succeeded. The outer benchmark wrapper subsequently failed because it looked for the panel receipt under the wrong filename; that failure was preserved, and a separate completion verification validates the actual `panel-provenance.json` and audit receipt.

This is below the saved independent panel’s 86.7446% common-metric coverage. The original input bytes match; the historical panel has not thereby been shown to pass the new constraints. This result is not an improvement claim or evidence about compatibility in the combined panel.

A separate code review found that construction queue refresh can reconsider consumed candidates and spend search attempts on them. The regression-tested fix is included in `matrix-03`; the cached single-target comparison below includes that fix. One shared deadline also permits initial seed passes to exhaust time before subset construction and repair. The final counters show strict selection completed its two work-capped seed passes but expanded only 32 of 143,297 families and reached no repair rounds. Later salvage tiers also suffered seed starvation. Among the strict configurations examined, specificity failed for 2,797 of 2,859, while dimer failed for 206 (204 also failed specificity). These are examined-configuration counts, not a full-catalog feasibility estimate.

[Completed strict coverage](/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mamu-a1-union-subsets-pilot-01/stages/strict/coverage.json) and [strict validation](/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mamu-a1-union-subsets-pilot-01/stages/strict/validation.json).

### Cached serial control on matrix-03

Reusing the identical A1 catalog with the reviewed queue fix and history v2 gives **46.0385%** mean trimmed coverage, with 10 amplicons and per-class fractions 40.6485–47.2898%. The native panel and independent audit both succeed. Search remains limited to 120 seconds: it examines 2,032 full-seed and 4,528 normal-seed families, expands 32 families, and reaches zero repair trials. This is a 6.91 percentage-point gain over the first pilot, but is still well below the saved independent panel. Wall-limited comparisons include storage/runtime effects and do not isolate a single code change.

Native panel wall time is 323.29 seconds and fresh audit time is 126.11 seconds; the outer runner records 3.27 GB native peak RSS under Darwin wait4 accounting. This control omits salvage because the strict result is the comparison of interest. Its original copied wrapper had the same receipt-name post-check error, preserved alongside a successful separate [completion verification](/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mamu-a1-cached-serial03-01-completion-verification/provenance.json).

The specificity diagnosis identifies many predicted products at the designated full footprints that fail only because coverage-derived intended signatures require exact sequence support. A separate opt-in `concrete-designated-sites` correction is being implemented and independently reviewed; no coverage credit for near-matches is proposed, and shifted or incomplete footprints remain distinct.

### Matched phase-scheduling controls on matrix-04

The serial control on frozen `1217c5c` reproduced **46.0385%** mean coverage and 10 amplicons. Native execution, the separate raw-row audit, and the outer provenance verification all succeeded. Native wall time was 326.70 seconds, audit 127.41 seconds, and native wait4 peak RSS 3.96 GB. Its 120-second search spent 61.99 seconds in the full seed pass, 31.45 seconds in the normal seed pass and 26.56 seconds in subset construction. It expanded 16 families and reached no repairs. Identical selected coverage despite different work counts illustrates the limits of wall-clock comparisons.

The matched optional `reserved` scheduling control completed with **39.4684%** mean coverage and 10 amplicons. Its native run, independent audit and wrapper verification succeeded. The resolved settings differ only in phase scheduling. It reached repair work (26 candidate probes, two neighborhoods and four trials), but accepted no repairs. Native wall time was 330.21 seconds and audit 127.35 seconds. This run does not support making reserved scheduling the default; serial is retained. [Paired comparison and provenance](/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mamu-a1-phase-comparison04-01/comparison.json).

[Serial control provenance](/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mamu-a1-cached-serial04-01-execution/provenance.json).

### Intended-site policy diagnostic on matrix-05

Two completed, independently audited controls differ only in `intended_product_policy`. At 120 seconds, exact-supported gives **46.0385%** mean A1 coverage; concrete-designated-sites gives **15.0005%** and three amplicons. The latter performs 4,929 pair checks versus 576 and reaches only seed work. This is not evidence that permitting designated near-matches lowers the feasible coverage ceiling: it changes which candidates reach the more expensive pair screen and therefore the work completed within the deadline. A completed 600-second run with the same original work caps improves the concrete-designated-sites result to **28.3224%** and four amplicons. It passes its independent audit, explores 151 subset families and makes 19,073 pair checks. About 364 seconds go to repair exchange; none of its 26 repair trials improves the incumbent. Native wall time is 824.62 seconds, fresh audit 130.26 seconds and wait4 peak RSS 5.30 GB. The matched ten-minute exact-policy control also passes its independent audit: **46.7945%** mean coverage with 13 amplicons, versus 46.0385% and 10 at 120 seconds. It accepts three repair exchanges, but still reaches the wall deadline during its first repair exchange. Native wall time is 849.00 seconds, fresh audit 137.14 seconds and native wait4 peak RSS 3.24 GB. The policy comparison receipt confirms that intended-product policy is the only differing resolved scientific/search option.

[Matched policy comparison](/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mamu-a1-intended-policy-comparison05-01/comparison.json) and [provenance](/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mamu-a1-intended-policy-comparison05-01/provenance.json).

### Search quality budget

The user explicitly permits an hour or longer for effective design. The 120-second controls above are diagnostic runs, not the final quality target. Longer cached comparisons will distinguish time exhaustion from deterministic work caps, record whether additional search improves target/class coverage, and inform a practical thorough configuration. A longer wall-clock limit alone does not guarantee broader exploration: construction attempts, repair work and family expansion are also bounded.

The residual pair diagnosis identifies 2,740 explored pair records whose only recorded failure is specificity and whose rejected products all have complete ordered, concrete, terminal-supported four-site geometry. That is a count of recorded pair verdicts, not jointly feasible placements or attainable coverage. The separately reviewed optional `ordered-disjoint-concrete-designated-sites/v1` secondary-product policy is implemented in native `61d6ac8`. All four selected occurrences, internal partners and raw-row certificates are required, and coverage remains exact-only. Its integrated frozen build passes 794 tests. A completed 600-second A1 diagnostic with both concrete policies reaches **86.7190%** mean trimmed coverage and 18 amplicons, with allele classes at 84.5916–89.4539%. Native execution and the separate authoritative audit both succeed; all input/source/runtime identities are unchanged. The result retains 403 permitted concrete intended witnesses and 1,740 secondary witnesses, including 1,380 new four-site certificates. Native wall time is 830.67 seconds, fresh audit 131.53 seconds and native wait4 peak RSS 7.33 GB. This is a descriptive comparison with the earlier 28.3224% concrete-intended/old-secondary result: the frozen builds also differ in reviewed progress observation. It nearly matches the saved independent panel’s 86.7446% under the common metric, but remains below the 95% aim and does not establish combined-panel compatibility. The matched same-settings cache-enabled run (`20fe136`) also passes its audit with exactly the same selected coverage and 18 amplicons. It expands 69 versus 53 families, makes 25,701 versus 23,124 pair checks, and reaches six versus two repair trials within 600 seconds. Native wall time is 830.97 seconds, audit 130.20 seconds and peak RSS 7.82 GB. More search work did not itself yield another coverage gain. The independently reviewed diagnostic-cache compression change preserves complete evidence in compressed private memory entries. An hour-long A1 run on frozen `01cafef` is evaluating eight starts, three repair rounds, 8,192 construction attempts and 32 families per refresh, with strict −26 dimer screening and both concrete-site policies. This changes several search controls together; it is a quality experiment, not an isolated speed comparison. Its provisional progress is not a final audited panel.

## Candidate availability and retained variants

An independently reviewed finite-catalog diagnostic examines all **143,297 A1 families**, 10,191 eligible sites and six distinct classes (859,782 family/class checks). Ignoring scientific interactions and panel limits, the stored candidates can supply **97.2349%** mean exact-binding trimmed coverage; class fractions range from **96.8633% to 97.9500%**. Both the singleton-pair union and the all-subset relaxation give that same union here. The calculation includes a longer nonbinding variant when needed to satisfy a configuration’s minimum reference envelope, avoiding an invalid singleton-only ceiling.

This is an upper bound within this finite catalog and current coverage/geometry model, **not a feasible multiplex scheme**. It ignores specificity, self/pair dimers, pooling/overlap and panel limits. It neither proves attainable 95% coverage nor bounds undiscovered primers. It shows that missing candidate binding sites alone do not explain the ten-minute panel’s 86.7190% coverage. The only uncovered intervals in the relaxation are terminal intervals; the actual selected panel additionally has internal gaps.

The diagnostic independently reconstructs the selected coverage and confirms its inclusion in the relaxation. Among 18 selected configurations, one at BED `[2164,2413)` retains **2 of 3 eligible forward variants and 4 of 5 reverse variants**, while still supporting all six classes. Two others deliberately retain useful partial support: `[85,315)` supports three classes and `[217,399)` supports five. These are descriptive selected supports; the report does not infer why a particular variant was omitted.

Execution completed successfully in76.50 seconds, with unchanged input/source/runtime identities. [Availability, per-class intervals and selected-variant report](/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mamu-a1-catalog-availability-01/availability.json) and [receipt](/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mamu-a1-catalog-availability-01/provenance.json).

## Mamu-A1 394–644 regional alternatives

The completed ten-minute panel (`secondary07`) covers **200 of 250 observed bases, 80%**, in every one of its six distinct classes for reference BED interval `[394,644)`. Coordinates are zero-based and half-open; the report projects them through the alignment and preserves each row’s coordinates. The nearby selected amplicons span `[217,399)`, `[410,648)` and `[614,818)`; full amplicon spans do not count as trimmed coverage.

All 989 historical normal/high-GC alternative records match current eligible catalog sites, yielding 903 distinct configurations. The diagnostic examines a bounded 16 configurations, ranked by trimmed reference overlap. All 16 pass fresh individual validation. None can be added directly to either existing pool: all 32 insertion checks fail overlap, 31 also fail specificity, and 15 fail strict dimer/exposure checks. A zero strict exposure allowance makes the latter two labels describe the same relaxed-edge prohibition, not separate evidence of damage. The alternatives individually cover 82.8–84.0% of this region under the exact binding model; no simultaneous feasibility is implied.

These results support testing replacements or shifts of existing amplicons. They do not establish that every alternative has been rejected, that a replacement will succeed, or that relaxing dimers alone can repair these placements. The other 887 distinct configurations remain untested by this bounded insertion diagnostic. The three nearby selected families retain all their eligible variants; omission causes are not inferred.

The source panel passed a fresh scientific audit before these checks. The diagnostic completed in 1,098.47 seconds with unchanged source/runtime/input identities. [Full regional report](/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mamu-a1-region394-644-secondary07-01/diagnostic.json) and [reproducibility receipt](/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mamu-a1-region394-644-secondary07-01/provenance.json).

## Engineering verification

The native implementation and LGE CLI integration have passed independent Astra reviews. The latest frozen native evaluation revision is `158a4a3` in `allele-aware-primal-matrix10`; the initial combined discovery remains frozen at the earlier `7ca64e6` revision. Scientific discovery dependencies are identical across these revisions. Subsequent changes add inspection, cache reuse, diagnostics, measured storage improvements and the reviewed construction-queue replay fix. The single-target pilot remains frozen on `matrix-02` (`c6aa554`).

- Native full suite on `matrix10`: **854 passed**, one upstream Kaleido deprecation warning, 193.08 seconds.
- Latest integrated LGE focused run: **150 passed**, seven environment-gated tests skipped, zero failures (157 total). The real A1 integration was run separately with its environment enabled: one passed in 251.64 seconds, including all 1,380 real four-site certificates, stored-bundle inspection/history and a fresh relocated raw-row audit.
- Real fresh and cached designs passed LGE publication and independent native audits. The matrix10 effort smoke also verified explicit old-default overrides, inherited quality values, saved inspection/history/audit, and failure provenance when an older native executable rejects an unsupported quality request.
- A cached-result bundle passed inspection, history and fresh audit after relocation while its original synthetic input, cache and prior bundles were temporarily unavailable. Originals were restored unchanged. [Relocation receipt](/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/lge-wrapper-relocation-01/provenance.json).
- Three current-binary failure-path checks retained byte-verified wrapper and native provenance.

These checks establish engineering behavior, not improved MHC coverage. GUI and managed-runtime changes remain deferred.

## Interpretation limits

- Dimer scores and exposure caps are computational screening policies, not calibrated probabilities of amplification failure or validated destructive thresholds.
- Specificity screening covers supplied MSA rows and declared seed/full-footprint uncertainty; it does not screen an unprovided genome.
- First-compatible discovery examines a bounded length prefix per row/anchor/profile. Longer alternatives require the explicit exhaustive-length option.
- Timing measurements came from a shared development machine with concurrent cold discovery and engineering work; they are not isolated performance benchmarks. Work counters accompany the wall-limited comparisons.
- Search is bounded. Unevaluated families/configurations cannot be called infeasible, and a sampled union is not a theoretical coverage ceiling.
- Exact support is conservative for primer mismatches; reports identify observed classes that remain unsupported.
