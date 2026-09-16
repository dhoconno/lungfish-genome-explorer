# Selective Discovery History Implementation Plan

> For agentic workers: use superpowers:subagent-driven-development. Luna implements and runs CLI tests; Astra reviews consequential scientific contracts and the final diff.

**Goal:** Remove exhaustive discovery bookkeeping while retaining reproducible candidates and on-demand detailed discovery diagnostics.

**Architecture:** Compact discovery bypasses diagnostic record construction and keeps bounded summaries. Existing evaluated-selection history and fresh final validation remain. A separate diagnostic command replays a requested site or family with detailed history.

**Tech Stack:** Python, Typer, SQLite, pytest, existing native provenance/candidate libraries.

**Spec:** ../specs/2026-09-16-selective-discovery-history.md

## Global constraints

No cancelled/frozen artifact edits, no GUI or managed-runtime changes, no full11 retry, no new dependency, no validation or chemistry relaxation. Preserve full-history mode and old bundle readers. Source/cache fingerprints remain enforced. User authorization covers implementation; no additional approval loop is needed.

## Task 1: Compact generation, CLI detail mode and cache compatibility (Luna)

Files: `primalscheme3/panel/coverage_discovery.py`, `allele_options.py`, `allele_pipeline.py`, `allele_catalog_cache.py`, `allele_inspection.py`, native capability/CLI registration files as discovered; new focused tests under `tests/lge/`.

Interface: add keyword `history_detail='full'` to `build_variant_catalog`. CLI `discovery_history='compact'` flows through AlleleOptions and config to the pipeline. Valid values compact/full only. A new compact helper can live in a focused module if it keeps discovery readable; share scientific enumeration/family predicates rather than duplicating an alternative algorithm.

- [x] Write failing scientific-projection tests. Compare target/observation records, site IDs/sequence/footprints/profile memberships, and family IDs/anchor/member/profile combinations while excluding evidence IDs and declared detail metadata. Compare repeated same-mode semantic digests exactly.
- [x] Add a recorder spy that raises on per-site/family discovery `record_evidence`/`assess` calls in compact mode. Assert only bounded target/profile summaries and dispositions; a no-op writer that still builds millions of payloads is not acceptable.
- [x] Implement explicit branches before origin grouping/evidence payload/digest construction where those serve only detailed history. Preserve needed scientific aggregation and worker recording. Emit honest history scope and compact counts.
- [x] Wire default, validation, capability advertisement and resolved options. Register the Task 2 diagnostic command only after its module interface is available.
- [x] Implement mode-aware compact cache export/reuse/projection and inspection disclosure. Full projection stays unchanged. Reject missing/incompatible declared policy and full-from-compact reuse; retain old full interpretation when declaration is absent in old artifacts.
- [x] Run focused discovery/cache/inspection/options tests, fix scientific regressions, commit code and tests. Report commands, failures, final results and changed files for Astra review.

## Task 2: On-demand anchored diagnostic replay (separate Luna)

Files: create `primalscheme3/panel/discovery_diagnostics.py` and `tests/lge/test_discovery_diagnostics.py`. Do not edit Task 1 files concurrently. Task 1 registers CLI entry after integration.

Interface: `diagnose_discovery(*, bundle, output, family_id=None, site_id=None, argv=None)` returns a small report dictionary and writes a separate result directory. Exactly one entity ID required; source must be a completed supported panel. Invoke `build_variant_catalog(..., indexes=(forward_anchors, reverse_anchors), history=detail_history, history_detail='full')` with reconstructed whitelisted original config and the original target.

- [x] Write failing tests for requested family/site replay, exclusive-ID validation, unknown entity, no-source-mutation, mismatched membership, runtime/input drift and failure receipt.
- [x] Reuse existing source descriptor, provenance, saved target/profile and runtime verification utilities. Do not create a second unrelated provenance system. Resolve relative stored payload paths against source bundle.
- [x] Implement bounded replay and explicit reconstructed scope, scientific membership comparison, output inventory/status and precise error reporting. Do not pretend evidence IDs or decision chronology match original run.
- [x] Run focused tests, commit only owned files, provide CLI wiring signature/help text and examples to Task 1/parent.

## Task 3: Integration and bounded CLI measurements (Luna runner)

- [x] Run focused combined tests, then one appropriate full native suite after changes stabilize. Record tests rather than repeating unchanged suites.
- [x] Create a frozen reviewed candidate build; capture actual capability/source/runtime identities.
- [x] Run tiny actual CLI compact/full, audit, history, cache export/reuse and site/family diagnostic commands; verify output provenance, default/override and failures. Use fresh output paths and retain exact command receipts.
- [x] Run bounded original-MHC anchored generation compact/full with same inputs/settings, scientific projection parity and phase/size measurements; save complete provenance.
- [x] Only after the preceding passes, run one full-A1 compact short-search/salvage-off CLI smoke with explicit wall/resource monitoring and retained failure provenance. Do not claim quality from a short engineering run.
- [x] Update public CLI controls and report with measured results, remaining selector costs and explicit deferred-history semantics. Parent reviews actual diff/contracts/evidence and marks these gates complete only when observed.


## Verification outcome (2026-09-16)

Native candidate commit `cfafd488fa064438f005417a85d85904ec81da4d` passed 900 tests (one upstream Kaleido deprecation warning). Luna executed compact/full/default CLI, audit, history, cache reuse, and site/family diagnostic checks. Original A1 six-anchor comparison preserved 370 sites and one family, with compact history 73,728 bytes versus 3,117,056 bytes. Single-sample discovery times were 0.269 and 0.647 seconds respectively; these are not full-panel benchmarks.

The bounded full-A1 compact engineering run completed in 246.64 seconds, peak sampled process-group RSS 4.16 GB, with stable provenance and successful fresh audit. It used one pool, one start, a 30-second search budget, no repairs and salvage off; its 24.13% trimmed coverage is not comparable to the earlier long two-pool quality run. No full11 retry, GUI edit or installed-runtime change was performed. Results and limitations are retained in the SDD evaluation report.
