# Selective discovery history seam map

Read-only seam map of mutable native `74102b8` (`.worktrees/allele-aware-primalscheme`). No production edits or cancelled-run access were performed.

## Current paths and proposed boundary

`coverage_discovery.build_variant_catalog` (`primalscheme3/panel/coverage_discovery.py:132–288`) accepts `history=None`, but immediately creates an in-memory `CoverageHistory` at lines 145–147. It then records history for every row/profile group: row-enumeration evidence, generated event, optional oligo-thermodynamics evidence, assessment, assessed event, family-generated event, family-geometry evidence/event, boundaries and final `complete_stage`. Candidate/site catalog objects themselves do not require history IDs; IDs are semantic digests and the catalog carries `intrinsic_evidence_ids`/`geometry_evidence_ids`, which do require stable evidence identities when retained.

The safe seam is a history writer interface with two modes: **compact** (no per-candidate evidence/event objects for ordinary successful candidates; retain only bounded counters/diagnostic summaries and IDs needed by retained catalog fields) and **diagnostic** (materialize the existing detailed records for a candidate/family when a cheap precheck fails, a conflict/gap is encountered, or an explicit diagnostic request selects it). The writer must still emit stage boundaries, final validation evidence, and a complete provenance summary. It must never manufacture absent evidence IDs or silently change catalog semantic identity.

`coverage_variants.propose_subsets` (`coverage_variants.py:133+`) already accepts `history=None` but assumes a writer at lines 198 and 219–283 (`latest_event`, `emit`). Its configuration proposals and rejection reasons can use the same compact writer; detailed configuration evidence should be requested only for failed/ambiguous proposals. `coverage_search.SearchState` (`coverage_search.py:248–340`) does not write canonical history; it keeps bounded search counters and objective history in memory. Selector unary/pair validation is routed through the oracle (`coverage_search.py:320–368`) and `coverage_validation` caches, so the discovery history seam should not be placed inside the selector oracle.

## Candidate and cache dependencies

`coverage_catalog._candidate` (`coverage_catalog.py:271–344`) creates a candidate from primer pair geometry and support-cache projections; it has no history argument. `_cloud_support` caches per-target/oligo/anchor row support, and candidate IDs derive from target/interval/oligo identity. This is the right low-level place for a cheap structural precheck, but not for writing history. Detailed diagnostics should be attached above this function, where the caller knows whether a candidate was accepted, omitted, or caused a coverage/conflict gap.

`coverage_specificity.SpecificityChecker` (`coverage_specificity.py:56–243`) and `_Evaluator` in `coverage_validation.py:150–205` use in-memory caches keyed by catalog/profile/candidate, with fresh uncached validation in `validate_allele_assignments` (`coverage_validation.py:371+`). Candidate generation must not reuse these caches as scientific evidence; cache identity remains catalog semantic digest + profile cache key. A compact history summary may record cache hit/miss counters, but final validation remains fresh and detailed.

Portable discovery cache compatibility is strict. `allele_catalog_cache.py:145–180` requires a closed origin history, complete discovery snapshot, catalog digest and committed counts; `:458–571` reconstructs/validates catalog evidence and derived family geometry; `:682–724` materializes derived evidence into the current history with exact IDs. A selective-history implementation therefore needs a versioned history/detail policy in the discovery/cache manifest and must either (a) retain enough origin evidence for the existing loader, or (b) version a compact cache schema with an explicit diagnostic-detail contract. Silent omission would break cache reuse and provenance.

## Publication, audit and inspection assumptions

`allele_publication.publish_allele_stage` / `audit_allele_stage` (`allele_publication.py:280–468`) require catalog and ledger semantic digests, selected artifacts and fresh validation; they do not require every candidate to have a detailed history record, but the final stage history snapshot/dispositions must remain complete. `allele_inspection.py:161–231` verifies history format, payload/index/link identity and origin references; `:405–465` queries current and immutable origin histories separately. `panel-history`, `panel-audit` and `panel-cache` must continue to reject compact outputs that claim a complete origin history without the required evidence.

## CLI/options and schema impact

Current CLI exposes science/compute controls (`cli.py:569–635`), including `--reuse-discovery`, `--variant-selection`, `--discovery-length-mode`, and cache/history commands. Do not overload `--discovery-length-mode` or `--variant-selection`. A new option should be an explicit, versioned compute/detail policy (for example `--discovery-history detail|compact`, defaulting to current `detail` until reviewed), saved in resolved options, capabilities, command receipts and cache identity. The policy must be rejected on cache reuse when the cache manifest’s history/detail contract is incompatible. No GUI change is implied.

## Minimal meaningful tests

1. Compact mode generates the same catalog semantic digest, candidate/site/family IDs, selected outputs, fresh validation result and final provenance as detail mode on tiny fixtures, while producing no per-candidate no-op history records.
2. A forced candidate gap/conflict switches only that candidate/family to detailed diagnostics; exact evidence/assessment/event links and reasons match current detail mode.
3. Compact discovery output either exports a valid versioned cache with the documented compact origin contract or is rejected clearly by `panel-cache`/reuse; no silent fallback to regeneration.
4. `panel-history` bounded queries and `panel-audit` preserve current corruption/reference/index checks; final complete-stage snapshots and dispositions remain valid in v1/v2 history backends.
5. Determinism test compares IDs, catalog/ledger digests, resolved options and provenance across repeated compact runs; memory test asserts no dense per-candidate diagnostic object graph is retained.

## Risks for Astra oversight

The key algorithm question is the cheap precheck that decides when detailed evidence is necessary. It must be conservative: any uncertain chemistry, missing/ambiguous row support, cross-target conflict, failed specificity, or unexplained coverage deficit should route to detailed evaluation. Compact mode may omit bookkeeping only after the same scientific predicate has passed; it must not prune candidates or weaken final validation. Astra review should approve the policy and cache schema before Luna implementation.
