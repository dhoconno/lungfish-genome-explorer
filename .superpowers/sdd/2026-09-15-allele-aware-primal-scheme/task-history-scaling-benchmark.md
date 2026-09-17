# Synthetic history checkpoint scaling benchmark

Date: 2026-09-16 America/Chicago  
Status: bounded benchmark completed; no production or live cold artifacts accessed.

## Method

`history-checkpoint-scaling-01/benchmark.py` used the current `SQLiteCoverageHistory` API from frozen matrix12 native commit `74102b8effef79f98487b4962c65b112454425d3`, Python 3.12.8, with identical deterministic canonical chains in format v1 and v2. Each chain has one evidence, one assessment referencing it, and one event referencing the assessment; two complete snapshots were written. Sizes were 1,000, 10,000 and 50,000 chains (3,000 / 30,000 / 150,000 records). The benchmark measured append, first `complete_stage`, second `complete_stage`, SQLite size and the relevant `EXPLAIN QUERY PLAN` form. Total wall time was 56.665 seconds; outputs are under `history-checkpoint-scaling-01/run-03/`.

Receipt: `history-checkpoint-scaling-01/receipt.json` (status `success`). Helper SHA-256: `da5eb7ef84dc58df8ba6cfc9f27f399b13484d1b35c64b2cebed0e17b4eb2b37`. Results SHA-256: `89c278a676eb12a5fdd9b26ecd71164ed1ce0c6a5b0c1ceb1482566a23c55985`. Earlier failed helper attempts are retained in `size-01000-v1/` and `run-02/` with no scientific inputs.

## Results

| chains | format | append s | first stage s | second stage s | DB bytes |
|---:|---:|---:|---:|---:|---:|
| 1,000 | v1 | 0.2463 | 0.0060 | 0.0081 | 3,985,408 |
| 1,000 | v2 | 0.2271 | 0.0046 | 0.0065 | 2,080,768 |
| 10,000 | v1 | 3.3818 | 0.0636 | 0.0836 | 39,419,904 |
| 10,000 | v2 | 2.7864 | 0.0428 | 0.0597 | 20,230,144 |
| 50,000 | v1 | 27.5259 | 0.5498 | 0.5193 | 197,586,944 |
| 50,000 | v2 | 20.3621 | 0.2456 | 0.3233 | 103,268,352 |

For every size, v1 and v2 had identical canonical-chain digests and identical snapshot IDs, proving equivalent synthetic records and snapshot identity under the shared run ID. The v1 plan used `record_links` plus textual ID lookups; v2 used `record_links_int` and integer `records.position`, with the source access shown as a covering index. This is plan evidence only; the benchmark does not claim an end-to-end or full-MHC speedup, and it does not isolate the query substitution from the format/storage difference.

## Interpretation and limits

The synthetic workload shows checkpoint time scaling roughly with record count and v2 storage materially smaller than v1. It does not reproduce the live MHC distribution, disposition volume, catalog/search work, page-cache state, or the frozen 7ca v1 source. It therefore cannot forecast the active cold run or justify launching another scientific arm. The parent’s scalability hold remains appropriate; any production optimization requires separate reviewed source work and a matched benchmark that isolates query shape while preserving all validation.
