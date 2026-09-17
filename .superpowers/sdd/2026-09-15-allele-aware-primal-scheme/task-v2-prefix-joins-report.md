# Native v2 checkpoint prefix join optimization

Date: 2026-09-16 America/Chicago  
Commit: `74102b8effef79f98487b4962c65b112454425d3`  
Base: `236e74af6b186367fd66f15e73b558a0c3e44a74`  
Scope: mutable `allele-aware-primalscheme` source and focused tests only.

## Change

`SQLiteCoverageHistory._validate_checkpoint` now uses the physical v2 `record_links_int` table and the integer `records.position` keys for each of its three prefix-closure checks. The checks still test the same link kinds (`evidence`, `assessment`, `parent`), required source streams, source ordinal `< source_count`, and target ordinal `>= target_count`. A matching row still rejects with `checkpoint references uncommitted prefix`.

The v1 query remains the original `record_links`/record-ID form. The change does not skip a query or validation, use a count/trust shortcut, change SQL schema, migrate history, modify CLI/science, or alter checkpoint IDs/digests/export bytes. All digest, inheritance, disposition, payload/index, foreign-key and cold reload checks remain in their original paths.

The source diff touches only `primalscheme3/panel/coverage_history.py`; the new test file is `tests/lge/test_v2_checkpoint_prefix_joins.py`. The eleven protected discovery files were independently compared byte-for-byte to the running cold source `7ca64e68690f6e4db5b91f54bfe8a4847c402a62`: `11/11` identical.

## Test-first evidence

The new query-shape test initially failed for v2 because SQLite traced a `record_links` compatibility-view query rather than `record_links_int`. After correcting two test-harness issues in that initial run (the durable checkpoint needed before rollback, and comparing the lazy sequence as a tuple), the intended red state was `1 failed, 4 passed`: the sole failure was the v2 physical-query assertion. The minimal SQL branch then gave `5 passed` on the first green run.

The completed focused tests cover:

- original ID/view closure verdict versus the production helper for all three link kinds over full and valid/invalid truncated prefixes, including an observed v2 physical query and unchanged v1 query;
- equal-count parent ordinal corruption rejected by the same closure guard;
- valid truncated checkpoint stored and reopened for both physical formats;
- v1/v2 complete-stage snapshot identity, stream export hashes, and reopen/query parity;
- cold reload rejection for changed unique record IDs and dangling foreign-key relations in both formats.

## Final verification

From `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primalscheme`:

```sh
.venv/bin/python -m pytest -q \
  tests/lge/test_coverage_history.py \
  tests/lge/test_sqlite_coverage_history.py \
  tests/lge/test_integer_coverage_history.py \
  tests/lge/test_v2_checkpoint_prefix_joins.py
```

Result: `60 passed in 0.94s`, exit `0` on the final run.

```sh
.venv/bin/python -m pytest -q \
  tests/lge/test_allele_catalog_cache.py \
  tests/lge/test_allele_inspection.py \
  tests/lge/test_cached_panel_benchmark.py
```

Result: `53 passed in 64.13s`, exit `0`.

```sh
.venv/bin/python -m ruff check \
  primalscheme3/panel/coverage_history.py \
  tests/lge/test_v2_checkpoint_prefix_joins.py
git diff --cached --check
```

Result: lint and whitespace checks passed. The final commit contains exactly two files, and the mutable native worktree is clean.

## Limits

This is a query-path change. No timing benchmark or full-MHC speedup is claimed. It does not accelerate v1 history, cold discovery, record writes, reload/integrity validation, truncated-prefix hashing, or later publication. The active cold writer and all frozen matrix worktrees/output were neither edited nor queried. The root owns independent Astra review and any later full native suite or frozen-build integration.
