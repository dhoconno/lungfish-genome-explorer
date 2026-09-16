# Selective discovery history

## Authorization and scope

The user authorizes skipping exhaustive initial bookkeeping, reconstructing detailed information as needed for problematic primers, and requests Luna implementation/CLI tests with Astra algorithm oversight. This supersedes the earlier requirement to retain every discovery attempt. Reproducibility provenance and final scientific validation remain mandatory. Work stays in the existing isolated native and LGE CLI worktrees; cancelled artifacts and frozen builds remain untouched, automation paused, no GUI changes.

## Decision

Default native allele-aware CLI discovery to `--discovery-history compact`, with `full` as an advanced comparison/debug option. Compact mode performs exactly the same chemistry, mapping, profile membership, site deduplication and feasible-family enumeration. It skips per-attempt evidence/assessment/event construction and per-site/family discovery dispositions. It must not replace SQLite records with an equally large in-memory history.

Preserve all concrete catalog sites (including rejected mapped sites already retained by full mode), generated/accepting profile membership, targets, observed classes and family membership. Absent intrinsic/geometry evidence is represented by empty evidence-ID tuples, never dangling or fabricated IDs. Failed attempts without a concrete site are aggregated by target/profile/reason rather than individually identified. Retain bounded per-target/profile counts, enumeration boundaries, actual workers, a history-detail declaration and a complete summary-stage snapshot whose completeness applies only to the declared recorded scope.

Keep existing selector diagnostics for configurations actually evaluated, accepted moves, conflicts, and selected final independent validation. This first implementation removes exhaustive discovery history; it does not claim to eliminate all selector bookkeeping. Do not change selection thresholds, scoring, candidate order, specificity, partial-allele support, coverage calculation or salvage behavior.

Add `panel-discovery-diagnose --bundle PATH --family-id ID --output NEWPATH` (alternatively `--site-id ID`, exactly one required). This is an explicit on-demand replay of discovery at the requested entity's anchors, using all original target rows and the original resolved profiles/chemistry/length policy. It emits detailed history and a small replay report with original source/catalog/entity bindings. It is labeled reconstructed anchored discovery, not the original historical sequence of decisions. It must not infer that a diagnostic explains why the optimizer historically omitted an entity. It must reject unsupported/drifted inputs/settings/runtime rather than inventing exact replay. Diagnostics remain separate from and do not mutate the source panel.

## Identity and compatibility

Site/family/configuration scientific IDs and profile memberships must agree between compact and full modes. Catalog/ledger/history digests may differ because recorded evidence and the explicit detail policy differ. Never assert catalog byte/digest equality across modes. Each mode remains deterministic and internally consistent.

Record the mode in resolved options, capability descriptors, catalog detail metadata, panel provenance, history inspection and cache manifests. Old bundles with no declaration retain full-history interpretation. Low-level `build_variant_catalog(..., history_detail='full')` retains its historical default; pipeline passes the CLI's resolved compact/full choice explicitly.

Compact caches use the existing protected input/runtime/source checks, plus an explicit detail-policy binding. Projection to normal/high-GC uses catalog generated/accepting profile memberships and reconstructs the same feasible families without looking for omitted evidence in SQLite. Full mode retains its existing evidence projection. A request for full history from compact origin is an explicit incompatibility, never silent promotion. Existing older discovery caches can fail the existing changed-source fingerprint gate; do not weaken it for this feature. Old completed bundle inspection/audit remains supported.

## On-demand replay contract

Load a completed, provenance-bound source panel; validate entity membership, exact stored/raw target correspondence and runtime/kernel/profile compatibility using existing native helpers. Reconstruct config from whitelisted resolved fields, never execute saved arbitrary commands. For a family replay enumerate its forward and reverse anchors; for a site replay enumerate its strand/anchor. Keep the original target object/row corpus and full profile set. Force explicit full history for the replay. Compare replayed site/profile membership and requested family membership to the source, ignoring evidence-detail fields only. Any mismatch is failure provenance, not a successful explanation.

Write exact argv/workflow and version, all resolved defaults, runtime/kernel identities, source input/output descriptors with hashes and sizes, timestamps/wall time, status and errors using existing provenance utilities. Failures must not overwrite source or an existing output directory. The new output should expose whether only a bounded anchor slice was examined.

## Validation gates

1. Tiny deterministic compact/full discovery has identical scientific projections and no per-candidate history calls in compact mode. Aggregate counts agree and compact history grows with target/profile summaries, not row-attempt/family count.
2. Fixed-work tiny selector results and final fresh validation agree across modes; wall-clock limited runs may differ because recording costs differ and must not be used for exact parity assertions.
3. Compact cache export/reuse and normal/high-GC projections match fresh same-mode discovery. Full-from-compact, missing declared metadata, tampered input/catalog and source/runtime drift fail explicitly.
4. On-demand site and family replay preserves source bytes, produces linked full evidence, reports reconstructed scope, and matches source scientific membership; malformed/unknown entities and failure paths retain provenance.
5. Real CLI help/capabilities/default/full override, cold compact design, cached design, audit/history and replay run successfully on a small fixture. Retain receipts and inspect provenance paths.
6. Compare compact/full generation on bounded anchors from original MHC input with identical source/settings/work; measure phase time, history size/record counts, and memory when available. Then one bounded full-A1 compact CLI smoke (short search, salvage off) only after correctness gates. No full11 retry or long search without oversight review of measured scaling.
