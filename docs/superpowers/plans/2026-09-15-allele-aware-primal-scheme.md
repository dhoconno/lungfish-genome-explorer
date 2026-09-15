# Allele-aware PrimalScheme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and evaluate a CLI-first MHC panel designer that combines discovery profiles, selects useful oligo subsets, optimizes observed-allele primer-trimmed coverage and offers bounded salvage alternatives.

**Architecture:** Extend the existing native lge.3 catalog/search/validation/publication pipeline with versioned allele and selected-variant records. Keep profile discovery, support, specificity and stage exposure explicit; maintain a fresh output validator and an independent tiny-instance oracle. Integrate into the Lungfish CLI only after native evidence, and hold GUI implementation until explicit user acceptance.

**Tech Stack:** Python 3.12 reference runtime, native primalschemers/primer3 kernels, pytest, Swift/Lungfish CLI and workflow package, JSON/gzip catalogs, BED/FASTA and existing atomic scientific bundles.

**Spec:** [Detailed specification](../specs/2026-09-15-allele-aware-primal-scheme.md).

## Global Constraints

- CLI first; no GUI implementation, managed-runtime changes, installation replacement or release in this plan.
- Equal weight per distinct observed allele; partial support remains valuable.
- Coverage after primer trimming; goal 0.95 is soft and reports distinguish >95% from equality.
- New default discovery is union; strict dimer threshold -26; salvage is off by default.
- New-mode specificity is positive-bound selected-sites-v2; do not inherit historical D=0 behavior.
- Original scientific inputs and prior outputs remain unchanged. Scientific fixture payloads are local only; commit synthetic fixtures and manifests without private sequences.
- Every scientific workflow records exact execution, resolved settings, source/runtime identity, input/output hashes and sizes, status/time/stderr and durable final payload paths.
- Astra oversees scientific architecture, review and result interpretation; cheaper agents handle bounded work only after interfaces are frozen.

## 1. Ownership, repository setup and execution gates

This document plans implementation; creating it does not claim the algorithm is implemented or validated.

| Role | Model | Responsibility |
|---|---|---|
| Supervising architect | Astra (`gpt-6-astra`) | Objective, contracts, decomposition, scientific decisions, integration and benchmark signoff |
| Scientific implementation | Astra | Variant-preserving discovery, support/specificity, subset search and independent validation |
| Bounded implementation | Sol (`gpt-5.6-sol`) | Provenance/export, CLI plumbing, benchmark runner and fixed-schema tests |
| Mechanical work | Luna (`gpt-5.6-luna`) | Documentation, fixture formatting and help text after contract approval |
| Independent reviewer | Astra, separate from implementer | Review correctness and evidence; require fixes before next scientific gate |

Do not assign a lower-capability agent scientific policy decisions to reduce cost. Escalate unexpected algorithm or data-model findings to Astra. Run independent tasks concurrently only when file ownership and interfaces are settled.

Use the using-git-worktrees skill before implementation. Start the native branch from the actual lge.3 fork, not the older Documents/primalscheme3 checkout. Read applicable AGENTS.md in both roots. Preserve existing uncommitted work.

Suggested branch names: `codex/allele-aware-primal-scheme` in native and `codex/allele-aware-primal-cli` in LGE. Each worktree gets an isolated Python environment; never pip-install into `/Users/dho/.lungfish/conda/envs/primalscheme3` during development.

Commands below run at their labeled repository roots. `.venv/bin/python` denotes the new isolated environment populated from the native lock/dependency files, not an unverified system Python. Use absolute source/executable paths in scientific receipts.

## 2. File map and interfaces

Native existing files to extend:

- `primalscheme3/core/{config,digestion,parallel_discovery,msa}.py`: new discovery route and resolved policies; historical paths unchanged.
- `primalscheme3/panel/coverage_types.py`: versioned immutable records.
- `primalscheme3/panel/coverage_catalog.py`: profile union, stable IDs, bindings and configuration ledger.
- `primalscheme3/panel/coverage_search.py`: existing bounded engine extended with variant neighborhoods and allele objective.
- `primalscheme3/panel/coverage_specificity.py`: selected-site products under common profile.
- `primalscheme3/panel/coverage_validation.py`: new profile and fresh validation.
- `primalscheme3/panel/coverage_pipeline.py`: detached subset export, strict/tier artifacts.
- `primalscheme3/panel/coverage_provenance.py`, `primalscheme3/panel/panel_main.py`, `primalscheme3/cli.py`: execution/capabilities/entry-point integration.

New focused native modules:

- `primalscheme3/panel/allele_coverage.py`: observation identities, row support and coverage arithmetic.
- `primalscheme3/panel/coverage_variants.py`: immutable selected configurations and lazy subset proposals.
- `primalscheme3/panel/coverage_salvage.py`: stage policies and exposure accounting.
- `primalscheme3/panel/coverage_history.py`: immutable evidence, contextual assessments, append-only decision events, indexed stage snapshots and dependency-keyed reuse.
- `scripts/benchmark_allele_coverage.py`: reproducible fixture snapshots and experiment matrix.
- `scripts/audit_allele_panel.py`: saved-output audit independent of optimizer caches.

Interfaces to freeze at Task 2 (types live in coverage_types; use explicit dataclass fields from spec):

```python
canonical_observations(target: Target) -> tuple[ObservedAllele, ...]
configuration_coverage(target: Target, configuration: SelectionConfiguration) -> dict[str, frozenset[int]]
allele_summary(targets: tuple[Target, ...], assignments: tuple[AlleleAssignment, ...], ledger: ConfigurationLedger) -> CoverageSummary
coverage_utility(target_fractions: tuple[float, ...], goal: float = 0.95) -> float
build_variant_catalog(msa_dict: dict[int, MSA], profiles: tuple[DiscoveryProfile, ...]) -> VariantCatalog
make_configuration(catalog: VariantCatalog, family_id: str, forward_site_ids: tuple[str, ...], reverse_site_ids: tuple[str, ...]) -> SelectionConfiguration
propose_configurations(catalog: VariantCatalog, family_id: str, witnesses: tuple[ConflictWitness, ...], limits: SubsetLimits) -> tuple[SelectionConfiguration, ...]
validate_allele_assignments(catalog: VariantCatalog, ledger: ConfigurationLedger, assignments: tuple[AlleleAssignment, ...], profile: AlleleConstraintProfile, stage: StagePolicy) -> ValidationReport
search_allele_assignments(catalog: VariantCatalog, profile: AlleleConstraintProfile, options: AlleleSearchOptions) -> AlleleSearchResult
run_salvage(catalog: VariantCatalog, strict: AlleleSearchResult, profile: AlleleConstraintProfile, policies: tuple[StagePolicy, ...]) -> tuple[AlleleSearchResult, ...]
```

Existing search interfaces need not be renamed; the new entry point may delegate to the existing generic engine. Never change old dataclass meanings in place. Astra may refine signatures at the Task 2 gate, updating all consumers and this plan together.

## Task 1: Freeze the benchmark inputs and establish valid controls

**Owner:** Sol; Astra reviews fixture identity and controls.

**Files:** Create `scripts/benchmark_allele_coverage.py`, `tests/lge/test_allele_benchmark.py`; extend `docs/designs/coverage-panel.md` with fixture receipt format.

**Consumes:** Original saved MHC bundles. **Produces:** immutable local snapshot, source-row label map and hash manifest; runner options `--fixture-root`, `--native-executable`, `--output`, `--matrix`.

- [ ] Read manifests and verify all selected input/artifact hashes before copying; identify the 11 target inputs by manifest labels, not guessed UUID order.
- [ ] Add tests that an existing output is refused, a mismatched input checksum aborts before scientific execution, duplicate labels retain source occurrence IDs, and a failed subprocess records status/stderr.
- [ ] Run `.venv/bin/python -m pytest tests/lge/test_allele_benchmark.py -q`; confirm the new requirements fail before implementation.
- [ ] Implement snapshot verification and subprocess execution using argument arrays. Required receipt shape:

```python
receipt = {"argv": argv, "resolvedOptions": resolved, "inputArtifacts": inputs,
           "outputArtifacts": outputs, "sourceIdentity": source,
           "runtimeIdentity": runtime, "exitStatus": completed.returncode,
           "wallTimeSeconds": elapsed, "stderrPath": stderr_path}
```

- [ ] Add baseline matrix entries for historical independent/combined lge.2 artifacts and existing lge.3 execution. Re-score historical outputs under the new profile later; do not treat different specificity settings as a controlled comparison.
- [ ] Run tests, inspect a non-scientific fake-process receipt, and commit only script/tests/docs. The real snapshots go to a new local directory beneath `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/` with refusal to overwrite.

## Task 2: Immutable allele/configuration records and literal coverage oracle

**Owner:** Astra. **Files:** Extend `coverage_types.py`, `coverage_catalog.py`; create `allele_coverage.py`, `tests/lge/test_allele_coverage.py`, `tests/lge/allele_fixtures.py`.

**Produces:** first four interfaces above plus serializable `ObservedAllele`, `OligoSite`, `BindingSupport`, `CandidateFamily`, `SelectionConfiguration`, `AlleleAssignment`, `ConfigurationLedger`, `CoverageSummary`. Define test helper `literal_coverage(observed, interiors)` independent of production mapping:

```python
def literal_coverage(observed, interiors):
    recovered = set().union(*(set(range(a, b)) for a, b in interiors))
    return None if not observed else len(set(observed) & recovered) / len(observed)

def test_reference_independent_fraction():
    assert literal_coverage(set(range(10)), [(2, 8)]) == 0.6

def test_unobserved_is_not_complete():
    assert literal_coverage(set(), []) is None
```

- [ ] Add failing production tests for duplicate observation invariance, differing masks remaining distinct, allele insertions absent from the reference, overlapping interval unions, unsupported classes and zero-observation targets.
- [ ] Define a two-class support fixture: F supports class A only, R supports class B only. Require zero supported products, then add an R variant supporting A and require coverage for A only.
- [ ] Add a hand-calculated row combining a reference insertion, internal deletion, internal N and terminal missing padding; verify both observed-mask and interior coordinates. Test exact full-primer support separately from substitution-tolerant screening, split-family assignments across pools, and all-unassessable outcomes.
- [ ] Add explicit objective tests:

```python
def test_partial_coverage_improves_soft_objective():
    assert coverage_utility((0.50, 0.80)) > coverage_utility((0.0, 0.80))
    assert coverage_utility((0.96, 0.80)) > coverage_utility((0.95, 0.80))
```

- [ ] Run `.venv/bin/python -m pytest tests/lge/test_allele_coverage.py -q` to establish failures, implement the formula and row-specific footprints, then rerun.
- [ ] Implement stable canonical observation/site/configuration IDs and JSON round trips; test paths and duplicate aliases do not alter semantic IDs, while changed selected variants do.
- [ ] Freeze `AssessmentRecord`, `DecisionEvent` and `StageSnapshot` schemas from spec §5.4; create `coverage_history.py` and `tests/lge/test_coverage_history.py`. Test lineage and round trips, per-pool/per-profile concurrent statuses, short-circuited checks explicitly unperformed, and feasible-but-not-selected distinct from rejected. Establish serialization/query interfaces before Tasks 3–8 consume them.
- [ ] Astra independent review approves denominator, unknown-state semantics, identity and new-vs-historical metric distinction. Commit this contract before dependent work.

## Task 3: Variant-preserving dual-profile discovery

**Owner:** Astra. **Files:** Modify `core/digestion.py`, `parallel_discovery.py`, `msa.py`, `panel/coverage_catalog.py`; create `tests/lge/test_variant_discovery.py`.

**Consumes:** Task 2 site/support records. **Produces:** `build_variant_catalog`, full per-oligo profiles/reasons and candidate families.

- [ ] Add synthetic fixtures for a cloud with one chemistry-failing member and two passing members; a cloud-internal dimer that can be removed; a long out-of-bounds member with shorter valid members; disjoint profile-only candidates; and shared candidates accepted by both profiles.
- [ ] Require these assertions on a fixture-specific catalog:

```python
assert normal_only_site in union.site_by_id
assert high_gc_only_site in union.site_by_id
assert union.site_by_id[shared_site].accepting_profiles == ("high-gc", "normal")
assert invalid_member not in union.selectable_site_ids
assert useful_sibling in union.selectable_site_ids
```

- [ ] Run `.venv/bin/python -m pytest tests/lge/test_variant_discovery.py -q`; verify cloud-level rejection causes the expected failures before implementing the new route.
- [ ] Extract per-variant digestion evidence without altering legacy functions' behavior; defer distinct-member dimer gates, retain self-dimer scores for stage policy, and reject chemistry independently per oligo.
- [ ] Emit history before each discovery filter can discard an entity. Preserve rejected generated sites, deduplication aliases and all measurements actually evaluated; record enumeration boundaries without materializing the full combinatorial pair/subset space.
- [ ] Build hybrid anchor families across accepting profiles. Reject only families for which no selected geometry can satisfy bounds. Test exact-size recomputation after removing a longest member.
- [ ] Test fixed-work/profile-union scientific identity across worker counts. Run existing discovery/coverage catalog tests and commit after Astra review.

## Task 4: Selected-subset geometry and support

**Owner:** Astra; Sol may implement immutable serialization after interfaces freeze.

**Files:** Create `coverage_variants.py`, `tests/lge/test_coverage_variants.py`; extend `coverage_catalog.py`.

**Consumes:** Variant catalog and binding support. **Produces:** `make_configuration`, `propose_configurations`, ledger records.

- [ ] Add a three-RIGHT fixture with a conflicting third member. The selected two-member subset must remain eligible when it supports only two of three classes; assert the third class loses coverage and the first two retain theirs.
- [ ] Add a subset with no common supported class; it must be ineligible even with nonempty F and R lists.
- [ ] Test selected IDs, recomputed full envelope, row interiors, retained profile memberships and removal reasons. No cached support from the full family is allowed.
- [ ] Implement lazy witnesses/minimal-support proposals, deterministic beam width 16 and expansion limit 256. Retain alternatives with distinct future-conflict signatures even if current coverage is equal.
- [ ] Verify bounded proposal count and explicit truncation diagnostics on a synthetic large family; never enumerate a whole power set for the real panel.
- [ ] Link each proposed subset to its parent, exact removed/added sites, triggering witnesses and support/coverage changes; emit explicit not-explored states for materialized configurations omitted by work limits.
- [ ] Run `.venv/bin/python -m pytest tests/lge/test_coverage_variants.py tests/lge/test_allele_coverage.py -q`, review and commit.

## Task 5: Common specificity and fresh scientific validation

**Owner:** Astra; a separate Astra reviews.

**Files:** Extend `coverage_specificity.py`, `coverage_validation.py`; create `tests/lge/test_allele_validation.py`; extend existing `test_coverage_validation.py`.

**Consumes:** Exact selected configurations. **Produces:** `AlleleConstraintProfile`, `validate_allele_assignments`, detailed conflict witnesses and numeric dimer scores.

- [ ] Freeze selected-sites-v2: common terminal seed 17, one substitution and no indel matching, positive inclusive D=2000, full-row footprints, selected-site exemptions, no cross-row products. Preserve old profiles unchanged.
- [ ] Write boundary tests for D, zero rejection, exact -26 equality, both orientation scores against the native numerical/boolean kernel at boundaries, F/F and R/R interactions, and self dimers.
- [ ] Add pair-local product-certificate tests: adding/removing/repooling C cannot change A/B verdict; endpoint membership alone is insufficient; ordered-disjoint certified secondary products are reported with zero coverage credit; ambiguous/incomplete potential products conservatively block when not ruled out.
- [ ] Test removing a selected variant removes its intended-site exemption; identical physical sequences at different selected sites retain every valid intended site.
- [ ] Test a normal-profile oligo rejected by high-GC constraints still passes its complete accepting normal profile. Do not use a merged rectangular GC/length range.
- [ ] Test tampered support, omitted selected variants, incorrect observed denominators, outside-reference selected geometry and false profile membership all fail fresh validation.
- [ ] Implement an independently rebuilt selected configuration for validation rather than consuming optimizer support caches. Keep valid partial and empty results publishable.
- [ ] Run `.venv/bin/python -m pytest tests/lge/test_allele_validation.py tests/lge/test_coverage_validation.py -q`; Astra reviews implications of stricter specificity before search benchmarks.

## Task 6: Strict coverage search with variant-aware exchanges

**Owner:** Astra. **Files:** Extend `coverage_search.py`; create `tests/lge/test_allele_search.py` and `tests/lge/allele_exhaustive_oracle.py`.

**Consumes:** catalog, configuration proposals, common oracle/profile. **Produces:** `search_allele_assignments`, validated incumbent and complete work/stop metadata.

- [ ] Build a tiny exhaustive test oracle over predeclared configurations/pool placements. Enumerate all subsets and pool assignments, reject declared edges, and score literal per-class base sets independently of production `_State`.
- [ ] Add a counterexample where dropping one RIGHT variant recovers coverage; another where moving/deleting a blocker and adding two configurations beats greedy selection; and a case where partial allele support beats leaving a region empty.
- [ ] Require the heuristic to match the exhaustive optimum on the declared tiny fixtures, not on arbitrary real panels:

```python
assert heuristic.objective == exhaustive.objective
assert heuristic.validation.valid
assert heuristic.coverage.per_class["unsupported"].covered_bases == 0
```

- [ ] Extend existing state with per-class interval contribution accounting and reference-counted removal. Implement add/drop/variant swap/pool move/up-to-two-configuration exchange neighborhoods; retain best incumbent throughout.
- [ ] Include feasible normal/full-cloud starts; add a regression that supplying optional candidates does not erase a better seeded incumbent under the same metric/profile.
- [ ] Test fixed-work reproducibility, cancellation/time exhaustion with best valid incumbent, explicit unsearched-family counters and no overclaim of optimality.
- [ ] Record proposal/selection/replacement/move decisions and stage snapshots. Test that a Pool 1 conflict does not globally reject the primer, that changing blocker membership invalidates contextual verdicts, and that unchanged numerical measurements can be reused under matching dependency keys.
- [ ] Run `.venv/bin/python -m pytest tests/lge/test_allele_search.py tests/lge/test_coverage_search.py -q`; obtain independent Astra review and commit.

## Task 7: Bounded salvage and strict-baseline preservation

**Owner:** Astra scientific review; Sol may implement fixed policy accounting.

**Files:** Create `coverage_salvage.py`, `tests/lge/test_coverage_salvage.py`; extend search result/stage records.

**Consumes:** completed validated strict result. **Produces:** `StagePolicy`, `run_salvage` and strict/tier comparison.

- [ ] Add tests that salvage off performs no relaxation, increasing/nonfinite thresholds fail, and equality to an active cutoff rejects.
- [ ] Use a fixture where two rescues individually fit against strict baseline but conflict with each other; reject or prune their combination unless all current tier limits permit it.
- [ ] Implement the explicit research ladder (-28,-30,-32), max 8 violating unordered physical edges and max 4 incident physical oligo/pool instances per pool, 60 seconds per tier plus fixed subset bounds. Count self edges and shared species consistently.
- [ ] Require cumulative exposure accounting relative to -26; do not reset edge budget at each tier. Record removed/moved/added variants and gains/losses for every target/class.
- [ ] Consume prior history to reconsider dimer-blocked entities at each tier. Test strict rejection remains in history after salvage acceptance, a changed threshold recomputes its verdict, and chemistry failures cannot become salvage-eligible through a stale status.
- [ ] Test chemistry/specificity/size/overlap cannot be relaxed, invalid tiers cannot overwrite strict output, and a later tier does not masquerade as a strict result.
- [ ] Run `.venv/bin/python -m pytest tests/lge/test_coverage_salvage.py -q`; review the limits as engineering constraints, not biological safety guarantees; commit.

## Task 8: Native CLI, v2 artifacts and independent output auditor

**Owner:** Sol implements wiring/export; Astra owns validator/auditor review.

**Files:** Modify `cli.py`, `core/config.py`, `panel_main.py`, `coverage_pipeline.py`, `coverage_provenance.py`; create `scripts/audit_allele_panel.py`; extend `tests/lge/test_coverage_cli.py`, `test_coverage_publication.py`; add `tests/lge/test_allele_publication.py`.

**Consumes:** new catalog/search/stages. **Produces:** explicit local new-contract executable, capability schemas, strict/tier selected BEDs and provenance.

- [ ] Add failing CLI tests for incompatible flags (`--high-gc` with new mode, zero specificity distance, unsupported metric, non--26 strict threshold, unavailable primary tier), new resolved defaults, and untouched historical argv.
- [ ] Export detached native objects containing selected variants only. Test removed variants do not appear in BED, FASTA, order sheets or selected coverage; parent provenance remains available.
- [ ] Include authoritative input copies, catalog/ledger hashes, stage IDs, objective/metric versions and final-byte output descriptors. Hash runtime kernels and source identity. Record discovery, search, validation and total times separately.
- [ ] Publish complete histories for generated rejected/unselected entities plus evidence and snapshot hashes. Add native query support by entity/region/pool/stage with lineage and non-evaluation reasons. Test restart/reload, failed-stage tails, corrupted evidence references, and an original-family-to-pruned-subset-to-salvage query without rerunning discovery. Include history storage/time in benchmarks; deduplicate repeated evidence without dropping decisions.
- [ ] Build saved-output auditor that reads selected oligos plus durable original rows and recomputes support/interiors literally without optimizer caches. Independently enumerate selected oligo interactions; reuse native numerical kernel but not cached decisions.
- [ ] Test corruption, relocation, cancellation and below-goal publication, then run:

```sh
.venv/bin/python -m pytest tests/lge/test_coverage_cli.py tests/lge/test_coverage_publication.py tests/lge/test_allele_publication.py -q
.venv/bin/python -m pytest tests/lge -q
.venv/bin/primalscheme3 --capabilities-json
```

- [ ] Reserve/verify lge.4 identity, update native design documentation, obtain independent Astra review and commit. Do not publish a package or replace managed installation.

## Task 9: Native CLI MHC experiments and scientific review

**Owner:** Sol runs the frozen matrix; Astra interprets and decides whether further algorithm work is needed.

**Files:** Extend Task 1 runner/tests; write local receipts and a sequence-free report at `docs/reports/2026-09-15-allele-aware-primal-scheme/native-cli-report.md`.

- [ ] Snapshot both named bundles, verify original checksums before/after, and extract all 11 combined inputs in a stable manifest-declared target order. Keep input/profile/metric/seed hashes identical for controlled comparisons.
- [ ] Execute matrix: normal/full clouds, union/full clouds, normal/subsets, union/subsets; strict repair off/on; union/subsets strict followed by explicit salvage. Define full cloud as all individually eligible variants of a family with subset pruning disabled; historical whole-cloud rejection is not applied. These are ablations under new specificity, not aliases for legacy.
- [ ] Add controlled terminal-seed 17 versus 19 comparisons using the same catalog restricted to ≥19-base oligos; report excluded 17–18-base candidates separately. Compare the declared ordered-disjoint secondary policy with a separately versioned strict-rejection policy, reporting secondary products and resulting coverage loss.
- [ ] For each arm, report C[m], class distribution/minimum/dropout, observed/unknown counts, full/reference-trimmed historical metrics, selected oligo/pool counts, actual support losses, interaction margins, additional products, work limits, wall time and peak RSS.
- [ ] Reproduce the local 394–644 alternatives as profile-specific diagnostics, then reevaluate them under selected-sites-v2. Do not require that a historical D=0-compatible candidate survive a different specificity policy.
- [ ] Compare first completed-work runs with repeated fixed-work runs; separately run 120-second and 600-second search budgets. Reuse immutable catalogs where scientific settings match, and record that reuse.
- [ ] Assess evaluated configuration unions and discovery bottlenecks. Do not call a sampled subset union an upper bound on all possible configurations. If 95% remains unmet, identify data/profile/search constraints rather than adding arbitrary time.
- [ ] Verify all resulting reports with the saved-output auditor. If strict quality is poor, return to Tasks 3–6 with documented hypotheses and repeat only affected matrix arms.
- [ ] Astra report explicitly states gains, regressions, unsupported classes, uncertainty and limits. No GUI work starts from native success alone.

Example runner invocation after Task 1 establishes this interface (supply actual isolated executable path):

```sh
.venv/bin/python scripts/benchmark_allele_coverage.py \
  --fixture-root /Users/dho/Desktop/sandbox/mhc-primal-scheme/mhc-primal-scheme.lungfish/Analyses \
  --native-executable "$PWD/.venv/bin/primalscheme3" \
  --matrix strict-and-salvage \
  --output /Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/native-review-01
```

The runner derives repeated `--msa` paths from the verified snapshot manifest; never hand-maintain 11 opaque UUID arguments. Log the complete expanded native argv for each arm.

## Task 10: Lungfish CLI contract and publication integration

**Owner:** Sol; Astra independent review. **Repository:** LGE isolated worktree.

**Files:** Modify `Sources/LungfishCLI/Commands/PrimerDesignCommand.swift`, `PrimerAnalysisCommand.swift`; `Sources/LungfishWorkflow/PrimerDesign/PrimalScheme3DesignPipeline.swift`, `PrimalScheme3CoverageContract.swift`; modify `PrimerAnalysisBundleWriter.swift` only if new artifacts require publication support. Extend the coverage fixture generator and workflow/CLI tests. No `Sources/LungfishApp` changes.

- [ ] Add new selector/options/capability version with explicit local executable requirement. Default union/allele metric only for the new mode; preserve legacy/coverage defaults and stored semantics.
- [ ] Extend `Tests/LungfishWorkflowTests/Resources/PrimalScheme3CoverageFixtureGenerator.py` with synthetic v2 records; keep v1 fixtures and readers.
- [ ] Add tests for false subset IDs, changed selected oligos, duplicate-row overweighting, wrong denominators, strict/salvage mismatch, missing ledger, tampered hashes and stale staging paths. Require rejection before destination publication.
- [ ] Require CLI inspect to report metric ID, target mean, class deficits, observed denominators, profile and strict/salvage tier. Do not rely on existing GUI coverage labels for the new objective.
- [ ] Preserve all native history/evidence artifacts through wrapper publication and relocation, and expose primer/pair/region histories through CLI inspection. Verify status/evidence queries agree before and after bundle publication.
- [ ] Default primary output to strict; validate explicit `--primary-tier` selection against completed validated tiers, and test unavailable/failed-tier rejection.
- [ ] Implement explicit native argv translation, v2 validation and durable artifact rehydration. Check native/source identity from capability probe through completion.
- [ ] Run:

```sh
swift test --skip-update --filter 'PrimalScheme3DesignPipelineTests|PrimalScheme3PublicationTests|PrimerDesignCommandTests|PrimerAnalysisBundleWriterTests|PrimerAnalysisBundleTests|PrimalSchemeOrderSheetTests'
swift test --skip-update --filter 'ScientificProvenancePolicyTests|ScientificCLIProvenanceCoverageTests'
```

- [ ] Re-run selected MHC strict/salvage experiments through `lungfish-cli primers design primalscheme3` using repeated snapshot `--msa` arguments, `--grouping combined`, explicit `--primalscheme3-path`, `--amplicon-size 200 --amplicon-size-min 150 --amplicon-size-max 250 --pool-count 2` and all resolved new settings. Confirm the isolated build advertises the new contract in its help/capability output before running.
- [ ] Compare native semantic artifacts and Lungfish published artifacts, relocate/reopen a copy using CLI inspection, verify hashes and final payload paths, and obtain Astra review.

## Task 11: CLI acceptance packet and GUI hold point

**Owner:** Astra. **Files:** `docs/reports/2026-09-15-allele-aware-primal-scheme/cli-acceptance.md`, native/LGE design documentation and review receipts.

- [ ] Produce a compact per-target strict/tier table, per-class dropout appendix, representative recovered regions, removed variants with lost support, exact settings, validation receipts and unresolved limitations.
- [ ] State which goals were met, which remain below 95%, and whether specificity or discovery—not search—is the current limiting factor. No aggregate-only success claim.
- [ ] Confirm all scientific defects and review findings are resolved or explicitly documented as blockers; preservation of old inputs/managed environment is verified.
- [ ] Present the CLI evidence to the user. Ask for acceptance of the concrete results and tradeoffs before GUI edits, as explicitly requested in this conversation.
- [ ] After acceptance, create a separate GUI spec/plan for default dual-profile discovery, correct allele-aware trimmed coverage displays, selected/dropped variants, strict/salvage comparisons and runtime delivery. This plan does not authorize those edits or package publication.

## 3. Review gates and task scheduling

Tasks 1 and 2 can start independently. Tasks 3 and 4 follow the frozen Task 2 model; avoid simultaneous edits to coverage_catalog.py without explicit ownership. Task 5 may run alongside bounded Task 4 serialization, but Astra must reconcile support semantics before Task 6. Tasks 6 and 7 are sequential. Export scaffolding may be prepared during search development only against frozen records. Tasks 9, 10 and 11 follow their evidence gates in order.

Each task: establish a meaningful failing test, implement, run focused checks, inspect the actual diff, receive a separate review where specified, and commit only its scoped changes. Do not repeat broad suites without a new change/failure/concern. The model assignment is a staffing plan, not a requirement to spawn every role immediately.

## 4. Acceptance checklist

- [ ] Union discovery retains usable variants lost by whole-cloud filters.
- [ ] Oligo subsets can preserve partial observed-allele coverage without false joint support.
- [ ] Duplicate observations do not change objective weight.
- [ ] Actual row interiors and observed insertions determine the new metric.
- [ ] Full-cloud legacy/reference metrics remain historically correct and readable.
- [ ] Selected-site specificity and physical-pool interactions are consistently evaluated.
- [ ] Strict search is bounded, reproducible under completed fixed work, and incumbent-preserving.
- [ ] Salvage is opt-in, cumulative-budgeted, independently validated and honestly labeled.
- [ ] Native and wrapper outputs have complete provenance and durable paths.
- [ ] Every generated entity has queryable stage history; partial evaluation, contextual rejection, pruning and reconsideration remain distinguishable and reusable without stale verdicts.
- [ ] CLI MHC results include per-target/class gains and losses and user-reviewed limits.
- [ ] No GUI implementation occurs before explicit CLI acceptance.
