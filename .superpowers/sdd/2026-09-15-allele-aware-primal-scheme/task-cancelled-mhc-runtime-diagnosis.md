# Cancelled full11 runtime diagnosis

Date: 2026-09-16 America/Chicago. The user-authorized cancellation targeted only native PID 24757. SIGINT was sent at `11:10:03 -0500`; the process was still present after the observed 50-second grace interval. SIGTERM was sent at `11:10:53 -0500`; the PID disappeared after approximately 5 seconds. The exact command/source/output and final file sizes are retained in `mhc-union-subsets-02-interruption-receipt.json`. The SQLite journal remains present; no recovery, audit, copy, restart or mutation was attempted. This is an interrupted run, not native success.

## Measured phase bounds

| Phase evidence | Observed time | Interpretation |
|---|---:|---|
| Process start | 2026-09-15 17:49:27 | Full old v1 `7ca64e6` run began. |
| End of family assembly / beginning of checkpoint work reported in retained ledger | ~2026-09-16 02:18 | ~8h29m elapsed; this is a parent/ledger observation, not an exact SQL timer. |
| Discovery checkpoint reported in retained ledger | ~04:05–04:06 | ~10h16m; indexed monitoring saw committed snapshot progress and strict selection began. |
| `stages/strict/{stage,validation}.json` | 06:03:35 | Strict publication/validation finished; both small files are valid. |
| `stages/salvage-1/{stage,validation}.json` | 09:11:40 | Salvage-1 publication/validation finished; valid but same 11.8941% mean. |
| Cancellation | 11:10:03 / 11:10:53 | ~17h21m wall time from 17:49:27 start; no root receipt/provenance. |

These timestamps bound phases; they do not split discovery, SQLite checkpoint SQL, optimizer, validation and filesystem work exactly. Search options were 120 seconds for strict and 60 seconds for salvage; frozen `allele_search.py` resets the deadline to infinity before final validation (`~963–973`), so those values are optimizer budgets, not total stage limits.

## What the evidence supports

1. **Discovery/enumeration and history writes are the dominant early risk, but their exact split is unmeasured.** The observed early bound is that family assembly reached its first checkpoint around 02:18 (~8h29m); this does not prove the preceding interval was all SQLite or all discovery. The retained 02:23 OS sample, after family assembly and during checkpoint-time work, caught PID 24757 in Python `sqlite3_step` with 762/762 samples, including 725 `pread` samples and B-tree index/page movement. OS reported physical footprint was 13.0 GiB with a peak-so-far of 22.3 GiB at that sample time, not a final run-wide maximum. This is real checkpoint-time evidence, but it does not identify one SQL statement or attribute the earlier discovery interval directly.
2. **Checkpoint/relation validation is a substantial measured contributor, but not the only one.** The frozen v1 `coverage_history.py` performs prefix hashes, three closure joins, disposition/entity queries and synchronous FULL commits on every complete stage. The old-tail assessment counts six normal complete snapshots (discovery, strict, up to three salvage, publication), with 18 closure invocations plus DISTINCT entity queries on a clean path. The sample’s SQLite B-tree/pread stack is consistent with this cost, but cannot assign all 17h20m to those joins.
3. **Stage publication and retained in-memory state recur.** `allele_publication.py` writes and reloads catalog/ledger/assignments/coverage/validation and renders outputs before renaming the stage directory (`~365–464`). `allele_pipeline.py` retains the catalog, score cache, explored ledger and stage results while salvage runs (`~152–219`), then constructs final ledger/publication history (`~257–286`). This explains why strict and salvage artifacts exist despite no whole-run receipt.
4. **The optimizer itself is bounded but its surrounding validation is not.** `allele_search.py` enforces work limits, then performs deadline-free final validation and `_finish_history`; salvage repeats fresh baseline validation and stage completion (`coverage_salvage.py ~168–297`). Thus strict/salvage limits do not cap checkpoint, validation, publication or inherited-disposition work.
5. **Memory pressure is plausible but undermeasured.** Known observations are 13.0 GiB physical footprint and 22.3 GiB sampled peak at 02:23, plus parent’s earlier RSS snapshots; no run-wide peak exists. Likely contributors are the in-memory variant catalog/family structures, canonical IDs/digests, score cache, explored configuration ledger, inherited disposition mappings and SQLite/page cache. This is inference from object lifetimes/source, not a measured attribution.

## v1 versus current v2

The cancelled run is old v1 (`7ca64e6`, textual `record_links` and 8 MiB page-cache implementation). Matrix12 includes several accumulated changes relative to that old source (including integer physical storage, larger SQLite cache and ID-LRU/cache work); the latest `236e74af6b18…→74102b8` change specifically substituted only the three closure queries with physical integer `record_links_int`/`records.position`, while retaining all validation and durability checks. The synthetic benchmark in `task-history-scaling-benchmark.md` matched canonical IDs/snapshots and showed smaller v2 files and faster synthetic append/checkpoint cases, but it is not an end-to-end or full-MHC speed claim. It cannot retroactively improve the cancelled v1 run.

## Ranked next fixes / measurements (no implementation approved)

1. **Measure phase counters on a small matched real-input run before any full-MHC retry.** Record append, each checkpoint query family, disposition DISTINCT queries, validation, publication, catalog reload and SQLite commit separately; retain RSS/physical-footprint samples. This resolves the current attribution gap.
2. **Keep the reviewed v2 integer-key query substitution as the narrow first candidate.** Benchmark it on a matched real cached history with all three closure checks retained; do not use the rejected count/trust shortcut and do not infer whole-run benefit from `EXPLAIN` alone.
3. **Reduce repeated materialization only after profiling.** Consider bounded/streaming disposition and ledger handling or explicit score-cache limits, with exact digest/output equivalence tests. Do not weaken provenance, canonical validation, FULL synchronization, or inherited-disposition checks.
4. **Treat large catalog/publication serialization as a separate measured phase.** Preserve the strict independently validated artifact, but measure catalog reload/render/hash costs before redesigning persistence.

No production source, frozen source, live database, journal or biological input was changed. The cancelled output is not eligible for the fresh matrix12 audit/cache gate because native completion/provenance is absent and the database has a retained hot journal.
