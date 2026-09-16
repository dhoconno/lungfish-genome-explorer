# Selective-history CLI and measurement plan

Planning only. No CLI/scientific run is authorized while Task1/2 source changes are active. Do not read, copy, recover or mutate the cancelled MHC history.

## Tiny CLI contract

Use an existing fixture only after confirming it produces at least one nonempty family in the current source. Candidate fixtures to inspect are `tests/test_data/test_msa/test_msa_valid.fasta` and the existing `tests/lge/allele_fixtures.py`/verified tiny integration fixture; do not assume the short FASTA is viable for 150–250 bp. Record fixture path, source digest, family/site counts and exact resolved options before comparing modes.

The reviewed option is `compact|full`, default `compact`. Use the final spelling from frozen CLI help, for example:

```sh
primalscheme3 panel-create --msa <verified-tiny-input> --output <fresh-output> \
  --selection-algorithm allele-coverage --preset allele-balanced-v1 \
  --amplicon-size 200 --amplicon-size-min 150 --amplicon-size-max 250 \
  --n-pools 1 --ncores 1 --min-base-freq 0 --mapping first \
  --terminal-gap-policy observed-only --optimizer-seed 0 \
  --optimizer-starts 1 --optimizer-repair-rounds 0 --optimizer-time-limit 5 \
  --salvage off --discovery-history compact --offline-plots
```

Run the same verified tiny input once in `compact` and once in `full`, with fresh outputs and the same fixed work unit. Cross-mode catalog/ledger digests are expected to differ by design; compare scientific projection IDs/profile membership/geometry and selected scientific outputs. Same-mode repeated runs must have exact catalog/ledger/output/provenance identity. A 5-second bounded run cannot establish selected-assignment parity; use a separate fixed-work-unit comparison if needed.

Use existing commands only. `panel-history` queries saved history and does not regenerate discovery; do not invent stage/target/region flags. The new diagnostic command is:

```sh
primalscheme3 panel-discovery-diagnose --bundle <completed-bundle> \
  --family-id <saved-family-id> --site-id <saved-site-id> --output <fresh-diagnosis>
```

Match the reviewed help/source exactly; omit a selector if optional. Diagnostic output gets its own receipt bound to saved catalog/source identity.

For each tiny bundle, use existing `panel-audit --bundle BUNDLE --output FRESH_AUDIT` and, only for a completed successful bundle, `panel-cache --bundle BUNDLE --output FRESH_CACHE`, then reuse with existing `--reuse-discovery FRESH_CACHE`. Verify source bytes/order, catalog/profile/detail policy identity, closed history, snapshot and provenance. Failure receipts retain exact argv, resolved options, source/runtime/input descriptors, stderr, exit status, wall time and partial outputs.

## Bounded original-A1 anchor comparison

This is one compact-only CLI arm, not a full11 or full-history A1 run. Use exactly this original A1 raw input:

`/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mhc-fixture-snapshot-v3/snapshot/source-inputs/C64AA855-086A-4BBB-8AB7-803F0FAC0212/source.lungfishmsa/alignment/primary.aligned.fasta`

Use original A1 discovery settings/indexes, a short 30-second optimizer bound, and salvage off. Record exact input hash/size, source/runtime/kernel identity, resolved options, candidate/site/family and history counts, wall time, peak RSS/physical footprint, disk high-water mark, output hashes and exit/stderr. Suggested limits: 10 minutes wall, 2 GiB output growth, fresh output, external interruption receipt on cancellation. Do not launch until parent review and a frozen source commit.

The compact/full comparison for this arm is a bounded anchored API probe over the same input, indexes, settings and fixed work unit before CLI launch. Compare candidate/site/family scientific projections and deterministic fixed-work results; report bookkeeping counts, diagnostic materialization and memory/time separately. Do not treat cross-mode semantic digests as expected equal.

## Targeted tests and limits

Use current tests rather than a new framework: `test_coverage_discovery.py`, `test_coverage_catalog.py`, `test_diagnostic_cache.py`, `test_coverage_validation.py`, `test_coverage_search.py`, `test_allele_catalog_cache.py`, `test_allele_inspection.py`, `test_coverage_cli.py`, and existing diagnosis tests. Add focused assertions for compact default/full explicit parsing, same-mode digest identity, cross-mode scientific projection equivalence, nonempty-family precondition, saved family/site diagnostic replay, cache incompatibility rejection, and complete provenance on failure.

No optional failure matrix, permission experiment, full11 arm or extrapolated performance claim is needed. Preserve final fresh validation, audit, provenance and cache contracts in both modes.
