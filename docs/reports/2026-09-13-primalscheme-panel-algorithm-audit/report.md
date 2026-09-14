# PrimalScheme3-LGE panel algorithm review

**Decision: add an optional complementary panel selector. Preserve legacy behavior, but resolve constraint correctness and reproducibility before claiming the new selector produces comprehensive or optimal panels.**

Date: September 13, 2026. Reviewed runtime: PrimalScheme3-LGE `3.3.0+lge.2`, source commit `00eaa252446f01cabfeae71e10306a68cdb941d6`; LGE CLI `2026.9.21`. The installed package, rather than the different local PrimalScheme checkout, was the authoritative source. Its source-file hashes are retained in `metrics.provenance.json`.

Three parallel reviews covered selection/optimization, candidate generation/primer support, and scaling/state management. The selection reviewer also performed a skeptical review of the combined recommendation. The coordinating review independently checked key source paths, reran the synthetic selector example, reproduced compatibility/state defects, and verified five real HLA result bundles. These are software reviews and computational observations, not laboratory validation.

## What the algorithm actually does

The current combined-panel path already builds a large candidate pool. It discovers forward/reverse primer clouds for every MSA and enumerates size-eligible cloud pairs that pass the intrinsic interaction test. Only after processing all MSAs does it construct the panel. The original nine-HLA run generated **50,969 candidate amplicons**, then selected 44. High-GC mode generated **165,012**, then selected 47.

The limitation is an **irreversible greedy selection process over a restricted candidate universe**, not the absence of precomputed candidates. Each turn visits the next MSA in input order, rescoring and sorting that MSA's candidates, then takes the first acceptable candidate and first acceptable pool. Previous choices are never swapped or reassigned. An MSA is finished after a full unsuccessful scan. That stopping rule is reasonable for the add-only search: adding more primers cannot remove an existing overlap or interaction. The missed opportunity is revisiting earlier decisions that created the blockage.

The score is marginal primer-trimmed reference coverage, adjusted for GC proximity, with a **10-fold bonus** when a candidate crosses a covered/uncovered boundary. Ties favor fewer oligos. This is a local heuristic; it does not optimize a global per-MSA coverage floor, anticipate conflicts with scarce candidates at other loci, minimize target-size deviation, or balance oligo burden across pools. `polish()` is unfinished and uncalled. The independent-scheme backtracking option is not implemented for combined panels.

Source: [candidate construction](/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3/panel/panel_main.py:239), [pair enumeration](/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3/core/digestion.py:122), [selection](/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3/panel/panel_classes.py:333), [scoring](/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3/panel/panel_classes.py:436), [unfinished polish](/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3/core/multiplex.py:469).

## Evidence from the HLA designs

All designs use the same nine MSAs, each containing 20 rows, a nominal target of 200 bp, first-row mapping, observed-only discovery, equal panel mode, and no count limits. The percentages in this table are **unions of full reference amplicon envelopes, including primer sites**. Every successful bundle's artifact hashes, sizes, execution paths, and size bounds were independently checked. Complete per-locus full-span and primer-trimmed metrics are in [metrics.json](/Users/dho/Documents/lungfish-genome-explorer/docs/reports/2026-09-13-primalscheme-panel-algorithm-audit/metrics.json).

| Run | Bounds | Pools | Candidates | Selected | C | E |
|---|---:|---:|---:|---:|---:|---:|
| Original, ordinary primer settings | 150–280 | 2 | 50,969 | 44 | 84.92% | 77.34% |
| Reversed input order, ordinary settings | 150–280 | 2 | 50,969 | 43 | 84.92% | 96.84% |
| Explicit narrow control, ordinary settings | 180–220 | 2 | 16,376 | 45 | 85.47% | 73.63% |
| Ordinary settings, three pools | 150–280 | 3 | 50,969 | 51 | 93.28% | 96.94% |
| High-GC settings | 150–280 | 2 | 165,012 | 47 | 98.00% | 99.44% |

The reversed-order run gained E coverage but reduced A from **90.07% to 82.24%** and B from **91.18% to 81.18%**. It is evidence of consequential selection sensitivity, not a universal improvement. It also shows why better aggregate or minimum coverage is not equivalent to protecting each locus.

There is a confound: candidate order is initially randomized using native `FKmer.__hash__()`, followed by stable sorts with frequent score ties. Identical objects produced different hashes in five fresh-process checks. These are object-identity hashes, not semantic candidate identifiers controlled by a recorded seed. Equal candidate counts do not by themselves establish identical candidate membership. Consequently, the real reversed-order result is described as **input-order/re-run sensitivity**, not a clean measurement of the isolated causal effect of input order. A clean test must freeze canonical candidate membership and tie handling.

The explicit narrow control used the same `reference-span` size metric as the wide designs. It generally performed worse here, despite selecting one more amplicon; it improved C only slightly. Widening increased candidate count approximately threefold, as expected. It did not guarantee an improvement at every locus. Comparisons with flagless defaults require additional care because omitted bounds retain the separate `legacy-pairing` metric.

Full-span and usable interior coverage should not be conflated. In the high-GC design, C/E full-span coverage is 98.00%/99.44%, whereas primer-trimmed coverage is **94.19%/95.36%**. DPB1 full-span coverage is 94.21%, but its primer-trimmed coverage is **88.67%**. None of these coordinate metrics establishes that every allele can be amplified.

The two new controls initially failed under sandbox restrictions: the managed conda root was unwritable, and an executable-override retry failed in the Kaleido plot renderer. Both controls were then rerun successfully with the ordinary managed runtime. Only the completed, verified managed runs enter this table; failed-run logs are retained under `outputs/primalscheme-panel-audit-2026-09-13`.

Source: [initial hash ordering](/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3/panel/panel_main.py:374), [synthetic checks](/Users/dho/Documents/lungfish-genome-explorer/docs/reports/2026-09-13-primalscheme-panel-algorithm-audit/checks.json).

## A direct counterexample using the real selector

An interval-only test invoked the installed `Panel.add_next_primerpair` and real coverage bookkeeping. It replaced sequence chemistry with one declared candidate conflict. No biological input was used.

MSA A has a locally better candidate covering 100 positions and a compatible alternative covering 90. MSA B has one candidate covering 100 positions. A's locally better candidate conflicts with B's only candidate in the single available pool; A's shorter alternative does not.

| Input order | Selected combination | Covered target positions |
|---|---|---:|
| A, B | A's locally best candidate | 100 |
| B, A | B's candidate plus A's compatible alternative | 190 |

This proves the existing selection procedure can miss a better feasible combination because of order. It does not predict the size of the effect in a real HLA panel. The coordinator reran the assertions successfully. [Probe source](/Users/dho/Documents/lungfish-genome-explorer/docs/reports/2026-09-13-primalscheme-panel-algorithm-audit/evidence/selection-counterexample.py), [output and original runtime provenance](/Users/dho/Documents/lungfish-genome-explorer/docs/reports/2026-09-13-primalscheme-panel-algorithm-audit/evidence/selection-counterexample.json).

## Findings that matter for approximately 100 MSAs

| Finding | Classification | Consequence |
|---|---|---|
| Fixed round-robin, first-feasible pool, no swaps or repair | Confirmed heuristic limitation | Early choices can consume pool compatibility needed by difficult loci; extra candidates or wider bounds need not improve the final solution. |
| No global coverage-floor/scarcity objective | Confirmed objective limitation | A high mean coverage can hide undercovered MSAs; equal visitation is not equal final coverage. |
| Identity-based tie order with no recorded seed | Confirmed reproducibility defect | Repeated search outcomes cannot be cleanly compared or replayed from a scientific seed. |
| Only the first Tm-reaching length per row/anchor path is retained | Confirmed candidate-space limitation | The large pool still omits potentially useful length/sequence alternatives at the same binding anchor. |
| Independent terminal-row support at each end; no paired allele support | Confirmed representation limitation | Candidate coordinate coverage can overstate support for amplification of complete alleles. |
| Full candidate sorts, repeated score scans, repeated chemistry/match work | Confirmed scaling concern | Cost follows candidate count, cloud size, cross-locus similarity, selected oligos, and alignment dimensions—not MSA count alone. |

**Candidate completeness.** Observed-only walking returns at the first length that reaches minimum Tm, then screens the resulting oligos. It does not enumerate every valid primer length. Failure of an oligo can reject an entire cloud/anchor; a selector cannot recover an alternative never generated. First preserve discovery to isolate selector improvements, then add targeted alternative discovery around unresolved gaps. Any subcloud proposal must preserve its stated allele-support requirement; simply dropping troublesome alternatives changes the biological design problem.

**Allele support.** Terminal missing rows are removed from frequency denominators independently at each anchor. Clouds keep sequence counts but not the original row-to-oligo relationships needed to establish that both ends are supported on the same allele. With partial alignments, independent end support is insufficient. Missing sequence should be recorded as unknown rather than assumed binding or assumed failure. For the current requested metric, reference-span coverage remains useful, but a robust larger-panel workflow should also retain and report paired row support and individual allele product spans.

**Reference coordinates.** Coverage arrays are allocated with alignment width even when candidate coordinates are mapped to the ungapped first reference. A reference containing alignment gaps can therefore leave phantom tail positions in internal coverage percentages. The nine current MSAs have matching alignment/reference lengths, so this does not affect the table. It needs a dedicated gapped-reference regression case before the larger-panel objective is trusted.

Source: [first forward length](/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3/core/digestion.py:207), [first reverse length](/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3/core/digestion.py:294), [observed-only denominator](/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3/core/digestion.py:519), [cloud construction](/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3/core/digestion.py:479), [coverage allocation](/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3/core/multiplex.py:195).

## Correctness prerequisites before a new optimizer

**1. Make the product-specificity constraint real and explicit.** The installed configuration defaults to `use_matchdb=True` and `mismatch_product_size=0`. The rejection condition is `0 < distance < product_size`, so it can never reject at that default. A synthetic pair of hits 100 positions apart returns false at zero and true at 2000. Thus the prior HLA runs should not be described as having passed an active cross-product rejection screen merely because MatchDB was enabled. The flag's presence does not establish the behavior.

Changing zero to a positive number alone is insufficient. `remove_expected=True` retains only unexpected hits in the old primer's own MSA and discards cross-MSA hits. New candidates are checked against that incomplete old state. The semantics of intended products, cross-MSA/paralog products, same-allele occurrence, product distance, and background search space need to be specified together. Currently the database is built from supplied MSAs, not a complete genomic background.

Source: [default](/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3/core/config.py:95), [product detector](/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3/core/mismatches.py:249), [forward filtering](/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3/core/mismatches.py:132), [reverse filtering](/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3/core/mismatches.py:163), [stored pool hits](/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3/core/multiplex.py:320).

**2. Use correct reversible search state.** Existing removal clears Boolean coverage intervals and difference-removes hit tuples even if retained amplicons still contribute them. It also does not restore the panel's score array. A synthetic coverage check retained an amplicon covering 40 positions but reported only 20 after removing another overlapping amplicon from a different pool. This helper cannot simply be called from a new local-search loop. Use contribution counts or rebuild state from selected candidates after changes. Candidate objects must be immutable; pool assignment and numbering belong to separate solution state.

Source: [removal](/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3/core/multiplex.py:341), [Boolean coverage updates](/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3/core/multiplex.py:252), [reproduced state defect](/Users/dho/Documents/lungfish-genome-explorer/docs/reports/2026-09-13-primalscheme-panel-algorithm-audit/checks.json).

**3. Validate independently.** Final validation must recompute coverage and all specified constraints from immutable oligos, alignments, and assignments. Replaying the same incremental acceptance method would reproduce its mistakes. Version the constraint profile separately from the selector. A legacy output is a usable feasible starting solution only if it passes the selected profile; correcting specificity semantics may invalidate it. Do not silently weaken checks to improve a coverage score.

The reviewers also identified region-group index/counter issues, but fresh whole-MSA equal/entropy panels do not use them. Region/imported-primer modes should remain outside the first new selector's supported scope until separately reviewed.

## Algorithm options and recommendation

| Option | Strength | Limitation | Recommendation |
|---|---|---|---|
| Cache and speed up legacy only | Low behavioral risk; useful baseline | Leaves irreversible choices and objective problems | Do as supporting work, not the complete solution. |
| Multiple reproducible starts plus bounded swap/repool/refill repair | Reuses discoveries, jointly revisits candidates and pools, returns best solution found within a budget | Heuristic; cannot certify the global optimum or recover undiscovered candidates | **Primary complementary selector.** |
| Full CP-SAT/MILP over every candidate and pool | Precise mathematical model; potential bounds and proofs | Building the model/conflicts can dominate runtime and memory | Keep experimental; use restricted neighborhoods first. |

The proposed selector should:

1. Freeze candidate records with stable IDs derived from logical input identity, mapped coordinates, canonical oligo clouds, support information, and discovery settings. Preserve rare-coverage candidates and alternatives around gap boundaries.
2. Validate and retain the legacy solution as a starting solution when its constraints match. Also try reproducible starts favoring difficult/undercovered loci, candidates with few alternatives, and different pool allocations.
3. Maintain the best valid solution while exploring bounded changes: remove a small conflicting set, swap in alternatives, reassign pools, then refill gaps. Track accepted objective improvements and stop reason.
4. Compute and cache conflicts only when needed. Use an independent final check before publishing any result. In the add-only phase, failed-pool caches are monotone; invalidate or rebuild them during removal/repooling.
5. Optionally solve a restricted CP-SAT neighborhood containing selected candidates and alternatives near bottlenecks. A proof or bound for this subset is not a proof of global optimality over all possible candidates.
6. Later, expand discovery selectively where the best frozen-pool result still has gaps. Separate this from selector-only benchmarks so its contribution is measurable.

Repeated randomized starts and pool swapping have precedent in published primer-pooling work: PrimerPooler uses multiple starting points, hill climbing, and perturbation/restarts while retaining the best pool allocation. It operates on supplied primers rather than solving this full MSA discovery-plus-selection problem; it supports the approach, not a claim that it can replace PrimalScheme directly. [PrimerPooler paper](https://pmc.ncbi.nlm.nih.gov/articles/PMC6994079/).

For exact subproblems, distinguish feasible, optimal, infeasible, and unknown outcomes. A time-limited feasible result is not a proof of optimality, and a restricted-model optimum applies only to that model. [OR-Tools CP-SAT status definitions](https://developers.google.com/optimization/cp/cp_solver).

## Objective and guarantees

For the user's current full-span reference-coverage goal, a proposed lexicographic objective is:

1. Minimize the worst normalized per-MSA shortfall from the chosen coverage threshold.
2. Minimize total normalized shortfall, then maximize additional normalized unique coverage.
3. Minimize oligo/amplicon burden and pool imbalance, with target-size deviation and primer quality as further tie-breakers.

This is a proposed policy, not an existing option. The primary metric must be explicit: full-span reference coverage, primer-trimmed reference coverage, or supported allele coverage. Report all applicable metrics separately. Impossible or candidate-unreachable targets should have explicit shortfalls and optimistic candidate-union bounds; do not hide them by quietly changing the denominator.

Keeping a valid baseline ensures **no worse under the same objective and constraints**. It does not guarantee no locus loses coverage. An optional conservative mode can enforce each locus's baseline coverage as a floor, with the understood cost of forbidding some useful tradeoffs. Widened-bound monotonicity is defensible only if the old candidate set remains feasible, the old solution is retained, and the same objective/constraints are used. No such guarantee applies across changed GC presets, discovery backends, specificity profiles, or sizing definitions.

## Scaling strategy and benchmark gates

With candidate count C, constructing every candidate-pair relation costs O(C²). The original 50,969 candidates already imply about **1.3 billion unordered pairs**; the high-GC candidate pool implies about **13.6 billion**. Actual conflicts can be sparse and many candidates share oligos, so a dense graph is the wrong default.

The existing selector repeatedly scans interval scores, sorts each MSA's entire candidate list after selections, rebuilds pool oligo lists, and repeats chemistry/mismatch work. Use cached per-oligo matches, lazy candidate-pair conflicts, compact interval/coverage structures, and incremental scoring. Cache identities must include scientific inputs, reference mapping, discovery and specificity settings, native-kernel identity, and schema version. Top-N candidate pruning is a heuristic and must be disclosed; safe dominance would require no worse coverage/quality and no additional conflicts, not merely a better local score.

Discovery processes MSAs sequentially and starts a fresh worker pool for each observed-only MSA. At approximately 100 MSAs, a bounded shared scheduler and reusable/read-only alignment storage warrant profiling. Changing worker architecture must preserve canonical candidate membership and cancellation behavior. The optimum workload partition depends on row counts, lengths, ambiguity, cloud sizes, and homology.

Source: [repeated sorts and pool construction](/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3/panel/panel_classes.py:369), [uncached match composition](/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3/core/classes.py:65), [MatchDB construction](/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3/core/mismatches.py:31), [per-MSA multiprocessing](/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3/core/parallel_discovery.py:109).

No representative 100-MSA benchmark was supplied or run in this review. Do not extrapolate runtime from nine MSAs or promise a speedup. Before release, benchmark frozen panels at increasing scale up to approximately 100, varying family similarity, MSA row count, alignment length/gaps, cloud complexity, pool count, and explicit size range. Retain the nine-HLA ordinary/high-GC cases as regressions. Duplicating the same nine loci is not an adequate substitute for a representative 100-MSA corpus.

Required validation gates:

- Tiny synthetic instances checked against exhaustive feasible optima; demonstrate known greedy counterexamples are repaired.
- Identical canonical candidate membership for selector-only comparisons; source order and object identity cannot affect deterministic results. Fixed seeds and search budgets must reproduce canonical scientific outputs; volatile UUIDs/timestamps are compared separately.
- Randomized add/remove/swap/repool state checks against a full rebuild; no stale coverage, score, match, or rejection cache state.
- Every published solution passes the independent constraint validator, reports unmet floors, and is no worse than its valid starting solution under the declared objective. A conservative mode additionally protects each locus.
- Cold/warm stage profiles, wall/CPU time, peak memory, candidate counts, unique oligos, rejection reasons, cache hits, starts/moves, and incumbent history. Set operational time/memory acceptance thresholds from those measurements and actual user needs, not invented percentages.
- Any exact solver reports status, budget, and the scope of its bound. Timeout returns the best validated result with a clear stop reason.
- Gapped-reference and partial-row tests verify denominator correctness, unknown support, same-row paired binding, and individual product spans.

## Integration and provenance

Add an explicit algorithm choice to the fork and LGE adapter; the existing legacy path remains available with its recorded historical semantics. Suggested names are illustrative, not current CLI flags. A first release should support fresh linear, first-reference, whole-MSA panels; other modes need separate validation.

Record the algorithm/version, objective ordering and coverage metric, threshold/floors, constraint profile, exact argv and all resolved defaults, seed/start schedules, time/work budgets, native and solver identities, candidate catalogue checksum, cache provenance, starting/final objective vectors, per-locus metrics, validation results, stop reason, and any solver bounds. Preserve the existing runtime/input/output hashes and sizes, wall time, status, stderr, and durable stored paths. Candidate catalogues and refined output bundles are scientific artifacts and need the same provenance discipline.

Changes to default sizing or specificity semantics should receive separate versioned treatment. The new selector is not a reason to silently reinterpret old bundles. No production algorithm, installed environment, or user scheme was modified by this review; the only new designs are the separate audit controls.

**Recommended next development decision:** proceed with an opt-in joint candidate-selection/pool-repair algorithm, preceded by the shared correctness validator and stable candidate representation. Keep exhaustive global optimization and broader candidate discovery as separately benchmarked extensions. The evidence supports this direction; it does not yet establish a production-ready 100-MSA optimizer.
