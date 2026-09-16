# Old cold-run tail assessment

Read-only inspection of `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-benchmark-01`, HEAD **7ca64e68690f6e4db5b91f54bfe8a4847c402a62**. No live DB/output/process inspection, mutation, interruption, helper or scientific run. Parent reports the process is still in the first discovery checkpoint after final family generation; this report does not independently identify its current SQL statement or predict an ETA.

## Remaining checkpoints: exact successful path

All paths below are under `primalscheme3/panel/` in that frozen source. This is the old **v1**, 8 MiB page-cache implementation, not current optimized code.

| Stage | Call site | Full-prefix reference queries |
|---|---|---:|
| Discovery (reported currently pending) | `coverage_discovery.py:287` before returning catalog | 3 |
| Strict selection, after fresh final validation | `allele_search.py:1153` → `_finish_history:853` | 3 |
| Salvage-1 | same production search completion | 3 |
| Salvage-2 | same | 3 |
| Salvage-3 | same | 3 |
| Final publication | `allele_pipeline.py:275` | 3 |

Thus, assuming all three configured salvage stages execute successfully, **five further complete snapshots / 15 closure SQL queries after discovery**, or six snapshots / 18 queries including the pending discovery checkpoint. These are *query invocations*, not a claim that every query scans an identical number of pages.

For every snapshot, `coverage_history.py:496–524` checks cached current-prefix digests, then issues the same evidence→assessment, assessment→event and parent→event SQL joins against the entire supplied prefix. It then performs two `SELECT DISTINCT entity_id` queries: all included event entities, and newly touched entities since the prior complete snapshot. Successful path therefore has ten further DISTINCT queries after discovery (12 including discovery). The first is whole-prefix each time; the second is incremental after discovery. Inherited dispositions are recursively loaded/merged (`:235–240`), so later stages still involve the large discovery disposition mapping. New snapshot payloads contain stage-local dispositions, but validation resolves inherited mappings in memory.

Current-full prefix hashes use copies of running hash state (`:481–493`); they do **not** reread/decompress all history payloads during normal live completion. Snapshot creation calls those digests and checkpoint validation checks them again, both using cached full-prefix hashes. Closure joins and disposition queries remain the large disk work.

`_finish_history` scans/decompresses only events since the previous complete snapshot (`allele_search.py:827`) to build local dispositions. It does not intentionally rescan all discovery events. Final publication likewise scans events since the last complete snapshot (`allele_pipeline.py:265`). Snapshot insertion commits synchronously; ordinary `checkpoint()` and `close()` (`coverage_history.py:575–585`) only update committed counts and commit—they do not themselves execute the three closure queries.

### Failure-dependent extra calls

Salvage catches an ordinary `Exception`, emits failure history and writes a separate `salvage-N-failed` complete snapshot (`coverage_salvage.py:259–297`). If failure occurs **after** that tier's search snapshot, this adds another three closure queries and two DISTINCT queries on top of the tier's existing checks. If failure occurs before successful search completion, only the failure checkpoint may complete; an attempted search checkpoint may already have consumed work. A failure in the failure handler itself escapes to the pipeline. No bounded exact failure-path count is possible without the failure location. Cancellation can stop later tiers; commit-only cancellation calls do not add closure checks. No unconditional extra snapshot is created by stage publication/audit itself.

## Work after the current discovery checkpoint

1. Discovery returns the fully built in-memory catalog only **after** the snapshot succeeds. The pipeline records timing, reparses authoritative input copies, creates reference mapping, and starts strict search (`allele_pipeline.py:128–153`).
2. Strict search has its configured optimizer budget, then final validation and history completion outside that budget. Search explicitly disables the deadline for final checking (`allele_search.py:963–973`); production fresh scientific validation and snapshot completion follow. Therefore a 120 s search setting is not a 120 s stage wall-time ceiling.
3. Strict publication validates again, writes a complete catalog, ledger, targets, assignments, coverage and sequence/BED outputs into a pending directory, hashes them, reloads catalog/ledger and revalidates saved bytes, writes validation, and renames the directory to `stages/strict` (`allele_publication.py:365–464`). This involves full catalog serialization and reload **but not full history reload**.
4. Bounded salvage first independently checks the strict baseline, then performs up to three searches. Each successful stage repeats search validation/checkpoint and publication/saved-byte audit. The configured per-tier 60 s is a search budget; checkpoint, fresh validation and publication costs are additional (`coverage_salvage.py:168–258`).
5. The pipeline writes the aggregate explored configuration ledger and salvage status, selects primary, copies six selected stage text files to root, writes coverage/comparison/diagnostics, takes the final publication snapshot, closes history, writes optimizer/config metadata, then fingerprints every output for final provenance (`allele_pipeline.py:190–386`).

**No `history.export()`, `export_database()`, history backup/copy or nonempty `SQLiteCoverageHistory` reopen is called on the normal pipeline path.** The only constructor is at pipeline start (`:114`), when the fresh DB is empty. Methods for full deterministic JSONL export and SQLite backup exist in the history class but are not invoked here. Final provenance reads the whole closed DB once sequentially for SHA-256 (`coverage_provenance.py:309–314`); it does not decode/replay records. It also hashes all saved catalogs/stages. Six primary text files are copied, not the DB. An external later `panel-audit`/cache export is separate work and is not counted in the native completion path here.

## What is retained before whole-run success?

**There is no early standalone discovery catalog in 7ca.** In particular, the newer `discovery-catalog.json.gz` persistence is absent. The discovery snapshot commits IDs, catalog digest, counts and dispositions in the DB, but is not a serialized full catalog or independently published panel. Batches of evidence/events are durable before it; this does not by itself satisfy the completed-panel cache/export gate.

The first standalone full catalog file is written inside strict publication's pending directory, after strict search completes. On successful saved-byte validation and rename, `stages/strict/` contains the full catalog plus selected-stage ledger, authoritative targets, assignments, stage manifest, fresh validation and rendered outputs. This is the first complete independently audited **stage artifact**, before salvage and before overall success. The code intentionally leaves failed pending directories too; their presence alone does not certify validation. File writes/rename here are ordinary filesystem operations, not an explicit per-file fsync durability protocol; the SQLite snapshot commitment does use FULL synchronization.

Strict publication does not additionally commit all its generated validation history as a complete snapshot; those new records are committed by ordinary batch boundaries or later close/stage checkpoints. Its file-based audit result is nevertheless retained independently of whether later tiers succeed.

## Failure after strict publication

- Ordinary salvage-tier exceptions are recorded as failed tiers; the loop may continue. Already published strict files are not deleted. With strict primary, individual failed salvage tiers need not prevent successful whole-run publication.
- Pipeline-level `BaseException` handling (`allele_pipeline.py:388–408`) closes/commits history, logs the error, writes **failure** provenance over all retained files, and rethrows. It does not erase the strict or successful salvage stage directories. The aggregate root ledger is only written after `run_salvage` returns; failures before then may leave stage ledgers but no complete aggregate ledger/root optimizer.
- A strict stage surviving a failed run is not a successful whole-panel receipt. Existing cache export requires stable successful panel provenance; do not treat retained stage bytes as authorization to bypass that gate. Stage-local saved-byte inspection and any future recovery process are distinct work, not implemented or recommended here.
- Hard termination, power loss or uncatchable failure can prevent failure provenance; only already committed SQLite batches and filesystem artifacts remain. Even catchable errors are not guaranteed a receipt if `history.close()` or provenance hashing/writing itself fails: the old handler does not independently protect these secondary operations.

## Remaining risk, without an ETA

The pending expensive check is not the last whole-prefix validation: five more checkpoints on a larger history remain on a clean strict+three-tier path. Large inherited disposition processing and catalog serialization/reload also recur. There is no accidental whole-history JSON export or semantic reload in this native tail, but final DB hashing and external verification still cost sequential reads. Search budgets do not bound these costs. Available code and parent samples cannot establish per-query duration, total remaining runtime, memory headroom, or whether the reported current wait is a specific join versus another checkpoint substep. This assessment supports preserving the run and making its remaining costs explicit; it proposes no interruption, source mutation, recovery shortcut or validation bypass.
