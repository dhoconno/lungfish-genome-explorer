# Allele-aware PrimalScheme candidate selection and bounded salvage

Date: 2026-09-15
Status: Detailed design for user review; implementation has not begun.

## 1. Objective and agreed decisions

Develop the native PrimalScheme3-LGE algorithm and validate it using the CLI and the user's macaque MHC/KIR data. Integrate the improved scientific contract into the Lungfish CLI next. GUI work begins only after the user explicitly accepts the CLI evidence.

User decisions:

- Combine normal and high-GC candidate discovery by default in the new algorithm.
- Optimize coverage **after primer trimming**, aiming for greater than 95% of each target MSA.
- Treat that coverage goal as an aspiration, not a validity or publication threshold.
- Weight each distinct observed allele equally; duplicate rows must not increase its weight.
- Retain useful partial allele coverage. An amplicon does not need to support every allele.
- Remove individual conflicting primer variants when that preserves a useful amplicon. Do not reject a cloud solely because one member conflicts.
- Attempt strict selection and conflict-aware repair at dimer score -26 before optional permissive salvage.
- Astra owns scientific architecture, integration review and benchmark interpretation; delegate bounded implementation to Sol or Luna where appropriate.

This is a computational design system. Dimer scores do not provide calibrated probabilities of experimental failure or a validated destructive-interaction boundary.

## 2. Existing software and evidence

### Repositories

- LGE: `/Users/dho/Documents/lungfish-genome-explorer`.
- Native coverage implementation: `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/primalscheme-panel-fork`, reviewed at `2abc3207629aacb101f1c04a4f57348ef5b903b2`. This directory is a separate clone, despite its location.
- `/Users/dho/Documents/primalscheme3` is an older checkout without the coverage modules; do not implement there accidentally.
- Managed runtime remains `3.3.0+lge.2`. Existing explicit-executable coverage integration uses `3.3.0+lge.3`.

Extend the existing `coverage_types`, `coverage_catalog`, `coverage_search`, `coverage_specificity`, `coverage_validation`, `coverage_pipeline` and `coverage_provenance` modules. Do not create a competing end-to-end optimizer.

Existing `primer-trimmed` coverage is first-reference interval coverage, not the new allele-aware objective. Historical artifacts and their metrics retain their existing meaning.

### Local scientific fixtures

Project: `/Users/dho/Desktop/sandbox/mhc-primal-scheme/mhc-primal-scheme.lungfish`.

- `Analyses/MHC v1.lungfishprimeranalysis`: 11 independent designs.
- `Analyses/MHC merged v1.lungfishprimeranalysis`: combined two-pool design.
- Audit evidence: `/Users/dho/Desktop/sandbox/mhc-primal-scheme/combined-diagnosis-20260915`.
- Earlier comparison: `/Users/dho/Desktop/sandbox/mhc-primal-scheme/diagnosis-20260915`.

The original Mamu-A1 catalog contains 10,067 pairs. Normal discovery provides 121 pairs overlapping BED interval [394,644), none compatible with the final saved pools at -26. High-GC discovery provides 868 overlapping pairs, seven individually compatible, including [408,657) in Pool 2. These counts are historical profile-specific evidence, not required output counts for the expanded variant-preserving algorithm.

The saved lge.2 product-distance value of zero disables its cross-product rejection. Historical results must not be described as independently validated under the new specificity contract. The previous lge.3 delivery report also documents poor coverage under its stricter specificity contract; it is not an established quality baseline.

## 3. Scope and non-goals

Initial supported scope: fresh linear combined whole-MSA panels, observed-only missing-data policy, first-reference BED export, user-selected positive pool count, explicit reference-span bounds. The MHC benchmark uses 2 pools, target size 200 and bounds 150–250.

In scope: dual-profile discovery, individual-variant retention, observed-allele coverage, bounded search and exchanges, strict and salvage alternatives, independent validation, CLI artifacts, complete provenance and explanation of uncovered regions.

Not in this implementation: wet-lab protocol optimization, guaranteed global optimality for full panels, automatic reaction-condition changes, adding pools without request, unrestricted mismatch rescue, empirical allele-frequency inference, independent-scheme redesign, GUI controls or managed-runtime release. Partial observations are not imputed into full alleles.

## 4. Versioned scientific contract

Introduce `--selection-algorithm allele-coverage` without changing the meaning of `legacy` or `coverage`. Reserve native package version `3.3.0+lge.4` for this contract; confirm availability at execution and revise all pins together if already occupied. Use explicit local executable overrides during CLI development.

New algorithm ID: `bounded-allele-coverage/v1`.
New metric ID: `observed-allele-primer-trimmed/v1`.
New constraint profile: `allele-panel-v1`.
New specificity revision: `selected-sites-v2`.

Use v2 schemas for catalog, optimizer, validation, provenance and native integration records. Capabilities must advertise supported versions explicitly. Keep old readers/validators for old contracts; reject unsupported combinations rather than partially decoding them. Every selected configuration must be resolvable from an immutable catalog and explored-configuration ledger.

## 5. Discovery and catalog

### 5.1 Two profiles, one chemistry model

Normal profile: GC 30–55%, length 19–36. High-GC profile: GC 40–65%, length 17–30. Both use configured Tm limits 59.5–62.5 C and the existing explicitly recorded effective thermodynamic tolerances, including the current +2 C upper check. Record chemistry concentrations, hairpin/homopolymer limits and kernel versions. Do not silently change thermodynamic behavior in this project.

The new mode defaults to `--candidate-profiles union`; `normal` and `high-gc` are CLI-only ablation choices. The legacy `--high-gc` option remains for historical modes but is rejected with `allele-coverage`. Future GUI integration removes the profile toggle for the new default workflow only.

Do not validate union candidates against a synthetic envelope of all profile limits. Each selected oligo must pass at least one complete declared profile. An oligo may have multiple accepting profiles.

Default enumeration uses `first-compatible-length/row-anchor-v1`: examine lengths within each complete profile in increasing order, retain assessed failures, stop that row/anchor/profile after the first complete individual chemistry pass, and explicitly report unexamined longer lengths. Self dimers are deferred to stage selection. `--discovery-length-mode all` permits exhaustive profile lengths; default is `first-compatible`. Other rows remain independent. The choice controls enumeration, not retrospective deletion of generated candidates.

### 5.2 Retain variants before cloud rejection

Introduce a variant-preserving discovery path. Current whole-cloud thermo failure, cloud dimer failure, F×R pair dimer failure and longest-member remapping rejection must not erase individually usable members in this path.

- Retain observed oligos with their individual binding footprints and supporting observations.
- Evaluate individual chemistry and self-dimer evidence; retain dimer-disfavored variants as scored candidates for explicit salvage rather than silently accepting them.
- Defer interactions between distinct oligos to configuration selection.
- Retain a chemistry-rejected oligo's diagnostic record but never select it through dimer salvage.
- Retain variants whose individual coordinates map correctly even if a different cloud member maps out of bounds.

Construct anchor families from forward and reverse sites. Permit normal/high-GC hybrid combinations at compatible anchors, explicitly recorded as hybrid origin. A parent family's longest-member envelope must not preclude a valid selected subset: pair families when at least one subset can meet span bounds; enforce exact bounds on each selected configuration.

Deduplicate an intended site by target identity, strand, anchor/footprint and sequence. Sequence alone does not identify an intended site. Physical oligo species are separately deduplicated by sequence within each pool for burden/conflict accounting. Preserve the many-to-many relation between physical species and intended sites.

### 5.3 Model

- `ObservedAllele`: target ID, canonical observation signature, concrete-base mask, original row IDs and multiplicities.
- `OligoSite`: stable site ID, sequence, strand, anchor, accepting profiles and observation support.
- `BindingSupport`: site/allele, observed row footprint and confirmed/unknown/mismatch reason.
- `CandidateFamily`: target ID and sets of alternative forward/reverse site IDs.
- `SelectionConfiguration`: family ID, selected forward/reverse site IDs and recomputed envelope/interiors. Both sides must be nonempty.
- `AlleleAssignment`: configuration ID, pool and stage.

IDs are content-addressed with versioned canonical serialization, independent of paths and random UUIDs. Preserve source occurrence identity for duplicate input MSAs; do not merge distinct target occurrences. Catalog is immutable; configurations are created lazily and persisted in a hashed ledger. Stable IDs include selected sites, not just parent family ID. A family may supply different subsets to different pools, each counted and exported as a separate assignment. Reject duplicate assignments; within a pool, the same-target overlap constraint prevents redundant overlapping configurations.

### 5.4 Persistent candidate history and reusable assessments

Every generated oligo/site, candidate family and materialized selected-subset configuration must have a durable identity and machine-readable history from its first evaluation onward, including entities rejected before selection. This is a required scientific artifact used by downstream stages, not optional debug logging. Preserve all generated candidates; do not claim to enumerate all theoretically possible pairs/subsets. Record discovery boundaries and enumeration limits so absence from the catalog is distinguishable from rejection.

Keep three separate record types:

- **Intrinsic evidence:** discovery profile(s), source sites/observations, sequence and coordinates, chemistry measurements, self-dimer score, support and geometry evidence. Retain failed measurements as well as passing ones.
- **Contextual assessments:** stage/run, exact entity/configuration IDs, pool, constraint-profile and kernel versions, active thresholds, relevant incumbent/conflict context, check name, outcome, reason code, numerical evidence and witness IDs. A dimer record identifies both physical sequences/sites, orientation, score and cutoff; a specificity record identifies the screened product and classification. Context-dependent rejection must never become a permanent property of an oligo.
- **Decision events:** generated, deduplicated/aliased, assessed, proposed, selected, pruned, replaced, moved, reconsidered and final disposition. Each event has a stable event ID, run-local sequence number, causal/parent links and evidence references. Subset changes create a new immutable configuration linked to its parent, with removed/added sites and per-class support/coverage changes; do not overwrite the parent.

Assessments distinguish `pass`, `fail`, `unknown` and `not-evaluated`. Decisions distinguish feasible-but-not-selected, selected-strict, selected-salvage, superseded and search-limit-not-explored. Store all checks actually performed, not just the first reported failure. If evaluation short-circuits, explicitly mark remaining checks unperformed; do not infer that they pass or that all blockers have been found. A primer may simultaneously pass normal chemistry, fail high-GC chemistry, conflict in Pool 1 and remain usable in Pool 2.

Persist append-only decision events plus immutable evidence records, and derive indexed stage snapshots for querying. Every stage exposes each entity's disposition or explicit non-evaluation reason; unchanged states may reference a prior snapshot. Repeated identical assessments may reference one evidence record without duplicating its payload. Stage snapshots include catalog, configuration-ledger, assessment and event hashes. Partial/failure outputs identify the last complete stage and incomplete tail; successful publication requires complete history for the published result.

Strict repair, salvage and subsequent CLI runs consume this catalog and assessment history. Reuse raw measurements only when their complete scientific dependency keys match (sequence/sites, source observations, chemistry/kernel parameters and versions as applicable). Reassess policy verdicts when thresholds change; invalidate pool-context verdicts when relevant assignments change. Never reuse a prior selection decision as proof of current validity. Final independent validation still recomputes from authoritative inputs.

Provide CLI queries by primer/site, family, configuration, target region, pool and stage, returning lineage, measured scores, blockers, unperformed checks and why an eligible entity was not selected. Export a human-readable summary alongside the authoritative machine-readable records. In particular, a query for Mamu-A1 [394,644) must link its original family to explored alternatives/subsets and strict/salvage outcomes without requiring a rerun.

## 6. Coverage and allele support

### 6.1 Distinct observed alleles

Collapse exact duplicate normalized aligned observations including their missing-data masks within each target. Preserve aliases and multiplicities. Do not infer that a matching fragment is the same allele as a full sequence or combine differently incomplete rows without explicit identity evidence. Describe these groups as distinct observed allele classes in reports.

Retain original rows and masks for specificity/provenance. Duplicate collapse affects objective weighting only.

### 6.2 Coverage formula

For allele class a in target m:

- Use zero-based ungapped row coordinates for non-gap sequence symbols, including N/IUPAC. Maintain an explicit alignment-to-row map; alignment gaps and terminal missing padding supply no sequence coordinate. `O[m,a]` contains concrete A/C/G/T row positions, including insertions relative to the reference.
- A retained site confirms support only when its complete anchored footprint is observed, all primer/template bases are concrete, and the synthesized oligo exactly matches the strand-correct template. No mismatch or compatible ambiguity establishes support. Biological deletions are handled by the ungapped anchor walk, not treated as primer/template mismatches.
- Enumerate every retained F×R combination with confirmed support **on the same row** and `f.end <= r.start`. `I[m,a]` is the union of their half-open trimmed interiors `[f.end, r.start)`. Empty interiors contribute nothing. Secondary screening products never add coverage.
- `c[m,a] = |O[m,a] intersect I[m,a]| / |O[m,a]|`.
- `C[m] = mean_a(c[m,a])`, equal weight for each assessable distinct observed allele class.

Unknown/ambiguous binding does not establish support. Terminal missing cells, N and ambiguous IUPAC cells contribute no confirmed observed-base numerator or denominator; report their counts and fractions separately so missingness cannot masquerade as complete biological coverage. Internal gaps represent deletions, not observed bases. A zero-concrete-base class is unassessable, never 100%; a target with no assessable classes is excluded from optimization with an explicit unassessable-target status. If all targets are unassessable, return a structured `no-assessable-targets` outcome with provenance before search; never compute an empty mean.

Removing one variant may reduce support for some classes without invalidating the configuration. At least one class must have confirmed joint support and positive useful interior for a selected configuration to count toward this whole-MSA design. Never preserve parent-cloud support after variant removal.

### 6.3 Soft objective

Default aspiration `tau = 0.95`. Maximize the mean over assessable target MSAs of:

`u(C) = C - max(0, tau - C)^2 / tau`.

This gives extra value to reducing deficits, values every improvement, and continues rewarding coverage above 95%. It is a declared engineering policy, not a biological utility model. Require `0 < tau <= 1`.

Tie-break in order: higher target-mean coverage; higher worst-target coverage; lower relaxation burden within a salvage tier (violating-edge count, then incident-oligo count); fewer unique sequence/pool instances; fewer amplicons; more balanced pool oligo counts; smaller size deviation; canonical IDs. Round numeric objective components to 12 decimal places before lexicographic comparison to obtain a transitive deterministic ordering; retain unrounded scientific metrics in reports.

Report unrounded fractions and distinguish `>=0.95` from the user's aspiration `>0.95`. No hard per-allele minimum, no all-alleles requirement, and no automatic rejection of a lower-coverage valid panel. Always show target and per-class deficits/dropout. Do not pool raw bases across MSAs, which would overweight longer targets.

## 7. Consistent specificity and physical-pool validation

Use one versioned selected-site specificity checker for all profiles. Default terminal seed length is 17 for the new mode, at most one nucleotide substitution in the terminal seed, without indel matching, and maximum product size 2,000 bases inclusive. These are engineering starting settings; benchmark seed length 17 versus 19 where oligo length permits, clearly marking unsupported short-oligo comparisons. Require a positive product bound; reject zero and disabled specificity in the new mode.

Specificity exemptions are complete product certificates, not endpoint membership. Intrinsic checks for configuration A use its exact retained-site products. Pair A/B checks use complete certificates from A or B, identified by target occurrence, original row, ordered full binding footprints, orientation and physical oligo sequences. Enumerate all matching selected sites within A/B for shared sequences. A third configuration C, unselected variants and parent-cloud declarations cannot rescue an A/B conflict. Pair verdicts therefore remain independent of other assignments and valid under deletion.

Preserve the existing narrowly defined ordered-disjoint secondary category: A and B must certify intended products on the same target occurrence and original row, with the left product's reverse footprint ending no later than the right product's forward footprint begins. The left forward/right reverse combination may then be tolerated. Report every such secondary product and give it zero coverage credit. Merely combining selected endpoints is insufficient. This is a declared policy, not a claim that longer secondary products are harmless. Benchmark a separately versioned policy rejecting this category to expose its coverage consequences.

All other screened potential products within the positive size bound conflict; cross-locus products receive no blanket exemption. A terminal-seed screening hit is not confirmed allele support. Compatible ambiguous hits or unavailable complete footprints must be recorded as uncertain and conservatively blocking when a correctly oriented product within the bound cannot be ruled out; do not silently treat missing sequence as specific. Record uncertainty blocks separately. The finite screening domain is supplied-row seed windows, including compatible N/IUPAC symbols; a seed hit whose complete footprint extends into unavailable sequence is uncertain and blocking. Do not invent seed coordinates wholly outside observed row sequence from terminal padding. Serialize this limitation as `supplied-row-seeds-and-seeded-full-footprints/v1`; it does not establish specificity in unobserved flanking sequence. The corpus is the supplied MSA rows; make no whole-genome specificity claim without a declared background corpus. No specificity relaxation occurs during dimer salvage.

Check selected oligos for profile chemistry, self dimers, F/F, R/R and F/R interactions, both orientations, and interactions with all physical species in their pool. Same-sequence physical species must not become fake distinct interaction edges. Actual synthesized tails, if introduced later, require a separate declared full-oligo chemistry model.

Recompute selected full BED envelopes and size constraints after pruning. Preserve historical nonoverlapping same-target amplicon constraints within a pool; do not relax overlap, chemistry, size, missing-data or specificity constraints in salvage.

## 8. Bounded strict search

Extend the existing search engine and incumbent/repair machinery. Do not enumerate every subset or claim global optimality on full panels.

Candidate configurations are generated from full individually eligible families; minimal same-allele supported F/R pairs; conflict-witness variant deletion; addition/removal/swapping of variants; alternate anchors/profile combinations; pool moves; and exchanges with actual blocking configurations. Try removing a blocking variant before dropping its entire amplicon.

Default engineering budgets: 4 starts, 2 repair rounds, 120 search seconds, beam width 16 configurations per examined family, and 256 expanded subset states per neighborhood. Permit exchange neighborhoods involving up to 2 incumbent configurations. Expose and record deterministic expansion budgets as well as time limits. Use canonical starts plus seeded alternatives. Temporary losses are allowed within a bounded exchange, but commit only improvements under the declared objective and retain the best independently valid incumbent.

Cache chemistry, binding support and pairwise numerical dimer scores. Cache keys include selected site IDs and scientific profile, never only family ID. Configuration specificity is recomputed or keyed by its exact selected intended sites. Use lazy scores/sparse conflict witnesses rather than a mandatory dense all-candidate graph.

Retain old full-cloud and normal-only starts when valid under the same new contract. Expanded choices cannot justify discarding an already better incumbent. Report what was and was not explored, work truncation, resource exhaustion and stop cause. Fixed completed work should be repeatable; wall-time cutoffs may select different valid incumbents and must say so.

## 9. Optional salvage

The new mode fixes strict `--dimer-score` at -26 and rejects another value; relaxation is expressed only through salvage. Salvage is off by default. If enabled, save and independently validate the strict incumbent first. Initial research ladder: -28, -30, -32; more negative means more permissive, and equality still rejects (`score <= threshold`). A custom ladder must be finite, strictly decreasing from the strict threshold, and explicit in provenance.

No calibrated destructive threshold exists. Instead enforce a finite **computational exposure policy**. Initial research policy per pool, measured cumulatively relative to strict -26:

- At most 8 unique unordered physical-oligo edges violating strict -26, including self edges.
- At most 4 unique sequence/pool instances incident to those edges.
- Every edge must still pass the active stage threshold.
- At most 3 stages, 60 search seconds per stage and the strict deterministic neighborhood bounds.

These numbers are proposed experimental search budgets, not claims of safe assay behavior. Expose their values in CLI reports and allow explicit override; do not silently expand them. Stop a tier when the objective cannot improve within bounds; report whether that means exhausted work, no valid gain or time limit. A lack of gains in one tier does not prove a more permissive tier futile.

For each tier, assess all selected interactions, including rescue-rescue interactions. Optional repair may alter assignments; report every removed/moved/added oligo and coverage change against strict baseline. Do not call retained baseline sequence coverage preserved experimental performance. Archive each validated tier; a failed tier cannot overwrite the strict result. The primary BED defaults to strict. `--primary-tier strict|salvage-1|salvage-2|salvage-3` may select an existing independently validated tier; an unavailable or failed tier is an error. Every artifact states its tier.

## 10. Outputs and provenance

Publish compressed catalog, explored configuration ledger, assessment evidence, append-only decision history and indexed stage snapshots, selected assignments, selected-oligo BED/FASTA/order sheet, row-specific trimmed coverage, per-target summaries, unknown/unassessable diagnostics, gap reasons, numeric dimer witnesses, strict/tier comparison and independent validation. The bundle must preserve histories for rejected and unselected generated entities, not only final selected primers.

Gap reasons distinguish: unavailable observations; no individually eligible binding sites; no valid geometry; no confirmed joint support; chemistry; specificity; same-pool overlap; dimer threshold; salvage exposure budget; selector not explored/work limit. Exact feasible-union bounds must not be inferred from a truncated subset search. Label parent-catalog versus evaluated-configuration bounds accurately.

For every native and Lungfish scientific invocation, record workflow/tool/version, source identity and dirty state, exact argv and reproducible command, explicit options and resolved defaults, runtime/conda/container identity, input/output paths/checksums/sizes, exit status, wall time, seed/work budgets and useful stderr. Record profile membership, dropped variants and resulting support losses. Copies and exports point to final stored payloads, not only staging paths.

Final validation freshly reconstructs selected sites, support, coverage, chemistry, interactions, specificity and budgets from authoritative inputs and selected outputs without optimizer caches. Validate bytes and stage/profile IDs before atomic publication. Invalid artifacts block publication; low coverage alone does not. Retain failure provenance. Moving/reopening a bundle must preserve valid local payload references. Old records remain readable and retain old metric meanings.

## 11. CLI interface

New native mode uses `panel-create --mode equal --selection-algorithm allele-coverage` with explicit size bounds. New parameters:

- `--candidate-profiles union|normal|high-gc` (union).
- `--coverage-metric observed-allele-primer-trimmed` (required/resolved for new mode).
- `--coverage-target 0.95`.
- `--allele-weighting distinct-observed` (only supported weighting initially).
- `--specificity-terminal-k 17`, `--mispriming-product-size 2000`.
- Existing pool, seed, starts, repair rounds and time controls.
- `--subset-beam-width 16`, `--subset-expansion-limit 256`, `--exchange-width 2`.
- `--primary-tier strict|salvage-1|salvage-2|salvage-3` (strict).
- `--salvage off|bounded` (off); repeated `--salvage-threshold`; `--salvage-max-edges-per-pool 8`; `--salvage-max-oligos-per-pool 4`; `--salvage-time-limit 60`.

Preset and advanced-control policy: expose a named versioned `--preset allele-balanced-v1` for the documented defaults, and allow explicit CLI overrides for target coverage, pool/amplicon bounds and caps, candidate profiles, minimum base frequency, seed/starts/repair rounds, time and deterministic work budgets, subset beam/expansion/exchange limits, specificity terminal k/product bound/secondary-product policy, and salvage ladder/exposure/time/primary tier. Preset values resolve first, explicit options second; provenance records both requested and resolved settings. Reject ignored or incompatible options, including unsupported chemistry overrides. CLI help explains scientific versus compute-cost controls and experimental salvage limits. Do not invent additional presets without benchmark evidence. The strict threshold remains fixed; advanced dimer relaxation uses the recorded salvage controls.

Native CLI and Lungfish CLI must resolve identical scientific settings. Lungfish preserves its existing flag spelling (`--pool-count`, `--core-count`, `--minimum-base-frequency`) and explicitly translates to native flags. Reject incompatible legacy flags. No implicit fallback to managed lge.2 when an explicit new-contract executable is required.

## 12. Evidence gates

G0: synthetic metric, variant, specificity, interaction and publication tests pass; exact tiny instances checked by an independent exhaustive oracle.

G1: native CLI benchmark completes on frozen local MHC inputs with complete receipts. Compare normal/full-cloud, union/full-cloud, normal/subsets and union/subsets under the same new metric and specificity contract; compare strict repair off/on and then salvage. Historical lge.2 and lge.3 panels are diagnostic comparisons, not controlled baselines unless revalidated under the common contract.

G2: Lungfish CLI creates, inspects and reopens validated new-contract bundles; corruption/relocation tests pass. No managed runtime or GUI changes.

G3: Astra reviews per-target and per-allele results, losses as well as gains, strict/tier interaction burden, specificity blocks, elapsed time, peak memory and unresolved coverage ceilings. Produce an explicit decision report. Do not gate on all targets reaching 95%, and do not declare success solely because aggregate coverage increases.

G4: user explicitly accepts the CLI result and tradeoffs. Only then write/execute GUI changes and separately plan managed-runtime packaging. Neither a timeout nor silence is approval.

## 13. Oversight and remaining decisions

Astra approves schema/metric/specificity/search decisions and independently reviews each scientific phase. Sol may implement frozen interfaces, benchmark runners and wrapper changes. Luna may handle mechanical documentation and fixture formatting after formats are frozen. Scientific semantics, independent validator, subset search and final interpretation remain Astra-owned. Implementers do not approve their own scientific changes.

No further answer is required to prepare this plan. The soft objective formula, exact observed-observation identity rule, specificity profile and salvage exposure values above are explicit proposed engineering defaults for review. CLI evidence may justify revising them, but changes require a new recorded profile/objective revision rather than hidden tuning.

## 14. Astra review disposition

Two Astra experts reviewed the scientific contract and implementation feasibility. Their findings were incorporated: exact support and coordinate semantics, pair-local product certificates, explicit secondary-product policy and sensitivity analysis, transitive objective ordering, family multiplicity, fixed strict threshold, primary-tier validation and controlled discovery ablations. The secondary-product policy preserves the existing narrow ordered-disjoint category; stricter rejection is an explicit experiment. All engineering defaults remain subject to the CLI evidence gates.

Related plan: [Implementation plan](../plans/2026-09-15-allele-aware-primal-scheme.md).

## 15. Recorded extensions from the first CLI evidence

The first independently audited single-Mamu-A1 pilot covers 39.1308% after trimming; all salvage tiers are unchanged. Its strict search expands only 32 of 143,297 families and performs no repair. Specificity rejects 2,797 of 2,859 explored configurations. These findings justify the following controlled extensions, approved by Astra during the user-authorized autonomous development. They do not establish whole-panel feasibility or laboratory performance.

### 15.1 Search allocation

Expose `--phase-scheduling serial|reserved`, initially defaulting to `serial`. Reserved mode gives the initial seed/construction/repair groups relative weights 20/40/40 and repair preparation/cleanup/exchange 20/20/60, transferring unused time forward while preserving the global deadline. Later starts retain the ordinary shared remaining budget. Record actual phase outcomes, objective before/after, work/cursor changes and accepted repairs. Distinguish a completed bounded work recipe from exhaustion of all families. Default promotion requires matched-catalog evidence.

### 15.2 Optional intended-site screening interpretation

Expose `--intended-product-policy exact-supported|concrete-designated-sites`, initially defaulting to legacy `exact-supported`. Under `concrete-designated-sites/v1`, a potential product from the unchanged terminal-hit screen may receive a complete configuration-local intended-site certificate despite full-primer mismatches only when:

- both oligos are selected F/R occurrences within the same configuration, on its own target and the same observed row;
- each actual orientation and both full-footprint endpoints exactly match projection from that selected site's alignment anchor and oligo length;
- both complete projected footprints contain only A/C/G/T, with no missing or ambiguous cells, and are correctly ordered;
- existing positive-inclusive product bound and uncertainty handling still apply.

For a pair of configurations, one complete certificate from either configuration is required; ends cannot be borrowed across configurations and a third configuration cannot rescue a rejected pair. Same product span alone, shifted repeats, other targets and incomplete footprints are insufficient. Existing ordered-disjoint secondary exemptions remain derived from exact-supported certificates only.

Keep `binding_support`, exact supported products, allele weights, observed denominators and coverage utility unchanged. Newly tolerated products are recorded separately as `allowed_intended_products`, with policy-specific identity, complete occurrence certificate, mismatch evidence, `uncertain=false` and **zero additional coverage credit**. Fresh raw-row validation reconstructs the certificate. This is a location-based screening interpretation, not an amplification prediction.

The scientific profile, capabilities, requested/resolved options, stage diagnostics and evidence contexts explicitly identify the policy. Missing fields in old saved outputs mean legacy exact-supported semantics. Discovery fingerprints and immutable origins remain unchanged; selection verdict caches are policy-specific. The current preset remains unchanged until controlled CLI evidence supports a separately recorded preset decision.
