# Legacy candidate dimer salvage

## Authorized scope

Implement the user-requested narrow alternative to the allele-aware refactor: retain original legacy candidate generation and selection, then add useful candidates in sequential, bounded dimer-relaxation passes. Luna implements and tests; Astra reviews scientific contracts. The user explicitly authorized implementation and autonomous work; no additional approval loop is required. No GUI, installed runtime, full11 run, or mutation of saved baseline/cancelled artifacts.

## Scientific contract

- Opt-in legacy-only mode; ordinary legacy behavior stays unchanged with the feature off. Do not use the allele catalog/search or regenerate normal/high-GC candidates.
- Generate the legacy candidate pairs once at the configured original strict cutoff (normally -26), including its original intrinsic and F/R compatibility filters. Keep every generated pair available for salvage. This first version cannot recover pairs excluded during original generation.
- Run the original strict selector without changing its scoring, order, constraints or acceptance. Preserve every selected sequence, pair and pool throughout salvage.
- Default successive salvage cutoffs: -28, -30, -32. Default hard floor: -32. Finite strictly decreasing cutoffs must be below the strict cutoff and at or above the configured floor. An advanced floor override is explicit and recorded; scores are screening heuristics, not assurances of experimental performance.
- Only inter-candidate same-pool dimer admission is relaxed. Keep legacy overlap, MatchDB/product, geometry, amplicon-count and input restrictions. No cloud splitting, pair replacement, eviction, chemistry relaxation or new specificity policy.
- Each addition must provide positive marginal reference coverage after primer trimming across the union of all pools for its target. Use published half-open ungapped-reference coordinates, not alignment length or allele perfect-match coverage. Report full spans as a secondary metric. Default minimum gain one base, configurable.
- Rank remaining candidates by useful marginal reference coverage, with deterministic ties. Try both existing pools without moving incumbents. Recompute gain after each accepted addition. Prefer greater normalized target gain and lower existing target coverage on ties; preserve deterministic scientific IDs.
- Bound cumulative same-pool relaxed conflicts across all passes: defaults eight distinct sequence-pair edges and four distinct incident oligo sequences per pool, counting incumbents as well as new oligos. Deduplicate sequences and edges; compare at the ORIGINAL strict cutoff, not the current pass. Never reset budgets between passes. Every new interaction must satisfy the active cutoff and hard floor.
- Use the native Boolean dimer kernel for cheap admission. Compute/cache exact numeric scores only where needed to describe relaxed conflicts and enforce budgets. Do not construct a global candidate interaction graph or exhaustive origin ledger. Cache sizes and stage evaluation are bounded.
- Stop on no candidates/coverage gain, exhausted limits, all configured passes completed, or an explicit work bound. A pass adding nothing does not automatically forbid a later, looser configured pass. Never declare a global optimum.

## Traceability and CLI

Expose opt-in mode, threshold list, hard floor, cumulative edge/incident-oligo budgets, minimum added reference bases and any work cap through native CLI. Use a separate legacy namespace so existing allele salvage options and defaults do not change. Record resolved options.

Persist compact stable candidate identities from target occurrence, reference footprints and concrete sequence sets, not Python hash. For each evaluated candidate/pool/pass record accepted/rejected/not-evaluated status, reasons and gain; accepted additions record active cutoff, numeric relaxed-conflict witnesses and cumulative risk counts. Retain a candidate manifest and stage coverage/selection summaries. Avoid repeated per-attempt histories for identical evaluations. Reports distinguish the strict baseline from later salvage additions and include per-MSA coverage.

For this new scientific workflow, provenance is mandatory on success and failure: tool/version, exact argv, resolved options/defaults, runtime/source identity, ordered original input paths/checksums/sizes and preserved raw copies with unique names, output paths/checksums/sizes, exit status, wall time and useful stderr. Existing legacy duplicate-basename working-copy behavior must not lose provenance inputs. Reuse established provenance helpers without introducing allele-catalog dependencies.

Final validation freshly verifies preserved strict assignments, positive incremental reference gain, original nondimer rules, active cutoffs, hard floor, cumulative conflict budgets, published geometry and input/source/runtime identity. A relaxed panel must not be labeled strict-valid or experimentally guaranteed.

## Acceptance

1. Disabled mode preserves ordinary legacy scientific output; enabled strict stage matches ordinary legacy on identical inputs/settings.
2. Focused tests demonstrate strict rejection followed by bounded rescue; hard floor and cumulative budgets reject excess; other validity checks remain effective; duplicates do not inflate risk counts; coverage does not double-count overlap or alignment gaps; deterministic trace and valid failure provenance.
3. CLI evaluation on the same original A1+A2 MSAs, two pools and authentic legacy scientific settings as saved baseline. Report strict and each pass, geometry coverage after trimming/full spans, accepted additions/conflicts, runtime/memory/storage. No forced improvement claim if no admissible rescue exists.
4. Fresh validation/audit of final published output and one appropriate test suite after source settles. No broad parameter sweep.
