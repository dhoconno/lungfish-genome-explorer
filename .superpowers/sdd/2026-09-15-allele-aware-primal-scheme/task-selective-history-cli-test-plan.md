# Selective-history CLI and measurement test plan

Status: planning only. Do not launch a scientific CLI run while Task1/2 source work is changing; parent review and a clean frozen commit are prerequisites. The cancelled MHC output/history is out of scope and must not be opened, copied or recovered.

## Tiny CLI smoke matrix

Use the tracked native fixture `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primalscheme/tests/test_data/test_msa/test_msa_valid.fasta` (and, for a deliberate malformed-input failure, `test_msa_non_dna.fasta`). Run from the frozen native worktree with `.venv/bin/primalscheme3`; each output directory must be fresh and have a per-command receipt, stderr, exit status, wall time, input/source/runtime descriptors and output inventory. Suggested compact command:

```sh
primalscheme3 panel-create \
  --msa tests/test_data/test_msa/test_msa_valid.fasta \
  --output /tmp/selective-history-cli/tiny-compact \
  --selection-algorithm allele-coverage --preset allele-balanced-v1 \
  --amplicon-size 200 --amplicon-size-min 150 --amplicon-size-max 250 \
  --n-pools 1 --ncores 1 --min-base-freq 0 --mapping first \
  --terminal-gap-policy observed-only --optimizer-seed 0 \
  --optimizer-starts 1 --optimizer-repair-rounds 0 --optimizer-time-limit 5 \
  --salvage off --offline-plots
```

Run the same exact argv with `--discovery-history compact` and `--discovery-history detail` (or the final reviewed option name), then compare catalog/ledger semantic digests, selected assignments, fresh `panel-validation.json`, resolved options, history policy, and provenance. The default/detail run is the oracle. A compact run must not produce millions of no-op candidate records; a gap/conflict fixture must produce detailed records for the affected family/site.

For each successful tiny bundle, run these exact bounded follow-ups into fresh sibling directories:

```sh
primalscheme3 panel-history --bundle tiny-compact --output tiny-history \
  --stage discovery --limit 20 --offset 0 --lineage
primalscheme3 panel-history --bundle tiny-compact --output tiny-history-target \
  --target '<saved target id or reference name>' --region 0:200 --limit 20
primalscheme3 panel-audit --bundle tiny-compact --output tiny-audit
primalscheme3 panel-cache --bundle tiny-compact --output tiny-cache
primalscheme3 panel-create \
  --reuse-discovery tiny-cache --output tiny-reuse \
  --msa tests/test_data/test_msa/test_msa_valid.fasta \
  --selection-algorithm allele-coverage --preset allele-balanced-v1 \
  --amplicon-size 200 --amplicon-size-min 150 --amplicon-size-max 250 \
  --n-pools 1 --ncores 1 --min-base-freq 0 --mapping first \
  --terminal-gap-policy observed-only --optimizer-seed 0 \
  --optimizer-starts 1 --optimizer-repair-rounds 0 --optimizer-time-limit 5 \
  --salvage off --offline-plots
```

The saved catalog/history IDs should drive targeted replay (`panel-history --target/--region`, bounded `--limit`) rather than regenerating discovery. Verify cache manifest/source provenance, origin history role, compact/detail policy compatibility, and exact reuse identities. A cache with missing detail required by the manifest must fail closed.

Failure cases: malformed/non-DNA input; missing output parent permissions; pre-existing output directory; compact/detail policy mismatch on cache reuse; changed input bytes/order; changed discovery profile/length mode; missing or journaled origin history; corrupted candidate evidence/index/reference; audit of a failed/incomplete bundle. Every failure must retain a receipt with exact argv, resolved options, source/runtime identity, inputs, partial outputs, stderr, exit status and wall time, and must not claim successful scientific provenance.

## Full original-A1 bounded comparison (future, gated)

After Task1/2 review and a frozen source commit, use the existing raw MSA inputs under `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mhc-fixture-snapshot-v3/snapshot/source-inputs/*/alignment/primary.aligned.fasta`, in canonical `input-order.json` order. The command must repeat all eleven `--msa` paths and use the already measured A1 settings: `--mode equal --selection-algorithm allele-coverage --preset allele-balanced-v1 --amplicon-size 200 --amplicon-size-min 150 --amplicon-size-max 250 --n-pools 2 --ncores 4 --min-base-freq 0 --mapping first --terminal-gap-policy observed-only --optimizer-seed 0 --optimizer-starts 4 --optimizer-repair-rounds 2 --optimizer-time-limit 120 --salvage bounded --salvage-time-limit 60 --primary-tier strict --offline-plots`. Run compact and detail on identical inputs/options, with one short engineering bound and fresh outputs; do not launch until parent/Astra oversight approves the frozen command.

Record for each arm: exact argv, source commit/digest and dirty status, native/runtime/kernel identities, all eleven input hashes/order/sizes, resolved options, history stream counts and bytes, candidate/site/family counts, detailed-record counts, stage/panel validation, catalog/ledger/output digests, wall time by discovery/selection/validation/publication, peak RSS/physical footprint sampling, disk high-water mark, exit/stderr and receipt paths. Suggested limits are 15 minutes wall per arm, 2 GiB output/disk growth, and cancellation only through the reviewed runner with an external interruption receipt; no partial arm is reported as successful.

Use the existing provenance-bearing runner and output auditor patterns; do not create a new framework or infer speed from one phase. The comparison is an engineering measurement of bookkeeping policy. It must report whether selected science artifacts are byte/semantic-equivalent and where compact history differs in detail coverage. No full-MHC feasibility or 95% claim follows from this arm.

## Targeted tests before the A1 arm

Run the focused history, discovery, cache, inspection, CLI and provenance suites already present: `tests/lge/test_coverage_history.py`, `test_sqlite_coverage_history.py`, `test_integer_coverage_history.py`, `test_coverage_discovery.py`, `test_allele_catalog_cache.py`, `test_allele_inspection.py`, `test_coverage_cli.py`, and new selective-policy tests. Include v1/v2 history backends, exact snapshot/digest equivalence, compact failure escalation, cache rejection, bounded history query, fresh audit, and receipt-on-error assertions. Run the full native suite only after the focused suites pass and the source is frozen.
